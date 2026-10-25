# RBOTE stop variants — in-sample 2020-01-01 → 2023-12-31 (selection period only)

Backtester `build/rbote_bt`, Dukascopy M1 bid/ask, 100k, risk 0.25 %/trade, commission 5 $/lot RT,
SL slippage 10 ticks, swap −45/−15 $/lot/night (placeholder), daily guard 1 %, regime neutral, flat risk.
OOS (2024 →) NOT looked at.

| Stop | RR | Trades | Win % | Avg R (net) | Net $ | Max DD % |
|---|---|---|---|---|---|---|
| FIXED 10.00 | 6 | 419 | 15.8 | −0.016 | −2,690 | — (PF 0.97) |
| FIXED 10.00, no costs | 6 | 419 | 15.8 | +0.092 | +8,761 | — |
| STRUCTURAL (wick ± 0.30, ≤ 3 ATR) | 6 | 772 | 8.5 | −0.494 | −61,587 | — |
| STRUCTURAL, no costs | 6 | 772 | 8.5 | −0.402 | −54,269 | — |
| STRUCTURAL + min 0.3 ATR | 6 | 396 | — | — | −34,846 | — |
| STRUCTURAL + min 0.5 ATR | 6 | 31 | — | — | −91 | — |
| ATR 1.0 | 3 / 6 | 2380 / 2114 | 18.9 / 10.9 | −0.301 / −0.303 | −83,218 / −80,031 | 83.5 / 80.1 |
| ATR 1.5 | 3 / 6 | 1981 / 1510 | 21.0 / 11.7 | −0.211 / −0.251 | −64,867 / −61,658 | 66.6 / 63.1 |
| ATR 2.0 | 3 / 6 | 1539 / 1114 | 21.6 / 11.5 | −0.187 / −0.265 | −51,442 / −52,471 | 52.3 / 53.2 |
| ATR 3.0 | 3 / 6 | 867 / 507 | 23.3 / 13.0 | −0.128 / −0.201 | −24,481 / −22,676 | 30.4 / 28.2 |
| ATR 4.0 | 3 / 6 | 553 / 273 | 23.0 / 13.9 | −0.155 / −0.186 | −19,099 / −11,956 | 21.5 / 13.1 |

FIXED 10.00 by year (avg R net): 2020 +0.226, 2021 −0.020, 2022 −0.189, 2023 −0.162.

Structural stop median distance = 0.30 × ATR: inside M15 noise, big lots, stopped within minutes
(same picture as the MT5 tester month 2026-10: 21 high-margin trades, 3 winners).

Conclusion (D-038): no RBOTE stop variant reaches PF ≥ 1.30; RBOTE is disabled by default.
