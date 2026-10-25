# MT5 cross-check tools (Linux / Wine)

| File | Purpose |
|---|---|
| `RBOTE_ImportDukascopy.mq5`, `run_import.sh <csv...>` | Build custom symbol `XAUUSD.DK` from Dukascopy M1 bid/ask CSVs (bars + 4 ticks per minute: O, L/H, H/L, C) |
| `RBOTE_SignalReplay.mq5`, `cpp_signals.cpp` | Account-free check: replays the EA's signal path inside MT5 and dumps the same fields from the C++ scan |
| `run_tester.sh <name> <from> <to> [model]`, `tester_template.ini`, `rbote_cmp.set` | Headless Strategy Tester run (model 4 = real ticks) with a preset matching the C++ baseline |
| `compare_trades.py <mt5.csv> <cpp.csv> [--mt5-commission-missing X]` | Trade-by-trade comparison joined on signal_id |
| `run_script.sh <script.mq5> [set]` | Compile and run any script headless |

Status (2026-10-25):
- Signal path: **344/344 signals byte-identical** between the MQL5 runtime and the C++ backtester (Q1 2020, custom symbol).
- Strategy Tester: **blocked** — MT5 build 6283 refuses to start the tester without an account that logged in once
  ("tester not started because the account is not specified"). Needs a demo account opened on a MetaQuotes/broker
  server (MT5's own TCP protocol) or the Config of an authorized install. Custom symbols carry no commission, so
  `compare_trades.py --mt5-commission-missing` corrects MT5 net.

Copy `env.sh.example` to `env.sh` and set the paths first.
