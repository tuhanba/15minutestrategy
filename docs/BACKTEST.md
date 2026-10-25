# Bağımsız backtest, challenge simülasyonu ve araştırma planı

## Neden ikinci bir backtest motoru

`backtest/rbote_bt.cpp`, EA'nın **aynı** saf mantık dosyalarını (`MQL5/Include/RBOTE/*.mqh`) g++ ile derleyip
kendi piyasa simülasyonuyla çalıştırır. MT5 Strategy Tester sonuçlarıyla karşılaştırılınca iki motordan birindeki
hata görünür hale gelir. Ayrıca bu ortamda MT5 çalışmadığı için gerçek sayı üretmenin tek yolu budur.

## Veri

`make data` (veya `tools/fetch_dukascopy.py`): Dukascopy XAUUSD M1 BID+ASK, 2020-01-01'den düne, UTC.
İşlem olmayan dakikalar atılır. Bu veri bir **MT5 brokerının verisi değildir**: spread, seans saatleri ve fiyatlar biraz farklıdır.

## Simülasyon kuralları (muhafazakâr)

| Olay | Kural |
|---|---|
| Sinyal | M15 kapanışında, yalnız kapanmış barlarla (EA ile aynı `RB_Scan`); bir sonraki bar boşluklu başlıyorsa (hafta sonu) sinyal atlanır, EA'nın `DATA_STALE` davranışı |
| Buy limit dolumu | M1 `ask_low <= entry` → giriş fiyatından |
| Sell limit dolumu | M1 `bid_high >= entry` |
| Aynı dakikada dolum + SL | zarar |
| Aynı dakikada SL + TP | SL |
| SL çıkışı | SL (boşlukta daha kötü açılış) − 10 tick kayma |
| TP çıkışı | TP (boşlukta daha iyi açılış) |
| Fill öncesi TP | dakika dolmadıysa ve TP görüldüyse iptal |
| Yönetim stop değişikliği | bir sonraki dakikadan itibaren |
| Komisyon | 5 $/lot gidiş-dönüş (kullanıcının Ash Turbo hesabı: 0.5 lot için 2.50 $, D-029); hassasiyet 0 ve 10 $ |
| Swap | **varsayımsal** (D-026): long −45, short −15 $/lot/gece, Çarşamba gecesi ×3, 21:00 UTC rollover'da açık pozisyona (`--swap-long/--swap-short/--swap-hour`); hassasiyet: swap 0. Gerçek değer MT5 sembol özelliklerinden gelince güncellenecek |
| Dönem sonu | açık pozisyon son fiyattan kapatılır, `exit_reason=END` (`--end-close on`) |
| Gün / seans / cuma kesimi | UTC (Upcomers günlük DD 00:00 UTC) |
| Kişisel limitler | günlük limit (`--daily`) stratejinin parçası, aktif. Toplam DD tabanı araştırmada **kapalı** (`--max-dd 0 --dd-trailing off`): ilk ihlalde donma örneklemi keserdi; yalnız ölçülür (D-025) |
| Firma limitleri | backtest'te yalnız raporlanır (`--firm-daily`, `--firm-max`, ...); uygulanır hâli `tools/prop_sim.py`'dedir |

## Araştırma planı (önceden kayıtlı: D-004 … D-009, D-023 … D-029 ile güncel)

`make research` → `reports/research.md`. Seçim kuralları `tools/run_research.py` içinde kodludur.

**Temel kural: seçim ve benimseme YALNIZ IS (2020-01-01 → 2023-12-31) ile yapılır. OOS (2024-01-01 → 2026-10-23)
yalnız NİHAİ konfigürasyon için bir kez raporlanır ve seçimi değiştirmez (D-023).** Diğer adayların OOS satırları
şeffaflık için ayrı bir tabloda "NOT used for selection" etiketiyle gösterilir. IS içinde walk-forward (18 ay eğitim /
6 ay test pencereleri) yalnız kararlılık raporudur.

