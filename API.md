# Infois Mobile API — v1

Kontrak API antara aplikasi HP (Flutter, folder `android/`) dan `backoffice` (Laravel).
Semua endpoint ada di bawah **`/api/v1`**, berformat JSON, pesan galat dalam Bahasa Indonesia.

- Kode: `backoffice/routes/api.php`, `app/Http/Controllers/Api/V1/*`, `app/Services/Mobile/*`.
- Tes: `backoffice/tests/Feature/Mobile/*` (Tim AI: `MobileAiTest.php`); uji langsung dari sisi HP ke server sungguhan: `android/test_live/ai_live_test.dart` (lihat komentar di atas file untuk cara menjalankan).

## 1. Aturan umum

| Hal | Aturan |
|---|---|
| Autentikasi | Token Sanctum per **user + HP**: `Authorization: Bearer <token>`. Token terikat ke `device_uid` (ID pemasangan aplikasi). |
| Perusahaan | Dikirim per request: header **`X-Tenant: <id atau slug>`**. Wajib untuk semua endpoint bertanda 🏢. |
| Pengecekan 🏢 | user anggota perusahaan → langganan aktif (`hasActiveAccess()`) → HP belum dicabut → konteks tenant + team permission diaktifkan. |
| Header opsional | `X-App-Version: 1.0.0` dan `X-Platform: android` (dicatat di Tim & Akses › Perangkat; tanpa `X-Platform` web menampilkan "HP"), `X-Outbox-Count: 3` (jumlah transaksi tertunda di HP, tampil di web; HP memperbarui angka ini segera setelah outbox terkirim, sebelum request tarik data). |
| Hak akses | Sama persis dengan web (role & permission per perusahaan, termasuk role custom). Server selalu mengecek ulang. |
| Angka | Uang = string desimal 2 angka (`"52650.00"`), qty = 6 angka (`"1.500000"`). Kirim string, bukan float. |
| Waktu | ISO 8601. HP mengirim UTC (`…Z`); server mengonversi ke zona waktu aplikasi (WIB) sebelum menyimpan dan menjawab dengan offset (`+07:00`). `date` = `YYYY-MM-DD` (tanggal lokal HP). |

### Format galat

```json
{ "message": "Langganan perusahaan ini sedang tidak aktif. Kelola paket lewat website Infois.", "code": "langganan_tidak_aktif" }
```

| HTTP | `code` | Arti |
|---|---|---|
| 401 | `unauthenticated` | Token tidak ada/dicabut → login ulang. Pesan: "Sesi berakhir. Silakan masuk lagi." |
| 400 | `perusahaan_belum_dipilih` | Header `X-Tenant` kosong |
| 403 | `bukan_anggota` | User bukan anggota perusahaan itu |
| 403 | `langganan_tidak_aktif` | Langganan ditangguhkan/dibatalkan |
| 403 | `perangkat_dicabut` | HP dicabut aksesnya di web (Tim & Akses › Perangkat) |
| 403 | `perangkat_tidak_dikenal` | Token bukan token HP (tanpa `device_uid`) |
| 403 | `tidak_berhak` | Tidak punya permission untuk aksi itu |
| 422 | — | Validasi: `{ "message": "...", "errors": { "field": ["..."] } }` |
| 429 | — | Terlalu sering (login: 10/menit; API: 240/menit) |

## 2. Sistem

### `GET /ping`
Cek internet sungguhan (HP memakai batas waktu 5 detik) + versi minimum aplikasi. Tanpa token.

```json
{ "ok": true, "server_time": "2026-10-07T10:00:00+07:00", "min_app_version": "1.0.0", "latest_app_version": "1.0.0" }
```
Bila `AppConfig.version < min_app_version`, aplikasi menampilkan "Perbarui aplikasi". Diatur lewat env `INFOIS_MOBILE_MIN_VERSION` / `INFOIS_MOBILE_LATEST_VERSION`.

## 3. Akun

