# Toplantı 2026-10-25 — DTBS filtre araması (kullanıcı: "doğru filtreyi bulana kadar devam")

Katılımcılar (roller): Yönetici (karar), Araştırmacı (filtre önerir), Risk (firma kuralları), Şüpheci (aşırı uyum denetimi).

## Durum
- DTBS W0: IS 2020-2023 −0.153R (PF 0.76), 2024-2026 +0.001R (PF 1.00). Trend yönü kırılımları her dönemde karşı yönden iyi.
- Bilinen sızıntı: 2024-2026 W0 sonucu (trend yönü +0.043R, karşı −0.075R) görüldü. Bu yüzden "yalnız trend yönü" OOS'ta kanıt sayılmaz; tek başına kabul edilmez.

## Şüphecinin itirazı (kabul edildi)
"Bulana kadar dene" sınırsız olursa mutlaka bir filtre "bulunur" ama tesadüftür. 30 filtre denersen biri %5 şansla geçer.
→ Arama SINIRLI ve önceden kayıtlı; doğrulama zinciri üç ayrı dönem.

## Protokol (D-040)
1. Veri: her DTBS sinyali bağımsız etiketlenir (pozisyon çakışması yok), M1 ile SL/TP/ufuk; maliyet R cinsinden düşülür.
2. Dönemler: KEŞİF 2020-2021 → DOĞRULAMA 2022-2023 → OOS 2024-01-01 → 2026-10-23 (tek sefer, yalnız finalist).
3. Aday filtreler (sabit ızgara, tercile eşikleri KEŞİF verisinden):
   F1 yön (trend yönü / karşı) · F2 seans UTC (Asya 0-6, Londra 7-11, NY 12-16, geç 17-23) · F3 volatilite oranı (ATR/baz) tercile ·
   F4 verimlilik (ER, yatay/trend) tercile · F5 kırılım mumu gövdesi/ATR tercile · F6 kapanışın çizgiyi geçme mesafesi/ATR tercile ·
   F7 bacak boyu (pB−pA)/ATR tercile · F8 stop/ATR tercile · F9 B→kırılım bar sayısı tercile · F10 haftanın günü ·
   Hedef RR ∈ {1.0, 1.5, 2.0, 3.0}.
   Kombinasyon: tek filtre veya en çok İKİ filtrenin kesişimi (+ RR). Toplam aday sayısı raporlanır.
4. Seçim (KEŞİF): n ≥ 120, ortalama net R > 0, PF ≥ 1.20. En iyi 10 (net R × √n sırası) DOĞRULAMA'ya geçer.
5. DOĞRULAMA geçme: n ≥ 80, net R > 0, PF ≥ 1.15, bootstrap %95 alt sınır > −0.05. Geçenlerden EN ÇOK 1 finalist (DOĞRULAMA net R × √n en yüksek; eşitlikte daha basit).
6. Finalist EA mantığına (DTBS.mqh) eklenir, tam motorla (tek pozisyon, günlük limit) 2020-2023 tekrar ölçülür, sonra OOS bir kez.
   Kabul (D-034): OOS ≥ 100 işlem, net R > 0 ve bootstrap alt sınır > 0, PF ≥ 1.30, yılların ≥ %60'ı pozitif, DD p95 < %4.
7. Tur sınırı: en çok 3 tur. Her tur yeni ve önceden yazılmış bir hipotez ailesi. OOS her turda yalnız o turun finalistine bir kez açılır;
   OOS'ta başarısız finalist bir sonraki turda tekrar aday olamaz. 3 turda geçen yoksa durulur ve kullanıcıya "bulunamadı" denir.
8. Risk: challenge kararı yalnız OOS kabulü + prop simülasyonu (Ash Turbo, 7 işlem günü) ile. Canlı hesap kapalı kalır.

## Karar
Yönetici: Protokol onaylandı. Tur 1 = yukarıdaki aile. Başla.

---
## Tur 1 sonucu
Etiket verisi: IS 1002 sinyal (bağımsız). Filtresiz ortalama: keşif −0.17R (RR 1.5), doğrulama −0.13R — tam motorla tutarlı (−0.15R).
1.964 aday (tek/çift filtre × 4 RR): KEŞİF eşiğini (n ≥ 120, R > 0, PF ≥ 1.20) geçen **0**. Finalist yok. OOS açılmadı.

## Toplantı 2 (tur 2 ön kaydı)
Araştırmacı: Sorun filtrede değil girişte olabilir — piyasa emri kırılımın en kötü fiyatından giriyor. Ayrıca bağlam (günlük/4 saatlik trend) tur 1'de yoktu.
Şüpheci: "Ters işlem (kırılımı fade et)" fikri REDDEDİLDİ: 2024-2026 W0 sonucunu gördük (+0.02R maliyetsiz), ters işlem OOS'ta zaten eksi çıkacağı biliniyor; kör test sayılmaz.
Tur 2 ailesi (aynı protokol, aynı eşikler, aynı dönemler):
- E: giriş türü {piyasa, RETEST limit = kırılan seviyede (trend kırılımı: kırılım barındaki çizgi değeri, karşı kırılım: pB), ömür 8 bar, hedef dolmadan görülürse iptal}. Stop yapısı aynı (EA'nın ADAPTIVE planındaki SL seviyesi).
- C1: D1 EMA50 eğimi işlem yönünde (son kapanmış günlük EMA50 > 5 gün önceki, alış için)
- C2: H4 EMA50 eğimi işlem yönünde (son kapanmış H4, 5 bar)
- C3: H1 kapanışı H1 EMA200'ün işlem tarafında
- Kombinasyon: E × {yok, C1, C2, C3, C1&C2, F1_with, F1_with&C1, F1_with&C2} × RR {1, 1.5, 2, 3} = 64 aday (az aday = düşük tesadüf riski).

---
## Tur 2 sonucu
64 aday, KEŞİF eşiğini geçen 0. Retest girişi piyasadan iyi değil. Desen: D1 + H4 EMA50 eğimi işlem yönündeyken ve RR büyüdükçe
sonuç düzenli iyileşiyor (piyasa, C1&C2, RR3: keşif +0.005R PF 1.01, doğrulama +0.185R PF 1.27). Eşiği geçmedi.

## Toplantı 3 (SON tur, ön kayıt)
Şüpheci: Tur 3 ailesi IS'te görülen desenden türetildi → keşif/doğrulama artık kör değil. Tek kör test OOS 2024-2026.
Bu yüzden: aday az (9), seçim tüm IS (2020-2023) üzerinde, iki yarı da > 0 şartı, OOS kabulü değişmeden sıkı (D-034).
Not: W0'ın OOS sonucu görülmüştü; C1&C2 filtresinin OOS sonucu GÖRÜLMEDİ.
Aday: bağlam {C1&C2, C1&C2&C3, with&C1&C2} × RR {2, 3, 4}, giriş piyasa.
Seçim: IS ortalama R > 0, PF ≥ 1.15, 2020-21 ve 2022-23 ayrı ayrı > 0, n ≥ 250; puan = R × √n; eşitlikte daha az filtre.
Finalist → DTBS.mqh'ye filtre olarak eklenir → tam motor IS → OOS bir kez → D-034 kabul (OOS ≥ 100 işlem, R > 0 ve bootstrap alt > 0, PF ≥ 1.30,
yılların ≥ %60'ı pozitif). Geçmezse arama BİTER (3 tur doldu).
