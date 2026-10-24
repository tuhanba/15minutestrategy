# XAUUSD M15 PD Array + Rejection Block + OTE 0.79 — Teknik Spesifikasyon

Durum: **TASLAK v0.1 — doğrulanmamış hipotez.** Bu belge kârlılık iddiası içermez.
Hiçbir parametre backtest/forward test ile doğrulanmadan canlı işlemde kullanılamaz.

---

## 0. Mevcut proje incelemesi (sonuç)

| Başlık | Bulgu |
|---|---|
| Dil / platform | Yok. Repo boş (commit yok, uzak dalda dosya yok). |
| MT5 bağlantısı | Yok. |
| Emir yönetimi | Yok. |
| Risk yönetimi | Yok. |
| Loglama / hata yönetimi | Yok. |
| Test altyapısı | Yok. |
| Mevcut stratejiler | Yok, çakışma yok. |
| Hesap / prop firma yapılandırması | Yok. Firma adı ve kuralları verilmedi. |
| Kaynak strateji (video vb.) | Repoda yok. Tanımlar yalnızca görev metninden alındı. |

Sonuç: "mevcut projeye uyarlama" yerine **sıfırdan, tek kod yolu (backtest = demo = canlı) olan** bir proje kurulacak.

---

## 1. Açık sorular ve belirsizlikler (uygulamadan önce cevaplanmalı)

Aşağıdakiler cevaplanana kadar ilgili davranış **yapılandırılabilir** yapılacak ve
varsayılan değer **en korumacı** seçenek olacak. Hiçbiri "kesin kural" kabul edilmeyecek.

| # | Konu | Neden önemli | Önerilen varsayılan |
|---|---|---|---|
| Q1 | Kaynak strateji (video linki, kesin RB ve OTE tanımı) | RB ve Fib ankraj noktaları kaynağa göre tamamen değişiyor | İki tanım da uygulanır, ayrı test edilir (§5, §6) |
| Q2 | "10 point" ne demek? | XAUUSD'de 0.10 $, 1.00 $ veya 10.00 $ fiyat mesafesi olabilir (§7) | Stop mesafesi **fiyat birimi** ile girilir, "point" ile değil |
| Q3 | Prop firma adı, program tipi, güncel kurallar | Günlük/toplam DD, reset saati, haber, hafta sonu, EA izni | Firma kuralı yok sayılır; kişisel limitler uygulanır (§9) |
| Q4 | Broker, sunucu, sembol adı (ör. `XAUUSD`, `XAUUSD.r`, `GOLD`) | digits/point/tick value/komisyon farklı | Çalışma anında MT5'ten okunur, sabit kodlanmaz |
| Q5 | Platform tercihi: Python+MT5 paketi mi, saf MQL5 EA mı? | Mimari kararı | Python çekirdek + MT5 adaptörü (§12, Karar D1) |
| Q6 | Gün sınırı (sunucu saati gece yarısı mı, 17:00 New York mu?) | Günlük zarar hesabı | Yapılandırılabilir, varsayılan sunucu 00:00 |
| Q7 | Tick verisi mevcut mu? Kaç yıllık? | Gerçekçi test | MT5 broker geçmişi; yoksa M1 + muhafazakâr kural |
| Q8 | Breaker Block dahil mi? | Kapsam | Faz 2 (opsiyonel), baseline'da kapalı |
| Q9 | 5R/6R tek hedef mi, kısmi kâr mı? | Sonuçları değiştirir | Tek hedef, kısmi yok, breakeven/trailing yok (baseline) |
| Q10 | Seans filtresi (London/NY killzone) kaynakta var mı? | Kaynakta belirtilmemiş | Kapalı; ayrıca test edilecek varyant |

---

## 2. Genel kurallar (tüm modüller)

1. **Yalnızca kapanmış mumlar** kullanılır. `i` = son kapanan M15 mumu. Oluşmakta olan mum sinyal mantığında asla okunmaz.
2. Bir yapının "bilinme zamanı" (`known_at`) kaydedilir. Hiçbir karar `known_at > karar_zamanı` olan bir yapıyı kullanamaz (lookahead yasağı).
3. Swing noktaları **fraktal** ile tanımlanır ve sağ taraftaki `N` mum kapanınca onaylanır (`known_at = time[j+N] + 15dk`).
4. Fiyatlar her zaman `tick_size`'a yuvarlanır.
5. Backtest, demo ve canlı **aynı sinyal motorunu** çalıştırır; sadece broker adaptörü değişir.
6. Bar verisi **Bid** fiyatıdır (MT5 standardı). Ask = Bid + spread.