### `POST /auth/login`
```json
{ "email": "sari@warung.id", "password": "rahasia", "device_name": "HP Kasir Depan", "device_uid": "5b0e7c1a-…", "platform": "android", "app_version": "1.0.0" }
```
Login ulang dengan `device_uid` yang sama mengganti token lama HP itu. `device_name` menjadi nama HP di web (Tim & Akses › Perangkat) saat HP pertama kali tercatat di sebuah perusahaan; setelah itu nama diatur dari web. Jawaban = token + isi `GET /me`:
```json
{
  "token": "12|xYz…",
  "token_type": "Bearer",
  "user": { "id": 5, "name": "Sari", "email": "sari@warung.id", "avatar_url": null },
  "tenants": [ { "id": 1, "slug": "warung-bu-sri", "name": "Warung Bu Sri", "role": "cashier", "role_label": "Kasir", "active": true, "subscription_status": "active", "permissions": ["Create:Invoice", "issue-invoice", "record-payment", "…"], "menus": { "pos": true, "void_sale": false, "shift": true, "reports": false, "ai": true, "records": true, "stock": true, "cash_journal": false, "add_customer": true, "printer": true } } ],
  "default_tenant_id": 1
}
```
Galat: 422 `login_gagal` ("Email atau kata sandi salah."), 403 `tanpa_perusahaan`.

### `POST /auth/logout`
Mencabut token HP ini. `{ "ok": true }`

### `GET /me`
User, daftar perusahaan, role, permission, dan **menu** aplikasi per perusahaan (lihat contoh di atas).

Pemetaan menu (PLAN-MOBILE §7.1):

| Menu | Permission |
|---|---|
| `pos`, `shift` (Kasir, buka/tutup shift) | `issue-invoice` + `record-payment` + `Create:Invoice` |
| `void_sale` | `void-invoice` |
| `reports` | `view-reports` |
| `ai` (Tim AI) | `use-ai-assistant` |
| `stock` | `ViewAny:ProductService` atau `ViewAny:StockOpname` |
| `cash_journal` | `post-journal` |
| `records` (Catatan) | `ViewAny:Invoice` atau `stock` atau `cash_journal` |
| `add_customer` | `Create:Customer` |
| `printer` | `pos` atau `ai` |

## 4. Sinkron 🏢

### `GET /sync/pull?since=<cursor>`
Tanpa `since` = tarikan penuh. Dengan `since` = barang/pelanggan yang berubah sejak cursor (barang juga dianggap berubah bila satuan, harga grosir, komposisi, atau stok di gudang HP berubah). Daftar **`ids`** selalu lengkap → HP menghapus data yang sudah dihapus di server. Data nonaktif tetap dikirim (`is_active: false`). HP melakukan tarikan penuh minimal sekali sehari.

```json
{
  "cursor": "2026-10-07T10:00:00.123456+07:00",
  "full": false,
  "server_time": "2026-10-07T10:00:05+07:00",
  "tenant": { "id": 1, "name": "Warung Bu Sri", "prices_include_tax": false, "sales_tax_name": "PPN", "sales_tax_rate": "11.00", "auto_stock_adjustment": true, "payment_terms_days": 14 },
  "receipt": {
    "width": 58, "font_size": "normal", "show_logo": true, "show_address": true, "show_phone": true, "show_cashier": true,
    "show_customer": true, "show_tax": true, "show_payment": true, "show_qr": true,
    "header_text": null, "footer_text": "Terima kasih atas kunjungan Anda",
    "company": { "name": "Warung Bu Sri", "address": "Jl. Melati 5", "phone": "0812…", "website": null },
    "logo_url": "https://app.infois.id/api/v1/branding/logo", "logo_version": "3f2a9c1d0b7e",
    "verify_base_url": "https://app.infois.id/verify"
  },
  "device": { "id": 3, "code": "K1", "name": "HP Kasir Depan", "warehouse_id": 1, "revoked": false },
  "user": { "id": 5, "name": "Sari" },
  "permissions": ["…"],
  "menus": { "pos": true, "…": "…" },
  "products": {
    "items": [
      {
        "id": 10, "sku": "KOP-01", "name": "Kopi bubuk", "type": "product", "unit": "pcs", "price": "25000.00", "tax_rate": "11.00",
        "track_inventory": true, "stock_quantity": "12.000000", "minimum_stock": "5.000000", "has_composition": false, "is_active": true,
        "units": [ { "name": "karton", "factor": "24.000000", "price": "550000.00" } ],
        "tiers": [ { "unit": "pcs", "min_quantity": "10.000000", "price": "23000.00" } ],
        "updated_at": "2026-10-07T09:58:00+07:00"
      }
    ],
    "ids": [10, 11, 12]
  },
  "customers": { "items": [ { "id": 7, "name": "Bu Ani", "phone": "0812", "email": null, "address": null, "client_uuid": null, "is_walk_in": false } ], "ids": [7, 8] },
  "accounts": { "items": [ { "id": 21, "code": "1-1100", "name": "Kas", "kind": "cash" }, { "id": 22, "code": "1-1200", "name": "Bank", "kind": "bank" } ], "ids": [21, 22], "default_cash_id": 21, "default_transfer_id": 22 },
  "warehouses": { "items": [ { "id": 1, "code": "UTAMA", "name": "Gudang Utama", "is_default": true, "is_active": true } ], "ids": [1] },
  "number_blocks": [ { "id": 4, "format": "POS-K1/{SEQ:6}", "start": 1, "end": 500, "last_used": 37 } ],
  "open_shift": null
}
```
- `stock_quantity` = stok di gudang HP (diatur di web, default gudang utama); `null` untuk barang tanpa stok.
- `receipt.show_qr` sudah memperhitungkan modul Verify dan pengaturan branding. QR offline = `verify_base_url + "/" + client_uuid` (server memakai `client_uuid` sebagai UID verifikasi saat nota diterbitkan).
- `logo_url` diunduh dengan header yang sama (token + `X-Tenant`).

