# RBOTE — XAUUSD M15 PD Array + Rejection Block + OTE 0.79 (MQL5 EA)

Durum: **EA yazıldı, saf mantık testli. MetaEditor derlemesi ve backtest henüz YAPILMADI.**
Performans iddiası yok. Varsayılan ayarlar gerçek hesapta çalışmayı reddeder.

## Strateji (tek cümle)

M15'te FVG veya Order Block'a fitil atıp gövdesi bölgenin dışında kapanan mum Rejection Block'tur (RB).
Fibonacci RB'nin fitil ucu (1) ile gövde ucu (0) arasına çizilir. 0.79 seviyesine limit emir girilir.
Stop sabit mesafededir (kaynakta 10), hedef 6R'dir (5R alternatif). Ayrıntı: [docs/01_STRATEJI_SPESIFIKASYONU.md](docs/01_STRATEJI_SPESIFIKASYONU.md).

```
Bullish:  Entry = H − 0.79 × (H − L)    Buy Limit     L = fitil dibi, H = gövde altı
Bearish:  Entry = L + 0.79 × (H − L)    Sell Limit    L = gövde üstü, H = fitil tepesi
RiskDistance = |Entry − SL|      TP = Entry ± RR × RiskDistance      (RR = 6 veya 5)
lots = floor( risk_money / loss_per_lot / step ) × step     risk_money = 0.25% × min(balance, equity)
```

## Dosyalar

