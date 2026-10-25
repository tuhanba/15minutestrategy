# Test ve Canlıya Geçiş Kontrol Listesi

Her kutu kanıtla (rapor dosyası, log, ekran görüntüsü) işaretlenir. Bir madde eksikse sonraki aşamaya geçilmez.

## Aşama 0 — Tanımlar ve bilgiler

- [x] Kaynak görsel incelendi: RB = tek mum, Fib 1 = fitil ucu, Fib 0 = gövde ucu, giriş 0.79, 6R
- [ ] Kaynak videonun tamamı izlendi; RB onayı (RB mumu kapanışı mı, sonraki mum mu) ve fitil oranı doğrulandı
- [ ] "10 point"in fiyat karşılığı belirlendi (0.10 / 1.00 / 10.00) (Q2)
- [ ] Broker, sunucu, sembol adı; MT5'ten okunan digits, point, tick_size, tick_value, contract_size, volume_min/step, stops_level kaydedildi (Q4)
- [ ] Gerçek komisyon ve tipik/rollover spread ölçüldü
- [x] Platform: saf MQL5 EA
- [ ] Prop firma adı, programı ve **güncel** kuralları resmi kaynaktan alındı, `config/prop_firm.example.yaml` kopyalanıp dolduruldu, `verified_on` yazıldı (Q3, Q6)
- [ ] Kişisel günlük limit < firma günlük limiti; kişisel toplam limit < firma toplam limiti

## Aşama 1 — Yazılım doğruluğu

- [ ] `make test` (g++) ve `python3 -m pytest tools/tests` yeşil
- [ ] EA ve `RBOTE_Tests` script'i MetaEditor'de 0 hata ile derlendi; script MT5'te `ALL PASSED` yazdı
- [ ] Lookahead özellik testi yeşil
- [ ] Spesifikasyon §5 ve §8 sayısal örnekleri testte birebir
- [ ] SL genişletme girişimi exception veriyor
- [ ] Duplicate sinyal → tek emir
- [ ] Yeniden başlatma testi: kesintili koşu = kesintisiz koşu
- [ ] Gerçek hesapta EA'yı varsayılan ayarlarla eklemek `INIT_REFUSED LIVE_DISABLED_BY_DEFAULT` veriyor
- [ ] `InpRbStopUnit` seçilmeden EA başlamıyor

## Aşama 2 — Backtest

- [ ] Veri kalite raporu temiz (eksik bar oranı, boşluklar belgelendi)
- [ ] Maliyet modeli: gerçek spread + komisyon + SL kayması dahil
- [ ] IS / Doğrulama / OOS tarihleri sonuçlara bakmadan sabitlendi
- [ ] Varyantlar (`MQL5/Presets`: 6R sabit, 5R sabit, 6R yapısal) yalnız IS'te karşılaştırıldı; tüm varyantlar raporlandı
- [ ] 5R vs 6R: hedefe ulaşma oranı, expectancy, max DD ayrı raporlandı
- [ ] Sabit stop vs yapısal stop karşılaştırması raporlandı
- [ ] Rejim analizi (volatilite tercilleri, trend/range) raporlandı
- [ ] Walk-forward sonuçları raporlandı
- [ ] OOS **tek sefer** çalıştı, sonuç ne olursa raporlandı
- [ ] Kabul kriterleri (spec §11.6) — hepsi PASS
  - [ ] OOS ≥ 100 işlem
  - [ ] Net expectancy > 0, bootstrap %95 alt sınır > 0
  - [ ] PF ≥ 1.30
  - [ ] Monte Carlo %95 DD < kişisel toplam limit; %99 günlük zarar < kişisel günlük limit
  - [ ] OOS expectancy ≥ IS'in %50'si
  - [ ] Yıllık dilimlerin ≥ %60'ı pozitif
  - [ ] Komşu parametrelerde işaret kararlı

## Aşama 3 — Demo forward test (MT5 demo hesap)

- [ ] Hesap tipi DEMO (journal'da `INIT_OK demo`)
- [ ] En az 8 hafta ve en az 50 işlem (veya kabul edilen eşik)
- [ ] Her demo işlemi aynı dönemin backtest'i ile işlem-işlem eşleştirildi; sapma sebepleri (spread, dolum, kayma) açıklandı
- [ ] Sunucu tarafı expiry çalışıyor (bot kapalıyken emir düştü)
- [ ] Bağlantı kesme senaryosu: terminal/internet kapatıldı → HALTED, yeni emir yok, açılışta reconcile doğru
- [ ] EA/bot yeniden başlatma: pozisyon ve bekleyen emirler doğru uzlaştı, duplicate yok
- [ ] Günlük limit senaryosu (demo'da düşük limitle zorlandı): yeni emir engellendi, bekleyenler iptal edildi
- [ ] Haber penceresi ve cuma kesimi çalıştı
- [ ] PnL ve gerçek kayıp broker deal geçmişiyle birebir uyuştu (komisyon/swap dahil)
- [ ] Gerçekleşen R dağılımı backtest ile istatistiksel olarak uyumlu

## Aşama 4 — Canlı (prop) geçiş

- [ ] Firma EA/otomasyon kullanımına izin veriyor (yazılı kaynak)
- [ ] Firma kuralları son 30 gün içinde tekrar kontrol edildi; `InpPropRulesVerified=true`
- [ ] Kullanıcı açık yazılı onay verdi; `InpAllowLiveTrading=true` ayarlandı (`InpLiveConfirmLogin=<hesap no>` demo ve prop challenge dahil her hesapta zaten gerekli)
- [ ] İlk 2 hafta risk %0.10–0.125 (yarım risk), sonra kademeli %0.25
- [ ] Günlük izleme: journal, açık risk, günlük worst-case, DD
- [ ] Durdurma kuralları yazılı: canlı expectancy demo'dan anlamlı sapma, art arda X kayıp, firma limitinin %50'sine yaklaşma → sistem kapatılır, inceleme
- [ ] Manuel acil durdurma (kill switch) test edildi: tüm bekleyenleri iptal, yeni emir kapalı
