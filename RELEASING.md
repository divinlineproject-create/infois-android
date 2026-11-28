# Merilis Infois POS ke Google Play

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

Versi saat ini **1.0.0+1** = **rilis pertama di Google Play** (keputusan pemilik 2026-10-18:
aplikasi belum pernah diunggah atau dipasang di mana pun, jadi penomoran dimulai dari 1.0.0,
build 1). Nomor 1.1.0+2 dan 1.2.0+3 sebelumnya hanya build uji internal dan tidak dipakai lagi.
APK uji lama (1.2.0+3) yang mungkin masih ada di HP tes harus **dihapus dulu** sebelum memasang
build ini (versionCode lebih kecil tidak bisa dipasang di atasnya).

Isi 1.0.0 (Infois POS): nama aplikasi **Infois POS** (package tetap `id.infois.infois`), foto
barang di kasir (cache offline), chip **Kategori** (menggantikan chip satuan), **scan barcode
dengan kamera** (izin `CAMERA` baru, lihat `play/data-safety.md`) + scanner Bluetooth/USB tanpa
keyboard layar, tampilan kasir baru, perbaikan keyboard yang muncul sendiri, ditambah semua fitur
build uji sebelumnya (Pusat Bantuan, verifikasi dua langkah, pesan pemeliharaan, Akun Usaha).

Server: `INFOIS_MOBILE_MIN_VERSION` (default `1.0.0`) **tidak boleh** lebih tinggi dari 1.0.0,
kalau tidak aplikasi menampilkan "Versi aplikasi ini sudah lama".

Contoh rilis berikutnya: ubah ke `1.0.1+2`, lalu `AppConfig.version = '1.0.1'`.

**1.1.0+2** (2026-10-25, untuk uji tertutup setelah 1.0.0+1): **Input AI** di kasir (ketik, tahan untuk
bicara, atau foto pesanan → langsung masuk keranjang; online saja, memakai koin perusahaan) dan kode
scan/ketik yang hanya cocok dengan barang nonaktif ditolak ("Barang ini sudah dinonaktifkan.").
Server harus sudah punya `POST /api/v1/pos/ai-input` sebelum build ini dirilis.

**1.1.0+2 — tambahan 2026-11-02** (1.1.0+2 belum dirilis/diunggah, jadi isi ini masuk ke build yang sama;
AAB lama di `~/Desktop/Infois-POS-PlayStore/1-AAB-rilis/infois-1.1.0+2.aab` sudah usang, bangun ulang):
- **Tablet kasir bersama (PIN)**: tablet login penuh sekali, lalu tiap kasir membuka dengan pilih nama +
  PIN 6 angka (Akun › Kunci dengan PIN; kunci otomatis setelah ditinggal). Satu database per tablet:
  pesanan tersimpan dan antrean kirim dipakai bersama, tiap transaksi tercatat atas nama kasirnya.
- **Operasional harian** (tombol **Catat** di tab Catatan): catat/ubah/hapus biaya, tagihan pemasok
  (barang stok + biaya lain, bisa langsung dibayar), uang masuk/keluar/pindah rekening, bayar tagihan,
  terima pembayaran pelanggan; tombol Ubah/Hapus mengikuti hak akses dan kunci (cut off, disetujui,
  sudah dibayar) seperti di web.
- Layar **Masuk** baru: separuh layar panel brand seperti halaman masuk dashboard.
- **Tablet miring nyaman dipakai**: navigasi pindah ke bilah samping kiri dan bilah atas jadi satu baris;
  kasir tetap dua panel (katalog + pesanan) dengan tata letak padat di tablet 7–8"; layar Bayar
  rincian kiri + keypad kanan.
- **Catatan**: Penjualan, Pembayaran, Pembelian, dst. di bilah samping (tablet/miring selalu tampil,
  HP tegak dari tombol menu).
- **Unduh PDF** di setiap laporan (format resmi seperti PDF laporan web, periode yang dipilih).
Server harus sudah punya `/api/v1/pin/*`, `/api/v1/ops/*` (backoffice main, migrasi
`2026_11_02_100000_add_mobile_pin`) dan `?format=pdf` di `/api/v1/reports/*` sebelum build ini dirilis.

