#!/usr/bin/env python3
"""Run the pre-registered research plan (manager decisions D-004 ... D-009) end to end.

  A  variants V0..V4 on IS (2020-2023) and OOS (2024 -> end); selection on IS only
     sensitivity grid (report only) and cost sensitivity
  D  trade management M0..M4 on the selected variant
  C  Upcomers challenge simulation on the selected flat-risk variant

Selection rules are coded here so they cannot be changed after looking at results.
Writes reports/research.md and keeps every run's trades/daily files under reports/runs/.
"""
from __future__ import annotations

import argparse
import glob
import statistics
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import analyze_trades as at  # noqa: E402
import prop_sim as ps  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
IS = ("2020-01-01", "2024-01-01")
OOS = ("2024-01-01", "2026-10-24")

BASE = ["--stop", "fixed", "--stop-dist", "10", "--stop-unit", "price", "--rr", "6",
        "--regime", "neutral", "--adaptive", "off", "--risk", "0.25", "--daily", "1.0",
        "--open-risk", "0.5", "--max-dd", "4.0", "--dd-trailing", "on", "--commission", "6", "--slip-ticks", "10",
        "--friday-cutoff", "20"]

VARIANTS = {
    "V0_fixed10_6R": [],
    "V1_fixed10_5R": ["--rr", "5"],
    "V2_structural_6R": ["--stop", "structural", "--buffer", "0.30"],
}
MGMT = {
    "M0_none": [],
    "M1_BE_at_2R": ["--be-r", "2", "--be-offset-r", "0.1"],
    "M2_BE_at_3R": ["--be-r", "3", "--be-offset-r", "0.1"],
    "M3_half_at_3R": ["--partial-r", "3", "--partial-frac", "0.5"],
    "M4_trail_2R_after_3R": ["--trail-start-r", "3", "--trail-r", "2"],
}


def run_bt(binary: Path, data: list[str], name: str, period: tuple[str, str], args: list[str], outdir: Path):
    tag = f"{name}__{period[0][:4]}_{period[1][:4]}"
    trades, daily, summ = outdir / f"{tag}_trades.csv", outdir / f"{tag}_daily.csv", outdir / f"{tag}_summary.txt"
    if not trades.exists():
        cmd = [str(binary)] + sum((["--data", f] for f in data), []) + ["--from", period[0], "--to", period[1]] + BASE + args + [
            "--out-trades", str(trades), "--out-daily", str(daily), "--out-summary", str(summ)]
        subprocess.run(cmd, check=True, capture_output=True)
    return tag, trades, daily, summ


def stats(trades_path: Path) -> at.Summary:
    return at.summarize(at.load_trades(trades_path), 0.0025, 100000.0, 0.01, runs=2000)


