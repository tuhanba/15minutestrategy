#!/usr/bin/env python3
"""Prop-firm challenge simulator (Upcomers Phoenix / Thunderbolt rules).

Input: the trades file (and optionally the daily file) of a FLAT-risk backtest run.
R multiples are scale free, so the simulator can re-size every trade at any risk %.

Two estimates per risk level:
  * Monte Carlo: trading days are drawn with replacement (whole days, so the order of
    trades inside a day is kept), 10 000 attempts by default.
  * Historical replay: the real trade sequence started on the first trading day of every
    month in the data.

Modelled rules (help.upcomers.com, read 2026-10-24; the user must confirm them):
  daily loss  : equity must stay above ref*(1-daily), ref = max(balance, equity) at 00:00 UTC.
                Floating loss is included; the worst intraday equity of a trade is
                balance + mae_r * risk (mae_r from the backtest, <= 0).
  max loss    : static  -> equity >= initial*(1-max)
                trailing (Dynamic Risk Shield) -> floor = max(initial*(1-max), equity_peak - max*initial),
                never above the initial balance.
  target      : closed balance >= initial*(1+target) per phase; each phase restarts at initial.
  inactivity  : 35 calendar days without a closed trade fails the account
                (trading days are converted with 7/5).
  all-or-nothing : passes that needed fewer than 5 trades in a phase are reported separately.
Positions are assumed flat at 00:00 UTC (the strategy holds for hours, rarely overnight).
"""
from __future__ import annotations

import argparse
import csv
import random
import statistics
import sys
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path


@dataclass(frozen=True)
class Program:
    name: str
    targets: tuple[float, ...]
    daily: float
    max_loss: float
    trailing: bool
    inactivity_days: int = 35


PROGRAMS = {
    "ash": Program("Ash 1-step 100k", (0.02,), 0.03, 0.06, True),
    "phoenix": Program("Phoenix 2-step 100k", (0.04, 0.04), 0.04, 0.06, False),
    "thunderbolt": Program("Thunderbolt 1-step 100k", (0.05,), 0.03, 0.06, True),
}


@dataclass
class Day:
    day: date
    trades: list[tuple[float, float]] = field(default_factory=list)  # (r, mae_r)


def _d(text: str) -> date:
    text = text.strip()
    for fmt in ("%Y.%m.%d %H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d", "%Y.%m.%d"):
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            pass
    raise ValueError(text)


def load_days(trades_path: Path, daily_path: Path | None) -> list[Day]:
    days: dict[date, Day] = {}
    if daily_path and daily_path.exists():
        with daily_path.open() as fh:
            for row in csv.DictReader(fh, delimiter=";"):
                d = _d(row["date"])
                days[d] = Day(d)
    with trades_path.open() as fh:
        for row in csv.DictReader(fh, delimiter=";"):
            d = _d(row["close_time"])
            days.setdefault(d, Day(d)).trades.append((float(row["r"]), min(0.0, float(row.get("mae_r") or -1.0))))
    return [days[k] for k in sorted(days)]


@dataclass
class Outcome:
    passed: bool = False
    reason: str = "timeout"     # passed | daily | max_loss | inactivity | timeout
    trading_days: int = 0
    trades: int = 0
    min_phase_trades: int = 10**9


def attempt(day_iter, prog: Program, risk: float, initial: float = 100000.0, max_days: int = 520) -> Outcome:
    out = Outcome()
    for target in prog.targets:
        bal = initial
        peak = initial
        floor = initial * (1 - prog.max_loss)
        phase_trades = 0
        idle_trading_days = 0
        while True:
            if out.trading_days >= max_days:
                out.reason = "timeout"
                return out
            day = next(day_iter)
            out.trading_days += 1
            ref = bal
            daily_floor = ref * (1 - prog.daily)
            if not day.trades:
                idle_trading_days += 1
                if idle_trading_days * 7 / 5 >= prog.inactivity_days:
                    out.reason = "inactivity"
                    return out
                continue
            idle_trading_days = 0
            for r, mae in day.trades:
                risk_money = risk * bal
                low = bal + mae * risk_money
                if low < daily_floor:
                    out.reason = "daily"
                    return out
                if low < floor:
                    out.reason = "max_loss"
                    return out
                bal += r * risk_money
                out.trades += 1
                phase_trades += 1
                if bal < daily_floor:
                    out.reason = "daily"
                    return out
                if bal < floor:
                    out.reason = "max_loss"
                    return out
                if prog.trailing and bal > peak:
                    peak = bal
                    floor = min(initial, max(floor, peak - prog.max_loss * initial))
                if bal >= initial * (1 + target):
                    break
            if bal >= initial * (1 + target):
                out.min_phase_trades = min(out.min_phase_trades, phase_trades)
                break
    out.passed = True
    out.reason = "passed"
    return out