---

## 3. Swing tanımı (fraktal)

- Swing high `j`: `high[j] > high[j-k]` ve `high[j] >= high[j+k]` her `k = 1..N` için. (Eşitlikte sağdaki elenir — deterministik.)
- Swing low `j`: `low[j] < low[j-k]` ve `low[j] <= low[j+k]` her `k = 1..N` için.
- Varsayılan `N = 2` (M15), `N_htf = 2` (H1).
- `known_at = close_time(j+N)`.

## 4. PD Array tanımları (M15)

Her bölge şu alanlarla kaydedilir:

```
Zone {
  id: str            # hash(symbol, tf, type, formed_bar_time)
  type: FVG | OB | BREAKER
  direction: BULL | BEAR      # BULL = destek (long arar), BEAR = direnç (short arar)
  top: float
  bottom: float
  formed_at: datetime         # bölgeyi oluşturan son mumun kapanışı (= known_at)
  status: ACTIVE | ARMED | USED | INVALID | EXPIRED
  invalidated_at, invalid_reason
  touches: int
}
```

### 4.1 Fair Value Gap (3 mum: i-2, i-1, i)

- **Bullish FVG:** `high[i-2] < low[i]`. Bölge: `bottom = high[i-2]`, `top = low[i]`.
- **Bearish FVG:** `low[i-2] > high[i]`. Bölge: `top = low[i-2]`, `bottom = high[i]`.
- Minimum boyut: `top - bottom >= fvg_min_atr * ATR14(M15)` (varsayılan `0.10`). Küçükler kaydedilmez.
- Orta mum (`i-1`) gövdesi `>= displacement_body_atr * ATR14` olmalı (varsayılan `0.8`) — "displacement" şartı.
- `formed_at = close_time(i)`.

### 4.2 Order Block

- **Bullish OB:** Son düşüş mumu `j` (`close[j] < open[j]`), ardından `j+1..j+M` (varsayılan `M = 3`) içinde:
  (a) bir mum, `j`'den önceki son onaylı swing high'ın **üstünde kapanır** (BOS), **ve**
  (b) bu yükseliş bacağında en az bir bullish FVG oluşur.
- Bölge: `top = high[j]`, `bottom = low[j]` (alternatif `ob_zone_mode = BODY`: `top = open[j]`, `bottom = low[j]`).
- **Bearish OB:** ayna — son yükseliş mumu, ardından swing low altında kapanış + bearish FVG.
- `formed_at` = (a) ve (b) şartlarının ikisinin de sağlandığı mumun kapanışı.

### 4.3 Breaker Block (Faz 2, varsayılan kapalı)

- Bullish OB, bir mum `bottom` altında kapanarak geçersiz olursa **ve** ardından daha düşük bir swing low onaylanırsa → aynı fiyat aralığı **bearish breaker** olur. Ayna kural bearish OB için.

### 4.4 Geçersizlik ve tüketim

| Olay | Sonuç |
|---|---|
| BULL bölgede bir M15 mumu `bottom` altında **kapanır** | `INVALID (close_through)` |
| BEAR bölgede bir M15 mumu `top` üstünde **kapanır** | `INVALID (close_through)` |
| Bölge bir sinyal üretti (RB onaylandı) | `USED` — tekrar sinyal üretmez |
| `formed_at`'ten sonra `zone_max_age_bars` geçti (varsayılan 192 = 2 gün) | `EXPIRED` |
| Bölge fiyatın yanlış tarafında oluştu (ör. BULL bölge fiyatın üstünde kaldı ve fiyat üstten gelmedi) | Kaydedilir ama sadece fiyat **dışarıdan** girerse armlanır |

Alternatif (test varyantı): `invalidation_mode = WICK` → fitil geçişi de geçersiz kılar.

### 4.5 Aynı anda birden fazla bölge — öncelik (deterministik)

Fiyat aynı mumda birden fazla aynı yönlü bölgeye girerse tek bölge seçilir:

