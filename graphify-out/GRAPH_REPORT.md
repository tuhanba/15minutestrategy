# Graph Report - 15minutestrategy  (2026-10-25)

## Corpus Check
- Corpus is ~30,660 words - fits in a single context window. You may not need a graph.

## Summary
- 512 nodes · 964 edges · 27 communities (20 shown, 7 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 19 edges (avg confidence: 0.87)
- Token cost: 114,653 input · 0 output

## Community Hubs (Navigation)
- Prop Challenge Simulator
- Trade Analysis & Acceptance
- Python Research Tooling
- Backtest Engine State
- Backtester Options
- Pending Order Model
- Backtester Entry & Includes
- Prop Firm Rules Config
- Dukascopy Data Fetcher
- Backtest Run Loop
- Signal & Risk Handlers
- Test & Live Gates
- M1 Bars & Swap
- Filter Search Protocol
- RBOTE Risk & Journal Spec
- Backtest & MT5 Cross-Check
- Signal Record
- DTBS Specification
- Stop Variant Results
- Rejection Block & OTE
- Shared Account Guards
- MQL5 Compile Script
- Custom Symbol Import
- MT5 Script Runner
- MT5 Tester Runner

## God Nodes (most connected - your core abstractions)
1. `Engine` - 85 edges
2. `Options` - 46 edges
3. `Pending` - 25 edges
4. `attempt()` - 23 edges
5. `M1` - 20 edges
6. `days_from()` - 19 edges
7. `main()` - 18 edges
8. `Position` - 17 edges
9. `RBOTE Technical Specification v0.2` - 17 edges
10. `load_trades()` - 16 edges

## Surprising Connections (you probably didn't know these)
- `Rejection Block (RB)` --semantically_similar_to--> `Rejection Block conditions (wick, body, approach, confirm)`  [INFERRED] [semantically similar]
  README.md → docs/01_STRATEJI_SPESIFIKASYONU.md
- `OTE 0.79 Fibonacci limit entry` --semantically_similar_to--> `Fibonacci 0.79 entry on RB bounds`  [INFERRED] [semantically similar]
  README.md → docs/01_STRATEJI_SPESIFIKASYONU.md
- `Volatility (VR) and range (ER) regime policy` --semantically_similar_to--> `VR/ER regime measurement and policy (v0.3)`  [INFERRED] [semantically similar]
  README.md → docs/01_STRATEJI_SPESIFIKASYONU.md
- `DECISION/CLOSED journal and trades.csv` --semantically_similar_to--> `Explainability decision card and outcome story (v0.4)`  [INFERRED] [semantically similar]
  README.md → docs/01_STRATEJI_SPESIFIKASYONU.md
- `Profit-scaled risk and edge weighting` --semantically_similar_to--> `Bounded anti-martingale profit scaling`  [INFERRED] [semantically similar]
  README.md → docs/01_STRATEJI_SPESIFIKASYONU.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Pre-registered IS-selection / one-shot OOS validation discipline** — docs_backtest_research_plan, reports_filter_search_meeting_protocol_d040, docs_01_strateji_spesifikasyonu_acceptance_criteria, reports_dtbs_filter_search_d034_acceptance, docs_03_test_ve_canli_gecis_kontrol_listesi_stage_gates [INFERRED 0.85]
- **RBOTE signal pipeline: PD array -> RB -> Fib 0.79 -> stop/lot** — docs_01_strateji_spesifikasyonu_fair_value_gap, docs_01_strateji_spesifikasyonu_order_block, docs_01_strateji_spesifikasyonu_zone_lifecycle, docs_01_strateji_spesifikasyonu_rejection_block_rules, docs_01_strateji_spesifikasyonu_fib_entry, docs_01_strateji_spesifikasyonu_stop_modes, docs_01_strateji_spesifikasyonu_lot_risk_formula [EXTRACTED 1.00]
- **Dual-engine cross-check (C++ backtester vs MT5)** — docs_backtest_independent_backtest, tools_mt5_readme_signal_replay, tools_mt5_compare_trades, tools_mt5_readme_import_dukascopy, docs_backtest_dukascopy_data [INFERRED 0.85]

## Communities (27 total, 7 thin omitted)

### Community 0 - "Prop Challenge Simulator"
Cohesion: 0.08
Nodes (52): attempt(), block_days(), _d(), Day, decide(), decide_combined(), Decision, _dt() (+44 more)

### Community 1 - "Trade Analysis & Acceptance"
Cohesion: 0.07
Nodes (38): acceptance(), bootstrap_mean_ci(), bucket_table(), build_report(), Criteria, daily_breaches(), equity_curve(), _fmt() (+30 more)

### Community 2 - "Python Research Tooling"
Cohesion: 0.08
Nodes (25): inline(), main(), load(), adopt_mgmt(), adopt_money(), cache_key(), daily_stats(), file_sha256() (+17 more)

### Community 3 - "Backtest Engine State"
Cohesion: 0.04
Nodes (44): Engine, balance, consec_losses, ctx_d1, ctx_h4, cur_day, d1, day_blocked (+36 more)

### Community 4 - "Backtester Options"
Cohesion: 0.05
Nodes (36): Options, balance, cfg, commission, dcfg, digits, edge, end_close (+28 more)

### Community 5 - "Pending Order Model"
Cohesion: 0.06
Nodes (30): Pending, active, bars_alive, ds, edge_mult, feat, lots, pct (+22 more)

### Community 6 - "Backtester Entry & Includes"
Cohesion: 0.09
Nodes (10): main(), usage(), M1, bc, bh, bl, bo, t (+2 more)

### Community 7 - "Prop Firm Rules Config"
Cohesion: 0.08
Nodes (25): account_size, consistency_rule, daily_loss, amount, includes_floating, reference, reset_time, reset_tz (+17 more)

### Community 8 - "Dukascopy Data Fetcher"
Cohesion: 0.19
Nodes (6): cache_path(), day_rows(), decode(), download(), fetch(), main()

### Community 9 - "Backtest Run Loop"
Cohesion: 0.22
Nodes (4): fmt_date(), fmt_time(), load_csv(), parse_time()

### Community 11 - "Test & Live Gates"
Cohesion: 0.18
Nodes (10): VR/ER regime measurement and policy (v0.3), Demo forward test (>=8 weeks / 50 trades), Test and live transition checklist, Stop rules and manual kill switch, Stage gates 0-4 (definitions, software, backtest, demo, live prop), Live account gate (InpLiveConfirmLogin, InpAllowLiveTrading, InpPropRulesVerified), MQL5 tester presets (6R/5R fixed, structural, regime, adaptive), RBOTE EA (XAUUSD M15 RB + OTE 0.79) (+2 more)

### Community 12 - "M1 Bars & Swap"
Cohesion: 0.18
Nodes (10): M1, ac, ah, al, ao, bc, bh, bl (+2 more)

### Community 13 - "Filter Search Protocol"
Cohesion: 0.25
Nodes (9): OOS acceptance criteria (>=100 trades, PF>=1.30, MC DD p95<10%), HTF main trend (H1+H4 fractal structure), D-034 acceptance bar, DTBS filter search report, Finalist D1&H4 EMA50 RR3 not accepted, InpDtbsCtxFilter EA input, D1/H4 EMA50 slope context filter (C1&C2), Meeting 2026-10-25: DTBS filter search (+1 more)

### Community 14 - "RBOTE Risk & Journal Spec"
Cohesion: 0.22
Nodes (8): Bounded anti-martingale profit scaling, Explainability decision card and outcome story (v0.4), Edge weighting with shrinkage (prior 20, gain 0.15), Fair Value Gap (FVG), Order Block (with BOS), Order lifecycle, cancel rules, duplicate guard, reconciliation, RBOTE Technical Specification v0.2, DECISION/CLOSED journal and trades.csv

### Community 15 - "Backtest & MT5 Cross-Check"
Cohesion: 0.24
Nodes (8): Dukascopy XAUUSD M1 bid/ask data, Independent C++ backtester rbote_bt, MetaEditor under WineHQ 10+/11, Run cache keyed by SHA-256, RBOTE_ImportDukascopy custom symbol XAUUSD.DK, MT5 cross-check tools (Linux/Wine), RBOTE_SignalReplay (344/344 signals identical), Strategy Tester blocked without logged-in account

### Community 17 - "Signal Record"
Cohesion: 0.33
Nodes (4): SigEx, candle_range, reg, sig

### Community 18 - "DTBS Specification"
Cohesion: 0.40
Nodes (6): Lot sizing and risk formula, A-B-C triangle geometry (sloped line A->C), ADAPTIVE stop (BREAK_START/BREAK_CANDLE/EXTREME/ATR), Trend-break and counter-break signals (close confirm), Target RR 1.5 ('40 to 60'), DTBS Dynamic Trend Break System Spec v0.1

### Community 19 - "Stop Variant Results"
Cohesion: 0.33
Nodes (5): Stop modes FIXED / STRUCTURAL / ATR, DTBS backtest 2020-2026 report, Verdict: DTBS has no measurable edge, DTBS variants W0-W4, RBOTE stop variants IS 2020-2023 report

### Community 20 - "Rejection Block & OTE"
Cohesion: 0.50
Nodes (5): Fibonacci 0.79 entry on RB bounds, Rejection Block conditions (wick, body, approach, confirm), PD zone lifecycle (ACTIVE/USED/INVALID/EXPIRED), OTE 0.79 Fibonacci limit entry, Rejection Block (RB)

### Community 21 - "Shared Account Guards"
Cohesion: 0.50
Nodes (3): Daily worst-case loss and account guard, tools/prop_sim.py challenge simulation, Upcomers Ash Turbo 100k prop challenge

## Knowledge Gaps
- **134 isolated node(s):** `t`, `bo`, `bh`, `bl`, `bc` (+129 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 241 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Engine` connect `Backtest Engine State` to `Backtester Options`, `Pending Order Model`, `Backtester Entry & Includes`, `Backtest Run Loop`, `Signal & Risk Handlers`, `M1 Bars & Swap`, `DTBS Scan & Labels`, `Signal Record`?**
  _High betweenness centrality (0.098) - this node is a cross-community bridge._
- **What connects `t`, `bo`, `bh` to the rest of the system?**
  _134 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Prop Challenge Simulator` be split into smaller, more focused modules?**
  _Cohesion score 0.07769973661106233 - nodes in this community are weakly interconnected._
- **Why does `Options` connect `Backtester Options` to `DTBS Scan & Labels`, `Backtest Run Loop`, `Backtest Engine State`, `Backtester Entry & Includes`?**
  _High betweenness centrality (0.059) - this node is a cross-community bridge._
- **Should `Trade Analysis & Acceptance` be split into smaller, more focused modules?**
  _Cohesion score 0.07242063492063493 - nodes in this community are weakly interconnected._
- **Why does `OOS acceptance criteria (>=100 trades, PF>=1.30, MC DD p95<10%)` connect `Filter Search Protocol` to `Trade Analysis & Acceptance`, `Test & Live Gates`, `RBOTE Risk & Journal Spec`?**
  _High betweenness centrality (0.046) - this node is a cross-community bridge._
- **Should `Python Research Tooling` be split into smaller, more focused modules?**
  _Cohesion score 0.0784313725490196 - nodes in this community are weakly interconnected._