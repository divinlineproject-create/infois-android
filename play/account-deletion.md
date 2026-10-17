# Hapus akun: syarat Google Play

Google mewajibkan dua jalan untuk aplikasi yang punya akun:

1. **Di dalam aplikasi.** Sudah ada: Akun › **Hapus akun**. Aplikasi menjelaskan apa yang
   dihapus dan yang disimpan, lalu membuka `https://dashboard.infois.ai/app/hapus-akun` di browser.
   Penghapusannya sendiri terjadi di web: ketik `HAPUS AKUN`, lalu konfirmasi dengan kata sandi
   (akun Google: kode 6 angka lewat email).
2. **Tautan web di Play Console** (App content › Data safety › *Delete account URL*). Tautan ini
   harus bisa dibuka **tanpa memasang aplikasi**, harus menyebut nama aplikasi/pengembang, harus
   menampilkan **langkah-langkah** menghapus akun dengan jelas, dan harus menyebut data apa yang
   dihapus atau disimpan beserta lama penyimpanannya.

## Apakah `dashboard.infois.ai/app/hapus-akun` cukup?

Belum ideal. Halaman itu butuh login. Pengguna yang belum login langsung dialihkan ke
halaman Masuk, tanpa penjelasan langkah dan data yang dihapus. Kebijakan Google tidak
secara tegas melarang login, tetapi meminta halaman yang "prominently feature the steps" dan
bisa dipakai tanpa aplikasi. Peninjau sering menolak tautan yang langsung jatuh ke halaman login.

**Rekomendasi (TODO pemilik / tim landing):** buat halaman publik `https://infois.ai/hapus-akun`
di aplikasi `landing/` (sama seperti `/kebijakan-privasi`), lalu isi kolom *Delete account URL*
dengan alamat itu. Aplikasi sudah mengizinkan membuka `infois.ai/hapus-akun` (lihat
`isPurchaseUrl` di `lib/core/store_policy.dart`). Sampai halaman itu terbit, pakai sementara
`https://dashboard.infois.ai/app/hapus-akun`.

### Isi halaman `infois.ai/hapus-akun` (salin apa adanya)

```markdown
# Hapus akun Infois

Halaman ini menjelaskan cara menghapus akun Infois, baik akun yang dipakai di aplikasi
Android "Infois POS: Kasir & Tim AI" maupun di Infois versi web. Aplikasi dan layanan Infois
dikelola oleh PT. DEVINE AUTADA TECH.

## Cara menghapus akun

1. Buka https://dashboard.infois.ai/app/hapus-akun di browser (HP atau komputer).
   Dari aplikasi Android: buka menu **Akun**, pilih **Hapus akun**, lalu **Buka halaman Hapus akun**.
2. Masuk dengan email dan kata sandi akun yang ingin dihapus (atau tombol Masuk dengan Google).
3. Baca ringkasan dampaknya, ketik **HAPUS AKUN**, lalu konfirmasi dengan kata sandi.
   Akun yang masuk dengan Google mengonfirmasi dengan kode 6 angka yang dikirim ke email.
4. Akun langsung dinonaktifkan dan Anda keluar dari semua perangkat.

Tidak bisa masuk lagi (lupa kata sandi)? Pakai "Lupa kata sandi" di halaman Masuk, atau kirim
permintaan dari alamat email akun Anda ke [EMAIL DUKUNGAN]. Kami memverifikasi kepemilikan email
sebelum menghapus.

## Data yang dihapus

- Perusahaan yang Anda pegang sebagai pemilik ditutup, dan seluruh datanya dihapus permanen
  segera: transaksi, dokumen, file, foto nota, percakapan Tim AI, daftar pengguna dan perannya,
  sambungan Telegram, serta perangkat kasir.
- Dari perusahaan tempat Anda hanya anggota, Anda dikeluarkan. Data perusahaan itu tetap milik
  pemiliknya.
- Percakapan dan memori Tim AI pribadi Anda, sesi masuk, dan perangkat Anda dihapus.
- Sisa koin Tim AI dan masa aktif perusahaan yang ditutup hangus, tanpa pengembalian dana.

## Data yang tetap disimpan

- Nama, alamat email, dan nomor telepon akun disimpan dalam keadaan nonaktif sebagai bagian
  dari catatan tagihan dan untuk mencegah penyalahgunaan. Akun tidak dapat dipakai lagi.
- Nama perusahaan yang ditutup beserta catatan penutupannya, riwayat pembayaran langganan, dan
  catatan jumlah pemakaian Tim AI tanpa isi pekerjaannya, selama diwajibkan peraturan
  perpajakan dan perundang-undangan.
- Salinan cadangan (backup) terhapus bertahap sesuai siklus cadangan, paling lama [N] hari.

Penghapusan tidak dapat dibatalkan.
Pertanyaan: [EMAIL DUKUNGAN]. Kebijakan privasi: https://infois.ai/kebijakan-privasi
```

Isi `[EMAIL DUKUNGAN]` dan `[N]` (siklus cadangan sebenarnya) sebelum terbit. Isi data yang
dihapus/disimpan disalin dari Kebijakan Privasi bagian 6 dan perilaku `AccountDeletionService`.
Bila Akun Usaha mengubah aturannya (mis. semua perusahaan dalam Akun Usaha ikut ditutup),
samakan halaman ini dan teks di aplikasi (`showDeleteAccountSheet` di `akun_screen.dart`).

## Jawaban formulir

- *Does your app allow users to create an account?* **Ya** (akun dibuat di web; aplikasi hanya
  untuk masuk, tetapi Google tetap menganggapnya "app with accounts").
- *Delete account URL*: `https://infois.ai/hapus-akun` (setelah terbit) atau sementara
  `https://dashboard.infois.ai/app/hapus-akun`.
- *Do you provide a way for users to request that some or all of their data is deleted, without
  requiring them to delete their account?* Jawab **Tidak**, kecuali tim siap melayani permintaan
  hapus sebagian lewat email (Kebijakan Privasi bagian 6.4 menyebutnya). Bila Ya, isi URL halaman
  yang sama dan tambahkan paragraf "Hapus sebagian data" dengan alamat email dukungan.
