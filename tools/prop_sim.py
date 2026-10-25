#!/usr/bin/env python3
"""Prop-firm challenge simulator (Upcomers Ash Turbo / Ash / Phoenix / Thunderbolt rules).

Input: the trades file (and the daily file) of a FLAT-risk backtest run.
Every trade is re-sized at the simulated risk %:

    risk_money = risk * balance * size_mult
    P&L        = r * risk_money          (r = net / trade_risk of the backtest trade)

size_mult = trade_risk / (risk_pct/100 * balance at entry) of the backtest trade. It carries the
regime multiplier (x0.5) and the lot rounding of the backtest into the simulation (1.0 when the
columns are missing). Approximation: the backtest sized from min(balance, equity) and rounded lots
at its own risk; the simulator scales that ratio linearly to the simulated balance and risk.

Two estimates per risk level:
  * Monte Carlo: moving-block bootstrap of consecutive days (default 5 days = one trading week,
    manager D-028), 10 000 attempts by default. Days keep their trade order; each sampled day
    keeps its real calendar gap to the previous day, so weekends and holidays are carried.
  * Historical replay: the real day sequence started on every weekday of the history (or on the
    first day of every month). Starts that run out of history before the attempt ends are
    CENSORED: reported separately, excluded from the rates.

Modelled rules (help.upcomers.com, read 2026-10-24; the user must confirm them):
  daily loss  : equity must stay above ref - daily * (initial or ref), ref = balance at 00:00 UTC
                (positions are assumed flat at midnight). Floating loss is included: the worst
                intraday equity of a trade is balance + mae_r * risk_money (mae_r <= 0).
  max loss    : static  -> equity >= initial * (1 - max)
                trailing (Dynamic Risk Shield) -> floor = max(initial*(1-max), equity_peak - max*initial),
                optionally locked at the initial balance. The equity peak includes the intraday
                favourable excursion: per trade the peak is raised to balance + mfe_r * risk_money
                BEFORE the adverse excursion / stop is applied (conservative ordering).
  target      : closed balance >= initial * (1 + target) per phase; each phase restarts at initial.
  inactivity  : 35 calendar days (real dates) without a closed trade fails the account.
  time limits : calendar days use real dates (fail when date >= start + N days);
                weekday limit counts Mon-Fri dates since the start;
                active-day limit counts days with >= 1 closed trade (Ash Turbo: 7).
  personal EA guards (tracked and reported only, the attempt is not stopped): daily loss of
                `personal_daily` of the day reference, and the equity-peak trailing floor
                peak * (1 - personal_dd).
  all-or-nothing : passes that needed fewer than 5 trades (and exactly 1 trade) are reported.
"""
from __future__ import annotations

import argparse
import bisect
import csv
import random
import statistics
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path

PRESET_MAX_RISK = 0.005     # RBOTE_AshTurbo preset: InpMaxRiskPct 0.5 and open risk 0.5
SELECTION_CAP = 0.0035      # D-020/D-027: no single-win pass until Upcomers confirms it is allowed
DEFAULT_GRID = (0.0025, 0.003, 0.0035, 0.004, 0.005)   # D-027


@dataclass(frozen=True)
class Program:
    name: str
    targets: tuple[float, ...]
    daily: float
    max_loss: float
    trailing: bool
    inactivity_days: int = 35
    time_limit_days: int = 0          # calendar days for the whole challenge, 0 = unlimited
    time_limit_trading_days: int = 0  # Mon-Fri dates for the whole challenge, 0 = unlimited
    max_active_days: int = 0          # days with >= 1 closed trade allowed (Ash Turbo: 7), 0 = unlimited
    daily_on_initial: bool = False    # daily limit amount = daily * initial balance (fixed $), not * day reference
    lock_at_initial: bool = True      # trailing floor never above the initial balance


PROGRAMS = {
    "ash": Program("Ash 1-step 100k", (0.02,), 0.03, 0.06, True),
    # Ash Turbo (manager D-016..D-022): 2% target, daily 3% of the initial balance (3 000 $), 6% shield
    # from the equity peak (lock not stated -> unlocked), at most 7 trading days (= days with a closed
    # trade) within 30 calendar days.
    "ash_turbo": Program("Ash Turbo 100k (7 trading days / 30 calendar days)", (0.02,), 0.03, 0.06, True,
                         35, 30, 0, 7, True, False),
    # conservative reading (D-022 scenario 2): the challenge ends after 7 weekdays
    "ash_turbo_strict": Program("Ash Turbo 100k (strict: 7 weekdays)", (0.02,), 0.03, 0.06, True,
                                35, 0, 7, 0, True, False),
    "phoenix": Program("Phoenix 2-step 100k", (0.04, 0.04), 0.04, 0.06, False),
    "thunderbolt": Program("Thunderbolt 1-step 100k", (0.05,), 0.03, 0.06, True),
}


