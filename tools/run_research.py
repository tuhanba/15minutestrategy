#!/usr/bin/env python3
"""Run the pre-registered research plan (manager decisions D-004..D-009, D-023..D-029) end to end.

  A  variants V0..V2 on IS (2020-2023); selection on IS only
  B  V3 (regime policy) / V4 (adaptive risk): money-based adoption on IS only (D-024)
  D  trade management M0..M4 on the chosen configuration, IS only
  -> FINAL configuration; OOS (2024 -> end) is reported ONCE for it (D-023), with the full acceptance
     report, cost / swap sensitivity, walk-forward stability inside IS, and - for transparency, clearly
     labelled "not used for selection" - the OOS rows of the other candidates
  C  Upcomers challenge simulation (Ash Turbo primary) on the FINAL configuration at flat risk;
     risk decision once on IS trades, OOS only as validation (D-027)

Research backtests MEASURE, they do not gate: the personal total-DD floor is off (--max-dd 0, D-025),
the personal daily guard stays on (--daily). Firm limits are applied only in the prop simulator.
Selection rules are coded here so they cannot be changed after looking at results.
Writes reports/research.md and keeps every run's trades/daily files under reports/runs/.
"""
from __future__ import annotations

import argparse
import csv
import glob
import hashlib
import json
import math
import statistics
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import analyze_trades as at  # noqa: E402
import prop_sim as ps  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
IS = ("2020-01-01", "2024-01-01")       # D-004 / D-023 (exclusive end)
OOS = ("2024-01-01", "2026-10-24")
START_BALANCE = 100000.0
FLAT_RISK = 0.0025
PERSONAL_DAILY = 0.01                   # --daily 1.0 below
PERSONAL_TRAIL = 0.04                   # D-014: personal floor = equity peak * (1 - 4%), measured only (D-025)

# D-006/D-013/D-029 costs, D-025 no total-DD gate, D-026 swap placeholders (hypothetical)
SWAP = ["--swap-long", "-45", "--swap-short", "-15"]
BASE = ["--stop", "fixed", "--stop-dist", "10", "--stop-unit", "price", "--rr", "6",
        "--regime", "neutral", "--adaptive", "off", "--risk", "0.25", "--daily", "1.0",
        "--open-risk", "0.5", "--max-dd", "0", "--dd-trailing", "off", "--commission", "5", "--slip-ticks", "10",
        "--friday-cutoff", "20", "--end-close", "on"] + SWAP
REQUIRED_FLAGS = ("--swap-long", "--swap-short", "--end-close", "--max-dd")

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
REGIME = ["--regime", "policy"]
ADAPTIVE = ["--adaptive", "on"]
FLAT = ["--adaptive", "off"]
# challenge source run: EA Ash Turbo preset personal daily guard is 2% (D-021)
CHALLENGE = FLAT + ["--daily", "2.0"]

# D-024 money-based adoption of size-changing variants
ADOPT_SCORE_GAIN = 0.10       # (net / money MC DD p95) must improve by >= 10%
ADOPT_DD_MULT = 1.10          # money MC DD p95 <= 1.10 x baseline
# D-009 management adoption
MGMT_MIN_GAIN_R = 0.05

WF_TEST_WINDOWS = [("2021-07-01", "2022-01-01"), ("2022-01-01", "2022-07-01"), ("2022-07-01", "2023-01-01"),
                   ("2023-01-01", "2023-07-01"), ("2023-07-01", "2024-01-01")]   # 18m train / 6m test inside IS


# --- backtest runs with a content-addressed cache ------------------------------------------------

