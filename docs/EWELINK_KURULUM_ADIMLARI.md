# Sonoff'ları Telegram'dan yönetmek: eWeLink kurulumu (tek seferlik, ~10 dk)

Ön koşul: Telegram botu çalışıyor olmalı (yeni bot token'ı LuCI > Services > Huawei'ye girilmiş,
"Telegram Bot Komutlarını Dinle" işaretli).

## 1. eWeLink geliştirici uygulaması oluştur (dev.ewelink.cc)

1. Bilgisayarda **https://dev.ewelink.cc** adresini aç.
2. Sağ üstten **Login**: eWeLink uygulamasında kullandığın **aynı hesapla** giriş yap
   (bölge Türkiye için genelde *Europe*).
3. İlk girişte geliştirici türü sorarsa **Personal developer** (kişisel, ücretsiz) seç ve formu doldur.
4. **Console** → **Create** / **Create App** (Uygulama oluştur):
   * Ad: `WDR3600 Telegram` (istediğin bir ad)
   * **Redirect URL:** `https://127.0.0.1/ewelink`. Tam olarak bu, harfi harfine.
   * Rol/izin sorarsa standart olanı seç, kaydet.
5. Oluşan uygulamada **App ID** ve **App Secret** görünür. İkisini de kopyala.
   (Ekranlar zamanla değişebilir; menü adları biraz farklı olabilir.)

## 2. Router'a gir (LuCI)

1. http://192.168.1.1 → **Services → Huawei** → sayfanın altındaki **eWeLink (Sonoff) Telegram Kontrolü**.
2. **App ID** ve **App Secret** alanlarına yapıştır, **Bölge:** Avrupa (eu),
   **Redirect URL:** `https://127.0.0.1/ewelink` (değiştirme).
3. **Kaydet ve Uygula**.

## 3. Telegram'dan bağla (yönetici)

1. Bota **/ewelink_baglan** yaz. Bot bir giriş linki gönderir.
2. Linki aç → eWeLink hesabınla giriş yap → **izin ver / onayla**.
3. Tarayıcı `https://127.0.0.1/ewelink?code=...` adresine gider ve **"sayfa açılamıyor"** der. Bu **normal**.
   Adres çubuğundaki **tam adresi** kopyala.
4. Bota şunu gönder: `/ewelink_kod ` + kopyaladığın adres
   (örnek: `/ewelink_kod https://127.0.0.1/ewelink?code=abc123&region=eu&state=wdr3600`)
5. Bot "✅ eWeLink bağlandı" der. **/cihazlar** yazınca tüm cihazlar ve durumları gelir.

## 4. Kullanım (listedeki herkes)

* `ön ışıkları aç`, `ön ışıkları kapat`, `ön ışıklar durum`
* Fiil başta da olur: `aç ön ışıklar`, `kapat bahçe lambası`
* eWeLink'teki ad neyse o: "Ön Işıklar" → "ön ışıkları aç" (Türkçe ekler, büyük/küçük harf, ş/ç/ğ/ı fark etmez)
* 4 kanallı cihazlarda eWeLink'te kanallara ad verdiysen (ör. "Salon Avize") kanal adıyla da yönetilir
* Çevrimdışı cihaz için uyarı verir; ad bulunamazsa benzerlerini önerir
* Toplu komut (`hepsini kapat`) bilerek yok

## Notlar

* İnternet ve eWeLink bulutu gerekir (eWeLink uygulaması gibi).
* eWeLink şifren router'a kaydedilmez; yalnızca erişim anahtarı saklanır (dosya izni 600) ve
  süresi dolmadan otomatik yenilenir. 60 günden uzun hiç internet olmazsa yeniden `/ewelink_baglan` gerekebilir.
* Tapo P100'ler bu yolla yönetilemez (Tapo'nun açık bulut API'si yok); Tapo uygulamasıyla devam.