**1.0.1+2** (2026-11-10, keputusan pemilik): build yang dirilis sebagai pembaruan pertama setelah
1.0.0+1 memakai nomor **1.0.1** (naik satu), versionCode 2. Isinya semua yang tercatat di atas
sebagai "1.1.0+2" (nomor 1.1.0 dan 1.1.0+3 tidak pernah diunggah ke Play dan tidak dipakai lagi).
Kontrak API dicek ulang terhadap server produksi (semua endpoint `/api/v1` yang dipanggil aplikasi
ada). Aplikasi tidak memakai webhook pembayaran (`/api/webhooks/midtrans`, `/api/webhooks/doku`):
itu jalur server ↔ payment gateway, terpisah dari `/api/v1`. Setelah rollout Play selesai, set
`INFOIS_MOBILE_LATEST_VERSION=1.0.1` di `.env` backoffice (biarkan `INFOIS_MOBILE_MIN_VERSION=1.0.0`
dan `INFOIS_MOBILE_CLOSED_CODE_MIN_VERSION=1.0.0`).

**1.0.2+4** (2026-11-21; dulu direncanakan 1.0.2+3, tetapi Play Console menolak: "Version code 3 has already been used", jadi versionCode naik ke 4 pada 2026-11-25. AAB → `~/Desktop/Infois-POS-PlayStore/1-AAB-rilis/infois-1.0.2+4.aab`, ditandatangani kunci unggah CN=Infois; isi sama dengan build 1.0.2+3): **harga bertingkat per level pelanggan** (Member, Reseller,
Agen: `level_tiers` barang + `level_id` pelanggan, lihat API.md › sync/pull), daftar **Harga
bertingkat** di lembar barang (baris yang berlaku disorot), keterangan "harga grosir" / "harga
{level}" di baris pesanan, nama level di samping nama pelanggan, dan chip catatan cepat ("Tanpa
gula", "Pedas", …) dihapus (catatan barang tetap isian bebas). Database HP naik ke versi 4: tarikan
pertama setelah pembaruan selalu penuh. Server harus sudah mengirim `level_tiers` dan `level_id`
(backoffice dengan migrasi `2026_11_22_100000_create_customer_levels_table`) sebelum build ini
dirilis; server lama tetap bisa dipakai (tanpa harga level). Setelah rollout, set
`INFOIS_MOBILE_LATEST_VERSION=1.0.2`.
Tambahan 2026-11-22 (masih 1.0.2+3): **ketuk barang bersatuan lain → pilih satuan** (mis. pcs atau
"karton (isi 6 pcs)", harga 1 satuan ikut level pelanggan; "Atur jumlah & catatan" membuka lembar
barang) supaya kasir toko eceran tidak menghitung isi; barang satu satuan tetap langsung masuk, scan
dan Input AI tidak berubah. Satuan ditulis dengan isinya di baris pesanan dan chip satuan lembar barang.
Tambahan 2026-11-22 (masih 1.0.2+3): **fitur rumah makan / kafe bisa dimatikan** (`tenant.pos_dining`
dari web, Pengaturan Kasir › "Fitur rumah makan / kafe"; server lama tanpa kunci = tetap nyala): jenis
pesanan dan Meja / antrian disembunyikan, penjualan dikirim tanpa `order_type` / `order_label`. **Pesanan tersimpan yang dibuka lagi** memakai level pelanggan dan katalog
terbaru di HP (harga manual tetap); daftar pesanan tersimpan menampilkan "{nama} · {level}". Contoh
catatan pesanan jadi "mis. dikirim sore, nota dipisah"; petunjuk keranjang kosong menjelaskan pilihan
satuan.
Tambahan 2026-11-22 (masih 1.0.2+3): **Cetak tagihan** dan **Cetak list** dari panel pesanan sebelum
dibayar (pelanggan minta nota dulu / bon; offline, tidak dicatat): tagihan berjudul TAGIHAN, "Bukan
bukti pembayaran", cap BELUM DIBAYAR. Tombol "Pesanan dapur" setelah bayar jadi **Cetak list** (judul
LIST PESANAN) dan selalu tampil. **Biaya tambahan** nota (ongkos kirim, biaya layanan, biaya kemasan):
ikut total, tidak kena diskon nota & pajak, dikirim sebagai baris `charge` (server membukukan ke
Pendapatan Jasa; server lama menganggapnya baris tanpa barang biasa), tersimpan di pesanan tersimpan.
Tambahan 2026-11-22 (masih 1.0.2+3): **Alamat pengiriman** di pilihan pesanan, hanya bila barang dikirim
(Pesan antar atau ada ongkos kirim/antar/ekspedisi); isian awal dari alamat pelanggan, tercetak "Kirim ke:"
di struk, tagihan, dan list, dikirim sebagai `delivery_address`. Akun › **Pengaturan kasir** (dulu
"Printer struk"): pengguna yang boleh mengelola perusahaan (`menus.pos_settings`) bisa menyalakan /
mematikan "Fitur rumah makan / kafe" untuk semua kasir lewat `PUT /api/v1/pos/settings` (online saja);
printer tetap di bagian "Printer di perangkat ini". Server harus sudah punya endpoint itu (backoffice
565e431) sebelum rilis; server lama menjawab 404 dan HP menampilkan pesan galat biasa.
Tambahan 2026-11-24 (masih 1.0.2+3): **uang tunai kasir** — layar Bayar menyebut akun kas tujuan ("Uang
tunai masuk ke: Kas Kasir") bila ada lebih dari satu akun kas (akun laci dari Pengaturan Kasir web =
`accounts.default_cash_id`); Tutup kasir menampilkan dan mencetak uang awal & setoran otomatis dari server
(`cash_transfers` pada shift) beserta catatannya. Server lama tanpa kunci itu: tidak ada yang berubah.
Tambahan 2026-11-24 (masih 1.0.2+3): **bayar QRIS** (keputusan pemilik merevisi "tanpa QRIS di aplikasi"):
pilihan QRIS di layar Bayar bila `tenant.qris.enabled` — QR dinamis dari server (akun DOKU perusahaan),
status dicek tiap 3 detik, dibayar → penjualan langsung disimpan & dikirim dengan pembayaran `qris`
(ditolak = QR & keranjang tetap, bisa dicoba lagi); Batalkan QR / pindah cara bayar / keluar = QR dibatalkan;
"Cetak QR" (tagihan + QR ESC/POS) bila `print_on_bill`; struk "Bayar - QRIS"; baris QRIS di laporan shift.
Online saja. Server harus sudah punya `/api/v1/pos/qris` (backoffice 2b91647) sebelum rilis.
Tambahan 2026-11-24 (masih 1.0.2+3), **login perangkat seperti Majoo**: login penuh hanya untuk akun
pemilik (`role: owner`; selain itu ditolak di aplikasi, dan 403 `perangkat_khusus_pemilik` dari server →
kembali ke Masuk); setelah pemilik masuk layar PIN "Pilih Karyawan" selalu tampil (pemilik tanpa PIN
membuat PIN dulu; anggota tanpa PIN tampil redup; daftar dari `pin/users?include_without_pin=1`). Field
"Nama HP ini" dihapus: header `X-Device-Model` (MethodChannel `id.infois/device` di MainActivity) dan
model dikirim sebagai `device_name`. **Meja** dipilih dari `tenant.pos_tables` (kosong = isian bebas);
**nomor antrian** 6 angka harian per HP (`queue_number`, "ANTRIAN 000012" di list). **Printer kasir & printer
dapur** (list ke dapur, otomatis setelah bayar bila dinyalakan; cetak berurutan, pengaturan printer lama
jadi printer kasir). Perangkat yang login sebelum versi ini dengan akun selain pemilik tetap bisa dipakai
seperti dulu.