1. HTF filtresi açıksa H1 bias ile uyumlu olanlar.
2. **Confluence**: FVG ile OB çakışan (kesişim > 0) bölge önce.
3. Daha yeni `formed_at`.
4. Fiyata daha yakın (`|close - zone_mid|` küçük).
5. Eşitlikte `id` sırası.

Zıt yönlü iki bölge aynı anda armlanırsa: **o mum için sinyal yok** (belirsizlik).

## 5. Fiyatın bölgeye ulaşması (ARM)

- BULL bölge `ACTIVE` iken, mum `i`'de `low[i] <= top` ve önceki mumun kapanışı `close[i-1] > top` (yani yukarıdan geliyor) → `ARMED`, `armed_at = close_time(i)`.
- Dokunuş **tek başına sinyal değildir**; sadece RB aramasını başlatır.
- ARMED durumunda `arm_timeout_bars` (varsayılan 8) içinde RB oluşmazsa bölge tekrar `ACTIVE` olur (en fazla `max_arms = 2`).
- Bölge geçersizlik kuralı (§4.4) ARMED durumda da çalışır.

## 6. Rejection Block (M15)

> **Belirsizlik:** ICT literatüründe Rejection Block, swing ucundaki uzun fitil(ler)in
> gövde ucu ile fitil ucu arasındaki aralıktır. Kaynak stratejinin tam tanımı verilmedi.
> Aşağıdaki **R1 (tek mum)** önerilen varsayılandır; **R2 (çok mum)** alternatiftir.
> İkisi de uygulanır, ayrı test edilir. Hangisinin kaynakla uyumlu olduğu kullanıcı onayı gerektirir.

### 6.1 Bullish RB — R1 (tek mum)

ARMED bir BULL bölgede, mum `c` için **tüm** şartlar:

1. `low[c] <= zone.top` (bölgeye girdi) ve `close[c] > zone.bottom` (bölgenin altında kapanmadı).
2. Alt fitil: `W = min(open[c], close[c]) - low[c]`; `W / (high[c] - low[c]) >= rb_min_wick_ratio` (varsayılan `0.50`).
3. `W >= rb_min_wick_atr * ATR14` (varsayılan `0.25`) — mikro fitiller elenir.
4. `low[c]` son `rb_lookback` (varsayılan 5) mumun en düşük low'u.

Aday RB aralığı:
- `rb_extreme = low[c]` (fitil ucu, **L**)
- `rb_body = min(open[c], close[c])` (gövde ucu, **B**)

**Onay (confirmation):** `c+1 .. c+rb_confirm_bars` (varsayılan 3) içinde bir mum `high[c]` üstünde **kapanır**.
- Onay mumundan önce herhangi bir mum `low < L` yaparsa → aday **iptal** (RB süpürüldü).
- Onay gelmeden süre dolarsa → aday iptal, bölge ARMED kalır.
- Onay anı = `rb_confirmed_at = close_time(onay_mumu)`. **Sinyal ancak bu andan sonra üretilir.**

### 6.2 Bullish RB — R2 (çok mum)

`c1, c2` (ardışık veya `rb_cluster_max_gap` içinde) mumlarının low'ları `rb_equal_tol * ATR14` (varsayılan `0.10`) toleransında eşitse:
- `L = min(low[c1], low[c2])`, `B = min(gövde altları)`. Diğer şartlar ve onay R1 ile aynı.

### 6.3 Bearish RB

Ayna: üst fitil `W = high[c] - max(open[c], close[c])`, `rb_extreme = high[c]` (**H**), `rb_body = max(open[c], close[c])` (**U**). Onay: bir mum `low[c]` altında kapanır; öncesinde `high > H` olursa iptal.

### 6.4 Mum kapanışının rolü

| Kapanış | Etki |
|---|---|
| RB mumu bölgenin karşı ucunun ötesinde kapanır | RB değil, bölge INVALID |
| Onay mumu RB mumunun ucunun ötesinde kapanır | RB onaylanır |
| Onaydan önce fitil RB ucunu geçer | RB iptal |
| Emir beklerken bir mum `L` altında (bull) / `H` üstünde (bear) kapanır | Emir iptal (yapı bozuldu) |

## 7. "10 point" ve XAUUSD sembol özellikleri