def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cache_key(binary_hash: str, data: list[str], argv: list[str]) -> str:
    """Hash of the backtester binary, the full argument list and the data files (path, size, mtime)."""
    stats = []
    for f in data:
        st = Path(f).stat()
        stats.append([str(Path(f).resolve()), st.st_size, st.st_mtime_ns])
    blob = json.dumps({"bin": binary_hash, "argv": argv, "data": stats}, sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()


def run_bt(binary: Path, binary_hash: str, data: list[str], name: str, period: tuple[str, str], args: list[str],
           outdir: Path):
    tag = f"{name}__{period[0][:4]}_{period[1][:4]}"
    trades, daily, summ = outdir / f"{tag}_trades.csv", outdir / f"{tag}_daily.csv", outdir / f"{tag}_summary.txt"
    keyf = outdir / f"{tag}.key"
    argv = sum((["--data", f] for f in data), []) + ["--from", period[0], "--to", period[1]] + BASE + args
    key = cache_key(binary_hash, data, argv)
    fresh = trades.exists() and daily.exists() and keyf.exists() and keyf.read_text().strip() == key
    if not fresh:
        keyf.unlink(missing_ok=True)
        cmd = [str(binary)] + argv + ["--out-trades", str(trades), "--out-daily", str(daily), "--out-summary", str(summ)]
        subprocess.run(cmd, check=True, capture_output=True)
        keyf.write_text(key + "\n")
    return tag, trades, daily, summ


# --- metrics ------------------------------------------------------------------------------------

@dataclass
class Run:
    name: str
    label: str
    s: at.Summary
    trades: list
    p_daily: float           # share of days whose worst equity breached the personal daily limit
    trail_breaks: int        # days below the personal trailing floor (measured, not gated)
    first_break: str
    paths: tuple


def daily_stats(daily_path: Path) -> tuple[float, int, str]:
    rows = []
    if daily_path.exists():
        with daily_path.open() as fh:
            rows = list(csv.DictReader(fh, delimiter=";"))
    if not rows:
        return float("nan"), 0, ""
    breach, breaks, first, peak = 0, 0, "", 0.0
    for r in rows:
        ref, low, end = float(r["day_ref"]), float(r["min_equity"]), float(r["end_balance"])
        peak = max(peak, ref)
        if low - ref <= -PERSONAL_DAILY * ref:
            breach += 1
        if low < peak * (1 - PERSONAL_TRAIL):
            breaks += 1
            first = first or r["date"]
        peak = max(peak, end)
    return breach / len(rows), breaks, first


def measure(name: str, label: str, res, mc_runs: int) -> Run:
    tag, tr, dl, sm = res
    trades = at.load_trades(tr)
    s = at.summarize(trades, FLAT_RISK, START_BALANCE, PERSONAL_DAILY, runs=mc_runs)
    p, nb, fb = daily_stats(dl)
    return Run(name, label, s, trades, p, nb, fb, res)


RUN_HEADER = at.HEADER.split("\n")[0] + " P(personal daily breach) |\n" + at.HEADER.split("\n")[1] + "---|"


def row(r: Run) -> str:
    return at.summary_row(f"{r.name} / {r.label}", r.s) + f" {_pct(r.p_daily)} |"


def _pct(x: float, spec: str = ".2%") -> str:
    return "n/a" if x is None or (isinstance(x, float) and math.isnan(x)) else format(x, spec)


def adopt_money(cand: Run, ref: Run) -> tuple[bool, str]:
    """D-024: IS (net / money MC DD p95) +10%, money MC DD p95 <= 1.10x, P(personal daily breach) not higher."""
    sc, sr = cand.s.return_to_dd, ref.s.return_to_dd
    dc, dr = (cand.s.money_mc or {}).get("p95", math.nan), (ref.s.money_mc or {}).get("p95", math.nan)
    ok_score = cand.s.n > 0 and not math.isnan(sc) and not math.isnan(sr) and sc >= sr + ADOPT_SCORE_GAIN * abs(sr)
    ok_dd = not math.isnan(dc) and not math.isnan(dr) and dc <= ADOPT_DD_MULT * dr + 1e-12
    ok_daily = not (cand.p_daily > ref.p_daily + 1e-12)
    why = (f"score {_pct(sc, '.2f')} vs {_pct(sr, '.2f')} (need >= +{ADOPT_SCORE_GAIN:.0%}): {ok_score}; "
           f"money MC DD p95 {_pct(dc)} vs {_pct(dr)} (<= x{ADOPT_DD_MULT}): {ok_dd}; "
           f"P(daily breach) {_pct(cand.p_daily)} vs {_pct(ref.p_daily)} (not higher): {ok_daily}")
    return ok_score and ok_dd and ok_daily, why


def adopt_mgmt(cand: Run, m0: Run) -> tuple[bool, str]:
    """D-009 without the OOS clause (D-023): IS expectancy >= M0 + 0.05R and money MC DD p95 not worse."""
    ec, e0 = cand.s.expectancy_r, m0.s.expectancy_r
    dc, d0 = (cand.s.money_mc or {}).get("p95", math.nan), (m0.s.money_mc or {}).get("p95", math.nan)
    ok_e = cand.s.n > 0 and ec >= e0 + MGMT_MIN_GAIN_R
    ok_dd = not math.isnan(dc) and dc <= d0 + 1e-12
    return ok_e and ok_dd, (f"expectancy {ec:.3f}R vs {e0:.3f}R (+{MGMT_MIN_GAIN_R}R): {ok_e}; "
                            f"money MC DD p95 {_pct(dc)} vs {_pct(d0)} (not worse): {ok_dd}")


def walk_forward(runs: dict[str, list], windows) -> list[str]:
    out = ["| test window | " + " | ".join(f"{n} trades | {n} exp R | {n} net %" for n in runs) + " |",
           "|---|" + "---|---|---|" * len(runs)]
    for a, b in windows:
        lo, hi = datetime.fromisoformat(a), datetime.fromisoformat(b)
        cells = []
        for trades in runs.values():
            sub = [t for t in trades if lo <= t.open_time < hi]
            e = statistics.fmean(t.r for t in sub) if sub else math.nan
            cells += [str(len(sub)), _pct(e, ".3f"), _pct(sum(t.net for t in sub) / START_BALANCE)]
        out.append(f"| {a} -> {b} | " + " | ".join(cells) + " |")
    return out


# --- main ---------------------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", default=str(ROOT / "data/XAUUSD_M1_*.csv"))
    ap.add_argument("--out", type=Path, default=ROOT / "reports")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--mc-runs", type=int, default=5000, help="Monte Carlo runs for decisions (>= 5000)")
    ap.add_argument("--sim-runs", type=int, default=10000, help="challenge Monte Carlo attempts")
    ap.add_argument("--block", type=int, default=5, help="challenge Monte Carlo block length in days (D-028)")
    ap.add_argument("--allow-above-cap", action="store_true",
                    help="challenge grid may exceed the preset risk cap of 0.5%%")
    ap.add_argument("--periods", help=argparse.SUPPRESS)   # smoke tests only: IS_FROM,IS_TO,OOS_FROM,OOS_TO
    args = ap.parse_args(argv)
    if args.mc_runs < 5000:
        print("warning: --mc-runs < 5000 is not valid for decisions", file=sys.stderr)
    is_p, oos_p = IS, OOS
    if args.periods:
        a, b, c, d = args.periods.split(",")
        is_p, oos_p = (a, b), (c, d)

    data = sorted(glob.glob(args.data))
    if not data:
        print("no data files", file=sys.stderr)
        return 2
    runs_dir = args.out / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)
    binary = ROOT / "build/rbote_bt"
    binary.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["g++", "-std=c++17", "-O2", "-x", "c++", str(ROOT / "backtest/rbote_bt.cpp"), "-o", str(binary)],
                   check=True)
    usage = subprocess.run([str(binary)], capture_output=True, text=True).stdout
    missing = [f for f in REQUIRED_FLAGS if f not in usage]
    if missing:
        print(f"backtester does not support {missing}; update backtest/rbote_bt.cpp", file=sys.stderr)
        return 2
    bhash = file_sha256(binary)

    def batch(specs: dict) -> dict:
        with ProcessPoolExecutor(max_workers=args.jobs) as pool:
            futs = {k: pool.submit(run_bt, binary, bhash, data, k[0], k[1], extra, runs_dir) for k, extra in specs.items()}
            return {k: f.result() for k, f in futs.items()}

    def m(name, period, res) -> Run:
        return measure(name, "IS" if period == is_p else "OOS", res[(name, period)], args.mc_runs)

    out = [f"# RBOTE research report ({datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC)", "",
           "Pre-registered plan: manager decisions D-004..D-009 as amended by D-023..D-029. "
           "Data: Dukascopy XAUUSD M1 bid/ask (UTC).",
           f"IS {is_p[0]} -> {is_p[1]}, OOS {oos_p[0]} -> {oos_p[1]} (exclusive end). **All selection and adoption "
           "uses IS only; OOS is reported once for the final configuration.**",
           "Costs: commission 5 $/lot RT (D-029), SL slippage 10 ticks, real M1 spread, swap long -45 / short -15 "
           "$/lot/night x3 Wednesday at 21:00 UTC (**swap is hypothetical**, D-026). Risk 0.25% flat unless stated. "
           "Personal daily guard 1% on; personal total-DD floor OFF in research runs (measured, not gated, D-025). "
           "Open positions are closed at the end of each period (END).",
           f"Monte Carlo: {args.mc_runs} runs. R columns are size-blind; money columns use the actual P&L fraction "
           "of the balance at entry.", ""]

    # ---- A: variants (IS) + sensitivity grid (IS, report only)
    grid = [(s_, f_, w_) for s_ in ("5", "10", "15") for f_ in ("0.705", "0.79") for w_ in ("0.4", "0.5", "0.6")]
    specs = {(v, is_p): extra for v, extra in VARIANTS.items()}
    specs.update({(f"G_stop{s_}_fib{f_}_wick{w_}", is_p): ["--stop-dist", s_, "--fib", f_, "--wick", w_]
                  for s_, f_, w_ in grid})
    res = batch(specs)
    runs: dict[tuple[str, str], Run] = {}
    out += ["## A. Variants (IS)", "", RUN_HEADER]
    for v in VARIANTS:
        runs[(v, "IS")] = m(v, is_p, res)
        out.append(row(runs[(v, "IS")]))
    cands = [(runs[(v, "IS")].s.expectancy_r, v) for v in VARIANTS
             if runs[(v, "IS")].s.n > 0 and runs[(v, "IS")].s.profit_factor >= 1.3]
    selected = max(cands)[1] if cands else None
    out += ["", f"Selection (IS only, PF >= 1.30, highest expectancy; flat risk so R is comparable): "
                f"**{selected or 'NONE QUALIFIES'}**"]
    base_name = selected or "V0_fixed10_6R"
    if not selected:
        out.append("No variant qualifies on IS. Remaining steps run on V0 for information only; "
                   "the strategy is NOT validated.")
    sel = VARIANTS[base_name]

    # ---- B: V3 / V4 (IS, money-based adoption)
    v3, v4r, v4f = f"V3_{base_name}_regime", f"V4_{base_name}_regime_adaptive", f"V4_{base_name}_adaptive"
    res.update(batch({(v3, is_p): sel + REGIME, (v4r, is_p): sel + REGIME + ADAPTIVE, (v4f, is_p): sel + ADAPTIVE}))
    for n in (v3, v4r, v4f):
        runs[(n, "IS")] = m(n, is_p, res)
    base = runs[(base_name, "IS")]
    ok3, why3 = adopt_money(runs[(v3, "IS")], base)
    cur_extra, cur_name = list(sel) + (REGIME if ok3 else []), (v3 if ok3 else base_name)
    cur_ref = runs[(v3, "IS")] if ok3 else base
    v4 = v4r if ok3 else v4f
    ok4, why4 = adopt_money(runs[(v4, "IS")], cur_ref)
    if ok4:
        cur_extra, cur_name = cur_extra + ADAPTIVE, v4
    out += ["", "## B. V3 / V4 (regime policy, adaptive risk) - IS, money-based adoption (D-024)", "", RUN_HEADER,
            row(base), row(runs[(v3, "IS")]), row(runs[(v4, "IS")]), "",
            f"- V3 regime policy adopted: **{ok3}** ({why3})",
            f"- {v4} adopted (vs {'V3' if ok3 else base_name}): **{ok4}** ({why4})"]

    # ---- D: management on the chosen configuration at flat risk (IS)
    flat_extra = cur_extra[:-len(ADAPTIVE)] if ok4 else list(cur_extra)
    mg_names = {mg: f"{mg}__{cur_name}" for mg in MGMT}
    res.update(batch({(mg_names[mg], is_p): flat_extra + FLAT + extra for mg, extra in MGMT.items()}))
    for mg in MGMT:
        runs[(mg_names[mg], "IS")] = m(mg_names[mg], is_p, res)
    m0 = runs[(mg_names["M0_none"], "IS")]
    out += ["", f"## D. Trade management on {cur_name} at flat risk - IS", "", RUN_HEADER]
    out += [row(runs[(mg_names[mg], "IS")]) for mg in MGMT]
    out.append("")
    adopted = []
    for mg in list(MGMT)[1:]:
        ok, why = adopt_mgmt(runs[(mg_names[mg], "IS")], m0)
        out.append(f"- {mg} adopted: **{ok}** ({why})")
        if ok:
            adopted.append((runs[(mg_names[mg], "IS")].s.expectancy_r, mg))
    best_mg = max(adopted)[1] if adopted else "M0_none"
    if len(adopted) > 1:
        out.append(f"- several qualify -> highest IS expectancy: {best_mg}")

    final_extra = cur_extra + MGMT[best_mg]
    final = "FINAL"
    out += ["", "## Final configuration (chosen on IS only)", "",
            f"`{base_name}` + regime policy: {ok3} + adaptive risk: {ok4} + management: {best_mg}", "",
            "backtester arguments: `" + " ".join(BASE + final_extra) + "`"]

    # ---- final batch: final IS/OOS, sensitivities, challenge source, OOS transparency rows
    fspecs = {(final, is_p): final_extra, (final, oos_p): final_extra,
              ("FINAL_COST0", is_p): final_extra + ["--commission", "0"],
              ("FINAL_COST0", oos_p): final_extra + ["--commission", "0"],
              ("FINAL_COST10", is_p): final_extra + ["--commission", "10"],
              ("FINAL_COST10", oos_p): final_extra + ["--commission", "10"],
              ("FINAL_SWAP0", is_p): final_extra + ["--swap-long", "0", "--swap-short", "0"],
              ("FINAL_SWAP0", oos_p): final_extra + ["--swap-long", "0", "--swap-short", "0"],
              ("FINAL_CHALLENGE_FLAT", is_p): final_extra + CHALLENGE,
              ("FINAL_CHALLENGE_FLAT", oos_p): final_extra + CHALLENGE}
    transp = {v: extra for v, extra in VARIANTS.items()}
    transp.update({v3: sel + REGIME, v4: sel + (REGIME if ok3 else []) + ADAPTIVE})
    transp.update({mg_names[mg]: flat_extra + FLAT + extra for mg, extra in MGMT.items()})
    fspecs.update({(n, oos_p): extra for n, extra in transp.items()})
    res.update(batch(fspecs))
    fis, foos = m(final, is_p, res), m(final, oos_p, res)

    out += ["", "## OOS - final configuration (reported once, does not change the selection)", "", RUN_HEADER,
            row(fis), row(foos), "",
            f"Personal trailing floor (equity peak - {PERSONAL_TRAIL:.0%}, measured only): IS {fis.trail_breaks} days below "
            f"(first {fis.first_break or '-'}), OOS {foos.trail_breaks} days below (first {foos.first_break or '-'})."]

    out += ["", "## Cost and swap sensitivity of the final configuration", "", RUN_HEADER]
    for n in ("FINAL_COST0", "FINAL_COST10", "FINAL_SWAP0"):
        out += [row(m(n, is_p, res)), row(m(n, oos_p, res))]

    # walk-forward inside IS (report only)
    out += ["", "## Walk-forward stability inside IS (18 m train / 6 m test windows; report only)", ""]
    out += walk_forward({base_name: base.trades, "FINAL": fis.trades}, WF_TEST_WINDOWS)

    # sensitivity grid
    out += ["", "## Sensitivity grid (IS, report only - no selection)", "",
            "| stop (price) | fib | wick | trades | expectancy R | PF | net % | money MC DD p95 |",
            "|---|---|---|---|---|---|---|---|"]
    signs = []
    for s_, f_, w_ in grid:
        g = m(f"G_stop{s_}_fib{f_}_wick{w_}", is_p, res).s
        signs.append(g.expectancy_r > 0 if g.n else None)
        out.append(f"| {s_} | {f_} | {w_} | {g.n} | {at._fmt(g.expectancy_r, '.3f')} | {at._fmt(g.profit_factor, '.2f')} | "
                   f"{_pct(g.return_frac)} | {_pct((g.money_mc or {}).get('p95', math.nan))} |")
    pos = sum(1 for x in signs if x)
    out.append(f"\nPositive expectancy in {pos}/{len(signs)} grid cells "
               f"({'robust' if pos == len(signs) else 'FRAGILE' if 0 < pos < len(signs) else 'negative everywhere'}).")

    # half-year stability of the final configuration
    allt = fis.trades + foos.trades
    halves: dict[str, list] = {}
    for t in allt:
        halves.setdefault(f"{t.open_time.year}-H{1 if t.open_time.month <= 6 else 2}", []).append(t)
    out += ["", "## Half-year stability (FINAL)", "", "| half-year | trades | expectancy R | net $ |", "|---|---|---|---|"]
    out += [f"| {k} | {len(v)} | {statistics.fmean(t.r for t in v):.3f} | {sum(t.net for t in v):,.2f} |"
            for k, v in sorted(halves.items())]

    # full acceptance report on the final configuration
    out += ["", at.build_report({"FINAL": allt}, datetime.fromisoformat(oos_p[0]), FLAT_RISK, START_BALANCE,
                                PERSONAL_DAILY, at.Criteria()).replace("# RBOTE backtest analysis",
                                                                        "## Acceptance report - FINAL", 1)]

    # transparency: OOS of the other candidates, NOT used for selection
    out += ["", "## OOS of the other candidates - transparency only, NOT used for selection", "", RUN_HEADER]
    for n in transp:
        out.append(row(m(n, oos_p, res)))

    # ---- C: challenge simulation on the final configuration at flat risk
    grid_c = list(ps.DEFAULT_GRID) + ([0.0075, 0.01] if args.allow_above_cap else [])
    cis, coos = res[("FINAL_CHALLENGE_FLAT", is_p)], res[("FINAL_CHALLENGE_FLAT", oos_p)]
    days_is, days_oos = ps.load_days(cis[1], cis[2]), ps.load_days(coos[1], coos[2])
    out += ["", "## C. Upcomers challenge simulation - FINAL configuration at flat risk", "",
            "Source backtest: FINAL arguments + `" + " ".join(CHALLENGE) + "` (no adaptive sizing; EA Turbo personal "
            "daily guard 2%). Decision computed ONCE on IS trades; OOS shown only as validation (D-027). "
            f"Grid {', '.join(f'{r:.2%}' for r in grid_c)}; selection cap {ps.SELECTION_CAP:.2%}.", ""]
    for prog in ("ash_turbo", "ash_turbo_strict", "ash", "phoenix", "thunderbolt"):
        out.append(ps.report(days_is, prog, grid_c, args.sim_runs, 11, args.block, days_oos, args.allow_above_cap,
                             labels=("IS trades", "OOS trades")))

    report = args.out / "research.md"
    report.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
