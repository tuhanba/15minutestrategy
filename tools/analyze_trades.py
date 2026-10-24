#!/usr/bin/env python3
"""Analyze RBOTE trade files exported by the EA from the MT5 Strategy Tester.

Input: one or more `*_trades.csv` files (semicolon separated) written by
RBOTE_EA to `<Common>/Files/RBOTE/`. Each file is one tester run (for example
6R fixed stop, 5R fixed stop, 6R structural stop).

Output: a Markdown report with, per run and per period (all / in-sample /
out-of-sample):
  trades, win rate, average win/loss (R and money), net expectancy (R),
  bootstrap 95% CI of expectancy, profit factor, max equity drawdown,
  Monte Carlo drawdown percentiles, daily-loss-limit breach days,
  per-year and per-volatility-regime expectancy, and the acceptance checks.

No numbers are invented: everything is computed from the files given.
Standard library only.
"""
from __future__ import annotations

import argparse
import csv
import math
import random
import statistics
import sys
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Iterable, Sequence


@dataclass(frozen=True)
class Trade:
    open_time: datetime
    close_time: datetime
    direction: int
    risk_money: float
    net: float
    r: float
    atr: float
    rr: float
    stop_mode: int


def _parse_time(text: str) -> datetime:
    text = text.strip()
    for fmt in ("%Y.%m.%d %H:%M", "%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    raise ValueError(f"unrecognized time: {text!r}")


def load_trades(path: Path) -> list[Trade]:
    trades: list[Trade] = []
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh, delimiter=";")
        for row in reader:
            if not row.get("close_time"):
                continue
            trades.append(
                Trade(
                    open_time=_parse_time(row["open_time"]),
                    close_time=_parse_time(row["close_time"]),
                    direction=int(row["dir"]),
                    risk_money=float(row["risk_money"]),
                    net=float(row["net"]),
                    r=float(row["r"]),
                    atr=float(row.get("atr") or 0.0),
                    rr=float(row.get("rr") or 0.0),
                    stop_mode=int(row.get("stop_mode") or 0),
                )
            )
    trades.sort(key=lambda t: t.close_time)
    return trades


# --- metrics -----------------------------------------------------------------

def max_drawdown(equity: Sequence[float]) -> float:
    """Largest peak-to-trough fall of an equity curve, as a positive fraction of the peak."""
    peak = -math.inf
    worst = 0.0
    for value in equity:
        peak = max(peak, value)
        if peak > 0:
            worst = max(worst, (peak - value) / peak)
    return worst


def equity_curve(r_values: Iterable[float], risk_fraction: float, start: float = 1.0) -> list[float]:
    """Compounded equity when each trade risks `risk_fraction` of current equity."""
    eq = [start]
    for r in r_values:
        eq.append(eq[-1] * (1.0 + risk_fraction * r))
    return eq


def monte_carlo_dd(r_values: Sequence[float], risk_fraction: float, runs: int, seed: int) -> dict[str, float]:
    """Drawdown distribution from bootstrap resampling (with replacement) of the R sequence."""
    if not r_values:
        return {"p50": float("nan"), "p95": float("nan"), "p99": float("nan")}
    rng = random.Random(seed)
    n = len(r_values)
    dds = sorted(
        max_drawdown(equity_curve((r_values[rng.randrange(n)] for _ in range(n)), risk_fraction))
        for _ in range(runs)
    )

    def pct(p: float) -> float:
        return dds[min(len(dds) - 1, int(p * len(dds)))]

    return {"p50": pct(0.50), "p95": pct(0.95), "p99": pct(0.99)}


def bootstrap_mean_ci(values: Sequence[float], runs: int, seed: int) -> tuple[float, float]:
    if len(values) < 2:
        return (float("nan"), float("nan"))
    rng = random.Random(seed)
    n = len(values)
    means = sorted(sum(values[rng.randrange(n)] for _ in range(n)) / n for _ in range(runs))
    return (means[int(0.025 * runs)], means[min(runs - 1, int(0.975 * runs))])


def daily_breaches(trades: Sequence[Trade], start_balance: float, daily_limit_frac: float) -> list[date]:
    """Days whose realized net loss reached the daily limit (closed trades only; floating not modelled)."""
    by_day: dict[date, float] = {}
    for t in trades:
        by_day[t.close_time.date()] = by_day.get(t.close_time.date(), 0.0) + t.net
    limit = daily_limit_frac * start_balance
    return sorted(d for d, pnl in by_day.items() if pnl <= -limit)


@dataclass
class Summary:
    n: int
    win_rate: float
    avg_win_r: float
    avg_loss_r: float
    avg_win_money: float
    avg_loss_money: float
    expectancy_r: float
    ci_low: float
    ci_high: float
    profit_factor: float
    net_money: float
    max_dd: float
    mc: dict[str, float]
    breach_days: int


