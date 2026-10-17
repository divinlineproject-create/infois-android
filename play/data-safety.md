# Formulir Data Safety (Play Console › App content › Data safety)

Disusun dari kode aplikasi (`lib/`), manifest hasil gabungan, dan kebijakan privasi
https://infois.ai/kebijakan-privasi (versi 2026-10). Isi ulang bila aplikasi menambah SDK
(analitik, crash reporting, iklan) atau izin baru.

## Pertanyaan umum

| Pertanyaan | Jawaban |
|---|---|
| Apakah aplikasi mengumpulkan atau membagikan data pengguna yang wajib dilaporkan? | **Ya** |
| Apakah semua data pengguna dienkripsi saat transit? | **Ya**. Semua permintaan ke `https://dashboard.infois.ai` memakai HTTPS; `usesCleartextTraffic=false` di build rilis. |
| Apakah Anda menyediakan cara bagi pengguna untuk meminta penghapusan data? | **Ya**. Di aplikasi: Akun › Hapus akun. Di web: lihat `account-deletion.md` (URL untuk kolom "Delete account URL"). |
| Login | Aplikasi memakai akun Infois (email + kata sandi). |

## "Dibagikan" (shared)

Jawab **tidak ada data yang dibagikan** ke pihak ketiga. Menurut definisi Google, yang **bukan**
"sharing":

- Penyedia layanan yang memproses data atas nama kami: penyedia AI untuk Tim AI (transkripsi
  voice note, membaca foto nota/file), hosting, email.
- Tindakan yang dimulai pengguna sendiri: Bagikan ke WhatsApp / aplikasi lain, membuka PDF.
- Pemilik usaha atau anggota tim yang melihat data perusahaan yang sama (bagian dari layanan).

Tidak ada SDK iklan, analitik, atau crash reporting di aplikasi (cek `pubspec.yaml`).

## Data yang dikumpulkan

Semua: **dikumpulkan** (dikirim ke server Infois), **tidak dibagikan**, **tidak diproses
sementara saja** (disimpan), dienkripsi saat transit, bisa dihapus (hapus akun).

| Kategori Play | Jenis data | Wajib/opsional | Tujuan (pilihan Play) | Dari mana di aplikasi |
|---|---|---|---|---|
| Personal info | **Name** | Wajib | App functionality, Account management | Profil akun dari server; nama pelanggan yang dicatat kasir |
| Personal info | **Email address** | Wajib | App functionality, Account management | Masuk (email + kata sandi) |
| Personal info | **User IDs** | Wajib | App functionality, Account management, Fraud prevention/security | ID pengguna & perusahaan dari server |
| Personal info | **Phone number** | Opsional | App functionality | Nomor telepon pelanggan yang diisi kasir / untuk kirim struk WhatsApp |
| Personal info | **Address** | Opsional | App functionality | Alamat pelanggan / pengiriman pesanan bila diisi |
| Financial info | **Purchase history** | Wajib | App functionality | Penjualan & pembelian usaha yang dicatat (nota, item, total) |
| Financial info | **Other financial info** | Wajib | App functionality, Analytics (laporan usaha untuk pengguna) | Kas/bank, piutang, utang, shift kasir, laporan |
| Photos and videos | **Photos** | Opsional | App functionality | Foto nota yang dikirim ke Tim AI (kamera/galeri) |
| Audio | **Voice or sound recordings** | Opsional | App functionality | Voice note Tim AI (mikrofon, hanya saat merekam) |
| Files and docs | **Files and docs** | Opsional | App functionality | File PDF/Excel yang dilampirkan ke Tim AI |
| App activity | **Other user-generated content** | Opsional | App functionality | Pesan teks ke Tim AI, catatan pesanan |
| Device or other IDs | **Device or other IDs** | Wajib | App functionality, Fraud prevention/security | `device_uid` acak buatan aplikasi + nama HP (tampil di web › Tim & Akses › Perangkat; HP bisa dicabut) |

Tidak dikumpulkan (jawab **tidak**):

- **Location**: tidak dibaca. Izin lokasi hanya dideklarasikan untuk Android 11 ke bawah
  (`maxSdkVersion=30`) karena sistem mewajibkannya untuk memindai printer Bluetooth; di
  Android 12+ izin `BLUETOOTH_SCAN` memakai `neverForLocation`. Aplikasi tidak memanggil API
  lokasi dan tidak mengirim lokasi. Google: izin yang tidak dipakai mengumpulkan data tidak
  perlu dilaporkan.
- **Contacts**: kontak HP tidak dibaca (pelanggan diketik manual).
- **Crash logs / Diagnostics / Performance**: tidak ada SDK crash/analitik. Server mencatat
  log akses (IP, versi aplikasi `X-App-Version`, platform). Bila ingin sangat konservatif,
  centang *App info and performance › Diagnostics* dengan tujuan *App functionality*; tidak
  wajib karena itu log server biasa, bukan data diagnostik dari HP.
- **Web browsing, Messages (SMS/email), Health, Calendar, App interactions/analytics**: tidak.

## Catatan izin (cocok dengan manifest rilis)

| Izin | Kenapa | Penjelasan di aplikasi |
|---|---|---|
| INTERNET, ACCESS_NETWORK_STATE | Server Infois, status Online/Offline | - |
| BLUETOOTH_SCAN (neverForLocation), BLUETOOTH_CONNECT; BLUETOOTH/BLUETOOTH_ADMIN & lokasi hanya ≤ Android 11 | Printer struk | Dialog "Izinkan Bluetooth" sebelum mencari printer |
| RECORD_AUDIO | Voice note Tim AI | Dialog "Izinkan mikrofon" sebelum rekaman pertama |
| CAMERA | Scan barcode barang di kasir (mobile_scanner + ML Kit di dalam aplikasi) | Dialog "Izinkan kamera" saat tombol Scan pertama kali ditekan |
| WRITE/READ_EXTERNAL_STORAGE hanya ≤ Android 9 | Simpan PDF ke folder Download | Diminta saat mengunduh |
| WAKE_LOCK, RECEIVE_BOOT_COMPLETED | WorkManager: sinkron transaksi offline di latar | - |

Dibuang dari manifest: `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE` (bawaan plugin, tidak dipakai),
`READ_MEDIA_*`. Tidak ada `QUERY_ALL_PACKAGES`.

**Kamera (`CAMERA`, sejak 1.0.0 "Infois POS")**: hanya untuk scan barcode barang di kasir. Gambar
kamera diproses **di HP** oleh model barcode ML Kit yang dibundel di aplikasi (tanpa Google Play
Services, tanpa internet); yang dipakai hanya teks kodenya untuk mencari barang di katalog HP.
Gambar tidak disimpan, tidak diunggah, dan tidak dikirim ke server Infois atau pihak lain. Menurut
definisi Google, data yang hanya diproses di perangkat dan tidak dikirim keluar **bukan** data
yang "dikumpulkan", jadi formulir Data Safety tidak berubah (jangan centang Photos untuk scan).
Foto nota Tim AI tetap lewat aplikasi kamera sistem (image_picker) seperti sebelumnya.
Izin diminta hanya saat pengguna menekan tombol Scan, setelah penjelasan di aplikasi; bila
ditolak, kasir tetap bisa mengetik kode atau memakai scanner Bluetooth/USB.

Cadangan: `allowBackup=false` + `data_extraction_rules.xml` (tanpa cadangan cloud atau pindah
perangkat; token login terikat Keystore HP dan transaksi offline tidak boleh terkirim dua kali).