### `POST /sync/push`
Kirim isi outbox **berurutan**, maksimal **50** item. Setiap item punya `client_uuid` (UUID v4 dari HP) → idempoten.
Server memproses berurutan; gagal di satu item tidak menghentikan item lain. HP dengan akses dicabut masih boleh mengirim penjualan yang **dibuat sebelum** dicabut (`created_at` < waktu cabut).

```json
{ "items": [ { "type": "customer", "client_uuid": "…", "data": { … } }, { "type": "sale", "client_uuid": "…", "data": { … } } ] }
```

Jawaban:
```json
{ "results": [ { "client_uuid": "…", "type": "sale", "status": "ok", "invoice_id": 812, "number": "POS-K1/000038", "invoice_status": "paid", "total": "52650.00", "amount_paid": "52650.00", "verification_url": "https://app.infois.id/verify/0d4c…", "warnings": [] } ], "server_time": "…" }
```

| `status` | Arti | Tindakan HP |
|---|---|---|
| `ok` | Tercatat | Hapus dari antrean, simpan `number` final |
| `duplikat` | `client_uuid` sudah pernah diterima; tidak dicatat ulang (berisi data yang sudah ada; `needs_review: true` bila masih ditinjau) | Hapus dari antrean |
| `perlu_ditinjau` | Penjualan **diterima** (draft + masuk "Perlu Ditinjau" di web, pemilik diberi notifikasi) tetapi belum dibukukan: stok kurang tanpa stok otomatis, periode sudah tutup buku, total HP ≠ hitungan server, akun pembayaran tidak ada | Hapus dari antrean, tandai "Perlu ditinjau" |
| `ditolak` | Tidak dicatat: data tidak valid, tidak berhak, bon tanpa pelanggan, HP dicabut sebelum transaksi dibuat. `retry: true` = galat server sementara | Tampilkan pesan; `retry: true` → coba lagi nanti |