Her rapor hem R hem para cinsindendir. R (= net / işlem riski) pozisyon boyutunu görmez: rejim ×0.5 veya adaptif risk
R expectancy'de ve sabit riskli R Monte Carlo'sunda görünmez. Para metrikleri (`analyze_trades.Summary`): net $ ve %,
gerçek sıradan para max DD, ve **para Monte Carlo'su**: her işlemin gerçek P&L'i giriş anındaki bakiyenin oranı olarak
(`net / bakiye_giriş` = `r × risk_money / bakiye_giriş`; `risk_pct` sütunu rejim çarpanını içermediği için tek başına
kullanılmaz) iadeli yeniden örneklenir. Karar Monte Carlo'ları ≥ 5 000 koşu.

1. **A — varyantlar** (sabit %0.25 risk, IS): V0 sabit 10.00 fiyat stop 6R; V1 5R; V2 yapısal stop.
   PF ≥ 1.30 olanlardan IS expectancy'si en yüksek seçilir.
2. **B — V3 / V4** (boyutu değiştiren varyantlar, para bazlı, D-024): V3 = seçilen + rejim politikası;
   V4 = (V3 benimsendiyse V3, değilse seçilen) + adaptif risk. Benimseme, referansa göre IS'te:
   (net % / para MC max DD p95) ≥ %10 iyileşme **ve** para MC DD p95 ≤ 1.10 × referans **ve**
   P(kişisel günlük limit ihlali, `daily.csv`'deki gün içi en düşük equity ile) artmıyor.
3. **D — işlem yönetimi** (B'den çıkan konfigürasyon, sabit risk, IS): M1 +2R'de başabaş, M2 +3R'de başabaş,
   M3 +3R'de yarısını kapat, M4 +3R'den sonra 2R iz süren stop. Benimseme: IS expectancy ≥ M0 + 0.05R ve para MC DD p95
   M0'dan kötü değil. Birden fazla geçerse IS expectancy'si en yüksek olan.
4. **NİHAİ konfigürasyon** = A + B + D kararları. Bunun için: IS/OOS tablosu, tam kabul raporu
   (`analyze_trades.build_report`, IS/OOS ayrımıyla), komisyon 0/10 ve swap 0 hassasiyeti, yarıyıl kararlılığı,
   kişisel %4 izleyen tabanın kırıldığı gün sayısı ve ilk tarih (yalnız ölçüm).
5. **Hassasiyet ızgarası** (IS, yalnız rapor): stop 5/10/15, fib 0.705/0.79, fitil 0.4/0.5/0.6. İşaret değişiyorsa "FRAGILE".
6. **C — Upcomers challenge simülasyonu** (`tools/prop_sim.py`), NİHAİ konfigürasyonun **sabit riskli** backtest'i
   üzerinde (adaptif kapalı, kişisel günlük %2 = Turbo ön ayarı). Birincil program **Ash Turbo 100k**; Ash Turbo
   (katı okuma: 7 hafta içi gün), Ash, Phoenix, Thunderbolt karşılaştırma.
   - Risk ızgarası %0.25 / 0.30 / 0.35 / 0.40 / 0.50 (D-027). Ön ayar tavanı (`InpMaxRiskPct` %0.5, açık risk %0.5)
     üstü yalnız `--allow-above-cap` ile.
   - **Karar bir kez, IS işlemleriyle**: her yöntem için P(firma günlük ihlali) < %5 **ve** P(firma max-loss/shield
     ihlali) < %10 olanlar içinde geçme olasılığı en yüksek risk; eşitlikte düşük risk. **Tarihsel tekrar birincil,
     Monte Carlo sağlamlık kontrolü (D-031)**: iki yöntem farklı risk seçerse veya seçilen riskte geçme oranları
     10 puandan fazla ayrışırsa DÜŞÜK risk seçilir (iki yöntemde de kuralı sağlayan bir alt riske inilir) ve ayrışma
     raporlanır; Monte Carlo hiçbir risk bulamazsa sonuç "none qualifies". Ayrıca aynı kural **%0.35 tavanlı**
     (Upcomers tek kazançla geçmeye yazılı onay verene kadar kullanılacak risk). OOS işlemleri yalnız doğrulama.
   - EA'nın kişisel limitleri simülasyonda **uygulanır** (D-032), firma ihlallerinden ayrı raporlanır.

### prop_sim modeli

- Boyut: `risk_money = risk × bakiye × size_mult`, P&L = `r × risk_money`. `size_mult` = backtest işleminin
  `risk_money / (risk_pct/100 × giriş bakiyesi)`: rejim ×0.5 ve lot yuvarlamasını taşır. Yaklaşım: backtest
  min(balance, equity) ile ve kendi riskinde lot yuvarladı; oran simüle bakiyeye doğrusal ölçeklenir.
- Günlük limit: gün başı bakiye (00:00 UTC'de pozisyon yok varsayımı) − limit; gün içi dip = bakiye + `mae_r × risk_money`.
- Dynamic Risk Shield **equity tepesini** izler: her işlemde önce tepe `bakiye + mfe_r × risk_money`'ye çekilir, sonra
  ters hareket / stop uygulanır (muhafazakâr sıra, D-028). Ash Turbo'da kilit yok (belirtilmemiş).
- Süreler gerçek tarihlerle: takvim limiti `tarih ≥ başlangıç + N gün` olunca biter (hafta sonu/tatil dahil);
  hareketsizlik = son kapanıştan 35 takvim günü; Ash Turbo 7 işlem günü = en az bir işlemin kapandığı gün sayısı.
- Kişisel EA limitleri (D-032; firma kontrolleri önce yapılır, ikisini birden kıran hareket firma ihlali sayılır):
  - günlük: equity < gün başı referansı − %2 × (Ash Turbo'da başlangıç bakiyesi, firmanın günlük ölçümüyle aynı;
    floating MAE ile). O işlem çıkışına kadar sürer, o gün yeni işlem açılmaz, deneme devam eder.
  - izleyen taban: equity < equity tepesi (MFE dahil) − %4 × başlangıç (EA `RB_TotalDDFloor`). Açık işlem çıkışına
    kadar sürer (o çıkış hedefi tamamlarsa geçer), sonra EA durur: sonuç `personal_stop`.
- Monte Carlo: **ardışık günlerden kayan blok bootstrap** (varsayılan 5 gün = bir işlem haftası, `--block`), 10 000
  deneme; her günün gerçek takvim boşluğu korunur.
- Tarihsel tekrar: her hafta içi günden (veya `--replay-step month`) başlatılır; geçmişi yetmeyen başlangıçlar
  **sansürlenir** (ayrı sayılır, oranlara girmez), timeout sayılmaz.

### Önbellek

`reports/runs/<tag>.key`: backtester ikilisinin SHA-256'sı + tam argüman listesi + veri dosyalarının yol/boyut/mtime
bilgisinin hash'i. Anahtar tutmazsa koşu yeniden yapılır.

Sonuçlar kabul kriterlerini geçmezse strateji **doğrulanmamış** sayılır. Kriterler sonuca bakılarak gevşetilmez.

## MetaEditor under Wine (Linux)

Ubuntu'nun Wine 9.0 paketi MetaEditor'ün anti-debug kontrolüne takılır ("A debugger has been found running in your system").
WineHQ'nun Wine 10+/11 sürümüyle çalışır:

1. WineHQ apt kaynağını ekle, `wine-stable` paketlerini indir (sistem Wine'ını değiştirmeden `dpkg -x` ile açılabilir).
2. Yeni bir `WINEPREFIX` oluştur, MT5'i kur, `terminal64.exe /portable` ile bir kez çalıştır (standart kütüphane `MQL5/` oluşur).
3. `WINE=<wine11 yolu> MT5=<portable MT5 dizini> tools/compile_mql5.sh`: EA ve test script'ini derler, testleri terminalde başsız çalıştırır, hata varsa sıfırdan farklı kodla çıkar.
