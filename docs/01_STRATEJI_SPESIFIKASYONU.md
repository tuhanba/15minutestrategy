# XAUUSD M15 PD Array + Rejection Block + OTE 0.79 — Teknik Spesifikasyon v0.2

Durum: **Uygulandı (MQL5 EA), backtest edilmedi.** Bu belge kârlılık iddiası içermez.

v0.1 → v0.2 değişiklikleri:
- Platform kararı: **saf MQL5 EA** (kullanıcı kararı). Python yolu kaldırıldı.
- Fibonacci **yalnızca RB sınırlarına** çizilir (kaynak görsel). "Swing bacağı" modu kaldırıldı.
- RB tanımı görsele göre tek mum: fitil = Fib 1, gövde ucu = Fib 0.
- RBOTE varsayılan KAPALI: 2020-2023 IS'te hiçbir stop varyantı kârlı değil (reports/rbote_stop_IS_2020_2023.md, D-038). Stop varsayılanı sabit 10.00 (en az kötü).
- Varsayılan hedef 6R, alternatif 5R.

---

## 1. Kaynak görselden çıkan kurgu (bullish örnek)

```
   ┌── RB mumu (yukarıdan gelip FVG/OB'ye fitil atan mum)
   │
   █  ← gövde                       Fib 0    = RB üst sınırı (gövde altı)
   █
   │  ┐                            Fib 0.5 / 0.62 / 0.705
   │  │ 15M FVG
   │  │                            Fib 0.79 = BUY LIMIT
   │  ┘
   │ ─── 15M OB                    Fib 1    = RB alt sınırı (fitil dibi)
   ▼                               Stop: 10.00 (girişin altında)
                                   Target: 60.00 = 6R
```

Görseldeki etiketler: `Stop: 10.00`, `Target: 60.00`, `Risk/reward ratio: 6`.
Grafik TradingView pozisyon aracıdır. Bu araç mesafeyi **fiyat birimiyle** gösterir.
Kaynak hesap adı "nq.rich" olduğundan strateji büyük ihtimalle **NQ (Nasdaq vadeli)** üzerinde gösterilmiştir.
XAUUSD'ye aktarıldığında "10"un karşılığı **doğrulanmamış varsayımdır** (§7).

## 2. Genel kurallar

1. Yalnız M15 ve yalnız **kapanmış** mumlar (`CopyRates(..., start=1, ...)`).
2. Her bar kapanışında son `InpLookbackBars` mum baştan taranır (deterministik, restart-safe).
3. EA yalnızca **az önce kapanan mumda onaylanan** sinyale göre işlem yapar.
4. Her bölge en fazla bir sinyal üretir (`USED`).
5. Lookahead yasağı birim testiyle doğrulanır: kesilmiş seri ile tam seri, kesim noktasına kadar aynı sonucu vermelidir.

## 3. PD Array tanımları

### 3.1 FVG (mumlar i-2, i-1, i — i kapanınca bilinir)

| | Koşul | Bölge |
|---|---|---|
| Bullish | `high[i-2] < low[i]` | `[high[i-2], low[i]]` |
| Bearish | `low[i-2] > high[i]` | `[high[i], low[i-2]]` |

Opsiyonel minimum boyut: `InpFvgMinATR × ATR14` (varsayılan kapalı).

### 3.2 Order Block (FVG oluştuğu anda değerlendirilir)

- **Bullish:** `[i-1-InpObLookback, i-2]` aralığındaki **son düşüş mumu** `j`. Ayrıca `(j, i]` içinde bir mum, `j` anında **onaylı** son swing high'ın üstünde kapanmalı (BOS). Bölge `[low[j], high[j]]`.
- **Bearish:** Ayna kural: son yükseliş mumu ve onaylı swing low altında kapanış.
- Swing: fraktal, `InpSwingN` (varsayılan 2). Swing `s` ancak `s + N` mumu kapandıktan sonra kullanılır.

### 3.3 Bölge yaşam döngüsü

