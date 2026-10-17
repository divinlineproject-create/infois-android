# App content (Play Console › Policy and programs › App content)

## Kebijakan privasi

URL: `https://infois.ai/kebijakan-privasi` (juga ditautkan di aplikasi: Akun › Kebijakan privasi).

**TODO pemilik (landing):** kebijakan privasi saat ini membahas layanan web, tetapi belum menyebut
hal khusus aplikasi HP. Google meminta kebijakan menjelaskan data yang diakses aplikasi. Tambahkan
di bagian 2 "Data yang kami kumpulkan" (`landing/resources/markdown/pages/kebijakan-privasi.md`):

```markdown
8. **Aplikasi Android Infois**: pengenal perangkat acak yang dibuat aplikasi dan nama HP (untuk
   daftar perangkat di Tim & Akses dan mencabut akses HP), versi aplikasi, serta data transaksi
   kasir yang disimpan sementara di HP saat offline sampai terkirim ke server. Aplikasi meminta
   izin mikrofon hanya untuk merekam voice note Tim AI, dan izin Bluetooth hanya untuk printer
   struk. Di Android 11 ke bawah, sistem juga meminta izin lokasi untuk mencari printer
   Bluetooth; aplikasi tidak membaca, menyimpan, atau mengirim lokasi Anda. Foto nota diambil
   lewat aplikasi kamera HP hanya saat Anda memilihnya.
```

## Akses aplikasi (App access) untuk peninjau

Pilih **"All or some functionality is restricted"** dan berikan akun uji, karena aplikasi
menolak masuk bila perusahaan tidak punya paket aktif yang termasuk aplikasi HP.

**TODO pemilik:** siapkan akun khusus peninjau (jangan akun pribadi):

- Email & kata sandi khusus, email sudah terverifikasi, **tanpa** 2FA/kode email.
- Perusahaan contoh dengan langganan **aktif yang termasuk aplikasi HP**, katalog berisi barang,
  dan Tim AI menyala (jatah koin cukup). Akun demo Kopi Senja bisa dipakai bila paketnya
  memenuhi syarat. Catatan: akun `@kopisenja.example` tidak bisa dihapus (terkunci di server),
  jadi peninjau tidak bisa mencoba hapus akun di sana; sebutkan di instruksi.
- Instruksi untuk peninjau (Inggris):
  > Log in with the credentials above. The app is a companion for existing Infois business
  > customers; accounts and plans are managed by the business owner outside the app. No
  > purchases are possible in the app. Tabs: Kasir (point of sale, works offline), Tim AI (AI
  > assistant; type "2 cappuccino, cash" and tap Setujui on the proposal), Laporan (reports),
  > Catatan (records), Akun (account; "Hapus akun" opens the account deletion page). A Bluetooth
  > thermal printer is optional.

## Iklan

**Tidak, aplikasi tidak berisi iklan.**

## Rating konten (kuesioner IARC)

- Email kontak: email dukungan PT. DEVINE AUTADA TECH.
- Kategori: **"All other app types"** (utilitas/produktivitas/bisnis), bukan game.
- Kekerasan, seksual, bahasa kasar, narkoba/alkohol/tembakau, perjudian, horor: **Tidak** semua.
- *Does the app allow users to interact or exchange content with other users?* **Tidak.** Data
  hanya dilihat oleh tim di perusahaan yang sama (bukan komunikasi publik antar pengguna).
  Bila ragu karena tim perusahaan berbagi catatan, jawab Ya → rating tetap rendah; tidak ada
  pengaruh ke kebijakan lain.
- *Does the app share the user's current physical location?* **Tidak.**
- *Does the app allow users to purchase digital goods?* **Tidak** (pembelian tidak ada di aplikasi).
- *Unrestricted internet access (browser)?* **Tidak** (hanya membuka tautan tertentu ke browser HP).
- Konten buatan AI: Tim AI menghasilkan teks usulan pencatatan; pengguna menyetujui sendiri.
  Bila kuesioner menanyakan fitur AI generatif, jawab **Ya** (teks), bukan gambar/suara.
- Perkiraan hasil: **Semua umur / PEGI 3 / IARC 3+**.

## Target audiens & konten

- Usia target: **18 tahun ke atas** saja.
- *Could your app unintentionally appeal to children?* **Tidak** (aplikasi kasir & pembukuan).
- Tidak ikut program "Designed for Families".

## Kategori aplikasi & data lain

- Kategori: **Business**. Tipe: App.
- **Financial features declaration**: aplikasi mencatat pembukuan dan transaksi usaha milik
  pengguna, tetapi **tidak** memproses pembayaran, transfer uang, pinjaman, investasi, atau
  kripto. Pilih "My app doesn't provide any of these financial features" (atau padanannya,
  mis. hanya "budgeting/accounting tool" bila opsi itu ada). Jangan pilih "Payment processing".
- **Government app**: Tidak. **News app**: Tidak. **Health**: Tidak. **COVID**: Tidak.
- **Data safety**: lihat `data-safety.md`.
- **Foreground service / exact alarm / background location / photo & video permission
  declarations**: tidak perlu (izinnya tidak ada di manifest rilis). Bila Play Console tetap
  menanyakan, cek ulang manifest gabungan (lihat `RELEASING.md`).

## Kebijakan Pembayaran (penting untuk lolos review)

Paket berlangganan dan koin Tim AI dibeli di web (Midtrans). Google Play melarang aplikasi
mengarahkan pengguna ke pembayaran di luar Google Play untuk barang/layanan digital. Yang sudah
dilakukan di aplikasi:

- Tidak ada tombol/tautan ke Langganan, Dompet Koin, harga, atau "upgrade". Tautan ke dasbor web
  juga dihapus (dasbor memuat menu Langganan).
- Pesan server tentang paket/koin diganti kalimat netral: "Hubungi pemilik usaha atau admin
  Infois Anda" (`lib/core/store_policy.dart`).
- Jawaban Tim AI yang mengajak isi ulang koin/upgrade disaring di HP, dan tautan ke halaman
  pembelian diblokir.
- Login hanya untuk pelanggan yang sudah aktif; trial tidak bisa masuk dari HP.

**TODO backoffice (agar tidak bergantung pada saringan di HP):** saat percakapan Tim AI datang
dari kanal `mobile`, prompt sistem di `app/Services/Ai/AgentRunner.php` masih berisi:

- "...jelaskan singkat bahwa tim tersebut bisa dibuka lewat menu Langganan" (bagian tim terkunci)
- "Bila ditanya sisa koin/langganan, ... arahkan ke menu Dompet Koin untuk isi ulang."

Untuk kanal `mobile` ganti keduanya dengan: "Jangan menyebut harga, nama paket, menu Langganan,
Dompet Koin, atau cara membeli/isi ulang. Bila ditanya, sampaikan bahwa pengaturan akun dan jatah
Tim AI diurus oleh pemilik usaha atau admin Infois." Juga `MobileAccess::deniedPayload` dan
`AiChannels::lockedMessage(MOBILE)` sebaiknya mengirim kalimat netral untuk aplikasi (HP sudah
menggantinya, tetapi versi aplikasi lama/baru lebih aman bila server ikut netral).