def monte_carlo(days: list[Day], prog: Program, risk: float, runs: int, seed: int) -> list[Outcome]:
    rng = random.Random(seed)

    def gen():
        while True:
            yield days[rng.randrange(len(days))]

    return [attempt(gen(), prog, risk) for _ in range(runs)]


def replay(days: list[Day], prog: Program, risk: float) -> list[Outcome]:
    starts, seen = [], set()
    for i, d in enumerate(days):
        key = (d.day.year, d.day.month)
        if key not in seen:
            seen.add(key)
            starts.append(i)
    outs = []
    for s in starts:
        seq = days[s:]

        def gen(seq=seq):
            yield from seq
            while True:          # ran out of history: count as timeout
                yield Day(date.max)
        try:
            outs.append(attempt(gen(), prog, risk, max_days=len(seq)))
        except StopIteration:
            outs.append(Outcome())
    return outs


def summarize(outs: list[Outcome]) -> dict[str, float]:
    n = len(outs)
    passed = [o for o in outs if o.passed]
    res = {k: sum(1 for o in outs if o.reason == k) / n for k in ("passed", "daily", "max_loss", "inactivity", "timeout")}
    res["median_days"] = statistics.median(o.trading_days for o in passed) if passed else float("nan")
    res["median_trades"] = statistics.median(o.trades for o in passed) if passed else float("nan")
    res["few_trades"] = sum(1 for o in passed if o.min_phase_trades < 5) / n
    return res


def report(days: list[Day], program: str, risks: list[float], runs: int, seed: int) -> str:
    prog = PROGRAMS[program]
    n_trades = sum(len(d.trades) for d in days)
    lines = [f"## {prog.name}", "",
             f"history: {len(days)} trading days, {n_trades} trades "
             f"({days[0].day} -> {days[-1].day})" if days else "history: empty", "",
             "| risk/trade | method | pass | fail daily | fail max | inactivity | timeout | median trading days | median trades | pass with <5 trades in a phase |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    best = None
    for risk in risks:
        for method, outs in (("Monte Carlo", monte_carlo(days, prog, risk, runs, seed)), ("replay", replay(days, prog, risk))):
            s = summarize(outs)
            lines.append(f"| {risk:.3%} | {method} ({len(outs)}) | {s['passed']:.1%} | {s['daily']:.1%} | {s['max_loss']:.1%} | "
                         f"{s['inactivity']:.1%} | {s['timeout']:.1%} | {s['median_days']} | {s['median_trades']} | {s['few_trades']:.1%} |")
            if method == "Monte Carlo" and s["daily"] < 0.05 and (best is None or s["passed"] > best[1]):
                best = (risk, s["passed"])
    lines.append("")
    lines.append(f"Decision rule (manager D-008): highest Monte Carlo pass rate with P(daily breach) < 5% -> "
                 + (f"**{best[0]:.3%}** (pass {best[1]:.1%})" if best else "**none qualifies**"))
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trades", type=Path)
    ap.add_argument("--daily", type=Path, help="daily.csv from the backtester (adds days without trades)")
    ap.add_argument("--program", choices=sorted(PROGRAMS) + ["custom"], action="append")
    ap.add_argument("--name", default="Custom program", help="custom: display name")
    ap.add_argument("--targets", help="custom: profit target %% per phase, e.g. 8,5")
    ap.add_argument("--daily-pct", type=float, help="custom: daily loss %%")
    ap.add_argument("--max-pct", type=float, help="custom: max loss %%")
    ap.add_argument("--trailing", action="store_true", help="custom: trailing max loss locked at the initial balance")
    ap.add_argument("--inactivity-days", type=int, default=35)
    ap.add_argument("--risks", default="0.25,0.375,0.5,0.75,1.0", help="risk per trade in %%")
    ap.add_argument("--runs", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("-o", "--output", type=Path)
    args = ap.parse_args(argv)
    days = load_days(args.trades, args.daily)
    if not days:
        print("no data", file=sys.stderr)
        return 2
    risks = [float(x) / 100.0 for x in args.risks.split(",")]
    if args.program and "custom" in args.program:
        if not (args.targets and args.daily_pct and args.max_pct):
            print("custom program needs --targets --daily-pct --max-pct", file=sys.stderr)
            return 2
        PROGRAMS["custom"] = Program(args.name, tuple(float(x) / 100.0 for x in args.targets.split(",")),
                                     args.daily_pct / 100.0, args.max_pct / 100.0, args.trailing, args.inactivity_days)
    text = "# Upcomers challenge simulation\n\n" + "\n".join(
        report(days, p, risks, args.runs, args.seed) for p in (args.program or ["ash", "phoenix", "thunderbolt"]))
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
