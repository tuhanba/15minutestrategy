# Graph Report - 15minutestrategy  (2026-10-25)

## Corpus Check
- 29 files · ~28,424 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 33 file(s) not represented in the graph (top: .mqh 15, .set 9, .mq5 4)

## Summary
- 509 nodes · 905 edges · 29 communities (16 shown, 13 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 7 edges (avg confidence: 0.89)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `30deb81c`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- analyze_trades.py
- prop_sim.py
- run_research.py
- Engine
- XAUUSD M15 PD Array + Rejection Block + OTE 0.79 — Teknik Spesifikasyon v0.2
- Options
- Pending
- rbote_bt.cpp
- prop_firm.example.yaml
- fetch_dukascopy.py
- .run
- M1
- DTBS — Dynamic Trend Break System: Teknik Spesifikasyon v0.1
- string
- Test ve Canlıya Geçiş Kontrol Listesi
- SigEx
- Bağımsız backtest, challenge simülasyonu ve araştırma planı
- DTBS backtest 2020-01-01 → 2026-10-23
- install-graphify.sh
- compile_mql5.sh
- CLAUDE.md
- .claude/CLAUDE.md
- rbote_stop_IS_2020_2023.md
- mt5/README.md
- run_import.sh
- run_script.sh
- run_tester.sh

## God Nodes (most connected - your core abstractions)
1. `Engine` - 72 edges
2. `Options` - 41 edges
3. `Pending` - 25 edges
4. `attempt()` - 23 edges
5. `M1` - 20 edges
6. `days_from()` - 19 edges
7. `main()` - 18 edges
8. `Position` - 17 edges
9. `load_trades()` - 16 edges
10. `summarize()` - 16 edges

## Surprising Connections (you probably didn't know these)
- `Araştırma planı (önceden kayıtlı: D-004 … D-009, D-023 … D-029 ile güncel)` --references--> `Summary`  [INFERRED]
  docs/BACKTEST.md → tools/analyze_trades.py
- `Araştırma planı (önceden kayıtlı: D-004 … D-009, D-023 … D-029 ile güncel)` --references--> `build_report()`  [INFERRED]
  docs/BACKTEST.md → tools/analyze_trades.py
- `3.2 Order Block (FVG oluştuğu anda değerlendirilir)` --references--> `s()`  [INFERRED]
  docs/01_STRATEJI_SPESIFIKASYONU.md → tools/tests/test_prop_sim.py
- `measure()` --calls--> `load_trades()`  [EXTRACTED]
  tools/run_research.py → tools/analyze_trades.py
- `test_max_drawdown()` --calls--> `max_drawdown()`  [EXTRACTED]
  tools/tests/test_analyze_trades.py → tools/analyze_trades.py

## Import Cycles
- None detected.

## Communities (29 total, 13 thin omitted)

### Community 0 - "analyze_trades.py"
Cohesion: 0.07
Nodes (42): Araştırma planı (önceden kayıtlı: D-004 … D-009, D-023 … D-029 ile güncel), prop_sim modeli, Önbellek, acceptance(), bootstrap_mean_ci(), bucket_table(), build_report(), Criteria (+34 more)

### Community 1 - "prop_sim.py"
Cohesion: 0.08
Nodes (52): attempt(), block_days(), _d(), Day, decide(), decide_combined(), Decision, _dt() (+44 more)

### Community 2 - "run_research.py"
Cohesion: 0.08
Nodes (24): inline(), main(), load(), adopt_mgmt(), adopt_money(), cache_key(), daily_stats(), file_sha256() (+16 more)

### Community 3 - "Engine"
Cohesion: 0.05
Nodes (36): Engine, balance, consec_losses, cur_day, day_blocked, day_min_eq, day_ref, day_start_bal (+28 more)

### Community 4 - "XAUUSD M15 PD Array + Rejection Block + OTE 0.79 — Teknik Spesifikasyon v0.2"
Cohesion: 0.05
Nodes (39): 10. Emir yaşam döngüsü, 11. Doğrulama planı, 12.1 Ölçüm (yalnız kapanmış barlar, sinyali onaylayan bar `k`), 12.2 Politika (EA varsayılanları = koruyucu VARSAYIM), 12.3 Doğrulama sırası, 12. Volatilite ve piyasa rejimi (v0.3), 13.1 Karar kartı (her sinyalde journal'da `DECISION`), 13.2 Sonuç hikâyesi (her kapanışta journal'da `CLOSED`, trades.csv'de bir satır) (+31 more)

### Community 5 - "Options"
Cohesion: 0.05
Nodes (31): Options, balance, cfg, commission, dcfg, edge, end_close, expiry_bars (+23 more)

### Community 6 - "Pending"
Cohesion: 0.06
Nodes (30): Pending, active, bars_alive, ds, edge_mult, feat, lots, pct (+22 more)

### Community 7 - "rbote_bt.cpp"
Cohesion: 0.09
Nodes (12): load_csv(), main(), parse_time(), usage(), M1, bc, bh, bl (+4 more)

### Community 8 - "prop_firm.example.yaml"
Cohesion: 0.08
Nodes (25): account_size, consistency_rule, daily_loss, amount, includes_floating, reference, reset_time, reset_tz (+17 more)

### Community 9 - "fetch_dukascopy.py"
Cohesion: 0.19
Nodes (6): cache_path(), day_rows(), decode(), download(), fetch(), main()

### Community 11 - "M1"
Cohesion: 0.18
Nodes (10): M1, ac, ah, al, ao, bc, bh, bl (+2 more)

### Community 12 - "DTBS — Dynamic Trend Break System: Teknik Spesifikasyon v0.1"
Cohesion: 0.22
Nodes (8): 1. Kaynak görselden çıkan geometri (düşüş trendi, satış örneği), 2. Tanımlar (yalnız kapanmış barlar, lookahead yok), 3. Sinyal (mum kapanışıyla doğrulama, varsayılan), 4. Giriş, stop, hedef, 5. İki stratejinin birlikte çalışması, 6. Raporlama, 7. Doğrulama sırası, DTBS — Dynamic Trend Break System: Teknik Spesifikasyon v0.1

### Community 14 - "Test ve Canlıya Geçiş Kontrol Listesi"
Cohesion: 0.29
Nodes (6): Aşama 0 — Tanımlar ve bilgiler, Aşama 1 — Yazılım doğruluğu, Aşama 2 — Backtest, Aşama 3 — Demo forward test (MT5 demo hesap), Aşama 4 — Canlı (prop) geçiş, Test ve Canlıya Geçiş Kontrol Listesi

### Community 15 - "SigEx"
Cohesion: 0.33
Nodes (4): SigEx, candle_range, reg, sig

### Community 16 - "Bağımsız backtest, challenge simülasyonu ve araştırma planı"
Cohesion: 0.33
Nodes (5): Bağımsız backtest, challenge simülasyonu ve araştırma planı, MetaEditor under Wine (Linux), Neden ikinci bir backtest motoru, Simülasyon kuralları (muhafazakâr), Veri

### Community 18 - "DTBS backtest 2020-01-01 → 2026-10-23"
Cohesion: 0.40
Nodes (4): 2024 → 2026-10 (W0 only, the user's spec; nothing was selected), DTBS backtest 2020-01-01 → 2026-10-23, In-sample 2020–2023 (pre-registered plan D-036), Verdict

## Knowledge Gaps
- **112 isolated node(s):** `PATH`, `t`, `bo`, `bh`, `bl` (+107 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 277 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **13 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Engine` connect `Engine` to `Options`, `Pending`, `rbote_bt.cpp`, `.run`, `M1`, `string`, `SigEx`, `.snapshot`?**
  _High betweenness centrality (0.077) - this node is a cross-community bridge._
- **What connects `PATH`, `t`, `bo` to the rest of the system?**
  _112 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `analyze_trades.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06625258799171843 - nodes in this community are weakly interconnected._
- **Why does `_res()` connect `prop_sim.py` to `XAUUSD M15 PD Array + Rejection Block + OTE 0.79 — Teknik Spesifikasyon v0.2`?**
  _High betweenness centrality (0.067) - this node is a cross-community bridge._
- **Should `prop_sim.py` be split into smaller, more focused modules?**
  _Cohesion score 0.07960199004975124 - nodes in this community are weakly interconnected._
- **Why does `s()` connect `XAUUSD M15 PD Array + Rejection Block + OTE 0.79 — Teknik Spesifikasyon v0.2` to `prop_sim.py`?**
  _High betweenness centrality (0.066) - this node is a cross-community bridge._
- **Should `run_research.py` be split into smaller, more focused modules?**
  _Cohesion score 0.08163265306122448 - nodes in this community are weakly interconnected._