MT5'te değerler **her broker için çalışma anında okunur**: `digits`, `point`, `trade_tick_size`,
`trade_tick_value` (zarar tarafı `trade_tick_value_loss`), `trade_contract_size`, `volume_min/max/step`,
`trade_stops_level`, `trade_freeze_level`, `spread`.

Tipik (doğrulanması gereken) XAUUSD spesifikasyonu: `digits=2`, `point=0.01`, `tick_size=0.01`,
`contract_size=100 oz`, USD hesapta `tick_value ≈ 1.00 $/lot`.

| "10 point" yorumu | Fiyat mesafesi | 1 lotta parasal karşılık (tipik) | Değerlendirme |
|---|---|---|---|
| 10 × MT5 `point` (digits=2) | **0.10 $** | 10 $ | Tipik spread (0.10–0.40) ile aynı/küçük → **uygulanamaz** |
| 10 × MT5 `point` (digits=3) | **0.010 $** | 1 $ | Uygulanamaz |
| 10 "pip" (1 pip = 0.10) | **1.00 $** | 100 $ | Mümkün, çok dar |
| 10 "point" = 10 $ hareket (forum dili) | **10.00 $** | 1 000 $ | Mümkün, M15 swing ölçeğinde |

Kural: config'de `fixed_stop_price = <fiyat birimi>` girilir; `points` kullanılmaz.
Log ve raporda her zaman üçü birlikte yazılır: `price`, `points (= price/point)`, `money per lot`.

Stop reddedilir eğer:
- `stop_price < broker_min_stop = (stops_level + freeze_level) * point`, veya
- `stop_price < min_stop_spread_mult * current_spread` (varsayılan `3`), veya
- stop yapısal geçersizlik seviyesinin **ötesinde değilse** (§8.3).

## 8. OTE / Fibonacci ve emir seviyeleri

> **Belirsizlik:** Görev "RB'nin tanımlanmış fiyat aralığı üzerinde OTE" diyor. RB sınırları ile
> klasik OTE swing noktaları **aynı şey değildir**. İki ankraj modu uygulanır:
>
> - **A — `RB_RANGE` (önerilen varsayılan):** Fib, RB'nin kendi aralığına (gövde ucu ↔ fitil ucu) çekilir.
>   Dar stop ve 5–6R hedefle tutarlı olduğu için kaynağa daha yakın olduğu tahmin ediliyor — **doğrulanmadı**.
> - **B — `SWING_LEG`:** Klasik OTE. Fib, RB fitil ucu (swing low) ile onaydan sonraki ilk onaylı swing high arasındaki bacağa çekilir.

### 8.1 Formüller (seviye `f = 0.79`, config `ote_level`)