| Olay | Durum |
|---|---|
| Mum bölgenin uzak ucunun ötesinde **kapanır** | `INVALID` |
| Bölge bir RB üretti | `USED` (tekrar sinyal yok) |
| `InpZoneMaxAgeBars` aşıldı (varsayılan 192) | `EXPIRED` |
| Fitil girdi ama RB şartları yok | `ACTIVE` kalır (dokunuş sinyal değildir) |

## 4. Rejection Block (M15)

Bullish RB, mum `k`'de, ACTIVE bir bullish bölge Z için:

| # | Şart | Varsayılan / Not |
|---|---|---|
| 1 | Fitil bölgeye girer: `low[k] <= Z.top` | kaynak |
| 2 | Gövde reddedilir: `min(open,close) > Z.top` | kaynak görsel; alternatif `close > Z.bottom` (`InpRbCloseRule`) |
| 3 | Red fitili: `(min(o,c) − low) / (high − low) >= 0.5` | **VARSAYIM** (`InpRbMinWickRatio`) |
| 4 | Fiyat dışarıdan gelir: `close[k-1] > Z.top` | **VARSAYIM** (`InpRbRequireApproach`) |
| 5 | Onay: RB mumunun kapanışı | kaynak; alternatif: sonraki mum `high[k]` üstünde kapanır (`InpRbConfirm`) |

**RB sınırları (bullish):** `L = low[k]` (fitil dibi = Fib 1), `H = min(open[k], close[k])` (gövde altı = Fib 0).
**Bearish:** Ayna kural. `H = high[k]` (fitil tepesi = Fib 1), `L = max(open[k], close[k])` (gövde üstü = Fib 0).

Aynı mum birden fazla bölgeyi reddederse tek sinyal üretilir. Birincil bölge sırası: en yeni → FVG → fiyata en yakın.
Reddedilen tüm bölgeler `USED` olur. Aynı mum hem bull hem bear bölgeyi reddederse sinyal üretilmez.

## 5. Fibonacci ve giriş

```
Bullish:  Entry = H − 0.79 × (H − L)   → Buy Limit   (tick'e aşağı yuvarlanır)
Bearish:  Entry = L + 0.79 × (H − L)   → Sell Limit  (tick'e yukarı yuvarlanır)
```

- 0.79 giriş seviyesidir, TP değildir.
- `L < Entry < H` şartı sağlanmazsa emir verilmez.
- Buy limit için `Entry < Ask`, sell limit için `Entry > Bid` şartı aranır. Aksi halde emir verilmez ve market emre dönüştürülmez.

Örnek: L = 2650.00, H = 2660.00 → bullish Entry = **2652.10**, bearish Entry = **2657.90**.

## 6. Stop-loss ve take-profit

| Mod | Long SL | Short SL | Not |
|---|---|---|---|
| `FIXED` (varsayılan, D-038) | `Entry − d` | `Entry + d` | d = `InpStopDistance` × birim. SL tick'e **girişe doğru** yuvarlanır, asla genişlemez. Kaynaktaki "10" yalnız örnekti (kullanıcı); yine de IS'te en az kötü varyant (PF 0.97) |
| `STRUCTURAL` (karşılaştırma) | `L − buffer` | `H + buffer` | IS 2020-2023: −0.49R/işlem (D-038). `InpMaxStopATR` / `InpMinStopATR` sınırları |
| `ATR` (araştırma) | `min(L − buffer, Entry − k·ATR)` | `max(H + buffer, Entry + k·ATR)` | k = `InpRbStopATR`; IS'te k 1–4 hepsi negatif |

- `InpRequireSlBeyondRb = true`: sabit stop RB'nin dış ucunun **ötesinde değilse** (long: `SL > L`) işlem reddedilir. Görselde stop Fib 1'in hemen altındadır.
  Sonuç: RB yüksekliği `d / 0.21`'i aşarsa sinyal reddedilir (d = 10 için RB > 47.6 fiyat birimi).
