# DTBS — Dynamic Trend Break System: Teknik Spesifikasyon v0.1

Durum: **Tanımlandı, uygulanmadı, test edilmedi.** "%60/%40" ifadesi kanıtlanmış başarı oranı değildir;
yalnız backtest/OOS ile ölçülür, hiçbir raporda gerçekleşmiş performans gibi gösterilmez.

İkinci strateji olarak RBOTE (RB + OTE 0.79) ile **aynı EA içinde** çalışır. Her işlem strateji etiketi taşır,
raporlar strateji bazında ve toplam verilir. Risk ve firma limitleri hesap düzeyinde **ortaktır**.

---

## 1. Kaynak görselden çıkan geometri (düşüş trendi, satış örneği)

```
                 B ●──────────────────────────● C        yatay: B'den L mum sağa (C = (tB + L, pB))
                   │                    ╱
                   │               ╱                     eğimli çizgi: A → C   (A → B DEĞİL)
                   ▼ SATIŞ    ╱
                 ─────────╱─────   kapanış eğimli çizginin ALTINDA → satış
                      ╱
          A ●────╱                 A = karşı yönlü (yükseliş) hareketin başladığı onaylı dip
```

Görselde yatay çizgi yaklaşık 20 mum uzunluğunda; risk/ödül kutuları ≈ 1:2.

## 2. Tanımlar (yalnız kapanmış barlar, lookahead yok)

| Kavram | Tanım | Varsayılan / belirsizlik |
|---|---|---|
| İşlem zaman dilimi (LTF) | M15 | `dt_tf`, ayarlanabilir |
| Ana trend (HTF) | Her HTF'de son onaylı fraktal yapı: son kapanış son onaylı swing high üstündeyse BULL, son onaylı swing low altındaysa BEAR, değilse önceki durum | HTF listesi H1+H4 (`dt_htfs`); birleşim: **hepsi aynı yönde** olmalı (ALL) — alternatif MAJORITY |
| Karşı yönlü hareket (ana trend BEAR) | Onaylı swing low **A** → A'dan sonraki en yüksek onaylı swing high **B**; hareket boyu `pB − pA ≥ dt_min_leg_atr × ATR14` ve hareket bir **karşı yönlü kırılım** içerir: A ile B arasında bir mum, A'dan önceki son onaylı LTF swing high'ın **üstünde kapanır** | `dt_min_leg_atr = 1.0`, `dt_swing_n = 2` (VARSAYIM) |
| Ana trend BULL | Ayna: onaylı swing high A → en düşük onaylı swing low B, A'dan önceki son swing low altında kapanış | |
| Yatay uzatma | C = (tB + L, pB), L mum. Kaynak "20 pip" diyor, ama yatay çizgi zaman ekseninde uzanır ve görselde ≈ 20 **mum**. Varsayılan `L = 20` mum (`dt_ext_bars`). "20 pip" fiyat olarak okunursa (XAUUSD 1 pip = 0.10 → 2.00) yatay çizgiye uygulanamaz | **Kullanıcı onayı bekliyor**; 10/20/30 mum duyarlılık testi |
| Eğimli çizgi | A'dan C'ye doğru: `line(t) = pA + (pB − pA) · (t − tA) / (tC − tA)`; t = bar indeksi | |
| Üçgenin ömrü | tB'nin onaylandığı bardan (`tB + swing_n`) tC'ye kadar; tC'den sonra kırılım olmazsa EXPIRED | |
| Geçersizlik | Ana trend yönü değişirse, ya da yeni onaylı daha yüksek swing high (BEAR durumda) B'yi geçerse yapı yenilenir (yeni üçgen) | |

## 3. Sinyal (mum kapanışıyla doğrulama, varsayılan)