#### Item `sale` (penjualan kasir)
```json
{
  "client_uuid": "0d4c6a8e-…",
  "number": "POS-K1/000038", "number_seq": 38,
  "date": "2026-10-07", "created_at": "2026-10-07T03:12:44Z",
  "shift_client_uuid": "a1b2…",
  "customer_id": null, "customer_client_uuid": null,
  "notes": null,
  "total": "52650.00",
  "items": [
    { "product_id": 1, "description": "Kopi susu", "quantity": "2.000000", "unit": "gelas", "unit_price": "18000.00", "discount_percent": "0.00", "tax_rate": "0.00" },
    { "product_id": 2, "description": "Roti bakar", "quantity": "1.000000", "unit": "pcs", "unit_price": "15000.00", "discount_percent": "0.00", "tax_rate": "11.00" }
  ],
  "payments": [
    { "client_uuid": "9f1e…", "method": "cash", "amount": "52650.00", "account_id": 21, "tendered": "60000.00" }
  ]
}
```
- Tanpa pelanggan → "Pelanggan Umum". `customer_client_uuid` = pelanggan baru dari HP (item `customer` dikirim lebih dulu di antrean yang sama).
- **Bon**: `payments: []` (wajib pelanggan). **Campuran**: dua pembayaran `cash` + `transfer`. `method` hanya `cash` | `transfer` (tidak ada QRIS).
- `discount_percent` = diskon efektif per baris (diskon barang digabung diskon nota di HP, 2 desimal). `total` dipakai untuk cek paritas; beda → `perlu_ditinjau`.
- Harga di struk yang dipakai (harga server yang berubah saat offline tidak menimpa). Barang nonaktif/terhapus tetap diterima dengan `warnings`.
- Nomor: dipakai bila `number_seq` ada di jatah HP dan belum terpakai; bila tidak, server memberi nomor baru (+ `warnings`). `number_blocks[].last_used` di `sync/pull` adalah nomor terakhir yang sudah dipakai menurut server; HP memajukan penghitung lokalnya ke angka ini (pasang ulang aplikasi tidak mengulang nomor).
- `warnings` (array string, bisa kosong) ikut di jawaban `ok`: barang nonaktif/terhapus, nomor diganti server, tanggal HP di masa depan. HP menampilkannya sebagai catatan nota.
- Server: draft invoice (`source = pos`, `device_id`, `pos_shift_id`, `client_uuid`) → `InvoiceService::issue()` (stok, HPP, komposisi, stok otomatis, jurnal, verifikasi) → `recordPayment()` per pembayaran. Tidak ada baris buku besar yang ditulis langsung.
- Permission: `Create:Invoice` + `issue-invoice`; dengan pembayaran juga `record-payment`.

#### Item `customer`
```json
{ "client_uuid": "c7…", "name": "Pak Budi", "phone": "0812…", "email": null, "address": null }
```
→ `{ "status": "ok", "customer_id": 99 }`. Permission `Create:Customer`.

#### Item `shift_open` / `shift_close`
```json
{ "client_uuid": "a1b2…", "opened_at": "2026-10-07T01:00:00Z", "opening_cash": "100000" }
{ "shift_client_uuid": "a1b2…", "closed_at": "2026-10-07T10:00:00Z", "closing_cash": "119000" }
```
`shift_close` → `{ "status": "ok", "shift": { "id": 4, "expected_cash": "120000.00", "difference": "-1000.00", "summary": { "sales_count": 2, "sales_total": "40000.00", "cash_total": "20000.00", "transfer_total": "20000.00", "unpaid_total": "0.00", "opening_cash": "100000.00", "expected_cash": "120000.00" } } }`.
Uang seharusnya = uang awal + pembayaran tunai penjualan shift itu yang sudah sampai di server.

## 5. Kasir 🏢

### `POST /pos/number-blocks`
Jatah nomor nota offline untuk HP ini (permission `issue-invoice`). Body opsional `{ "size": 500 }` (maks. 2000; bawaan env `INFOIS_MOBILE_NUMBER_BLOCK`=500).
```json
{ "block": { "id": 5, "format": "POS-K1/{SEQ:6}", "start": 501, "end": 1000, "last_used": null } }
```
- `{DEVICE}` = kode kasir unik per perusahaan (K1, K2, …). Format diatur di web: Dokumen & Nota › Penomoran › "Nota kasir HP" (wajib `{DEVICE}` + `{SEQ}`; boleh `{YYYY} {YY} {MM} {DD}`, diisi HP dari tanggal penjualan). Bawaan `POS-{DEVICE}/{SEQ:6}`.
- Nomor urut per HP tidak pernah diulang; HP meminta jatah baru saat sisa < 100.

### `POST /pos/shifts`
Buka shift saat online (offline: item `shift_open` di outbox). Idempoten per `client_uuid`.
```json
{ "client_uuid": "a1b2…", "opening_cash": 100000, "opened_at": "2026-10-07T01:00:00Z" }
```
→ 201 `{ "shift": { "id": 4, "client_uuid": "a1b2…", "opened_at": "…", "closed_at": null, "opening_cash": "100000.00", … }, "status": "ok" }` (200 + `"duplikat"` bila sudah ada).

### `PATCH /pos/shifts/{id}/close`
```json
{ "closing_cash": 119000, "closed_at": "2026-10-07T10:00:00Z" }
```
→ `{ "shift": { …, "expected_cash": "120000.00", "difference": "-1000.00", "summary": { … } }, "status": "ok" }`. Shift harus milik HP ini.