- `RiskDistance = |Entry − SL|`. TP long için `Entry + RR × RiskDistance`, short için `Entry − RR × RiskDistance`. Varsayılan RR = 6.
- Reddetme sebepleri:
  - `stops_level + freeze_level` altında stop
  - `2 × spread`'ten küçük stop
  - fiyata çok yakın giriş
- SL hiçbir koşulda genişletilmez. Yalnız eksik SL eklenebilir (`RB_SlChangeAllowed`).

## 7. "10" ve XAUUSD birim dönüşümü

EA şu değerleri MT5'ten okur ve başlangıçta loglar:
- `SYMBOL_DIGITS`, `SYMBOL_POINT`, `SYMBOL_TRADE_TICK_SIZE`
- `SYMBOL_TRADE_TICK_VALUE_LOSS`, `VOLUME_MIN/MAX/STEP`
- `TRADE_STOPS_LEVEL`, `TRADE_FREEZE_LEVEL`

| `InpRbStopUnit` | 10 → fiyat (digits=2, point=0.01) | 1 lotta (tick value 1 $) | Değerlendirme |
|---|---|---|---|
| `NOT_SET` (varsayılan) | — | — | **EA başlamaz** |
| `POINTS` | 0.10 | 10 $ | Spread kuralına takılır, işlem yok |
| `TICKS` | 0.10 | 10 $ | Aynı |
| `PRICE` | 10.00 | 1 000 $ | Görseldeki "10.00" fiyat okumasıyla tutarlı. XAUUSD için **doğrulanmalı** |

Ek risk: NQ'da 10 puan ile XAUUSD'de 10 $ volatiliteye göre aynı şey değildir.
Sabit stop ile yapısal stop karşılaştırması bu yüzden zorunludur (§10).

## 8. Lot ve risk

```
risk_money   = InpRiskPct% × min(balance, equity)                 (varsayılan 0.25%)
loss_per_lot = max( |E−SL|/tick_size × tick_value_loss,  OrderCalcProfit(1 lot, E→SL) )
             + InpCommissionPerLotRT + InpSlippageTicks × tick_value_loss
lots         = floor(risk_money / loss_per_lot / volume_step) × volume_step
Reddet: lots < volume_min  |  lots × loss_per_lot > risk_money  |  marj > serbest marjın %90'ı
```

Lot asla yukarı yuvarlanmaz. `InpMaxLots` ve `volume_max` üst sınırdır.

| Equity | Stop | Lot başı zarar (komisyon 7 $) | Lot | Risk |
|---|---|---|---|---|
| 100 000 | 1.00 | 107 $ | 2.33 | 249.31 $ |
| 100 000 | 10.00 | 1 007 $ | 0.24 | 241.68 $ |
| 98 000 | 1.22 | 129 $ | 1.89 | 243.81 $ |
| 100 000 | 0.10 | — | — | Red: stop < 2 × spread |

## 9. Günlük ve hesap koruması (test limitleri — firma kuralı DEĞİL)

```
worst_day = realized_today
          − Σ (açık pozisyonlar: AÇILIŞ fiyatından SL'ye zarar + komisyon)   ← floating dahil, tekrar eklenmez
          − Σ (bekleyen emirler: emir fiyatından SL'ye zarar + komisyon)
          − yeni emrin riski
izin: worst_day >= −InpDailyLossPct% × day_start_ref
```

- `day_start_ref`: gün başındaki `max(balance, equity)`. Yeniden başlatmada bugünkü kapanmış işlemlerden geri hesaplanır.
- Hesaptaki **tüm** pozisyon ve emirler sayılır (her magic, her sembol) ve korelasyon 1 kabul edilir.
- SL'siz pozisyon veya emir varsa yeni emir yok.
- Ek sınırlar:
  - açık + bekleyen + yeni risk ≤ `InpMaxOpenRiskPct`
  - günlük giriş sayısı, maksimum pozisyon ve maksimum bekleyen emir sınırları
  - opsiyonel toplam DD tabanı
- Gün içi zarar limite ulaşırsa bekleyen emirler iptal edilir ve gün kapanana kadar yeni emir verilmez.

