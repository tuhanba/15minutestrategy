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
| Komisyon | 6 $/lot gidiş-dönüş (Upcomers tutarı bulunamadı, 0 ve 10 ile hassasiyet) |
| Gün / seans / cuma kesimi | UTC (Upcomers günlük DD 00:00 UTC) |

## Araştırma planı (yönetici kararları D-004 … D-009, önceden kayıtlı)

`make research` → `reports/research.md`

1. **A — varyantlar.**
   - V0: sabit 10.00 fiyat stop, 6R
   - V1: 5R
   - V2: yapısal stop

   IS (2020–2023) içinde PF ≥ 1.30 olup expectancy'si en yüksek olan seçilir. OOS (2024 → bugün) bir kez raporlanır.
2. **V3 / V4.** V3 = seçilen + rejim politikası, V4 = V3 + adaptif risk. Yalnız IS'i iyileştirip DD'yi kötüleştirmiyor ve OOS'u bozmuyorsa benimsenir.
3. **D — işlem yönetimi.**
   - M1: +2R'de başabaş
   - M2: +3R'de başabaş
   - M3: +3R'de yarısını kapat
   - M4: +3R'den sonra 2R iz süren stop

   Benimseme şartları: IS'te en az +0.05R, DD kötüleşmiyor, OOS'ta M0'dan kötü değil.
4. **Hassasiyet ızgarası** (yalnız rapor, seçimde kullanılmaz): stop 5/10/15, fib 0.705/0.79, fitil 0.4/0.5/0.6. İşaret değişiyorsa sonuç "FRAGILE" olarak işaretlenir.
5. **C — Upcomers challenge simülasyonu** (`tools/prop_sim.py`): Phoenix 2-step ve Thunderbolt 1-step, risk %0.25–1.0.
   - Monte Carlo: gün blokları, 10 000 deneme
   - Tarihsel tekrar: her ay başından başlatılır
   - Seçim: günlük ihlal olasılığı < %5 olan riskler içinde geçme olasılığı en yüksek olan.

Sonuçlar kabul kriterlerini geçmezse strateji **doğrulanmamış** sayılır. Kriterler sonuca bakılarak gevşetilmez.

## MetaEditor under Wine (Linux)

Ubuntu'nun Wine 9.0 paketi MetaEditor'ün anti-debug kontrolüne takılır ("A debugger has been found running in your system").
WineHQ'nun Wine 10+/11 sürümüyle çalışır:

1. WineHQ apt kaynağını ekle, `wine-stable` paketlerini indir (sistem Wine'ını değiştirmeden `dpkg -x` ile açılabilir).
2. Yeni bir `WINEPREFIX` oluştur, MT5'i kur, `terminal64.exe /portable` ile bir kez çalıştır (standart kütüphane `MQL5/` oluşur).
3. `WINE=<wine11 yolu> MT5=<portable MT5 dizini> tools/compile_mql5.sh`: EA ve test script'ini derler, testleri terminalde başsız çalıştırır, hata varsa sıfırdan farklı kodla çıkar.