def row(name: str, s: at.Summary) -> str:
    return at.summary_row(name, s)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data", default=str(ROOT / "data/XAUUSD_M1_*.csv"))
    ap.add_argument("--out", type=Path, default=ROOT / "reports")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--mc-runs", type=int, default=10000)
    args = ap.parse_args(argv)

    data = sorted(glob.glob(args.data))
    if not data:
        print("no data files", file=sys.stderr)
        return 2
    runs_dir = args.out / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)
    binary = ROOT / "build/rbote_bt"
    subprocess.run(["g++", "-std=c++17", "-O2", "-x", "c++", str(ROOT / "backtest/rbote_bt.cpp"), "-o", str(binary)], check=True)

    jobs = {}
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        def submit(name, period, extra):
            jobs[(name, period)] = pool.submit(run_bt, binary, data, name, period, extra, runs_dir)

        for v, extra in VARIANTS.items():
            for p in (IS, OOS):
                submit(v, p, extra)
        for stop in ("5", "10", "15"):
            for fib in ("0.705", "0.79"):
                for wick in ("0.4", "0.5", "0.6"):
                    submit(f"G_stop{stop}_fib{fib}_wick{wick}", IS, ["--stop-dist", stop, "--fib", fib, "--wick", wick])
        res = {k: f.result() for k, f in jobs.items()}

    out = [f"# RBOTE research report ({datetime.utcnow():%Y-%m-%d %H:%M} UTC)", "",
           "Pre-registered plan: manager decisions D-004..D-009. Data: Dukascopy XAUUSD M1 bid/ask (UTC).",
           f"IS {IS[0]} -> {IS[1]}, OOS {OOS[0]} -> {OOS[1]} (exclusive end). Costs: commission 6 $/lot RT, "
           "SL slippage 10 ticks, real M1 spread. Risk 0.25% flat unless stated.", "",
           "## A. Variants", "", at.HEADER]
    summaries = {}
    for v in VARIANTS:
        for p, label in ((IS, "IS"), (OOS, "OOS")):
            s = stats(res[(v, p)][1])
            summaries[(v, label)] = s
            out.append(row(f"{v} / {label}", s))

    # D-005 selection: highest IS expectancy among V0..V2 with PF >= 1.3
    cands = [(summaries[(v, "IS")].expectancy_r, v) for v in VARIANTS
             if summaries[(v, "IS")].n > 0 and summaries[(v, "IS")].profit_factor >= 1.3]
    selected = max(cands)[1] if cands else None
    out += ["", f"Selection (IS only, PF >= 1.30, highest expectancy): **{selected or 'NONE QUALIFIES'}**"]
    base_name = selected or "V0_fixed10_6R"
    if not selected:
        out.append("No variant qualifies on IS. Remaining steps run on V0 for information only; the strategy is NOT validated.")

    # V3 / V4 and management on the base
    base_extra = VARIANTS[base_name]
    jobs2 = {}
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        def submit2(name, period, extra):
            jobs2[(name, period)] = pool.submit(run_bt, binary, data, name, period, extra, runs_dir)

        for p in (IS, OOS):
            submit2(f"V3_{base_name}_regime", p, base_extra + ["--regime", "policy"])
            submit2(f"V4_{base_name}_regime_adaptive", p, base_extra + ["--regime", "policy", "--adaptive", "on"])
            for m, extra in MGMT.items():
                submit2(f"{m}__{base_name}", p, base_extra + extra)
            for c in ("0", "10"):
                submit2(f"COST{c}__{base_name}", p, base_extra + ["--commission", c])
        res2 = {k: f.result() for k, f in jobs2.items()}

    base_is = summaries[(base_name, "IS")]
    for title, names in (("V3 / V4 (regime policy, adaptive risk)", [f"V3_{base_name}_regime", f"V4_{base_name}_regime_adaptive"]),
                         ("D. Trade management", [f"{m}__{base_name}" for m in MGMT]),
                         ("Cost sensitivity (commission $/lot)", [f"COST{c}__{base_name}" for c in ("0", "10")])):
        out += ["", f"## {title}", "", at.HEADER]
        for n in names:
            for p, label in ((IS, "IS"), (OOS, "OOS")):
                s = stats(res2[(n, p)][1])
                summaries[(n, label)] = s
                out.append(row(f"{n} / {label}", s))

    # D-005 V3/V4 adoption, D-009 management adoption (IS decides, OOS must not be worse)
    def better(name, ref_is, ref_oos, min_gain=0.0):
        si, so = summaries[(name, "IS")], summaries[(name, "OOS")]
        return (si.n > 0 and si.expectancy_r >= ref_is.expectancy_r + min_gain and si.mc["p95"] <= ref_is.mc["p95"] + 1e-9
                and so.expectancy_r >= ref_oos.expectancy_r)

    base_oos = summaries[(base_name, "OOS")]
    v3 = f"V3_{base_name}_regime"
    v4 = f"V4_{base_name}_regime_adaptive"
    out += ["", "## Decisions (coded rules)", ""]
    out.append(f"- V3 regime policy adopted: {better(v3, base_is, base_oos)}")
    out.append(f"- V4 adaptive risk adopted: {better(v4, summaries[(v3, 'IS')], summaries[(v3, 'OOS')])}")
    m0 = f"M0_none__{base_name}"
    for m in list(MGMT)[1:]:
        out.append(f"- {m} adopted (IS +0.05R, DD not worse, OOS not worse than M0): "
                   f"{better(f'{m}__{base_name}', summaries[(m0, 'IS')], summaries[(m0, 'OOS')], 0.05)}")

    # sensitivity grid
    out += ["", "## Sensitivity grid (IS, report only - no selection)", "",
            "| stop (price) | fib | wick | trades | expectancy R | PF |", "|---|---|---|---|---|---|"]
    signs = []
    for stop in ("5", "10", "15"):
        for fib in ("0.705", "0.79"):
            for wick in ("0.4", "0.5", "0.6"):
                s = stats(res[(f"G_stop{stop}_fib{fib}_wick{wick}", IS)][1])
                signs.append(s.expectancy_r > 0 if s.n else None)
                out.append(f"| {stop} | {fib} | {wick} | {s.n} | {at._fmt(s.expectancy_r, '.3f')} | {at._fmt(s.profit_factor, '.2f')} |")
    pos = sum(1 for x in signs if x)
    out.append(f"\nPositive expectancy in {pos}/{len(signs)} grid cells "
               f"({'robust' if pos == len(signs) else 'FRAGILE' if 0 < pos < len(signs) else 'negative everywhere'}).")

    # half-year stability of the base (walk-forward style report)
    allt = at.load_trades(res[(base_name, IS)][1]) + at.load_trades(res[(base_name, OOS)][1])
    halves: dict[str, list[float]] = {}
    for t in allt:
        halves.setdefault(f"{t.open_time.year}-H{1 if t.open_time.month <= 6 else 2}", []).append(t.r)
    out += ["", f"## Half-year stability ({base_name})", "", "| half-year | trades | expectancy R |", "|---|---|---|"]
    out += [f"| {k} | {len(v)} | {statistics.fmean(v):.3f} |" for k, v in sorted(halves.items())]

    # full analyzer (acceptance + why) for the base
    runs_for_report = {f"{base_name}": allt}
    out += ["", at.build_report(runs_for_report, datetime(2024, 1, 1), 0.0025, 100000.0, 0.01, at.Criteria())]

    # C. challenge simulation on flat-risk base trades (IS for the decision, OOS shown too)
    for p, label in ((IS, "IS"), (OOS, "OOS")):
        tag, tr, dl, _ = res[(base_name, p)]
        days = ps.load_days(tr, dl)
        out += ["", f"## C. Upcomers challenge simulation - {label} trades of {base_name}", ""]
        if not any(d.trades for d in days):
            out.append("no trades")
            continue
        out.append(ps.report(days, "ash_turbo", [0.0025, 0.005, 0.0075, 0.01, 0.0125, 0.015], args.mc_runs, 11))
        out.append(ps.report(days, "ash", [0.001, 0.0015, 0.002, 0.0025, 0.0035, 0.005], args.mc_runs, 11))
        for prog in ("phoenix", "thunderbolt"):
            out.append(ps.report(days, prog, [0.0025, 0.00375, 0.005, 0.0075, 0.01], args.mc_runs, 11))

    report = args.out / "research.md"
    report.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