## 10. Emir yaşam döngüsü

```
RB onaylandı → duplicate kontrolü → filtreler → plan → piyasa kontrolü → lot → guard
            → ORDER_SENT (ticket) → FILLED (OnTradeTransaction, broker deal) → CLOSED (net = profit+commission+swap+fee)
            → ORDER_CANCELLED / ORDER_EXPIRED / SIGNAL_REJECTED (sebep)
```

**İptal kuralları** (her kapanan bar, sinyalden sonraki tüm barlar kontrol edilir):
- fill olmadan TP'ye ulaşıldı (tick seviyesinde de kontrol edilir)
- mum RB dış ucunun ötesinde kapandı
- PD bölgesi geçersiz oldu
- `InpOrderExpiryBars` doldu (varsayılan 8; sembol destekliyorsa sunucu tarafı `ORDER_TIME_SPECIFIED`)
- günlük limit aşıldı
- cuma kesimi

**Duplicate engeli:**
- `signal_id = RBOTE|B|<rb_time>` emir yorumuna yazılır.
- Global variable işareti tutulur.
- Açık emir, pozisyon ve son 7 günün emir geçmişi kontrol edilir.

**Uzlaştırma** (başlangıçta, her barda ve yeniden bağlanınca):
- Metadatası olmayan bekleyen emir iptal edilir.
- SL'siz pozisyona kayıtlı SL geri yazılır. Kayıt yoksa pozisyon kapatılır.

## 11. Doğrulama planı

1. `make test`: saf mantık testleri (g++). MT5 içinde aynı testler `RBOTE_Tests` script'i ile çalışır.
2. MetaEditor'de derleme (bu ortamda yapılamadı, bkz. README).
3. Strategy Tester, "Every tick based on real ticks":
   - 6R sabit stop, 5R sabit stop, 6R yapısal stop
   - IS ve OOS dönemleri ayrı
4. `tools/analyze_trades.py`:
   - expectancy ve bootstrap güven aralığı, PF, DD, Monte Carlo
   - yıl, volatilite ve yön kırılımları
   - kabul kontrolleri
5. Demo forward test (bkz. `03_TEST_VE_CANLI_GECIS_KONTROL_LISTESI.md`).

Kabul kriterleri (OOS):
- ≥ 100 işlem
- net expectancy > 0 ve bootstrap %95 alt sınırı > 0
- PF ≥ 1.30
- Monte Carlo DD p95 < %10
- OOS expectancy ≥ IS'in %50'si
- yılların ≥ %60'ı pozitif

Biri sağlanmazsa sonuç **FAIL** olur.

## 12. Volatilite ve piyasa rejimi (v0.3)

Kaynak strateji volatilite veya yatay piyasa için **kural vermiyor**. Aşağıdakiler ölçülebilir tanımlar ve
ayarlanabilir politikalardır. Hangi politikanın doğru olduğuna backtest'teki rejim kırılımına bakılarak karar verilir.

### 12.1 Ölçüm (yalnız kapanmış barlar, sinyali onaylayan bar `k`)

```
VR (volatilite oranı) = ATR14(M15)[k] / ortalama(ATR14, son 960 bar ≈ 10 işlem günü)
ER (verimlilik oranı)  = |Close[k] − Close[k−32]| / Σ |Close[i] − Close[i−1]|   (32 bar = 8 saat)
```

| Sınıf | Koşul | Anlamı |
|---|---|---|
| EXTREME | VR ≥ 2.50 | Haber patlaması, ani çöküş/yükseliş |
| HIGH | VR ≥ 1.50 | Bugün altın normalden belirgin hareketli |
| LOW | VR ≤ 0.70 | Sakin, dar aralık |
| NORMAL | diğer | |
| +RANGE | ER ≤ 0.20 | Yatay / testere piyasa (volatilite sınıfına ek etiket) |

### 12.2 Politika (EA varsayılanları = koruyucu VARSAYIM)