Ana trend BEAR, üçgen aktif, bar `t` kapanışında:
- **Trend yönünde kırılım (SATIŞ):** `close[t] < line(t)` ve `close[t-1] >= line(t-1)` → satış sinyali.
- **Karşı yönde kırılım (ALIŞ):** `close[t] > pB` → alış sinyali (karşı hareketin devamı).
- Varsayılan: **ikisi de** sinyal üretir (`dt_break_dirs = BOTH`); alternatif `WITH_TREND_ONLY`. Ayrı ayrı raporlanır.
- Fitil kırılımı (kapanış olmadan) sinyal değildir; yalnız journal'a "wick break" olarak yazılır (`dt_confirm = CLOSE`, alternatif `WICK`).
- Her üçgen **tek** sinyal üretir (ilk kırılım). Sinyal kaydı: ana trend, A, B, C koordinatları, kırılım yönü/zamanı, kapanış onayı.

Ana trend BULL: ayna. A onaylı tepe, B en düşük onaylı dip; eğimli çizgi A'dan C'ye **iner**. Kapanış çizginin **üstünde** → alış (trend yönünde); kapanış pB'nin **altında** → satış (karşı yönde).

## 4. Giriş, stop, hedef

| | Varsayılan | Alternatifler |
|---|---|---|
| Giriş | Sinyal barının kapanışından sonraki ilk tick'te **piyasa emri** (EA: yeni barın ilk tick'i) | `dt_entry = RETEST_LIMIT` (çizgi seviyesine limit) — test varyantı |
| Stop (satış) | Kırılım mumunun **tepesi + tampon** (`dt_sl_mode = BREAK_CANDLE`) | `EXTREME` (B + tampon), `ATR` (k × ATR) |
| Tampon | `max(dt_sl_buffer_price, spread)` | varsayılan 0.30 |
| Hedef | `entry ∓ dt_rr × risk`, `dt_rr = 2.0` (görsel ≈ 2.1) | 1.5 / 3 |
| Reddetme | stop < broker min / < 2×spread, stop > `dt_max_stop_atr × ATR` (varsayılan 3) | |

Lot ve risk RBOTE ile aynı formül ve aynı hesap düzeyi korumalar (`RB_CalcLots`, `RB_CheckNewOrder`).

## 5. İki stratejinin birlikte çalışması

- **Strateji kimliği:** `RBOTE = 1`, `DTBS = 2`. Ayrı magic (`InpMagic`, `InpMagic + 1`), sinyal kimliği önekleri `RBOTE|…`, `DTBS|…`.
- **Hedge yok (Upcomers yasağı):** hesapta açık pozisyon veya bekleyen emir varken **ters yöndeki** sinyal reddedilir (`OPPOSITE_EXPOSURE`). Aynı yöndeki sinyaller risk limitleri izin verirse kabul edilir.
- **Ortak limitler:** günlük zarar, toplam açık risk, toplam DD tabanı, Ash Turbo hedef/7 işlem günü hesap düzeyinde; strateji başına ayrıca `max_positions` ve risk % (varsayılan ikisi de %0.25).
- **Strateji aç/kapa:** `InpEnableRBOTE`, `InpEnableDTBS`.

## 6. Raporlama

trades.csv ve journal'a `strategy` sütunu. `analyze_trades.py`:
- strateji bazında ve toplam: işlem, kazanma oranı, ortalama R, expectancy (R ve para), PF, max DD, maliyetler
- iki stratejinin günlük P&L korelasyonu, aynı gün ikisinin de kaybettiği gün sayısı
- DTBS için ek kırılımlar: kırılım yönü (trend yönünde / karşı), kapanış onayı, ana trend uyumu, volatilite rejimi
- challenge simülasyonu: iki strateji birlikte (birleşik işlem akışı)

## 7. Doğrulama sırası

1. Geometri ve koordinat birim testleri (A, B, C, çizgi değeri, bull/bear ayna)
2. Yukarı/aşağı kırılım, kapanış vs fitil, tek sinyal, ömür dolması
3. Farklı digits/point sembollerde mesafe testleri
4. Spread + komisyon (5 $/lot) + swap + kayma içeren backtest, IS seçim / OOS tek rapor
5. EA + MT5 tester çapraz kontrolü
6. Demo forward test

Kabul kriterleri ve varyant listesi yönetici tarafından önceden kaydedilir (D-033+).