**1.0.5+7** (2026-11-26): izin **ubah harga & diskon** per role (`menus.edit_price`; tanpa izin: harga &
diskon baris terkunci, Diskon nota hilang; server lama = boleh), **Rekap kasir** (tombol Rekap di bilah kasir:
cetak rekap kasir yang masih dibuka + catatan) dan **catatan Tutup kasir** (dikirim `shift_close.notes`,
tercetak), nama bawaan Simpan pesanan = nomor pesanan, tulisan LUNAS/BELUM LUNAS di struk tidak lagi blok hitam.
Menggantikan 1.0.4+6 bila belum diunggah.

**1.0.9+11** (2026-11-28): **fitur dikunci paket** (server 2026-11-28, `tenant.locked_features`): fitur
rumah makan, QRIS, dan Input AI yang tidak termasuk paket tampil bergembok dan diketuk menjelaskan "Fitur
tidak tersedia pada paket ini" + paket yang membukanya (aplikasi lama: disembunyikan). Berisi semua isi
1.0.8+10; menggantikan 1.0.8+10 bila belum diunggah.

**1.0.8+10** (2026-11-28): **add-on barang** (mis. box nasi ayam + pilihan sambal hijau / saus). Katalog
mengirim `addons` per barang; mengetuk barang ber-add-on memunculkan pilihan add-on (bersama pilihan satuan
bila ada), juga di lembar barang dan ubah baris. Add-on tidak menambah harga, tampil di keranjang, dikirim per
baris (`items.*.addons`, server mengurangi stoknya seperti komposisi), dan tercetak di struk (`+ ...`), list
pesanan dapur, dan teks WhatsApp. Server lama mengabaikannya. **Merek Infois POS** (folder BRAND POS): ikon
peluncur, layar pembuka Android (tanda POS di kotak putih), layar pembuka aplikasi dan panel Masuk/Kunci
(logo + tulisan Infois POS, tagline "Transaksi simpel kalau punya asisten keuangan."), judul "Masuk ke
Infois POS". **Pesanan tersimpan rumah makan** bernama nomor-meja-pelanggan (`000001-Meja 01-Firmawan`,
tanpa meja `000001-Tanpa meja`; nama ketikan kasir tetap), daftar pesanan tersimpan punya kotak cari bila
lebih dari 5, dan pilih meja punya kotak cari bila lebih dari 9 meja. **Fitur dikunci paket** (server
2026-11-28, `tenant.locked_features`): fitur rumah makan, QRIS, dan Input AI yang tidak termasuk paket
Menggantikan 1.0.7+9 bila belum diunggah.