| Rejim | İşlem | Risk | RR | Gerekçe |
|---|---|---|---|---|
| NORMAL | evet | ×1.0 | 6R | Kaynak kurgu |
| HIGH | evet | ×0.5 | 6R | Spread/kayma artar. Sabit stop gürültüye göre küçük kalır. Büyük RB'ler zaten `SL_INSIDE_RB` ile reddedilir |
| EXTREME | **hayır** | — | — | Fiyat boşlukları, spread patlaması, stop'un kaymayla aşılması |
| LOW | evet | ×0.5 | 6R | 6R hedefe ulaşmak için hareket yetmeyebilir |
| +RANGE | evet | ×0.5 | 6R | Yatay piyasada 6R hedef ihtimali düşer |
| Veri yetersiz | **hayır** | — | — | Ölçülemeyen rejimde işlem yok (fail-safe) |

Birleştirme kuralı:
- EXTREME her şeyi geçersiz kılar.
- Volatilite veya range politikasından biri "hayır" derse işlem açılmaz.
- Risk çarpanı en düşük olandır.
- RR override önce range politikasından, sonra volatilite politikasından alınır.

Her rejim için işlem açılıp açılmayacağı, risk çarpanı ve RR override EA girdisidir.

### 12.3 Doğrulama sırası

1. **Ölçüm koşusu:** `RBOTE_6R_fixed10price.set`. Rejim yalnız loglanır, her rejimde tam riskle işlem açılır.
2. `analyze_trades.py` raporundaki "EA regime" tablosundan her rejimin IS expectancy değeri okunur.
3. Politika yalnız IS verisine göre seçilir:
   - expectancy'si negatif olan rejim → `InpTrade...=false`
   - pozitif ama oynak olan rejim → çarpan
4. Seçilen politika (ör. `RBOTE_6R_fixed10price_regime.set`) OOS'ta **bir kez** çalıştırılır ve ölçüm koşusuyla karşılaştırılır.
5. Politika OOS'ta ölçüm koşusundan iyi değilse kullanılmaz.

Bir rejimde 30'dan az işlem varsa o rejim için karar verilmez. Varsayılan politika korunur.

## 13. Açıklanabilirlik ve adaptif risk (v0.4)

Amaç: Bot "sinyal geldi, işlem açtım" demekle kalmamalı. Her kararın **neye dayandığı** ve her sonucun **hangi koşullarda** oluştuğu kayıtlı olmalı.

### 13.1 Karar kartı (her sinyalde journal'da `DECISION`)

```
WHY: zone=FVG(hits 2) RB wick=65% of candle, RB height=1.10 ATR, stop=0.80 ATR |
     regime=HIGH VR=1.72 ER=0.41 -> x0.50 rr=6.0 | base=0.250% profit-scale=SCALED -> 0.298% |
     edge=EDGE x1.120 [dir=LONG n=31 avgR=0.45 contrib=0.027 | zone=FVG ... ] |
     final risk=167.20 (0.167% of 100,450.00)
```

Sırasıyla:
- **Setup:** bölge, RB ve stop ölçüleri.
- **Rejim:** volatilite ve yataylık değerleri, bunlardan çıkan risk çarpanı.
- **Kâr ölçeklemesi:** temel risk ve kâra göre yükseltilmiş risk.
- **Kenar:** her koşulun geçmiş işlem sayısı, ortalama R'si ve risk çarpanına katkısı.
- **Sonuç:** nihai risk.

Ardından `ORDER_SENT` veya `SIGNAL_REJECTED <sebep>` satırı gelir.

### 13.2 Sonuç hikâyesi (her kapanışta journal'da `CLOSED`, trades.csv'de bir satır)

```
WIN 5.82R by TP | went +6.05R / -0.31R before exit | dir=LONG zone=FVG vol=NORMAL range=TREND session=H06-11 |
zone hits=2 wick=65% RB=1.10 ATR stop=0.80 ATR | filled after 2 bars | risk 0.298% (SCALED, edge x1.12, regime x1.00)
```