### `GET /branding/logo`
File logo perusahaan (untuk dicetak hitam-putih di struk). 404 bila tidak ada.

## 6. Tim AI 🏢

Semua endpoint butuh permission `use-ai-assistant` (menu `ai` di `GET /me`); tanpa itu → 403 `tidak_berhak` ("Anda tidak punya akses Tim AI di {perusahaan}. Hubungi pemilik usaha."). Aturan sama dengan web: koin ditahan per proses (maks. 25 koin) lalu dipotong sesuai pemakaian, usulan dijalankan lewat `ProposalExecutor` dengan permission pengguna (kasir tidak bisa menyetujui yang tidak boleh ia lakukan di web). Pesan dari HP tercatat dengan `channel: "mobile"`. Pengguna hanya melihat percakapan miliknya sendiri.

| HTTP | `code` | Arti |
|---|---|---|
| 503 | `ai_tidak_tersedia` | AI dimatikan admin / belum dikonfigurasi. `GET /ai/overview` tetap 200 dengan `enabled: false` |
| 422 | `koin_habis` | Koin tidak cukup ("Koin tidak cukup (tersisa 0 koin). Isi ulang koin di menu Services › Dompet Koin.") → tawarkan buka web |
| 429 | `sedang_diproses` | Masih ada 3 permintaan AI aktif di perusahaan; coba lagi |
| 422 | `file_tidak_didukung` / `file_terlalu_besar` | Lampiran ditolak (pesan menyebut nama file) |
| 422 | `ditolak` | Usulan tidak bisa dicatat (aturan pembukuan / hak akses). Usulan **tetap menunggu**, `proposal.error` berisi alasannya |
| 409 | `sudah_diproses` | Usulan sudah disetujui/ditolak sebelumnya (`proposal` ikut dikirim) |
| 409 | `sedang_diproses` | Hapus percakapan saat ada proses aktif |
| 404 | `tidak_ditemukan` | Percakapan / proses / usulan / lampiran bukan milik pengguna ini |

### `GET /ai/overview`
```json
{
  "enabled": true,
  "fast_mode": false,
  "teams": [
    { "key": "sales", "name": "Tim Penjualan", "role": "Kasir, pesanan, pengiriman, dan data pelanggan", "tone": "sky", "icon": "shopping-bag", "example": "Kopi susu 3, roti bakar 2, bayar tunai", "locked": false, "unlock_plan": null },
    { "key": "analyst", "name": "Tim Analis", "role": "Laporan, …", "tone": "violet", "icon": "chart-bar", "example": "Berapa untung bulan ini dibanding bulan lalu?", "locked": true, "unlock_plan": "Growth" }
  ],
  "coins": { "used": "4.260", "available": "45.740", "percent": 9, "resets_at": "2026-04-01T00:00:00+07:00" },
  "suggestions": ["Kopi susu 3, roti bakar 2, bayar tunai", "Beli 2 karung gula 350rb dari Toko Makmur, bayar nanti"],
  "pending_proposals": 1,
  "limits": { "max_attachments": 5, "max_upload_kb": 10240, "max_text": 4000 }
}
```
- `teams` = tim yang bisa bekerja untuk pengguna ini (sesuai hak akses, sama dengan web). `tone` ∈ sky, amber, emerald, indigo, violet, rose, teal, orange; `icon` = nama Heroicon outline tanpa awalan. Tim `locked` (belum termasuk paket) tetap ditampilkan dengan gembok + `unlock_plan`.
- `coins`: koin string 3 desimal; `percent` = terpakai ÷ (terpakai + tersedia) untuk bilah pemakaian; `used` = pemakaian bulan ini.
- `suggestions` = contoh perintah tim yang terbuka (chip di layar awal).

### `PATCH /ai/settings`
`{ "fast_mode": true }` → `{ "fast_mode": true }`. Mode cepat: penjualan yang barangnya ada di Katalog dan harganya jelas langsung tercatat tanpa Setujui (sama dengan web).