| Yol | İçerik |
|---|---|
| `MQL5/Experts/RBOTE/RBOTE_EA.mq5` | EA: girdiler, OnInit güvenlik kapıları, bar döngüsü, emir yönetimi, uzlaştırma, fill/close kaydı, OnTester |
| `MQL5/Include/RBOTE/Compat.mqh` | Saf mantığın g++ ile de derlenmesini sağlar (MQL5'te boş) |
| `MQL5/Include/RBOTE/Types.mqh` | Enum'lar, `RBBar/RBZone/RBSignal/RBPlan/RBSymbolSpec`, `CRBVec`, `CRBSeries` |
| `MQL5/Include/RBOTE/Config.mqh` | Strateji parametreleri ve varsayılanlar |
| `MQL5/Include/RBOTE/PDArray.mqh` | ATR, fraktal swing, FVG, Order Block |
| `MQL5/Include/RBOTE/RejectionBlock.mqh` | Bölge yaşam döngüsü, RB tespiti/onayı, `RB_Scan` |
| `MQL5/Include/RBOTE/TradeMath.mqh` | Fib girişi, SL/TP, birim dönüşümü, piyasa kontrolleri, lot hesabı |
| `MQL5/Include/RBOTE/RiskGuard.mqh` | Günlük zarar, açık risk, toplam DD, işlem sayısı sınırları |
| `MQL5/Include/RBOTE/Safety.mqh` | Canlı mod kapısı, veri tazeliği, bekleyen emir iptali, uzlaştırma kararları, signal id |
| `MQL5/Include/RBOTE/MT5Bridge.mqh` | Sembol özellikleri, hesap risk snapshot'ı, emir metadatası (global variables), duplicate kontrolü, ekonomik takvim |
| `MQL5/Include/RBOTE/Journal.mqh` | CSV karar günlüğü ve kapanan işlemler dosyası |
| `MQL5/Include/RBOTE/Tests/TestCases.mqh` | Ortak birim testleri (MT5 script'i ve g++ aynı dosyayı çalıştırır) |
| `MQL5/Scripts/RBOTE/RBOTE_Tests.mq5` | Testleri MT5 içinde çalıştıran script |
| `MQL5/Presets/*.set` | Tester ön ayarları: 6R sabit, 5R sabit, 6R yapısal |
| `tests/cpp/run_tests.cpp`, `Makefile` | Testleri Linux/CI'da g++ ile çalıştırma |
| `tools/analyze_trades.py` (+ `tools/tests`) | Tester çıktısı analizi: expectancy, CI, PF, DD, Monte Carlo, IS/OOS, rejimler, kabul kontrolleri |
| `config/prop_firm.example.yaml` | Prop firma kuralları kayıt şablonu (doldurulmadı) |
| `docs/` | Spesifikasyon ve test/canlıya geçiş kontrol listesi |

## Mimari

```
OnTick ─┬─ bağlantı yok → HALTED (işlem yok) ─ yeniden bağlanınca Reconcile
        ├─ gün değişimi → day_start_ref
        ├─ tick: bekleyen emir TP'ye fill'siz ulaştı mı → iptal
        └─ yeni M15 barı → OnNewBar
OnNewBar: CopyRates(kapanmış barlar) → bekleyen emir iptal kontrolleri → Reconcile
          → günlük limit kontrolü → veri tazeliği → RB_Scan (saf) → son barda onaylı sinyal?
          → ProcessSignal: duplicate → filtreler (gün blok, cuma, saat, haber, spread)
             → RB_BuildPlan → RB_CheckMarket → lot → marj → RB_CheckNewOrder → BuyLimit/SellLimit
OnTradeTransaction: FILLED / CLOSED (net = broker deal profit+commission+swap+fee, R = net / planlanan risk)
```

Backtest, demo ve canlı aynı kodu çalıştırır. Saf mantık (`RB_Scan`, `RB_BuildPlan`, `RB_CalcLots`, `RB_CheckNewOrder`…)
terminale dokunmaz. Terminal erişimi yalnız `MT5Bridge.mqh`, `Journal.mqh` ve EA dosyasındadır.

## Kurulum (Windows, MetaTrader 5)

1. MT5'te **File → Open Data Folder**. Bu repodaki `MQL5/` klasörünün içeriğini açılan `MQL5/` klasörüne kopyala (Experts, Include, Scripts, Presets).
2. MetaEditor'de `Scripts/RBOTE/RBOTE_Tests.mq5` ve `Experts/RBOTE/RBOTE_EA.mq5` dosyalarını derle (F7). **0 hata** olmalı.
3. `RBOTE_Tests` script'ini herhangi bir grafiğe sürükle. Experts sekmesinde `RBOTE tests: passed=150 failed=0` ve `ALL PASSED` görünmeli.
4. **Demo** hesapta XAUUSD M15 grafiğine EA'yı ekle. **Algo Trading** açık olmalı.
   - `InpStopUnit` seçilmezse EA başlamaz. `PRICE` seçmek, "10" değerini 10.00 fiyat birimi kabul etmek demektir.
   - `InpCommissionPerLotRT` alanına broker komisyonunu gir.
5. Journal: `MQL5/Files/RBOTE/<sembol>_<magic>_<login>_journal.csv`. Tester'da: `Common/Files/RBOTE/tester_*`.

Gerçek hesapta EA ancak şu üç girdi birlikte ayarlanırsa çalışır:
- `InpAllowLiveTrading=true`
- `InpLiveConfirmLogin=<hesap no>`
- `InpPropRulesVerified=true`

Aksi halde `INIT_REFUSED` verir. Contest hesapları her durumda reddedilir.

## Testler

```bash
make test                         # g++: ortak MQL5 testleri (150 kontrol)
python3 -m pytest -q tools/tests  # analiz aracı testleri
```

Kapsanan durumlar:
- bullish/bearish FVG ve OB, BOS olmadan OB oluşmaması, swing onay zamanı
- fitil + gövde kuralı, yaklaşma kuralı, zayıf fitil, onaysız RB'den emir çıkmaması, süpürülen RB
- RB sınırları, bullish/bearish 0.79, tick yuvarlama yönü, limit emir yönü, SL tarafı, 5R/6R
- SL'nin RB içinde kalması durumunda red, point/tick/fiyat dönüşümü, spread ve broker minimum stop
- lot normalizasyonu ve risk sınırı, komisyon ve kayma payı
- günlük limit (bekleyen emirler dahil, risk çift sayılmadan), açık risk, toplam DD
- bölgenin tek kullanımı ve geçersizliği, süre dolması, signal id
- iptal kuralları, uzlaştırma kararları, SL'nin genişletilmemesi, bağlantı kesintisi ve bayat veri
- bozuk sembol özellikleri, canlı mod kapısı
- lookahead: rastgele seride kesilmiş ve tam seri karşılaştırması

Testlerin gerçekten hata yakaladığı mutasyonlarla kontrol edildi. Fib yönü, onay, yaklaşma ve gövde kuralı, bölge tüketimi, swing onayı, stop yeri, günlük limit ve canlı mod kapısı tek tek bozuldu ve her biri en az bir testi kırdı.

## Backtest

1. Strategy Tester:
   - Expert `RBOTE\RBOTE_EA`, sembol XAUUSD, **M15**
   - Model **Every tick based on real ticks**
   - Gecikme: gerçekçi bir değer (ör. 50–100 ms)
   - Sembol özelliklerinde broker komisyonu ayarlı olmalı
2. `MQL5/Presets` içinden ön ayar yükle ve aynı tarih aralığında üç koşu yap:
   - `RBOTE_6R_fixed10price`
   - `RBOTE_5R_fixed10price`
   - `RBOTE_6R_structural`
3. Dönemler: IS (ör. 2020-01-01 → 2023-12-31) ve OOS (2024-01-01 → bugün). OOS'a bakmadan önce parametreleri sabitle.
4. Her koşu `Common/Files/RBOTE/tester_XAUUSD_<magic>_<zaman>_trades.csv` üretir. Analiz:

```bash
python3 tools/analyze_trades.py \
  6R_fixed=path/to/tester_..._trades.csv \
  5R_fixed=path/to/tester_..._trades.csv \
  6R_struct=path/to/tester_..._trades.csv \
  --oos-start 2024-01-01 --risk-pct 0.25 --balance 100000 --daily-limit-pct 1.0 -o report.md
```

Raporun içeriği:
- işlem sayısı, kazanma oranı, ortalama kazanç/kayıp (R ve para)
- net expectancy ve bootstrap %95 güven aralığı
- profit factor, net sonuç, maksimum DD, Monte Carlo DD p95
- günlük limitin aşıldığı günler
- yıl, ATR tercili (volatilite rejimi) ve yön kırılımları
- kabul kontrolleri (PASS/FAIL)

En az 100 OOS işlemi yoksa sonuç FAIL olur.

## Demo test planı

Ayrıntılar `docs/03_TEST_VE_CANLI_GECIS_KONTROL_LISTESI.md` içinde.
- En az 8 hafta veya 50 işlem.
- Her demo işlemi aynı dönemin tester işlemiyle eşleştirilir.
- Senaryolar:
  - EA'yı kaldır ve yeniden ekle: duplicate olmamalı, uzlaştırma çalışmalı
  - interneti kes: HALTED, ardından RESUMED
  - sunucu tarafında emir süresinin dolması
  - düşük günlük limitle zorlama: emirler iptal, gün bloke
  - cuma kesimi, haber penceresi
- Gerçekleşen R değerleri broker deal geçmişiyle karşılaştırılır.

## Bilinen sınırlamalar

- **MQL5 derlemesi doğrulanmadı.** MetaEditor bu bulut ortamında Wine altında kurulabildi, ama kopya koruması "A debugger has been found running in your system" hatası verip kapandı. İlk derlemede çıkan hatalar düzeltilmelidir. Saf mantık dosyaları g++ ile `-Wall -Wextra -Werror` altında temiz derleniyor ve testleri geçiyor. MT5'e bağlı kod (EA, MT5Bridge, Journal) hiç derlenmedi ve çalıştırılmadı.
- Ekonomik takvim filtresi Strategy Tester'da çalışmaz (MT5 kısıtı). Backtest haber filtresiz yapılır.
- Netting hesaplarda aynı semboldeki başka pozisyonlarla birleşme olabilir. Hedging hesap önerilir.
- `trades.csv` yalnız kapanmış işlemleri içerir. Gün içi floating zarar analizde yoktur. Tester raporundaki equity DD ayrıca okunmalıdır.
- Fill öncesi TP kontrolü canlıda tick bazlı, yeniden başlatmada bar bazlıdır.
- HTF (H1) filtresi uygulanmadı. Kaynak "one timeframe" stratejisi. İstenirse ayrı varyant olarak eklenip ölçülmeli.

## Çözülmemiş varsayımlar

| # | Konu | Varsayılan | Neden belirsiz |
|---|---|---|---|
| 1 | Stop "10"un birimi | Seçilmeden EA başlamaz. Ön ayarlar `PRICE` (10.00) kullanır | Görsel TradingView fiyat mesafesi gösteriyor ve kaynak muhtemelen NQ |
| 2 | RB fitil oranı ≥ 0.5 | `InpRbMinWickRatio` | Kaynakta sayısal eşik yok |
| 3 | Yaklaşma kuralı (önceki kapanış bölge dışında) | açık | Kaynakta açıkça yok |
| 4 | Onay = RB mumunun kapanışı | `InpRbConfirm` | Görselde ek onay mumu yok |
| 5 | Sabit stop RB ucunun ötesinde olmalı | açık | Görselde stop Fib 1'in hemen altında |
| 6 | OB tanımı (son karşı mum + BOS + FVG) | | Kaynakta OB kuralı verilmedi |
| 7 | Bölge ömrü 192 bar, emir ömrü 8 bar | | Kaynakta yok |
| 8 | Risk %0.25, günlük %1, açık risk %0.5 | | Test değerleri; firma kuralı değil |
| 9 | Prop firma adı ve kuralları | **bilinmiyor** | Kullanıcı sağlamadı |
