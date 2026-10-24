# Claude Code'a gönderilecek nihai uygulama promptu

Aşağıdaki bloğu olduğu gibi Claude Code'a gönder. Prompt, repodaki
`docs/01_STRATEJI_SPESIFIKASYONU.md` ve `config/*.example.yaml` dosyalarına dayanır.

---

```text
GÖREV: XAUUSD M15 PD Array + Rejection Block + OTE 0.79 sistemini uygula (Faz 1–3: çekirdek, backtest, rapor).
Canlı emir gönderen hiçbir kodu etkinleştirme. Kârlılık iddiası üretme.

KAYNAK BELGE (bağlayıcı): docs/01_STRATEJI_SPESIFIKASYONU.md
Belge ile bu prompt çelişirse belge geçerli. Belgede "Belirsizlik" veya "Q#" ile işaretli konularda
kendi varsayımını kodlama: config parametresi yap, varsayılanı belgedeki değer olsun, README'de listele.

BAĞLAM
- Repo şu an sadece docs/ ve config/ içeriyor. Dil: Python 3.11+. Paket adı: xau_rb_ote.
- MetaTrader5 Python paketi yalnız Windows'ta çalışır: import'u sadece adapters/mt5.py içinde, lazy yap.
  Çekirdek ve testler Linux'ta MT5 olmadan çalışmalı.
- Tek kod yolu: backtest, demo ve canlı AYNI SignalEngine ve RiskManager'ı kullanır; sadece Broker arayüzü değişir.

DOSYA YAPISI (oluştur)
pyproject.toml                      # deps: pandas, numpy, pyyaml, pydantic>=2, pytest, hypothesis; extra [mt5]: MetaTrader5
README.md                           # kurulum, çalıştırma, açık sorular listesi (spec §1)
config/strategy.example.yaml        # mevcut, gerekirse alan ekle
config/prop_firm.example.yaml       # mevcut
src/xau_rb_ote/__init__.py
src/xau_rb_ote/config.py            # pydantic modelleri, YAML yükleme, doğrulama
src/xau_rb_ote/types.py             # Bar, Tick, SymbolSpec, AccountState, Zone, Swing, RBCandidate, RBConfirmed,
                                    # EntryPlan, SizedOrder, OrderState, Trade, Reject(reason), enumlar
src/xau_rb_ote/data/loader.py       # CSV/Parquet M1/M15/H1/tick yükleme, M1→M15/H1 resample (sağ kapalı değil: bar açılış zamanı etiketi)
src/xau_rb_ote/data/quality.py      # eksik bar, boşluk, spread dağılımı raporu
src/xau_rb_ote/detect/indicators.py # ATR14 (Wilder), sadece kapanmış barlar
src/xau_rb_ote/detect/swings.py     # fraktal, known_at alanı (spec §3)
src/xau_rb_ote/detect/pd_arrays.py  # FVG, OB, (Breaker flag ile kapalı), geçersizlik, öncelik (spec §4)
src/xau_rb_ote/detect/rejection_block.py  # R1, R2, onay/iptal (spec §6)
src/xau_rb_ote/detect/htf_bias.py   # OFF, H1_BOS, H1_BOS_PD, H1_ZONE (spec §10)
src/xau_rb_ote/signal/ote.py        # RB_RANGE ve SWING_LEG formülleri, tick yuvarlama, SL/TP (spec §8)
src/xau_rb_ote/signal/engine.py     # durum makinesi: ACTIVE→ARMED→RB_CANDIDATE→RB_CONFIRMED→ORDER...; signal_id
src/xau_rb_ote/risk/sizing.py       # lot formülü (spec §9.1)
src/xau_rb_ote/risk/guard.py        # PropRuleGuard: günlük worst-case, toplam DD, eşzamanlı risk, işlem sayısı,
                                    # ardışık kayıp, haber, seans, cuma kesimi (spec §9.3, §13)
src/xau_rb_ote/exec/broker.py       # Broker Protocol: symbol_spec, account, bars, ticks, place_limit, cancel,
                                    # modify_sl(only_tighten=True), positions, orders, deals
src/xau_rb_ote/exec/sim_broker.py   # backtest dolum modeli (spec §11.2), M1 ve tick modu
src/xau_rb_ote/exec/order_manager.py# yaşam döngüsü, iptal kuralları (spec §8.5), idempotency
src/xau_rb_ote/exec/reconcile.py    # yeniden başlatma uzlaştırması (spec §13)
src/xau_rb_ote/adapters/mt5.py      # MT5 Broker uygulaması; demo kontrolü; live kilidi
src/xau_rb_ote/state/store.py       # SQLite: signals, orders, trades, daily_stats
src/xau_rb_ote/journal.py           # JSONL karar günlüğü (ts_utc, ts_server, module, event, signal_id, inputs, decision, reason)
src/xau_rb_ote/backtest/engine.py   # olay döngüsü: M15 kapanışında engine.on_bar, M1/tick ile sim_broker
src/xau_rb_ote/backtest/splits.py   # IS/VAL/OOS, walk-forward, rejim etiketleme
src/xau_rb_ote/backtest/metrics.py  # spec §11.5 tüm metrikler, bootstrap, Monte Carlo
src/xau_rb_ote/backtest/grid.py     # spec §11.4 test matrisi
src/xau_rb_ote/backtest/report.py   # Markdown + CSV rapor, kabul kriterleri PASS/FAIL (spec §11.6)
src/xau_rb_ote/cli.py               # komutlar: data-check, backtest, grid, report, demo-run, reconcile
tests/...                           # aşağıdaki test listesi
tests/fixtures/                     # elle yazılmış küçük bar dizileri (CSV), her senaryo için

KESİN KURALLAR (özet — ayrıntı spec'te)
1. Sadece kapanmış barlar. Her yapı known_at taşır; known_at > karar zamanı ise kullanılamaz.
2. FVG bull: high[i-2] < low[i], zone [high[i-2], low[i]]; bear: low[i-2] > high[i], zone [high[i], low[i-2]].
   Min boyut fvg_min_atr*ATR14, orta mum gövdesi >= displacement_body_atr*ATR14.
3. OB bull: son düşüş mumu j; j+1..j+M içinde önceki onaylı swing high üstünde kapanış VE bull FVG. Zone [low[j], high[j]]
   (BODY modu: [low[j], open[j]]). Bear ayna.
4. Geçersizlik: bull zone bottom altında kapanış (CLOSE modu) → INVALID. Sinyal üreten zone → USED. Yaş → EXPIRED.
5. ARM: bull zone için low[i] <= top ve close[i-1] > top. Dokunuş sinyal değildir.
6. Öncelik: HTF uyumu > FVG∩OB confluence > yeni formed_at > fiyata yakınlık > id. Zıt yönlü eşzamanlı arm → sinyal yok.
7. RB bull R1: low<=top, close>bottom, alt fitil/menzil >= 0.50, fitil >= 0.25*ATR14, low son 5 barın en düşüğü.
   L = low, B = min(open, close). Onay: 3 bar içinde high[c] üstünde kapanış; öncesinde low < L → iptal.
   Bear ayna. R2: eşit diplerden küme (spec §6.2).
8. OTE RB_RANGE: bull E = B - 0.79*(B-L); bear E = U + 0.79*(H-U).
   SWING_LEG: bull E = SH - 0.79*(SH-L); bear E = SL + 0.79*(H-SL).
   Buy limit floor'a, sell limit ceil'e tick yuvarla. R<=0, R<min_range_atr*ATR, ankraj yok,
   veya E fiyatın yanlış tarafında → Reject (market emre dönüştürme YOK).
9. SL STRUCTURAL: bull L - buffer, bear H + buffer; buffer = max(sl_buffer_price, mult*spread).
   FIXED: E ∓ fixed_stop_price (FİYAT birimi); SL yapısal seviyenin ötesinde değilse Reject.
   Stop < (stops_level+freeze_level)*point veya < 3*spread → Reject. SL asla aleyhte genişletilmez
   (modify_sl only_tighten=True, aksi istek exception).
10. TP = E ± n*|E-SL|, n ∈ {5,6}. Opsiyonel maliyet düzeltmesi.
11. Emir iptali: expiry_bars, fill öncesi TP'ye ulaşma, L/H ötesinde kapanış, zone INVALID, guard deny, spread.
    Broker'a ORDER_TIME_SPECIFIED expiry ile gönder. signal_id = sha1(symbol|tf|zone_id|rb_confirmed_at|anchor_mode),
    aynı signal_id için ikinci emir yok (SQLite + broker comment kontrolü).
12. Lot: risk_money = risk_pct*min(balance,equity); loss_per_lot = stop_ticks*tick_value_loss + commission_rt
    + slippage_ticks*tick_value_loss; lots = floor_step(risk_money/loss_per_lot);
    lots<min → Reject (yukarı yuvarlama YOK); lots*loss_per_lot > risk_money → Reject; marj yetersiz → Reject.
13. Guard: worst_case_today = realized_today + floating + Σ open remaining risk + Σ pending risk + new risk
    <= daily_loss_limit. Aşılırsa yeni emir yok + bekleyenler iptal. Hesaptaki TÜM pozisyonlar korelasyon=1.
14. HTF: sadece kapanmış H1 barları.

TESTLER (pytest; hepsi Linux'ta MT5 olmadan geçmeli)
Birim:
- swings: known_at doğru; son N bar onaysız; eşit high'larda deterministik.
- FVG: bull/bear tespit; min boyut filtresi; displacement filtresi; i (oluşmakta olan) bar eklenince sonuç değişmiyor.
- OB: BOS+FVG şartı; BODY/FULL modları; BOS olmadan OB yok.
- Geçersizlik: CLOSE vs WICK; USED zone ikinci sinyal üretmiyor; EXPIRED.
- Öncelik: confluence kazanır; zıt yönlü eşzamanlı arm → sinyal yok.
- RB R1/R2: geçerli oluşum; fitil oranı yetersiz; onaydan önce süpürme → iptal; onay süresi dolması;
  bölge altında kapanış → RB değil + zone INVALID.
- OTE: spec §8.2 sayısal örneği birebir (E=2648.92, SL=2647.70, TP5=2655.02, TP6=2656.24; SWING_LEG E=2650.10);
  bear ayna örneği; tick yuvarlama yönleri; R<=0 reject.
- Stop: FIXED yapısal seviyeyi geçmiyorsa reject; stop < 3*spread reject; modify_sl genişletme → exception.
- Sizing: spec §9.2 tablosunun 4 satırı birebir; lot<min reject; normalizasyon sonrası risk kontrolü;
  digits=3 sembol ile ayrı test.
- Guard: günlük worst-case örneği (realized -500, açık 250, bekleyen 250, yeni 250, limit 1000 → deny);
  gün sınırında sıfırlama (server tz); ardışık kayıp halt; haber penceresi; cuma kesimi.
- Lookahead özellik testi (hypothesis): rastgele bar dizisinde, t anındaki sinyaller veri t'de kesilerek
  hesaplanan sinyallerle aynı.
Entegrasyon (sim_broker):
- Buy limit ask ile dolar (low_bid+spread<=E); sell limit bid ile.
- Aynı barda dolum+SL → zarar; aynı barda SL+TP → SL (M1 modu), tick modunda gerçek sıra.
- Fill öncesi TP'ye ulaşınca iptal; expiry; zone invalid iptali.
- Duplicate: aynı sinyal iki kez işlenince tek emir.
- Yeniden başlatma: motor ortada kesilip state.sqlite'tan yeniden kurulunca sonuçlar kesintisiz koşu ile aynı.
- Bağlantı kesintisi: veri boşluğu > 2 bar → HALTED, yeni emir yok.
- Reconcile: DB'de olmayan broker emri iptal; SL'siz pozisyona SL eklenir.
Rapor:
- Sentetik veri ile grid çalışır, tüm metrik alanları dolu, kabul kriterleri PASS/FAIL hesaplanır;
  OOS işlem < 100 → "YETERSİZ VERİ / FAIL".

KABUL KRİTERLERİ (bu görev için — strateji başarısı değil, yazılım doğruluğu)
1. `pytest -q` tamamen yeşil; çekirdek modüllerde satır kapsamı >= %90 (pytest-cov).
2. `ruff` ve `mypy --strict src/` temiz.
3. `xau_rb_ote backtest --config config/strategy.example.yaml --data <csv>` sentetik veriyle uçtan uca çalışır,
   reports/ altına Markdown + CSV üretir; her işlem için signal_id, zone, RB, E/SL/TP, lot, risk, sonuç, sebep var.
4. Her Reject/Cancel journal'da sebebiyle görünür.
5. `mode: live` ile başlatma: prop_firm.verified=false veya env XAU_RB_OTE_LIVE_CONFIRM yoksa/yanlışsa
   sıfırdan farklı kodla çıkar ve emir göndermez (testli).
6. `mode: demo`: hesap ACCOUNT_TRADE_MODE_DEMO değilse çıkar (mock ile testli).
7. Hiçbir yerde sabit point/tick değeri yok; hepsi SymbolSpec'ten.
8. README: kurulum, komutlar, açık sorular (spec §1), "10 point" tablosu (spec §7), sonuç uydurma yasağı.

YAPMA
- Gerçek veri yokken sonuç/metrik yazma; örnek sonuçları "gerçek" diye sunma.
- Prop firma adı/kuralı uydurma; config/prop_firm.yaml'ı doldurma.
- Live emir yolunu varsayılan açık bırakma; martingale, grid, SL genişletme, ortalama düşürme ekleme.
- Spec'teki belirsizlikleri kodda sessizce çözme.

ÇALIŞMA SIRASI
1. pyproject + types + config + testler için fixture'lar.
2. TDD ile: indicators → swings → pd_arrays → rejection_block → ote → sizing → guard → engine.
3. sim_broker + order_manager + backtest engine + metrics + report + grid.
4. state store + journal + reconcile + mt5 adapter (mock'lu testler).
5. README. Her adımda commit; mesajlar İngilizce, açıklayıcı.
Bitirince: yapılanları, açık kalan soruları ve kullanıcının gerçek veriyle çalıştırması gereken komutları raporla.
```

---

## Sonraki fazlar (ayrı prompt, kullanıcı onayıyla)

- **Faz 4 — Gerçek veri araştırması:** Kullanıcı broker M1/tick verisini sağlar → `data-check` → IS grid → doğrulama → OOS (tek sefer) → rapor. Kabul kriterleri spec §11.6.
- **Faz 5 — Demo forward test:** En az 8 hafta veya 50 işlem (hangisi geçse), backtest ile işlem-işlem karşılaştırma.
- **Faz 6 — Canlı:** Yalnız prop kuralları doğrulanmış, Faz 4–5 PASS ve kullanıcı açık yazılı onay verdiyse.
