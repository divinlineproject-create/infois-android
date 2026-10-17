# Screenshot & grafik toko

Semua gambar dibuat dari layar aplikasi yang sebenarnya (widget test + data contoh "Kopi Senja"),
bukan mockup:

```bash
cd android
SHOTS_DIR=/folder/keluaran flutter test test/screenshots/play_store_screenshots.dart
```

Hasil terakhir (2026-10-11):
`/private/tmp/claude-501/-Users-macbook-Documents-saas-akuntan/714afe07-e34a-4bc6-89d6-9cb097baf70e/scratchpad/play/shots/`
(folder sementara, jadi salin ke tempat aman sebelum mengunggah, atau jalankan ulang perintah di atas).

## Yang diunggah

| Slot Play Console | File | Ukuran | Wajib? |
|---|---|---|---|
| App icon | `store-icon-512.png` | 512 x 512 PNG | Wajib |
| Feature graphic | `feature-graphic-1024x500.png` | 1024 x 500 PNG | Wajib |
| Phone screenshots (2-8) | `phone-1-kasir.png`, `phone-2-tim-ai.png`, `phone-3-usulan.png`, `phone-4-laporan.png` | 1080 x 1920 (9:16) | Wajib, min. 2 |
| 7-inch tablet | `tablet7-*.png` | 1200 x 1920 | Opsional (disarankan; kasir punya tata letak tablet) |
| 10-inch tablet | `tablet10-*.png` | 1600 x 2560 | Opsional |

Urutan & pesan tiap layar:

1. **Kasir**: katalog barang + pesanan berjalan (offline tetap jalan).
2. **Tim AI**: layar awal, saran perintah, tim yang siap bekerja.
3. **Usulan Tim AI**: pesan "jual 2 kopi susu ke pak budi" → kartu usulan → Setujui.
4. **Laporan**: omzet bulan ini, grafik, metode bayar, ringkasan hari ini.

Opsional berikutnya (tambahkan di test bila perlu): Catatan transaksi, Bayar (tunai/kembalian),
Printer struk.

Aturan Play: tanpa bingkai HP palsu yang menyesatkan, tanpa teks "No.1/terbaik", tanpa harga
paket. Tulisan tambahan di atas screenshot (caption) boleh, tetapi jangan menutupi UI.
Grafik fitur tidak boleh memuat harga atau ajakan "unduh sekarang".