**1.0.7+9** (2026-11-27): owner bisa **Hapus semua transaksi** di web (mulai dari nol). Saat tarik data,
HP membaca `tenant.transactions_reset_at` dan sekali membuang penjualan, shift, pesanan tersimpan, serta
antrean penjualan/shift yang lebih lama (server menolaknya); antrean pelanggan baru tetap dikirim. Server
lama tanpa kunci ini: tidak ada yang berubah. Menggantikan 1.0.6+8 bila belum diunggah.

**1.0.6+8** (2026-11-26): nama fitur **Tim AI** menjadi **Asisten AI** di seluruh aplikasi; tab bawah cukup
**AI** (sempit). Filter kalimat pembelian Play juga mengenali "asisten ai". Menggantikan 1.0.5+7 bila belum diunggah.

**1.0.4+6** (2026-11-26): **printer produksi** (dapur / bar / checker) sebanyak apa pun, masing-masing
Bluetooth atau Wi-Fi (ESC/POS TCP port 9100, cari di jaringan & tambah beberapa sekaligus), nama sendiri,
kategori barang (semua / beberapa), dan lebar kertas; printer kasir juga boleh Wi-Fi. "Cetak list" ke semua
printer sekaligus (judul = nama printer, ANTRIAN, meja); yang gagal disebut namanya + Ulangi. Nomor antrian
sejak barang pertama, tampil di Pesanan tersimpan & Riwayat. QR struk bisa tautan sendiri + tulisan
(`receipt.qr_mode/qr_link/qr_caption`, server 2026-11-26; server lama = QR cek keaslian seperti biasa). Foto
profil Google tampil di Akun & layar PIN. Tulisan bantuan di kasir dipangkas.

**1.0.3+5** (2026-11-25): **Masuk dengan Google** (tombol di bawah "Masuk"; paket baru `google_sign_in`
7.2.0 + `google_sign_in_android` 7.2.1 = versi terakhir untuk Flutter 3.29/Dart 3.7, lolos build dengan
Kotlin Gradle plugin 1.8.22) dan **tampilan awal hijau** dengan logo web (layar pembuka Android, layar
pembuka aplikasi, dan panel Masuk/Kunci: latar `#0A7F3E`, logo `assets/images/infois-logo-web-on-green.png`
= logo Administrator › Brand Aplikasi versi putih). Server harus sudah punya `GET/POST /api/v1/auth/google`
(backoffice, 2026-11-25) sebelum rilis; server lama menjawab 404 → "Masuk dengan Google belum tersedia".

Sebelum rilis, buat **OAuth client jenis Android** di project Google Cloud yang sama dengan Client ID web
(Administrator › Login Google › bagian "Aplikasi Android" menuliskan langkahnya):

| Untuk | Package | SHA-1 |
|---|---|---|
| Aplikasi dari Play Store | `id.infois.infois` | Play Console › App integrity › **App signing key certificate** |
| APK rilis yang dipasang manual | `id.infois.infois` | Kunci unggah `CN=Infois`: `4C:F6:B0:75:5E:8B:F3:57:22:8F:8E:C2:EF:F1:4E:7C:98:46:24:58` |
| Build debug di mesin pengembang | `id.infois.infois` | `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android` |

SHA-1 kunci unggah bisa dicek ulang tanpa kata sandi: `keytool -printcert -jarfile infois-x.y.z+n.aab`.

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