### `GET /ai/conversations?cursor=`
Terbaru dulu, 20 per halaman (cursor pagination).
```json
{
  "data": [ { "id": 12, "title": "jual 2 kopi susu ke pak budi", "channel": "mobile", "preview": "Saya siapkan penjualan 2 kopi susu…", "pending_proposals": 1, "working": false, "last_message_at": "2026-03-10T09:00:05+07:00", "created_at": "…", "updated_at": "…" } ],
  "next_cursor": "eyJsYXN0X21lc3NhZ2VfYXQiOi…"
}
```
`preview` = pesan terakhir (maks. 120 huruf). `working: true` = masih ada proses aktif (tampilkan indikator). `next_cursor: null` = habis. Percakapan web & Telegram pengguna yang sama ikut tampil (`channel`: `web` | `telegram` | `mobile`).

### `POST /ai/conversations`
Membuat percakapan kosong (judul "Percakapan baru"; judul diganti dari pesan pertama). → 201 `{ "conversation": { …ringkasan seperti di daftar… } }`. Opsional: `POST /ai/messages` tanpa `conversation_id` juga membuat percakapan baru.

### `GET /ai/conversations/{id}?after=<message_id>`
Seluruh pesan (tanpa `after`) atau hanya pesan dengan id > `after` (untuk menambah pesan baru setelah polling).
```json
{
  "conversation": { "id": 12, "title": "…", "channel": "mobile", "preview": "…", "pending_proposals": 1, "working": false, "last_message_at": "…", "created_at": "…", "updated_at": "…" },
  "working": false,
  "active_run_id": null,
  "messages": [
    { "id": 40, "conversation_id": 12, "run_id": 7, "role": "user", "content": "jual 2 kopi susu ke pak budi", "failed": false, "coins": null, "teams": [], "run_status": "completed", "created_at": "…",
      "attachments": [ { "index": 0, "name": "nota.jpg", "mime": "image/jpeg", "size": 48213, "kind": "image", "seconds": null, "transcript": null, "url": "https://…/api/v1/ai/attachments/40/0" } ],
      "proposals": [] },
    { "id": 41, "conversation_id": 12, "run_id": 7, "role": "assistant", "content": "Saya siapkan penjualan…", "failed": false, "coins": "4.260",
      "teams": [ { "key": "sales", "name": "Tim Penjualan", "tone": "sky" } ], "run_status": "completed", "created_at": "…",
      "attachments": [], "proposals": [ { …lihat Usulan… } ] }
  ]
}
```
- `attachments[].kind`: `image` | `audio` (voice note, `seconds` + `transcript` hasil transkripsi) | `pdf` | `sheet` (xlsx/csv; file `text/plain` juga dianggap CSV) | `report` (file laporan buatan AI, mis. PDF/Excel laba rugi). `url` diunduh dengan header yang sama (token + `X-Tenant`); hanya pemilik percakapan (anggota lain 404). HP memakai bagian setelah `/api/v1/` dari `url` relatif terhadap server yang dipakainya, jadi `APP_URL` yang berbeda tidak masalah. Gambar/PDF/audio dikirim `inline`, lainnya `attachment`.
- `teams` = tim yang menjawab (untuk avatar & nama di bubble). `failed: true` = proses gagal, koin tidak terpakai.
- `content` pesan asisten = Markdown sederhana (**tebal**, _miring_, daftar `- `, judul `#`); render dengan `flutter_markdown` atau sejenisnya.
- `run_status`: `queued` | `running` | `completed` | `failed` (dari proses pesan itu; juga terisi pada `assistant_message` di `GET /ai/runs/{id}`).

### `DELETE /ai/conversations/{id}`
→ `{ "ok": true }` (pesan, proses, usulan, **dan file lampiran di disk** — foto nota, voice note, PDF/Excel, laporan — ikut terhapus; dokumen yang sudah tercatat tetap ada). 409 `sedang_diproses` bila ada proses aktif.

### `POST /ai/messages` (multipart/form-data)
| Field | Aturan |
|---|---|
| `conversation_id` | opsional; kosong = percakapan baru (judul dari teks / nama lampiran) |
| `text` | opsional, maks. 4000; **wajib bila tanpa lampiran** |
| `attachments[]` | opsional, maks. **5** file, masing-masing maks. `limits.max_upload_kb` (bawaan 10 MB → 422 `file_terlalu_besar`). Foto `jpg/png/webp`, voice note `m4a/aac/ogg/mp3/wav/webm`, `pdf`, `xlsx/csv`. Jenis dicek dari **isi** file; nama `.csv`/`.xlsx` hanya menolong bila isinya memang teks/arsip zip (file biner lain → 422 `file_tidak_didukung`). Semua file diperiksa dan koin dicek **sebelum** ada yang disimpan: permintaan yang ditolak tidak meninggalkan file. |
| `durations[i]` | opsional, detik (1–600) untuk lampiran ke-`i` yang berupa voice note. Hanya **petunjuk**: server menagih koin audio minimal `ceil(ukuran_file / 32000)` detik (±256 kbps), jadi durasi yang terlalu pendek tidak mengurangi tagihan; tanpa durasi dipakai perkiraan `ukuran / 16000`. |

