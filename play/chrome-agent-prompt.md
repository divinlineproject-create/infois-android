# Prompt untuk Claude in Chrome: setup aplikasi di Google Play Console

Salin semua teks di dalam blok di bawah ini ke Claude in Chrome. Sebelum menyalin, ganti semua
`[ISI: …]` dengan nilai sebenarnya.

```text
Kamu membantu saya menyiapkan aplikasi Android baru "Infois POS" di Google Play Console
(https://play.google.com/console). Saya sudah login di Chrome dengan akun developer
PT. DEVINE AUTADA TECH. Kerjakan langkah demi langkah di tab ini.

ATURAN PENTING (wajib dipatuhi):
1. JANGAN memasukkan atau mengubah data pembayaran, rekening, pajak, atau profil merchant.
2. JANGAN menekan tombol yang menerbitkan atau mengirim untuk ditinjau: "Send for review" /
   "Kirim untuk ditinjau", "Start rollout" / "Mulai peluncuran", "Publish" / "Publikasikan",
   "Promote release" / "Promosikan rilis". Berhenti di halaman ringkasan, lalu laporkan ke saya.
3. Sebelum mencentang pernyataan hukum (Developer Program Policies, US export laws, Play App
   Signing Terms), tampilkan teks pernyataannya kepada saya dan tunggu saya bilang "setuju".
4. Bila ada kolom yang jawabannya tidak tercantum di bawah, atau pilihan di layar berbeda dari
   yang saya tulis, BERHENTI dan tanyakan. Jangan menebak.
5. Jangan mengunggah file apa pun kecuali saya sendiri yang memilihnya di dialog file. Bila
   perlu unggahan (ikon, grafik, screenshot, AAB), lewati slotnya dan catat di laporan akhir.
6. Setelah tiap bagian selesai, tekan Save / Simpan, pastikan tidak ada pesan galat, lalu
   lanjut ke bagian berikutnya.
7. Jangan menempel email, kata sandi, atau data akun peninjau ke tempat lain selain kolom
   "App access" di Play Console.

DATA YANG DIPAKAI:
- Developer: PT. DEVINE AUTADA TECH
- Nama aplikasi: Infois POS: Kasir & Tim AI
- Package (sudah tetap di AAB): id.infois.infois
- Bahasa default: Indonesian – id-ID
- Jenis: App (bukan Game). Gratis (Free). Tanpa iklan.
- Kategori: Business (Bisnis)
- Email kontak dukungan: [ISI: email dukungan perusahaan]
- Situs web: https://infois.ai
- Kebijakan privasi: https://infois.ai/kebijakan-privasi
- URL hapus akun: https://infois.ai/hapus-akun
- Akun uji peninjau: email [ISI], kata sandi [ISI] (akun khusus peninjau, tanpa 2FA)

=====================================================================
LANGKAH 1 — Create app (Buat aplikasi)
=====================================================================
All apps / Semua aplikasi › Create app / Buat aplikasi:
- App name: Infois POS: Kasir & Tim AI
- Default language: Indonesian – id-ID
- App or game: App
- Free or paid: Free
- Declarations (pernyataan): tampilkan ke saya dulu (aturan no. 3), centang setelah saya setujui.
Tekan Create app.

=====================================================================
LANGKAH 2 — App content / Konten aplikasi (Policy › App content)
=====================================================================
a) Privacy policy: https://infois.ai/kebijakan-privasi

b) App access:
   - Pilih "All or some functionality is restricted" (sebagian/semua fungsi dibatasi).
   - Add instructions: Name "Akun uji Infois POS", username/email [ISI], password [ISI].
   - Any other information (tempel apa adanya):
     Log in with the credentials above. The app is a companion for existing Infois business
     customers; accounts and plans are managed by the business owner outside the app. No
     purchases are possible in the app. Tabs: Kasir (point of sale, works offline), Tim AI (AI
     assistant; type "2 cappuccino, cash" and tap Setujui on the proposal), Laporan (reports),
     Catatan (records), Akun (account; "Hapus akun" opens the account deletion page). A Bluetooth
     thermal printer is optional. In Kasir, the scan icon in the search bar scans a product
     barcode with the camera (camera permission is requested only then; images stay on the device).

c) Ads: No, my app does not contain ads.

d) Content rating (kuesioner IARC):
   - Email: [ISI: email dukungan]
   - Category: All Other App Types (utilitas/produktivitas/bisnis), bukan game.
   - Kekerasan, konten seksual, bahasa kasar, narkoba/alkohol/tembakau, perjudian, horor: No (semua).
   - Users interact or exchange content with other users: No.
   - Shares user's current physical location: No.
   - Allows users to purchase digital goods: No.
   - Unrestricted internet access / browser: No.
   - Bila ditanya fitur AI generatif: Yes, hanya teks (bukan gambar/suara).
   - Simpan, lalu terapkan rating yang dihasilkan (perkiraan: Semua umur / IARC 3+).

e) Target audience and content:
   - Usia target: hanya 18 and over.
   - Could your app unintentionally appeal to children? No.
   - Tidak ikut Designed for Families.

f) News apps: No. Government apps: No. Health apps: tidak ada fitur kesehatan. COVID-19: No.

g) Financial features: pilih "My app doesn't provide any of these financial features" (aplikasi
   hanya mencatat pembukuan usaha pengguna; tidak memproses pembayaran, transfer, pinjaman,
   investasi, atau kripto). Bila ada opsi khusus semacam "budgeting/accounting tool" saja,
   tanyakan ke saya dulu. JANGAN pilih payment processing.

h) Data safety:
   Pertanyaan umum:
   - Collects or shares required user data types: Yes
   - All user data encrypted in transit: Yes
   - Provide a way for users to request data deletion: Yes
   - Account creation: aplikasi memakai akun (login email + kata sandi dibuat di web).
     Delete account URL: [URL hapus akun di atas]
   - Partial data deletion without deleting account: No
   Data shared with third parties: TIDAK ADA (jangan centang "shared" di jenis mana pun).
   Data collected (semua: Collected = Yes, Shared = No, Processed ephemerally = No,
   bisa dihapus):
   | Kategori | Jenis | Wajib/Opsional | Tujuan |
   |---|---|---|---|
   | Personal info | Name | Required | App functionality, Account management |
   | Personal info | Email address | Required | App functionality, Account management |
   | Personal info | User IDs | Required | App functionality, Account management, Fraud prevention/security |
   | Personal info | Phone number | Optional | App functionality |
   | Personal info | Address | Optional | App functionality |
   | Financial info | Purchase history | Required | App functionality |
   | Financial info | Other financial info | Required | App functionality, Analytics |
   | Photos and videos | Photos | Optional | App functionality |
   | Audio | Voice or sound recordings | Optional | App functionality |
   | Files and docs | Files and docs | Optional | App functionality |
   | App activity | Other user-generated content | Optional | App functionality |
   | Device or other IDs | Device or other IDs | Required | App functionality, Fraud prevention/security |
   TIDAK dikumpulkan (biarkan tidak dicentang): Location, Contacts, Web browsing, Messages,
   Health, Calendar, App interactions/analytics, Crash logs, Diagnostics.
   (Kamera hanya dipakai untuk scan barcode dan diproses di HP, jadi BUKAN "Photos" untuk scan.)
   Simpan, lalu tunjukkan ringkasan pratinjau Data safety kepada saya.

=====================================================================
LANGKAH 3 — Store settings & Main store listing (Grow › Store presence)
=====================================================================
a) Store settings:
   - App category: Business
   - Tags: pilih yang paling mendekati Accounting / Point of sale / Productivity (maks. 5).
   - Contact details: email [ISI], website https://infois.ai. Telepon: kosongkan kecuali saya beri.

b) Main store listing (id-ID):
   - App name: Infois POS: Kasir & Tim AI
   - Short description:
     Kasir offline, laporan usaha, dan Tim AI untuk pengguna Infois di HP.
   - Full description: tempel PERSIS teks di blok "Deskripsi lengkap" yang saya berikan
     terpisah (dari file play/listing-id.md). Bila saya belum memberikannya, berhenti dan minta.
   - Graphics (app icon 512x512, feature graphic 1024x500, phone screenshots, tablet
     screenshots): LEWATI, saya unggah sendiri. Catat slot yang masih kosong.
   Simpan.

=====================================================================
LANGKAH 4 — Siapkan uji internal (Testing › Internal testing) — TANPA meluncurkan
=====================================================================
- Tab Testers: buat daftar penguji email "Infois internal" berisi [ISI: email penguji, dipisah koma].
- Tab Releases: Create new release.
  - Bila diminta memilih penandatanganan: pilih "Use Google-generated key" / Play App Signing
    (tampilkan syarat ke saya dulu, aturan no. 3).
  - Unggahan AAB: JANGAN diunggah sendiri. Berhenti di sini dan beri tahu saya untuk memilih
    file app-release.aab.
  - Setelah saya unggah: Release name "1.0.0 (1)". Release notes id-ID:
    Rilis pertama Infois POS di Google Play: kasir offline dengan foto barang, kategori, scan barcode kamera, dan printer Bluetooth, Tim AI (teks, voice note, foto nota), laporan penjualan, catatan transaksi, unduh PDF, dan hapus akun dari menu Akun.
  - Tekan Save, lalu Review release. BERHENTI di halaman review (jangan Start rollout).

=====================================================================
LAPORAN AKHIR
=====================================================================
Tulis ringkasan untuk saya:
1. Bagian yang selesai dan sudah tersimpan (centang hijau di Dashboard).
2. Bagian yang masih kosong atau butuh saya (unggah grafik/screenshot/AAB, pernyataan hukum, dll.).
3. Peringatan atau galat dari Play Console, beserta teks aslinya.
4. Pilihan yang berbeda dari instruksi saya, dan apa yang kamu pilih atau tanyakan.
```

## Sebelum menjalankan prompt (cek pemilik)

- [ ] Akun developer Play atas nama PT. DEVINE AUTADA TECH sudah aktif (organisasi, D-U-N-S terverifikasi).
- [ ] Email dukungan siap dipakai (muncul publik di toko).
- [ ] Akun peninjau: email terverifikasi, **tanpa** 2FA, perusahaan dengan paket aktif yang
      termasuk aplikasi HP (Android), katalog berisi barang dan foto, Tim AI menyala.
- [ ] Landing sudah di-deploy: halaman publik `https://infois.ai/hapus-akun` terbuka tanpa login,
      dan Kebijakan Privasi memuat paragraf "Aplikasi Android Infois POS". Bila teks privasi
      pernah diubah di Administrator › Website, tekan "Muat draf bawaan" lalu Simpan.
- [ ] Email kontak terisi di Administrator › Website › Kontak (tampil di halaman Hapus Akun).
- [ ] AAB rilis sudah dibangun dengan kunci rilis: `flutter build appbundle --release`.
- [ ] Grafik toko & screenshot siap: `screenshots.md`, `test/screenshots/`.
