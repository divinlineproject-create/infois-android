# Merilis Infois ke Google Play

Aplikasi HP Infois **hanya** didistribusikan lewat Google Play (keputusan pemilik,
2026-10-11). Tidak ada unduhan APK dari website atau landing.

## 1. Kunci (keystore)

| Apa | Di mana |
|---|---|
| Keystore rilis | `~/infois-keys/infois-release.jks` (alias `infois`) |
| Kata sandi & lokasi | `android/key.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`) |

- `key.properties` dan `*.jks` **tidak ikut Git** (lihat `android/.gitignore`). Jangan pernah
  menyalin kata sandinya ke chat, issue, atau dokumen.
- **Simpan cadangan folder `~/infois-keys/` dan `key.properties`** di tempat aman (mis. pengelola
  kata sandi + penyimpanan terenkripsi). Hilang kunci unggah = harus minta reset ke Google.
- Tanpa `key.properties`, build rilis jatuh ke kunci debug supaya tetap bisa dibangun di mesin
  lain. AAB seperti itu **ditolak** Play Console, jadi selalu bangun di mesin yang punya kuncinya.

### Play App Signing

Saat membuat aplikasi di Play Console, aktifkan **Play App Signing** (default untuk aplikasi baru):

- Google menyimpan **kunci penandatanganan aplikasi** (app signing key).
- Kunci kita (`infois-release.jks`) menjadi **kunci unggah** (upload key): setiap AAB yang
  diunggah harus ditandatangani dengan kunci ini.
- Pilih "Use Google-generated key" (paling sederhana), atau unggah kunci sendiri bila ingin
  APK yang sudah terpasang di HP tes tetap bisa diperbarui dari Play. Catatan: APK sideload
  lama yang ditandatangani `infois-release.jks` **tidak** bisa diperbarui oleh versi Play bila
  memakai kunci buatan Google: hapus dulu aplikasi lama di HP tes sebelum memasang dari Play.

## 2. Versi

Versi ada di `pubspec.yaml`: `version: <versionName>+<versionCode>`.

- `versionCode` (angka setelah `+`) **harus naik** di setiap unggahan ke Play (termasuk uji
  internal). Play menolak angka yang sama atau lebih kecil.
- `versionName` yang dilihat pengguna (mis. `1.1.0`). Samakan dengan
  `AppConfig.version` di `lib/core/config.dart` (dikirim sebagai `X-App-Version` dan dipakai
  server untuk `min_app_version`).

Versi saat ini **1.2.0+3** (Pusat Bantuan, verifikasi dua langkah saat masuk, pesan
pemeliharaan, hasil Setujui Tim AI). Sebelumnya 1.1.0+2 (Akun Usaha). Untuk unggahan pertama ke
Play angka ini boleh dipakai apa adanya; tidak perlu kembali ke `1.0.0+1`.

Contoh rilis berikutnya: ubah ke `1.2.1+4`, lalu `AppConfig.version = '1.2.1'`.

## 3. Membangun AAB

```bash
cd android            # folder proyek Flutter (berisi pubspec.yaml)
flutter analyze       # harus "No issues found"
flutter test --concurrency=2
flutter build appbundle --release
```

Hasil: `build/app/outputs/bundle/release/app-release.aab`. Server sudah tetap di build
(`https://dashboard.infois.ai`, lihat `AppConfig`), jadi tidak ada `--dart-define` yang perlu diisi.

Cek tanda tangan sebelum mengunggah (harus menyebut alias `infois`, bukan `androiddebugkey`):

```bash
keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab | head
```

## 4. Mengunggah

1. Play Console › Infois › **Testing › Internal testing** › Create new release › unggah AAB.
2. Isi catatan rilis (Bahasa Indonesia), simpan, lalu **Review release** › **Start rollout**.
3. Setelah lolos uji internal: promosikan ke Closed testing / Production.

Akun developer pribadi yang dibuat setelah Nov 2023 wajib uji tertutup (≥ 12 penguji, 14 hari)
sebelum Production. Akun **organisasi** (PT. DEVINE AUTADA TECH, butuh D-U-N-S) tidak terkena
syarat itu.

## 5. Bahan halaman toko

Lihat folder [`play/`](play/README.md): teks halaman toko, formulir Data Safety, rating konten,
target audiens, akses untuk peninjau, dan rencana screenshot. Screenshot & grafik toko dibuat dari
layar aplikasi sebenarnya:

```bash
SHOTS_DIR=/folder/keluaran flutter test test/screenshots/play_store_screenshots.dart
```

## 6. Aturan yang wajib dijaga di setiap rilis

- **Pembayaran Google Play:** aplikasi tidak boleh menjual atau mengarahkan pengguna membeli paket
  atau koin di web: tanpa tombol/tautan Langganan, Dompet Koin, upgrade, harga paket, atau nama
  paket yang membuka fitur. Semua kalimat seperti itu lewat `lib/core/store_policy.dart`;
  tes `test/play_policy_test.dart` dan pemindai `test/support/play_policy.dart` menjaganya.
- **Hapus akun** tetap ada di Akun › Hapus akun.
- Izin baru (kamera, lokasi, kontak, dll.) harus dijelaskan dulu di aplikasi
  (`lib/services/permission_gate.dart`) dan diperbarui di formulir Data Safety.