def summarize(trades: Sequence[Trade], risk_fraction: float, start_balance: float,
              daily_limit_frac: float, runs: int = 5000, seed: int = 7) -> Summary:
    rs = [t.r for t in trades]
    wins = [t for t in trades if t.net > 0]
    losses = [t for t in trades if t.net <= 0]
    gross_win = sum(t.net for t in wins)
    gross_loss = -sum(t.net for t in losses)
    money_eq = [start_balance]
    for t in trades:
        money_eq.append(money_eq[-1] + t.net)
    lo, hi = bootstrap_mean_ci(rs, runs, seed)
    return Summary(
        n=len(trades),
        win_rate=len(wins) / len(trades) if trades else float("nan"),
        avg_win_r=statistics.fmean(t.r for t in wins) if wins else float("nan"),
        avg_loss_r=statistics.fmean(t.r for t in losses) if losses else float("nan"),
        avg_win_money=statistics.fmean(t.net for t in wins) if wins else float("nan"),
        avg_loss_money=statistics.fmean(t.net for t in losses) if losses else float("nan"),
        expectancy_r=statistics.fmean(rs) if rs else float("nan"),
        ci_low=lo,
        ci_high=hi,
        profit_factor=(gross_win / gross_loss) if gross_loss > 0 else (math.inf if gross_win > 0 else float("nan")),
        net_money=sum(t.net for t in trades),
        max_dd=max_drawdown(money_eq),
        mc=monte_carlo_dd(rs, risk_fraction, runs // 5 or 1, seed),
        breach_days=len(daily_breaches(trades, start_balance, daily_limit_frac)),
    )


def group_expectancy(trades: Sequence[Trade], key) -> dict[str, tuple[int, float]]:
    groups: dict[str, list[float]] = {}
    for t in trades:
        groups.setdefault(key(t), []).append(t.r)
    return {k: (len(v), statistics.fmean(v)) for k, v in sorted(groups.items())}


def volatility_regimes(trades: Sequence[Trade]) -> dict[str, tuple[int, float]]:
    """Terciles of ATR at the signal (low / mid / high volatility)."""
    atrs = sorted(t.atr for t in trades if t.atr > 0)
    if len(atrs) < 3:
        return {}
    lo_cut = atrs[len(atrs) // 3]
    hi_cut = atrs[2 * len(atrs) // 3]

    def label(t: Trade) -> str:
        if t.atr <= 0:
            return "unknown"
        if t.atr < lo_cut:
            return "1-low"
        if t.atr < hi_cut:
            return "2-mid"
        return "3-high"

    return group_expectancy(trades, label)


# --- acceptance --------------------------------------------------------------

@dataclass
class Criteria:
    min_trades: int = 100
    min_pf: float = 1.30
    max_mc_dd95: float = 0.10
    min_oos_vs_is: float = 0.50
    min_positive_years: float = 0.60


def acceptance(is_s: Summary | None, oos_s: Summary, years: dict[str, tuple[int, float]],
               crit: Criteria) -> list[tuple[str, bool, str]]:
    checks: list[tuple[str, bool, str]] = []
    checks.append((f"OOS trades >= {crit.min_trades}", oos_s.n >= crit.min_trades, str(oos_s.n)))
    checks.append(("OOS net expectancy > 0", oos_s.expectancy_r > 0, f"{oos_s.expectancy_r:.3f}R"))
    checks.append(("OOS bootstrap 95% CI low > 0", oos_s.ci_low > 0, f"{oos_s.ci_low:.3f}R"))
    checks.append((f"OOS profit factor >= {crit.min_pf}", oos_s.profit_factor >= crit.min_pf, f"{oos_s.profit_factor:.2f}"))
    checks.append((f"OOS Monte Carlo DD p95 < {crit.max_mc_dd95:.0%}", oos_s.mc["p95"] < crit.max_mc_dd95,
                   f"{oos_s.mc['p95']:.2%}"))
    if is_s is not None and is_s.n > 0 and is_s.expectancy_r > 0:
        ratio = oos_s.expectancy_r / is_s.expectancy_r
        checks.append((f"OOS expectancy >= {crit.min_oos_vs_is:.0%} of IS", ratio >= crit.min_oos_vs_is, f"{ratio:.2f}"))
    else:
        checks.append(("OOS expectancy vs IS", False, "IS expectancy not positive / no IS"))
    if years:
        share = sum(1 for _, (_, e) in years.items() if e > 0) / len(years)
        checks.append((f"positive years >= {crit.min_positive_years:.0%}", share >= crit.min_positive_years, f"{share:.0%}"))
    return checks


# --- report ------------------------------------------------------------------

def _fmt(x: float, spec: str) -> str:
    return "n/a" if x is None or (isinstance(x, float) and math.isnan(x)) else format(x, spec)


def summary_row(name: str, s: Summary) -> str:
    return (f"| {name} | {s.n} | {_fmt(s.win_rate, '.1%')} | {_fmt(s.avg_win_r, '.2f')} | {_fmt(s.avg_loss_r, '.2f')} | "
            f"{_fmt(s.expectancy_r, '.3f')} | [{_fmt(s.ci_low, '.3f')}, {_fmt(s.ci_high, '.3f')}] | "
            f"{_fmt(s.profit_factor, '.2f')} | {_fmt(s.net_money, ',.2f')} | {_fmt(s.max_dd, '.2%')} | "
            f"{_fmt(s.mc['p95'], '.2%')} | {s.breach_days} |")


HEADER = ("| run / period | trades | win % | avg win R | avg loss R | expectancy R | 95% CI | PF | net | max DD | MC DD p95 | daily-limit days |\n"
          "|---|---|---|---|---|---|---|---|---|---|---|---|")


def build_report(runs: dict[str, list[Trade]], oos_start: datetime | None, risk_fraction: float,
                 start_balance: float, daily_limit_frac: float, crit: Criteria) -> str:
    out = ["# RBOTE backtest analysis", ""]
    out.append(f"risk per trade for Monte Carlo: {risk_fraction:.2%} | start balance: {start_balance:,.0f} | "
               f"daily limit: {daily_limit_frac:.2%} | OOS from: {oos_start.date() if oos_start else 'not split'}")
    out.append("")
    out.append("Daily-limit days count CLOSED-trade losses only; intraday floating losses are not in the trade files.")
    out.append("")
    out.append(HEADER)
    verdicts: list[str] = []
    for name, trades in runs.items():
        all_s = summarize(trades, risk_fraction, start_balance, daily_limit_frac)
        out.append(summary_row(f"{name} / all", all_s))
        if oos_start is not None:
            is_t = [t for t in trades if t.open_time < oos_start]
            oos_t = [t for t in trades if t.open_time >= oos_start]
            is_s = summarize(is_t, risk_fraction, start_balance, daily_limit_frac)
            oos_s = summarize(oos_t, risk_fraction, start_balance, daily_limit_frac)
            out.append(summary_row(f"{name} / IS", is_s))
            out.append(summary_row(f"{name} / OOS", oos_s))
        else:
            is_s, oos_s = None, all_s
        years = group_expectancy(trades, lambda t: str(t.open_time.year))
        checks = acceptance(is_s, oos_s, years, crit)
        passed = all(ok for _, ok, _ in checks)
        verdicts.append(f"## {name}: {'PASS' if passed else 'FAIL'}")
        verdicts.extend(f"- [{'x' if ok else ' '}] {label}: {value}" for label, ok, value in checks)
        verdicts.append("")
        verdicts.append("| year | trades | expectancy R |")
        verdicts.append("|---|---|---|")
        verdicts.extend(f"| {k} | {n} | {e:.3f} |" for k, (n, e) in years.items())
        regimes = volatility_regimes(trades)
        if regimes:
            verdicts.append("")
            verdicts.append("| volatility (ATR tercile) | trades | expectancy R |")
            verdicts.append("|---|---|---|")
            verdicts.extend(f"| {k} | {n} | {e:.3f} |" for k, (n, e) in regimes.items())
        dirs = group_expectancy(trades, lambda t: "long" if t.direction > 0 else "short")
        verdicts.append("")
        verdicts.append("| direction | trades | expectancy R |")
        verdicts.append("|---|---|---|")
        verdicts.extend(f"| {k} | {n} | {e:.3f} |" for k, (n, e) in dirs.items())
        verdicts.append("")
    out.append("")
    out.extend(verdicts)
    out.append("A run is only a candidate for demo testing when every check passes. "
               "FAIL or too few trades means the strategy is NOT validated.")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", type=Path, help="trades CSV files (name=path to label a run)")
    ap.add_argument("--oos-start", help="first date of the out-of-sample period, YYYY-MM-DD")
    ap.add_argument("--risk-pct", type=float, default=0.25, help="risk per trade in %% for Monte Carlo (default 0.25)")
    ap.add_argument("--balance", type=float, default=100000.0, help="start balance (default 100000)")
    ap.add_argument("--daily-limit-pct", type=float, default=1.0, help="daily loss limit in %% (default 1.0)")
    ap.add_argument("--min-trades", type=int, default=100)
    ap.add_argument("--mc-dd95-max-pct", type=float, default=10.0)
    ap.add_argument("-o", "--output", type=Path, help="write the Markdown report here")
    args = ap.parse_args(argv)

    runs: dict[str, list[Trade]] = {}
    for item in args.files:
        text = str(item)
        name, _, path = text.partition("=") if "=" in text else (Path(text).stem, "", text)
        runs[name] = load_trades(Path(path))
    oos = datetime.strptime(args.oos_start, "%Y-%m-%d") if args.oos_start else None
    crit = Criteria(min_trades=args.min_trades, max_mc_dd95=args.mc_dd95_max_pct / 100.0)
    report = build_report(runs, oos, args.risk_pct / 100.0, args.balance, args.daily_limit_pct / 100.0, crit)
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