**Bullish, mod A:**
```
L = rb_extreme (fitil dibi), B = rb_body (gövde altı), R = B - L   (R > 0 olmalı)
E = B - f * R   =  L + (1 - f) * R
```
**Bearish, mod A:**
```
H = rb_extreme (fitil tepesi), U = rb_body (gövde üstü), R = H - U
E = U + f * R   =  H - (1 - f) * R
```
**Bullish, mod B:** `SL_swing = L`, `SH` = onaydan sonra ilk onaylı swing high (veya onay mumunun high'ı, `swing_leg_end = CONFIRM_HIGH`).
```
E = SH - f * (SH - L)
```
**Bearish, mod B:** `E = SL + f * (H - SL)` (SL = sonraki onaylı swing low).

Yuvarlama: buy limit `floor(E / tick) * tick`, sell limit `ceil(E / tick) * tick`.

Geçersiz/belirsiz ankraj → emir yok:
- `R <= 0` veya `R < rb_min_range_atr * ATR14`
- Mod B'de SH, `swing_leg_timeout_bars` içinde onaylanmadı
- `E` mevcut fiyatın yanlış tarafında (buy limit için `E >= ask` → limit emir olmaz, sinyal düşer; market emre **dönüştürülmez**)

### 8.2 Örnek (bullish, mod A)

RB mumu: O=2652.40, H=2653.10, L=2648.00, C=2652.80
- B = 2652.40, L = 2648.00, R = 4.40
- E = 2652.40 − 0.79×4.40 = 2648.924 → **2648.92**
- Yapısal SL = L − buffer(0.30) = **2647.70** → stop mesafesi 1.22
- TP 5R = 2648.92 + 5×1.22 = **2655.02**; TP 6R = **2656.24**

Mod B ile aynı RB, SH = 2658.00: E = 2658.00 − 0.79×10.00 = **2650.10**.

### 8.3 Stop-loss modları

| Mod | Long SL | Short SL | Kabul şartı |
|---|---|---|---|
| `STRUCTURAL` (önerilen) | `L - buffer` | `H + buffer` | buffer = `max(sl_buffer_price, sl_buffer_spread_mult × spread)` |
| `FIXED` | `E - fixed_stop_price` | `E + fixed_stop_price` | SL, yapısal seviyenin **ötesinde veya eşit** olmalı (long: `SL <= L - buffer`), yoksa işlem açılmaz |

- Stop **asla** pozisyon aleyhine genişletilmez. Sadece kâr yönüne (baseline'da hiç) taşınabilir.
- SL ve TP emirle birlikte broker'a gönderilir (sunucu tarafında korunur).

### 8.4 Take-profit ve R

- `R_price = |E - SL|` (planlanan). `TP = E ± n × R_price`, `n ∈ {5, 6}` (config `tp_r_multiple`).
- `tp_cost_adjust = true` ise TP'ye beklenen maliyet fiyat cinsinden eklenir: `TP += dir × cost_price`, `cost_price = (commission_rt_per_lot / (tick_value / tick_size))`.
- **Gerçekleşen R** (rapor): `R_realized = net_pnl_money / planned_risk_money` — `planned_risk_money` = lot × (stop zararı + komisyon + beklenen kayma). Broker'dan gelen gerçek fill fiyatı ve gerçek komisyon kullanılır.

### 8.5 Emir yaşam döngüsü

```
RB_CONFIRMED → (risk ve guard kontrolü) → ORDER_SENT → ORDER_ACCEPTED (broker ticket)
            → FILLED → CLOSED_TP | CLOSED_SL | CLOSED_MANUAL | CLOSED_GUARD
            → CANCELLED (sebep) | EXPIRED | REJECTED (sebep)
```

Bekleyen emir **iptal** edilir eğer:
1. `order_expiry_bars` (varsayılan 8 = 2 saat) doldu (ayrıca broker'a `ORDER_TIME_SPECIFIED` ile süre verilir, bot kapalı olsa da düşer).
2. Fill olmadan fiyat TP seviyesine (veya `cancel_at_r_before_fill`, varsayılan `TP`) ulaştı.
3. Bir mum `L` altında (long) / `H` üstünde (short) kapandı.
4. Kaynak PD bölge INVALID oldu.
5. Prop guard yeni riski yasakladı (günlük limit, haber penceresi, hafta sonu kesimi).
6. Spread `max_spread_price` üstüne çıktı ve `cancel_on_spread = true`.

Yineleme engeli: `signal_id = sha1(symbol|tf|zone_id|rb_confirmed_at|anchor_mode)`. Aynı `signal_id` için
ikinci emir yok (yerel SQLite + broker'da `comment`/`magic` kontrolü).

## 9. Risk yönetimi ve 100 000 $ prop hesap

### 9.1 Lot hesabı

```
risk_money      = risk_pct × equity_ref                    # risk_pct = 0.0025
equity_ref      = min(balance, equity)                     # muhafazakâr
stop_ticks      = |E - SL| / tick_size
loss_per_lot    = stop_ticks × tick_value_loss
                + commission_rt_per_lot
                + slippage_ticks × tick_value_loss
lots_raw        = risk_money / loss_per_lot
lots            = floor(lots_raw / volume_step) × volume_step
reddet eğer:  lots < volume_min
              lots > volume_max  (veya > max_lots_config)
              lots × loss_per_lot > risk_money             # normalizasyon sonrası kontrol
              marj yetersiz (order_calc_margin)
```

Lot asla yukarı yuvarlanmaz. Bakiye/özsermaye her emir öncesi yeniden okunur.

### 9.2 Hesap örnekleri (varsayım: tick_size 0.01, tick_value 1 $/lot, komisyon 7 $/lot gidiş-dönüş, kayma 0)

| Senaryo | Stop (fiyat) | Lot başı zarar | Ham lot | Normalize lot | Gerçek risk |
|---|---|---|---|---|---|
| Equity 100 000, stop 1.00 | 1.00 | 100 + 7 = 107 $ | 2.336 | **2.33** | 249.31 $ |
| Equity 100 000, stop 10.00 | 10.00 | 1000 + 7 = 1007 $ | 0.2483 | **0.24** | 241.68 $ |
| Equity 100 000, stop 0.10 | 0.10 | 10 + 7 = 17 $ | 14.7 | — | **Red**: stop < 3 × spread |
| Equity 98 000, stop 1.22 | 1.22 | 122 + 7 = 129 $ | 1.899 | **1.89** | 243.81 $ (risk 245 $) |

5R kazanç (stop 1.00, 2.33 lot): brüt 2.33 × 500 = 1165 $; net = 1165 − 16.31 = 1148.69 $ → **≈ 4.61R net**.
6R: brüt 1398 $; net 1381.69 $ → **≈ 5.54R net**. Rapor net R'yi esas alır.

### 9.3 Günlük ve toplam limitler (kişisel — firma kuralı DEĞİL)

| Parametre | Varsayılan | Not |
|---|---|---|
| `risk_pct` | 0.25 % | 250 $ / 100 000 $ |
| `daily_loss_limit_pct` | 1.0 % (1 000 $) | Firmanın gerçek limitinden **düşük** olmalı; firma bilinince doğrulanır |
| `daily_loss_ref` | `max(balance, equity)` gün başında | Firmanın yöntemi bilinince değiştirilir (Q3, Q6) |
| `max_total_dd_pct` | 4.0 % | Statik (başlangıç bakiyesi). Trailing ise firma kuralına göre |
| `max_trades_per_day` | 3 | |
| `max_concurrent_risk_pct` | 0.50 % | Açık + bekleyen tüm emirler |
| `max_consecutive_losses_halt` | 4 | Gün sonuna kadar dur |

**Günlük kontrol (her yeni emir öncesi):**
```
worst_case_today = realized_loss_today             # kapanmış işlemler + komisyon + swap
                 + floating_loss_now               # açık pozisyonların mevcut zararı
                 + Σ remaining_risk(open positions)  # mevcut fiyattan SL'ye
                 + Σ planned_risk(pending orders)
                 + risk(new_order)
izin: worst_case_today <= daily_loss_limit_money
```
Limit aşılırsa: yeni emir yok, tüm bekleyen emirler iptal, açık pozisyonlar SL'leriyle kalır
(`flatten_on_daily_breach = false` varsayılan; firma kuralı gerektirirse true).

**Korelasyon:** Hesaptaki **tüm** pozisyonlar (magic fark etmeksizin, XAGUSD dahil) toplam açık riske eklenir ve
korelasyonlu kabul edilir (korelasyon katsayısı = 1, en kötü durum).

### 9.4 Prop firma kuralları — doğrulanması gerekenler

Firma ve kuralları bilinmiyor. `config/prop_firm.yaml` boş şablon olarak gelir ve `verified: false` iken:
- canlı mod **başlatılamaz**,
- demo/backtest sadece kişisel limitlerle çalışır.

Doldurulacak alanlar: günlük maksimum zarar (tutar, referans, reset saati ve saat dilimi), toplam maksimum zarar
(statik/trailing, trailing'in kapanışta mı intraday mi güncellendiği), kâr hedefi, minimum işlem günü,
haber kısıtı (pencere dakikaları, hangi haberler), hafta sonu/gece taşıma, maksimum lot/kaldıraç,
EA/otomasyon izni, tutarlılık (consistency) kuralı, kaynak URL ve doğrulama tarihi.

## 10. HTF (H1) filtresi

Sadece **kapanmış** H1 mumları (`h1_close_time <= karar_zamanı`).

| Varyant | Kural |
|---|---|
| `OFF` | Filtre yok |
| `H1_BOS` | Bias = son kırılım yönü: son H1 kapanışı son onaylı H1 swing high üstünde → BULL; swing low altında → BEAR. Sadece bias yönünde işlem |
| `H1_BOS_PD` | `H1_BOS` + premium/discount: long sadece fiyat H1 dealing range'in (son onaylı swing low–swing high) %50 altındayken; short %50 üstünde |
| `H1_ZONE` | M15 bölgesi bir H1 FVG/OB ile kesişiyorsa (ek confluence) |

Filtre "mantıklı" olduğu için değil, sadece IS ve OOS'ta `OFF` varyantından ölçülebilir şekilde iyiyse tutulur (§11.4).

## 11. Backtest ve doğrulama

### 11.1 Veri

- Birincil: aynı broker'ın MT5 geçmişi — M1 + mümkünse gerçek tick (`copy_ticks_range`).
- İkincil: harici tick verisi (ör. Dukascopy) — spread farkı belgelenir.
- Veri kalite raporu: eksik mumlar, sıfır hacim, hafta sonu boşlukları, spread dağılımı.

### 11.2 Dolum modeli

| Olay | Kural (bar verisi Bid) |
|---|---|
| Buy limit dolumu | `low_bid + spread <= E` (ask E'ye değdi) |
| Sell limit dolumu | `high_bid >= E` |
| Long SL | `low_bid <= SL` |
| Long TP | `high_bid >= TP` |
| Short SL | `high_bid + spread >= SL` |
| Short TP | `low_bid + spread <= TP` |
| Aynı mumda dolum + SL | Tick yoksa **zarar** varsayılır |
| Aynı mumda SL + TP | Tick/M1 yoksa **SL** varsayılır (muhafazakâr) |
| Kayma | Limit emirde 0 (dolum E'de); SL'de `sl_slippage_ticks` (varsayılan 5) aleyhte |
| Spread | Tick verisinde gerçek; M1'de bar spread'i; yoksa saat bazlı tablo + rollover penceresinde × 3 |

Simülasyon M1 üzerinde yürür (M15 sinyal, M1 dolum); tick varsa tick üzerinde.

### 11.3 Dönemler

| Bölüm | Örnek | Kullanım |
|---|---|---|
| IS (eğitim) | 2019-01 → 2022-12 | Parametre seçimi yalnız burada |
| Doğrulama | 2023-01 → 2023-12 | Seçilen varyantların kontrolü |
| OOS (kilitli) | 2024-01 → son veri | **Tek sefer** çalıştırılır, sonuç ne olursa raporlanır |

Ek: walk-forward (12 ay eğitim / 3 ay test, kayan). Rejim analizi: H1 ATR tercilleri (düşük/orta/yüksek
volatilite), D1 trend (SMA50 eğimi + ADX>25 / <20).

### 11.4 Test matrisi

`anchor ∈ {RB_RANGE, SWING_LEG}` × `rb ∈ {R1, R2}` × `stop ∈ {STRUCTURAL, FIXED(x)}` ×
`tp ∈ {5R, 6R}` × `htf ∈ {OFF, H1_BOS, H1_BOS_PD}` = 48 varyant (FIXED için birden fazla x denenirse çarpılır).
Çoklu test yanılgısı nedeniyle: tüm varyantlar raporlanır, seçim IS'te yapılır, OOS'ta sadece seçilen 1–3 varyant çalışır.

### 11.5 Raporlanacak metrikler (her varyant, her dönem)

İşlem sayısı, kazanma oranı, ortalama kazanç/kayıp ($ ve R), expectancy (R ve $), profit factor,
maksimum equity DD (% ve $), maksimum günlük zarar, günlük limit ihlali sayısı/günleri,
toplam DD ihlali, ortalama R, brüt vs net (spread + komisyon + kayma) sonuç, en uzun kayıp serisi,
yıllara/rejimlere göre expectancy, dolmayan emir oranı, iptal sebepleri dağılımı,
Monte Carlo (10 000 karıştırma) DD %95 ve %99 persentil, expectancy için bootstrap %95 güven aralığı.

### 11.6 Kabul kriterleri (önceden kayıtlı — sonuçlara bakmadan sabitlenir)

Strateji "demo'ya geçebilir" sayılır ancak ve ancak:
1. OOS'ta en az **100 işlem** (yoksa sonuç: "yetersiz veri", başarısız sayılır).
2. OOS net expectancy > 0 ve bootstrap %95 alt sınırı > 0.
3. OOS profit factor ≥ 1.30 (net).
4. Monte Carlo %95 DD < `max_total_dd_pct`; %99 günlük zarar < `daily_loss_limit_pct`.
5. OOS expectancy, IS expectancy'nin en az %50'si.
6. Yıllık dilimlerin en az %60'ında net expectancy > 0.
7. Komşu parametrelerde (±1 adım) expectancy işareti değişmiyor (parametre kararlılığı).

Herhangi biri sağlanmazsa rapor "BAŞARISIZ" yazar; sistem demo/canlı moda geçirilmez.

## 12. Mimari (önerilen)

**Karar D1 (kullanıcı onayı bekliyor):** Python çekirdek + `MetaTrader5` Python paketi adaptörü.
- Artı: sinyal/risk/backtest mantığı Linux'ta birim test edilebilir; araştırma ızgarası kolay; tek kod yolu.
- Eksi: `MetaTrader5` paketi sadece Windows'ta çalışır; terminal açık olmalı; MT5 Strategy Tester'ın "real ticks" modunu doğrudan kullanmaz.
- Alternatif: MQL5 EA (Strategy Tester real ticks, sunucuya yakın) — mantık iki dilde tutulursa sapma riski. Doğrulama sonrası port olarak değerlendirilir.

| # | Modül | Girdi | Çıktı | Hata koşulları |
|---|---|---|---|---|
| 1 | Market Data + MT5 Adapter | sembol, tf, zaman aralığı | `Bar[]`, `Tick[]`, `SymbolSpec`, `AccountState` | bağlantı yok, eksik bar, bayat veri → `DataError`, motor durur |
| 2 | Swing + PD Array Detector | kapanmış `Bar[]` | `Zone[]` olayları (yeni/invalid/expired) | yetersiz geçmiş (ATR için < 14 bar) |
| 3 | Rejection Block Detector | ARMED zone + yeni bar | `RBCandidate`, `RBConfirmed`, `RBCancelled` | |
| 4 | OTE Calculator | `RBConfirmed`, swingler, mod | `EntryPlan(E, SL, TP)` veya `Reject(reason)` | R ≤ 0, ankraj yok |
| 5 | Signal Engine (durum makinesi) | bar akışı | `Signal` olayları | durum tutarsızlığı → durur |
| 6 | Risk Manager | `EntryPlan`, `SymbolSpec`, `AccountState` | `SizedOrder(lots, risk_money)` / `Reject` | lot < min, marj yok |
| 7 | Order Manager | `SizedOrder` | broker ticket, durum geçişleri | reject, requote, timeout → yeniden dene yok, logla |
| 8 | Prop Rule Guard | hesap durumu, gün geçmişi, takvim | `Allow` / `Deny(reason)` / `CancelAllPending` | config `verified=false` → canlı kapalı |
| 9 | Backtest Engine | veri, config | işlem listesi, equity eğrisi | |
| 10 | Logging / Reporting | tüm olaylar | JSONL karar günlüğü, SQLite durum, HTML/Markdown rapor | disk hatası → motor durur |

## 13. Güvenlik ve canlı işlem

- Varsayılan `mode: backtest`. `demo` modu MT5 hesabının `ACCOUNT_TRADE_MODE_DEMO` olduğunu doğrular; değilse çıkar.
- `live` modu için üçü birden gerekli: `mode: live`, `prop_firm.verified: true`, ortam değişkeni `XAU_RB_OTE_LIVE_CONFIRM=<hesap_numarası>`. Biri eksikse sistem başlamaz.
- Bağlantı/veri sorunu (son bar gecikmesi > 2 × tf, tick yok > 120 sn): yeni emir yok, durum `HALTED`; bekleyen emirler broker'da kendi expiry'leri ve SL/TP'leriyle korunur.
- Yeniden başlatma uzlaştırması: SQLite durumu + broker'daki `magic` emir/pozisyonları karşılaştırılır.
  - Broker'da var, DB'de yok bekleyen emir → iptal, logla.
  - DB'de var, broker'da yok → geçmişten (deals) kapanış/iptal bulunur, durum güncellenir.
  - SL'si olmayan pozisyon → DB'deki SL ile hemen eklenir; yoksa pozisyon kapatılır ve alarm.
- Emir gönderimi (`ORDER_SENT`) ile dolum (`DEAL_ENTRY_IN`) ayrı olaylardır. PnL ve gerçek kayıp **broker deal geçmişinden** (`profit + commission + swap + fee`) hesaplanır.
- Her karar: `ts_utc, ts_server, module, event, signal_id, inputs, decision, reason` ile JSONL'e yazılır.