trades.csv'deki ek alanlar:
- `exit_reason` (SL/TP/EA/MANUAL/STOP_OUT)
- `mfe_r` ve `mae_r`: işlem açıkken lehte ve aleyhte gidilen en uzak mesafe, R cinsinden
- `session`, `hour`, `weekday`, `zones_hit`, `wick_ratio`, `rb_range_atr`, `stop_atr`, `fill_delay_bars`
- `risk_pct`, `edge_mult`, `scale_reason`

`analyze_trades.py` bunlardan şunları üretir:
- her koşul için işlem sayısı, kazanma oranı ve expectancy tabloları
- kazananlarla kaybedenlerin sayısal ortalamaları
- önce +1R / +2R / +3R'ye gidip sonra stop olan kaybedenlerin oranı
- adaptif boyutlamanın etkisi: gerçek net sonuç ile aynı işlemlerin sabit riskle getireceği sonucun karşılaştırması

**Uyarı:** Bu tablolar **korelasyon** gösterir, nedensellik değil. 30'dan az işlemli kovalar `(small)` olarak işaretlenir.

### 13.3 Kâra göre risk artırma (bounded anti-martingale)

```
profit = balance − başlangıç bakiyesi
pct    = base_pct + profit_share × max(0, profit) / min(balance, equity)     (varsayılan share = %2)
pct    = min(pct, max_pct)                                                      (varsayılan cap = %0.5)
pct    = base_pct   eğer balance < tepe × (1 − %2)  veya  art arda ≥ 3 kayıp
```

Örnek: Hesap 100 000'den 105 000'e çıktıysa ek risk 5 000 × %2 = 100 $ olur. İşlem başına risk 262.5 $ + 100 $ ≈ %0.345.
- Ek risk **yalnız gerçekleşmiş kârdan** ödenir.
- Kayıpta veya tepe noktasından düşüşte risk otomatik olarak temele döner.
- Risk hiçbir zaman başlangıç riskinin altına inmez, `max_pct`'yi de aşmaz.
- Günlük limit ve açık risk kontrolleri (§9) her zaman en son söz sahibidir.

### 13.4 "Tutan yönde" riski artırma (kenar ağırlıklandırma)

Kapanan her işlem beş boyutta istatistiğe eklenir:
- yön (LONG/SHORT)
- bölge (FVG/OB)
- volatilite sınıfı
- yatay/trend
- seans (sunucu saati 0–5, 6–11, 12–17, 18–23)

Yeni sinyal için:

```
shrunk_d = Σ R(aynı kovadaki geçmiş işlemler) / (n + prior)        prior = 20 (küçük örneklemi 0'a çeker)
mult     = clamp(1 + gain × Σ_d shrunk_d, 0.5, 1.5)                 gain = 0.15
```

- 40 kapanmış işlemden önce mult = 1, yani ısınma dönemi.
- Yalnız **kapanmış geçmiş** işlemler kullanılır; gelecek veri kullanılmaz.
- Örnek: geçmiş LONG işlemleri ortalama +1R getirdiyse yeni LONG'larda risk artar. SHORT'lar kaybettirdiyse azalır.

Riskler:
- **Aşırı uyum:** geçmişte şans eseri iyi giden kova ödüllendirilebilir. Shrinkage ve 0.5–1.5 sınırı bunu yumuşatır ama ortadan kaldırmaz.
- **Rejim değişimi:** geçmişte işe yarayan koşul ileride yaramayabilir.
- **Prop limiti:** kârın artırdığı risk art arda kayıplarla günlük limite daha hızlı yaklaşır. Kayıp serisi freni ve günlük guard bunu sınırlar.

### 13.5 Doğrulama

`RBOTE_6R_fixed10price_regime` (sabit risk) ile `RBOTE_6R_fixed10price_adaptive` aynı dönemde çalıştırılır.
Adaptif koşu yalnız şu iki şart birlikte sağlanırsa kullanılır:
- OOS'ta net sonuç **ve** Monte Carlo DD p95 daha iyi ya da kabul edilebilir.
- Günlük limit ihlali yok.

Aksi halde sabit risk kullanılır.
