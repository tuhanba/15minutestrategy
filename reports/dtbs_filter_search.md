# DTBS filter search (user: "keep going until the right filter is found")

Protocol fixed before any search (reports/filter_search_meeting.md, manager D-040): discovery 2020-21 →
validation 2022-23 → blind OOS 2024-01 → 2026-10 once per finalist, at most 3 rounds.
Signal-level labels: `rbote_bt --strategy dtbs --label-out` (every signal simulated on its own, costs included).

| Round | Family | Candidates | Passed discovery | Finalist |
|---|---|---|---|---|
| 1 | direction, session, volatility, efficiency, break body, break distance, leg size, stop size, B→break bars, weekday; single or pair × RR {1, 1.5, 2, 3} | 1,964 | 0 | — |
| 2 | entry (market / retest limit) × context (D1 EMA50 slope, H4 EMA50 slope, H1 EMA200 side, combos, with-trend) × RR | 64 | 0 | — |
| 3 | context D1 + H4 slope (pattern seen in round 2) × {+H1, +with-trend} × RR {2, 3, 4}; whole IS, both halves > 0 | 9 | 1 | D1 & H4 EMA50 slope with the trade, RR 3 |

Finalist, full engine (one position, daily guard, commission 5 $/lot, slippage 10 ticks, swap placeholder, risk 0.25 %):

| Period | Trades | Win % | Avg R | 95 % low | PF | Net $ | Max DD | Years |
|---|---|---|---|---|---|---|---|---|
| 2020–2023 (selection) | 313 | 29.1 | +0.105 | −0.081 | 1.14 | +8,045 | 3.9 % | 2020 −0.7k, 2021 +4.5k, 2022 +2.9k, 2023 +1.3k |
| 2024–2026-10 (blind, once) | 228 | 28.1 | +0.079 | −0.155 | 1.10 | +4,224 | 3.8 % | 2024 +0.1k, 2025 +2.9k, 2026 +1.3k |

Acceptance (D-034): OOS ≥ 100 trades ✔, avg R > 0 ✔, bootstrap low > 0 ✘, PF ≥ 1.30 ✘, ≥ 60 % years positive ✔.
**Not accepted.** Positive in both periods but the edge is small and not statistically distinguishable from zero.
Caveat: round 3 was derived from a pattern seen in-sample, so the OOS is the only blind check.

Ash Turbo simulation (tools/prop_sim.py, decision on 2020–23, 2024–26 validation only):
risk 0.35 % → pass ≈ 15–18 % per attempt; 0.50 % → ≈ 28–32 %. Failures are almost all "time ran out"
(2 % not reached in 7 trading days / 30 days), not firm breaches (0 %).

Search ended (3 rounds used). The filter is in the EA as `InpDtbsCtxFilter` (on in the DTBS presets) for
demo / tester forward testing only.