→ 201
```json
{ "conversation_id": 12, "message_id": 40, "run_id": 7, "status": "queued" }
```
Proses berjalan di antrean server; HP **polling `GET /ai/runs/{run_id}` tiap ~2 detik** sampai `done: true`, lalu tambahkan `assistant_message` ke layar (atau tarik `GET /ai/conversations/{id}?after=<id pesan terakhir>`). Galat: 422 validasi (`errors.text`, `errors.attachments`), 422 `koin_habis`, 429 `sedang_diproses`, 503 `ai_tidak_tersedia`, 404 `tidak_ditemukan` (conversation_id bukan milik pengguna).

### `GET /ai/runs/{id}`
```json
{
  "id": 7, "conversation_id": 12, "status": "completed", "done": true, "error": null, "coins_charged": "4.260",
  "assistant_message": { …pesan asisten seperti di atas, proposals disematkan… },
  "proposals": [ { …Usulan… } ],
  "started_at": "…", "finished_at": "…"
}
```
`status`: `queued` → `running` → `completed` | `failed`. Saat `failed`, `error` berisi alasan teknis dan `assistant_message.content` berisi pesan ramah untuk pengguna (koin tidak dipotong). Proses yang menggantung > 10 menit otomatis gagal ("Koin Anda tidak terpakai. Silakan kirim ulang.").

### Usulan (`proposals[]`)
```json
{
  "id": 3, "conversation_id": 12, "run_id": 7, "type": "sale", "title": "Penjualan ke Pak Budi · Rp 30.000",
  "status": "pending", "status_label": "Menunggu persetujuan",
  "editable": true, "editable_fields": ["contact", "date", "items", "paid", "payment_method", "cash_account_id"],
  "payload": { "customer_id": 5, "customer_name": null, "date": "2026-03-10", "paid": false, "payment_method": null, "cash_account_id": null, "due_days": 14,
               "items": [ { "product_id": 10, "description": "Kopi susu", "quantity": "2.000000", "unit": "pcs", "unit_factor": "1.000000", "unit_price": "15000.00", "discount_percent": "0.00", "tax_rate": "0.00", "total": "30000.00" } ] },
  "preview": { "contact": "Pak Budi", "new_contact": false, "lines": [ { …sama dengan items… } ], "totals": { "subtotal": "30000.00", "tax_total": "0.00", "total": "30000.00" }, "payment": "Belum dibayar, ditagih ke pelanggan nanti", "warnings": [] },
  "error": null, "result_label": null, "result_url": null, "print_links": [],
  "decided_at": null, "created_at": "…"
}
```
- `status`: `pending` (Menunggu persetujuan) | `executed` (Tercatat) | `rejected` (Ditolak) | `failed` (Gagal). Setelah `executed`: `result_label` ("INV-0001 · Rp 30.000, lunas"), `result_url` (halaman web dokumen, bisa null), `print_links` `[ { "label": "Cetak invoice", "url": "…" }, { "label": "Cetak nota termal", "url": "…" } ]` untuk invoice yang sudah terbit.
- `type` dan isi `preview` yang perlu ditampilkan (sama dengan kartu di web):

| `type` | Tampilkan dari `preview` |
|---|---|
| `sale`, `sales_order`, `purchase` | `contact` (+ badge "baru" bila `new_contact`), `payload.date`, tabel `lines[]` (`description`, `quantity`, `unit`, `unit_price`, `total`, `account_label` untuk pembelian), `totals.tax_total`, `totals.total`, `payment` |
| `payment` | `document`, `contact`, `balance_before`, `amount`, `payment`, `currency` |
| `journal` (`payload.kind = cash` = uang masuk/keluar) | `journal[]` (`account`, `debit`, `credit`) — cukup judul + nominal untuk orang awam |
| `products` | `count`, `new` + `payload.items[]` (`name`, `type`, `unit`, `sale_price`, `cost_price`, `opening_stock`) |
| `delivery` | `order`, `contact`, `payload.lines[]` (`sales_order_item_id`, `description`, `remaining`, `unit`, `quantity`) |
| `production` | `materials[]` (`name`, `quantity`, `unit`, `stock`), `costs[]` |
| lainnya (`product_update`, `settings`, `void`, `collection`, `stock_opname`, …) | daftar `changes[]` |
| semua | `warnings[]` (kuning), `error` (merah, bila gagal dicatat) |