@dataclass(frozen=True)
class SimTrade:
    r: float
    mae: float = -1.0     # <= 0, in R
    mfe: float = 0.0      # >= 0, in R
    size: float = 1.0     # size multiplier relative to the flat risk (regime x0.5, lot rounding)


@dataclass
class Day:
    day: date
    trades: list = field(default_factory=list)   # SimTrade or (r, mae[, mfe[, size]]) tuples


def _trade(t) -> SimTrade:
    if isinstance(t, SimTrade):
        return t
    r, mae = float(t[0]), min(0.0, float(t[1]))
    mfe = max(0.0, float(t[2])) if len(t) > 2 else max(0.0, r)
    size = float(t[3]) if len(t) > 3 else 1.0
    return SimTrade(r, mae, mfe, size)


def _d(text: str) -> date:
    text = text.strip()
    for fmt in ("%Y.%m.%d %H:%M", "%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d", "%Y.%m.%d"):
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            pass
    raise ValueError(text)


def _dt(text: str) -> datetime:
    text = text.strip()
    for fmt in ("%Y.%m.%d %H:%M", "%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            pass
    return datetime.combine(_d(text), datetime.min.time())


def _f(row: dict, key: str, default: float) -> float:
    v = (row.get(key) or "").strip()
    return float(v) if v else default


def load_days(trades_path: Path, daily_path: Path | None, start_balance: float | None = None) -> list[Day]:
    days: dict[date, Day] = {}
    if daily_path and daily_path.exists():
        with daily_path.open() as fh:
            for row in csv.DictReader(fh, delimiter=";"):
                d = _d(row["date"])
                days[d] = Day(d)
                if start_balance is None and row.get("start_balance"):
                    start_balance = float(row["start_balance"])
    if start_balance is None:
        start_balance = 100000.0
    with trades_path.open() as fh:
        rows = [r for r in csv.DictReader(fh, delimiter=";") if r.get("close_time")]
    rows.sort(key=lambda r: _dt(r["close_time"]))
    close_times = [_dt(r["close_time"]) for r in rows]
    cum = [0.0]
    for r in rows:
        cum.append(cum[-1] + _f(r, "net", 0.0))
    for row in rows:
        r = float(row["r"])
        size = 1.0
        risk_money, pct = _f(row, "risk_money", 0.0), _f(row, "risk_pct", 0.0)
        if risk_money > 0 and pct > 0 and row.get("open_time"):
            t_open = _dt(row["open_time"])
            bal = start_balance + cum[bisect.bisect_right(close_times, t_open)]
            if bal > 0:
                size = min(2.0, max(0.0, risk_money / (pct / 100.0 * bal)))
        d = _d(row["close_time"])
        days.setdefault(d, Day(d)).trades.append(
            SimTrade(r, min(0.0, _f(row, "mae_r", -1.0)), max(0.0, _f(row, "mfe_r", max(0.0, r))), size))
    return [days[k] for k in sorted(days)]


@dataclass
class Outcome:
    passed: bool = False
    reason: str = "timeout"     # passed | daily | max_loss | inactivity | timeout | censored
    trading_days: int = 0       # day entries processed
    calendar_days: int = 0      # real calendar days from the first day (inclusive)
    active_days: int = 0        # days with >= 1 closed trade
    trades: int = 0
    min_phase_trades: int = 10**9
    personal_daily_hit: bool = False
    personal_dd_hit: bool = False


def _weekdays(a: date, b: date) -> int:
    """Number of Mon-Fri dates in [a, b]."""
    if b < a:
        return 0
    n = (b - a).days + 1
    full, rem = divmod(n, 7)
    return full * 5 + sum(1 for i in range(rem) if (a + timedelta(days=i)).weekday() < 5)


def attempt(day_iter, prog: Program, risk: float, initial: float = 100000.0, max_calendar_days: int = 1100,
            personal_daily: float = 0.02, personal_dd: float = 0.04) -> Outcome:
    out = Outcome()
    start: date | None = None
    for target in prog.targets:
        bal = initial
        peak = initial
        ppeak = initial          # personal (EA) equity peak, restarts with each phase account
        floor = initial * (1 - prog.max_loss)
        phase_trades = 0
        last_activity: date | None = None
        while True:
            try:
                day = next(day_iter)
            except StopIteration:
                out.reason = "censored"
                return out
            if start is None:
                start = day.day
            if last_activity is None:
                last_activity = day.day
            if prog.time_limit_days and day.day >= start + timedelta(days=prog.time_limit_days):
                out.reason = "timeout"
                return out
            if prog.time_limit_trading_days and _weekdays(start, day.day) > prog.time_limit_trading_days:
                out.reason = "timeout"
                return out
            if (day.day - start).days >= max_calendar_days:
                out.reason = "timeout"
                return out
            if (day.day - last_activity).days >= prog.inactivity_days:
                out.reason = "inactivity"
                return out
            out.trading_days += 1
            out.calendar_days = (day.day - start).days + 1
            if not day.trades:
                continue
            ref = bal
            daily_floor = ref - prog.daily * (initial if prog.daily_on_initial else ref)
            personal_floor = ref * (1 - personal_daily)
            last_activity = day.day
            reached = False
            for raw in day.trades:
                t = _trade(raw)
                risk_money = risk * bal * t.size
                # equity peak first (conservative): the favourable excursion raises the shield floor
                top = bal + t.mfe * risk_money
                ppeak = max(ppeak, top)
                if prog.trailing and top > peak:
                    peak = top
                    floor = max(floor, peak - prog.max_loss * initial)
                    if prog.lock_at_initial:
                        floor = min(initial, floor)
                low = bal + t.mae * risk_money
                if low < personal_floor:
                    out.personal_daily_hit = True
                if low < ppeak * (1 - personal_dd):
                    out.personal_dd_hit = True
                if low < daily_floor:
                    out.reason = "daily"
                    return out
                if low < floor:
                    out.reason = "max_loss"
                    return out
                bal += t.r * risk_money
                out.trades += 1
                phase_trades += 1
                if bal < daily_floor:
                    out.reason = "daily"
                    return out
                if bal < floor:
                    out.reason = "max_loss"
                    return out
                ppeak = max(ppeak, bal)
                if prog.trailing and bal > peak:
                    peak = bal
                    floor = max(floor, peak - prog.max_loss * initial)
                    if prog.lock_at_initial:
                        floor = min(initial, floor)
                if bal >= initial * (1 + target):
                    reached = True
                    break
            out.active_days += 1
            if reached:
                out.min_phase_trades = min(out.min_phase_trades, phase_trades)
                break
            if prog.max_active_days and out.active_days >= prog.max_active_days:
                out.reason = "timeout"
                return out
    out.passed = True
    out.reason = "passed"
    return out


def block_days(days: list[Day], block: int, rng: random.Random):
    """Endless moving-block bootstrap of consecutive days with their real calendar gaps."""
    n = len(days)
    block = max(1, min(block, n))
    cur: date | None = None
    while True:
        s = rng.randrange(n - block + 1)
        for i in range(s, s + block):
            if cur is None:
                cur = days[i].day
            else:
                # gap to the day's own predecessor in the history (also at a block boundary)
                gap = (days[i].day - days[i - 1].day) if i > 0 else timedelta(days=1)
                cur = cur + max(gap, timedelta(days=1))
            yield Day(cur, days[i].trades)


def monte_carlo(days: list[Day], prog: Program, risk: float, runs: int, seed: int, block: int = 5) -> list[Outcome]:
    rng = random.Random(seed)
    return [attempt(block_days(days, block, rng), prog, risk) for _ in range(runs)]


def replay_starts(days: list[Day], step: str = "day") -> list[int]:
    if step == "month":
        starts, seen = [], set()
        for i, d in enumerate(days):
            key = (d.day.year, d.day.month)
            if key not in seen:
                seen.add(key)
                starts.append(i)
        return starts
    return [i for i, d in enumerate(days) if d.day.weekday() < 5]


def replay(days: list[Day], prog: Program, risk: float, step: str = "day") -> list[Outcome]:
    return [attempt(iter(days[s:]), prog, risk) for s in replay_starts(days, step)]


def summarize(outs: list[Outcome]) -> dict[str, float]:
    done = [o for o in outs if o.reason != "censored"]
    n = len(done)
    res: dict[str, float] = {"n": float(n), "censored": float(len(outs) - n)}
    for k in ("passed", "daily", "max_loss", "inactivity", "timeout"):
        res[k] = sum(1 for o in done if o.reason == k) / n if n else float("nan")
    passed = [o for o in done if o.passed]
    res["median_days"] = statistics.median(o.calendar_days for o in passed) if passed else float("nan")
    res["median_active"] = statistics.median(o.active_days for o in passed) if passed else float("nan")
    res["median_trades"] = statistics.median(o.trades for o in passed) if passed else float("nan")
    res["single_trade"] = sum(1 for o in passed if o.min_phase_trades == 1) / n if n else float("nan")
    res["few_trades"] = sum(1 for o in passed if o.min_phase_trades < 5) / n if n else float("nan")
    res["personal_daily"] = sum(1 for o in done if o.personal_daily_hit) / n if n else float("nan")
    res["personal_dd"] = sum(1 for o in done if o.personal_dd_hit) / n if n else float("nan")
    return res


def _p(x: float) -> str:
    return "n/a" if x != x else f"{x:.1%}"


def _m(x: float) -> str:
    return "n/a" if x != x else f"{x:g}"


TABLE_HEAD = ("| risk/trade | method | pass | fail daily | fail max | inactivity | timeout | censored | "
              "median calendar days | median active days | median trades | 1-trade pass | <5-trade pass | "
              "personal daily hit | personal DD hit |\n"
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")


def _row(risk: float, method: str, s: dict[str, float]) -> str:
    return (f"| {risk:.3%} | {method} ({int(s['n'])}) | {_p(s['passed'])} | {_p(s['daily'])} | {_p(s['max_loss'])} | "
            f"{_p(s['inactivity'])} | {_p(s['timeout'])} | {int(s['censored'])} | {_m(s['median_days'])} | "
            f"{_m(s['median_active'])} | {_m(s['median_trades'])} | {_p(s['single_trade'])} | {_p(s['few_trades'])} | "
            f"{_p(s['personal_daily'])} | {_p(s['personal_dd'])} |")


def evaluate(days: list[Day], program: str, risks: list[float], runs: int, seed: int, block: int = 5,
             step: str = "day") -> dict[float, dict[str, dict[str, float]]]:
    prog = PROGRAMS[program]
    return {risk: {"mc": summarize(monte_carlo(days, prog, risk, runs, seed, block)),
                   "replay": summarize(replay(days, prog, risk, step))} for risk in risks}


def decide(results: dict[float, dict[str, dict[str, float]]], cap: float | None = None) -> tuple[float, float] | None:
    """D-020/D-022/D-027: highest Monte Carlo pass rate with P(daily) < 5% and P(max loss) < 10%; ties -> lower risk."""
    best = None
    for risk in sorted(results):
        if cap is not None and risk > cap + 1e-12:
            continue
        s = results[risk]["mc"]
        if s["daily"] < 0.05 and s["max_loss"] < 0.10 and (best is None or s["passed"] > best[1] + 1e-12):
            best = (risk, s["passed"])
    return best


def report(days: list[Day], program: str, risks: list[float], runs: int, seed: int, block: int = 5,
           validation: list[Day] | None = None, allow_above_cap: bool = False, step: str = "day",
           labels: tuple[str, str] = ("decision sample", "validation sample")) -> str:
    """Decision computed ONCE on `days`; `validation` (e.g. OOS) is only shown for the same risks."""
    prog = PROGRAMS[program]
    skipped = [r for r in risks if r > PRESET_MAX_RISK + 1e-12 and not allow_above_cap]
    risks = [r for r in risks if r not in skipped]

    def hist(ds: list[Day]) -> str:
        if not ds:
            return "history: empty"
        return (f"history: {len(ds)} days, {sum(len(d.trades) for d in ds)} trades ({ds[0].day} -> {ds[-1].day}); "
                f"Monte Carlo: {runs} attempts, {block}-day moving blocks; replay: every "
                f"{'weekday' if step == 'day' else 'month start'}")

    lines = [f"## {prog.name}", "", f"{labels[0]}: {hist(days)}", ""]
    if skipped:
        lines += [f"Risks above the preset cap {PRESET_MAX_RISK:.2%} not simulated: "
                  + ", ".join(f"{r:.2%}" for r in skipped) + " (pass allow_above_cap to include them).", ""]
    if not days or not any(d.trades for d in days) or not risks:
        return "\n".join(lines + ["no trades / no risks", ""])
    res = evaluate(days, program, risks, runs, seed, block, step)
    lines += [TABLE_HEAD]
    for risk in risks:
        lines.append(_row(risk, "Monte Carlo", res[risk]["mc"]))
        lines.append(_row(risk, "replay", res[risk]["replay"]))
    best, capped = decide(res), decide(res, SELECTION_CAP)
    val = None
    if validation and any(d.trades for d in validation):
        val_risks = sorted({x[0] for x in (best, capped) if x})
        if val_risks:
            val = evaluate(validation, program, val_risks, runs, seed, block, step)
            lines += ["", f"{labels[1]} (validation only, NOT used for the decision): {hist(validation)}", "", TABLE_HEAD]
            for risk in val_risks:
                lines.append(_row(risk, "Monte Carlo", val[risk]["mc"]))
                lines.append(_row(risk, "replay", val[risk]["replay"]))

    def verdict(x):
        if not x:
            return "**none qualifies**"
        txt = f"**{x[0]:.3%}** (pass {x[1]:.1%}"
        s = res[x[0]]["mc"]
        txt += f", personal daily guard hit {_p(s['personal_daily'])}, personal trailing guard hit {_p(s['personal_dd'])}"
        if val and x[0] in val:
            txt += f"; validation pass {_p(val[x[0]]['mc']['passed'])}"
        return txt + ")"

    lines += ["", f"Decision rule (manager D-020/D-022/D-027), computed once on the {labels[0]}: highest Monte Carlo pass "
              "rate with P(daily breach) < 5% and P(max-loss breach) < 10%, ties -> lower risk:",
              f"- executable grid (<= {PRESET_MAX_RISK:.2%}): {verdict(best)}",
              f"- capped at {SELECTION_CAP:.2%} until Upcomers confirms that passing with a single win is allowed "
              f"(**this is the risk to use**): {verdict(capped)}",
              "- additional constraints of the EA (reported, not part of the rule): personal daily guard "
              "(2% of the day reference) and personal trailing floor (equity peak - 4%); a hit means the EA "
              "would have stopped trading for the day / for good in that attempt."]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trades", type=Path)
    ap.add_argument("--daily", type=Path, help="daily.csv from the backtester (adds days without trades)")
    ap.add_argument("--validation-trades", type=Path, help="second (e.g. OOS) trades file, shown as validation only")
    ap.add_argument("--validation-daily", type=Path)
    ap.add_argument("--program", choices=sorted(PROGRAMS) + ["custom"], action="append")
    ap.add_argument("--name", default="Custom program", help="custom: display name")
    ap.add_argument("--targets", help="custom: profit target %% per phase, e.g. 8,5")
    ap.add_argument("--daily-pct", type=float, help="custom: daily loss %%")
    ap.add_argument("--max-pct", type=float, help="custom: max loss %%")
    ap.add_argument("--trailing", action="store_true", help="custom: trailing max loss locked at the initial balance")
    ap.add_argument("--inactivity-days", type=int, default=35)
    ap.add_argument("--time-limit-days", type=int, default=0, help="custom: calendar-day limit (0 = none)")
    ap.add_argument("--time-limit-trading-days", type=int, default=0, help="custom: weekday limit (0 = none)")
    ap.add_argument("--max-active-days", type=int, default=0, help="custom: days with a closed trade (0 = none)")
    ap.add_argument("--risks", default=",".join(f"{r * 100:g}" for r in DEFAULT_GRID), help="risk per trade in %%")
    ap.add_argument("--allow-above-cap", action="store_true",
                    help=f"also simulate risks above the preset cap {PRESET_MAX_RISK:.2%}")
    ap.add_argument("--runs", type=int, default=10000)
    ap.add_argument("--block", type=int, default=5, help="Monte Carlo block length in days (default 5)")
    ap.add_argument("--replay-step", choices=("day", "month"), default="day")
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("-o", "--output", type=Path)
    args = ap.parse_args(argv)
    days = load_days(args.trades, args.daily)
    if not days:
        print("no data", file=sys.stderr)
        return 2
    val = load_days(args.validation_trades, args.validation_daily) if args.validation_trades else None
    risks = [float(x) / 100.0 for x in args.risks.split(",")]
    if args.program and "custom" in args.program:
        if not (args.targets and args.daily_pct and args.max_pct):
            print("custom program needs --targets --daily-pct --max-pct", file=sys.stderr)
            return 2
        PROGRAMS["custom"] = Program(args.name, tuple(float(x) / 100.0 for x in args.targets.split(",")),
                                     args.daily_pct / 100.0, args.max_pct / 100.0, args.trailing, args.inactivity_days,
                                     args.time_limit_days, args.time_limit_trading_days, args.max_active_days)
    text = "# Upcomers challenge simulation\n\n" + "\n".join(
        report(days, p, risks, args.runs, args.seed, args.block, val, args.allow_above_cap, args.replay_step)
        for p in (args.program or ["ash_turbo", "ash_turbo_strict", "ash", "phoenix", "thunderbolt"]))
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