### `POST /ai/proposals/{id}/approve`
Body opsional `{ "edits": { … } }` — isian formulir yang diubah pengguna, hanya key di `editable_fields` (sama persis dengan formulir web; kosong = pakai usulan AI apa adanya):

| Jenis | `edits` |
|---|---|
| `sale`, `purchase` | `contact` (nama pelanggan/pemasok, teks), `date` (`YYYY-MM-DD`), `items[]` (`product_id`, `description`, `quantity`, `unit`, `unit_price`, `discount_percent`, `tax_rate`; pembelian: `account_id`), `paid` (`"1"`/`"0"`), `payment_method` (`cash` \| `qris` \| `transfer`; pembelian tanpa `qris`), `cash_account_id` (akun kas/bank dari `sync/pull.accounts`) |
| `sales_order` | `contact`, `date`, `delivery_date`, `items[]` |
| `payment` | `amount`, `cash_account_id`, `date` |
| `journal` (kas) | `amount`, `description`, `date`, `cash_account_id` |
| `products` | `items[]` (`name`, `type` `product`\|`service`, `unit`, `sku`, `sale_price`, `cost_price`, `opening_stock`, `units[]`, `recipe[]`, `tiers[]`) |
| `delivery` | `lines[]` (`sales_order_item_id`, `quantity`) |

→ 200 `{ "proposal": { …status executed… }, "message": "Tercatat: INV-0001 · Rp 30.000, lunas" }`.
Penjualan wajib memakai barang Katalog (`items[].product_id`); tanpa itu → 422 `ditolak` "… belum ada di Katalog Barang". 422 `ditolak` juga untuk hak akses ("Anda tidak punya hak menginput tagihan pemasok."), harga/nominal kosong, stok kurang, periode tutup buku — usulan tetap `pending` dengan `proposal.error` supaya pengguna memperbaiki lalu mencoba lagi. 409 `sudah_diproses` bila sudah diputuskan.

### `POST /ai/proposals/{id}/reject`
→ `{ "proposal": { …status rejected… }, "message": "Usulan ditolak" }`. Usulan `failed` juga boleh ditolak (= "Abaikan").

### `GET /ai/attachments/{message_id}/{index}`
File lampiran pesan (lihat `attachments[].url`). Header token + `X-Tenant`; 404 bila bukan pemilik percakapan. `Cache-Control: private, max-age=86400`.

## 7. Web terkait
- **Tim & Akses › Perangkat** (`/app/{tenant}/tim/perangkat`, permission `manage-members`): daftar HP, kode kasir, pengguna, gudang, terakhir sinkron, transaksi tertunda di HP, **Cabut akses / Izinkan lagi**, atur nama & gudang.
- **Tim & Akses › Perlu Ditinjau (Kasir HP)** (`/tim/perlu-ditinjau`, permission `issue-invoice`): penjualan `perlu_ditinjau` → **Proses ulang** (boleh ganti tanggal, mis. periode tutup buku) atau **Tandai selesai**.

## 8. Contoh cepat (curl)
```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/auth/login -H 'Accept: application/json' \
  -d email=owner@contoh.id -d password=rahasia -d device_name='HP Tes' -d device_uid=hp-tes-0001 | jq -r .token)
curl -s http://localhost:8000/api/v1/sync/pull -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.device, .products.ids'
curl -s -X POST http://localhost:8000/api/v1/pos/number-blocks -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json'
curl -s http://localhost:8000/api/v1/ai/overview -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.teams[].name, .coins'
RUN=$(curl -s -X POST http://localhost:8000/api/v1/ai/messages -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' \
  -F 'text=kopi susu 2 tunai' -F 'attachments[]=@nota.jpg' | jq -r .run_id)
curl -s http://localhost:8000/api/v1/ai/runs/$RUN -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.status, .proposals[].title'
```
