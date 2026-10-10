# Infois Mobile API — v1

Kontrak API antara aplikasi HP (Flutter, folder `android/`) dan `backoffice` (Laravel).
Semua endpoint ada di bawah **`/api/v1`**, berformat JSON, pesan galat dalam Bahasa Indonesia.

- Kode: `backoffice/routes/api.php`, `app/Http/Controllers/Api/V1/*`, `app/Services/Mobile/*`.
- Tes: `backoffice/tests/Feature/Mobile/*` (Tim AI: `MobileAiTest.php`, Laporan: `MobileReportsTest.php`, Catatan: `MobileRecordsTest.php`); uji langsung dari sisi HP ke server sungguhan: `android/test_live/ai_live_test.dart`, `android/test_live/records_live_test.dart` (lihat komentar di atas file untuk cara menjalankan).

## 1. Aturan umum

| Hal | Aturan |
|---|---|
| Autentikasi | Token Sanctum per **user + HP**: `Authorization: Bearer <token>`. Token terikat ke `device_uid` (ID pemasangan aplikasi). |
| Perusahaan | Dikirim per request: header **`X-Tenant: <id atau slug>`**. Wajib untuk semua endpoint bertanda 🏢. |
| Pengecekan 🏢 | user anggota perusahaan → perusahaan boleh memakai aplikasi HP (paket berbayar aktif yang termasuk aplikasi HP, lihat §3) → HP belum dicabut → konteks tenant + team permission diaktifkan. |
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
| 403 | `langganan_tidak_aktif` | Langganan ditangguhkan/dibatalkan (isi jawaban sama dengan `akses_hp_tidak_tersedia`, `reason: langganan_tidak_aktif`) |
| 403 | `akses_hp_tidak_tersedia` | Perusahaan tidak boleh memakai aplikasi HP: trial, tanpa paket, atau paketnya tidak termasuk aplikasi HP (lihat §3) |
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

### Siapa yang boleh memakai aplikasi HP ("tolak total")
Aplikasi HP — **termasuk Kasir** — hanya untuk perusahaan yang **langganannya aktif** (`active` atau `past_due`), **punya paket**, dan **paketnya termasuk kanal aplikasi HP** (`plans.ai_channels` null = semua kanal, atau berisi `mobile`). Selain itu perusahaan ditolak dengan alasan:

| `reason` | Arti |
|---|---|
| `trial` | Masih masa trial |
| `tanpa_paket` | Belum memilih paket berbayar (tanpa langganan / tanpa paket) |
| `paket_tanpa_hp` | Paketnya tidak termasuk aplikasi HP |
| `langganan_tidak_aktif` | Langganan ditangguhkan / dibatalkan / berakhir |

Isi galat penolakan (login, `GET /me`, dan semua endpoint 🏢):
```json
{
  "code": "akses_hp_tidak_tersedia",
  "message": "Aplikasi HP Infois hanya untuk perusahaan dengan paket berbayar yang aktif dan termasuk aplikasi HP. Warung Bu Sri masih masa trial; langganan Toko Lain sudah berakhir atau dihentikan. Aplikasi HP tersedia mulai paket Starter. Kelola paket lewat website: dashboard.infois.ai › Langganan.",
  "tenants": [
    { "id": 1, "slug": "warung-bu-sri", "name": "Warung Bu Sri", "reason": "trial", "unlock_plan": "Starter" },
    { "id": 2, "slug": "toko-lain", "name": "Toko Lain", "reason": "langganan_tidak_aktif", "unlock_plan": "Starter" }
  ]
}
```
- `slug` = slug website perusahaan: tombol "Lihat paket" membuka `{server}/app/{slug}/langganan` (halaman Langganan selalu per perusahaan; `/app/langganan` tidak ada). Tanpa slug aplikasi membuka `/app`.
- `unlock_plan` = paket aktif termurah yang termasuk aplikasi HP (null bila tidak ada). Host di `message` mengikuti `APP_URL` server.
- Endpoint 🏢: perusahaan yang ditolak → 403 `akses_hp_tidak_tersedia` (langganan berhenti tetap memakai kode `langganan_tidak_aktif`, isi sama). Berlaku juga untuk token lama bila perusahaan berhenti memenuhi syarat saat sedang dipakai.
- **Aplikasi**: kedua kode diperlakukan sama — lupakan perusahaan itu di HP, kembali ke Pilih perusahaan (atau ke layar Masuk dengan `message` bila tidak ada yang tersisa). Jangan berhenti di layar buntu.
- **Masa tenggang kirim transaksi**: `POST /sync/push` masih diterima **7 hari** sejak server pertama kali melihat perusahaan tidak memenuhi syarat, supaya penjualan offline yang belum terkirim tidak hilang. Semua endpoint lain langsung ditolak. Lewat 7 hari push juga ditolak (data tetap di HP; terkirim lagi setelah paket diaktifkan). Hitungan dimulai ulang bila perusahaan memenuhi syarat lagi. Masa tenggang hanya untuk perusahaan yang **pernah** memenuhi syarat (server pernah meloloskannya, atau pernah membayar langganan); perusahaan yang belum pernah boleh (mis. trial sejak awal) langsung ditolak, termasuk push.

### `POST /auth/login`
```json
{ "email": "sari@warung.id", "password": "rahasia", "device_name": "HP Kasir Depan", "device_uid": "5b0e7c1a-…", "platform": "android", "app_version": "1.0.0" }
```
Login ulang dengan `device_uid` yang sama mengganti token lama HP itu. `device_name` menjadi nama HP di web (Tim & Akses › Perangkat) saat HP pertama kali tercatat di sebuah perusahaan; setelah itu nama diatur dari web. Jawaban = token + isi `GET /me`; `tenants` **hanya** berisi perusahaan yang boleh memakai aplikasi HP (`mobile_eligible: true`), `default_tenant_id` dipilih dari daftar itu:
```json
{
  "token": "12|xYz…",
  "token_type": "Bearer",
  "user": { "id": 5, "name": "Sari", "email": "sari@warung.id", "avatar_url": null },
  "tenants": [ { "id": 1, "slug": "warung-bu-sri", "name": "Warung Bu Sri", "role": "cashier", "role_label": "Kasir", "active": true, "mobile_eligible": true, "subscription_status": "active", "permissions": ["Create:Invoice", "issue-invoice", "record-payment", "…"], "menus": { "pos": true, "void_sale": false, "shift": true, "reports": false, "ai": true, "ai_channel_locked": false, "records": true, "stock": true, "cash_journal": false, "add_customer": true, "printer": true } } ],
  "default_tenant_id": 1
}
```
Galat: 422 `login_gagal` ("Email atau kata sandi salah."), 403 `tanpa_perusahaan` (akun belum terdaftar di perusahaan mana pun), 403 `akses_hp_tidak_tersedia` (punya perusahaan tetapi tidak ada yang boleh memakai aplikasi HP; **tidak ada token yang dibuat**).

### `POST /auth/logout`
Mencabut token HP ini. `{ "ok": true }`

### `GET /me`
User, daftar perusahaan, role, permission, dan **menu** aplikasi per perusahaan (lihat contoh di atas). Penyaringan sama dengan login: perusahaan yang tidak boleh memakai aplikasi HP tidak dikirim; bila user punya perusahaan tetapi tidak ada satu pun yang boleh → 403 `akses_hp_tidak_tersedia` (token tetap berlaku; aplikasi kembali ke layar Masuk dengan pesannya). Karena semua perusahaan di daftar sudah termasuk aplikasi HP, `menus.ai_channel_locked` praktis selalu `false` (tetap dikirim untuk aplikasi lama).

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

### Tim AI di Telegram (catatan, bukan endpoint HP)
Akun Telegram dihubungkan ke satu perusahaan dengan dua cara: (1) di bot tekan **Bagikan nomor saya** — hanya nomor milik pengirim sendiri yang diterima, nomornya harus sama dengan **Nomor HP (untuk Telegram)** di profil web (`/app/profile`, kolom `users.phone`; awalan +62/62/0, spasi, dan tanda hubung disamakan); bila user punya beberapa perusahaan yang paketnya membuka Telegram dan ia punya akses Tim AI, bot menampilkan tombol pilih perusahaan; nomor yang dipakai lebih dari satu akun ditolak; (2) kode sekali pakai dari Tim AI web › Saluran Telegram › Hubungkan. Hak akses di Telegram = role user itu di perusahaan tersebut (sama dengan web). Aplikasi HP cukup mengarahkan pengguna ke cara ini bila ditanya; tidak ada endpoint API-nya.

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
        "track_inventory": true, "stock_quantity": "12.000000", "stock_source": "own", "minimum_stock": "5.000000", "has_composition": false, "is_active": true,
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
- `stock_source`: `"own"` = stok barang itu sendiri; `"recipe"` = produk resep tanpa stok sendiri (menu/paket, "Kelola stok" mati) — `stock_quantity` dihitung dari stok bahan di gudang HP (porsi yang bisa dibuat, dibulatkan ke bawah; `0` bila salah satu bahan habis) dan `track_inventory` dikirim `true` supaya lencana stok & redup "Habis" tampil; `null` = tidak dikelola stok. Saat dijual, server tetap mengurangi bahannya, bukan produk resepnya. Tarikan `since` ikut mengirim ulang produk resep yang stok/data salah satu bahannya berubah.
- Hanya barang dengan **Tampilkan di POS** aktif yang dikirim (`items` dan `ids`). Barang yang dimatikan (mis. bahan baku) tidak ada di `ids`, sehingga HP menghapusnya di tarikan berikutnya; bila dinyalakan lagi, barang terkirim lagi karena `updated_at`-nya berubah. Penjualan dari HP lama yang masih memuat barang itu tetap diterima.
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
  "notes": "Antar ke lantai 2",
  "order_type": "take_away", "order_label": "Meja 5",
  "total": "52650.00",
  "items": [
    { "product_id": 1, "description": "Kopi susu", "quantity": "2.000000", "unit": "gelas", "unit_price": "18000.00", "discount_percent": "0.00", "tax_rate": "0.00", "note": "tanpa gula" },
    { "product_id": 2, "description": "Roti bakar", "quantity": "1.000000", "unit": "pcs", "unit_price": "15000.00", "discount_percent": "0.00", "tax_rate": "11.00" }
  ],
  "payments": [
    { "client_uuid": "9f1e…", "method": "cash", "amount": "52650.00", "account_id": 21, "tendered": "60000.00" }
  ]
}
```
- Tanpa pelanggan → "Pelanggan Umum". `customer_client_uuid` = pelanggan baru dari HP (item `customer` dikirim lebih dulu di antrean yang sama).
- **Data pesanan** (opsional): `notes` = catatan pesanan (maks. 1000), `order_type` = `dine_in` | `take_away` | `delivery` (lainnya → `ditolak`), `order_label` = meja/antrian (maks. 40), `items[].note` = catatan barang (maks. 200). Disimpan di `invoices.order_type`, `invoices.order_label`, `invoice_items.note`; `invoices.notes` berisi ringkasan yang tampil di web/PDF dan di `records/sales/{id}(/receipt).notes`: `Pesanan: Bawa pulang · Meja 5` ⏎ `Catatan: Antar ke lantai 2` ⏎ `- Kopi susu: tanpa gula` (tanpa jenis/meja: hanya catatan apa adanya).
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
| 403 | `kanal_tidak_termasuk_paket` | Paket perusahaan belum membuka Tim AI lewat HP (trial selalu web saja; paket berbayar mengikuti pengaturan admin). `message` menyebut paket termurah yang membukanya. Berlaku untuk `POST /ai/messages`, `POST /ai/conversations`, dan `POST /ai/proposals/{id}/approve|reject` (Setujui/Tolak dari web tetap bisa); riwayat (`GET /ai/conversations`, `GET /ai/conversations/{id}`, `GET /ai/runs/{id}`, lampiran), hapus percakapan, dan `PATCH /ai/settings` tetap terbuka. `GET /ai/overview` tetap 200 dengan `enabled: false`, `reason` = kode ini, dan `channels.message` → tampilkan penjelasan, bukan chat |
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
  "reason": null,
  "channels": { "web": true, "telegram": true, "mobile": true, "unlock_plan": null, "message": null },
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
- `reason` (saat `enabled: false`): `ai_tidak_tersedia` | `kanal_tidak_termasuk_paket`. `channels` = kanal Tim AI yang dibuka paket (web selalu `true`); bila `mobile: false`, `unlock_plan` + `message` menjelaskan paket yang membukanya, mis. "Tim AI lewat aplikasi HP belum termasuk paket trial. Tersedia di paket berbayar mulai paket Starter. Sementara ini, Tim AI tetap bisa dipakai lewat web." `GET /me` juga mengirim `menus.ai_channel_locked` (menu `ai` tetap mengikuti hak akses).

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

## 7. Laporan 🏢

Semua endpoint butuh permission `view-reports` (menu `reports` di `GET /me`); tanpa itu → 403 `tidak_berhak` ("Anda tidak punya akses laporan di {perusahaan}. Hubungi pemilik usaha."). Kasir dari template "Kasir" **tidak** punya hak ini. Setiap angka dihitung oleh service laporan web (`SalesReportService`, `ReportService`, cache `ReportCache`), jadi **sama persis dengan laporan web untuk periode yang sama**: invoice terbit saja (draft & batal tidak dihitung), per tanggal invoice, Rupiah, HPP dari mutasi stok. Kode: `ReportController`, `app/Services/Mobile/MobileReportPeriod.php`, `MobileSalesReportService.php`, `MobileReportService.php`; tes `tests/Feature/Mobile/MobileReportsTest.php`.

**Periode** (query, semua laporan berperiode; default `bulan_ini`):

| `period` | Rentang |
|---|---|
| `hari_ini`, `kemarin` | satu hari |
| `minggu_ini` | Senin s.d. Minggu pekan ini |
| `bulan_ini` (default), `bulan_lalu` | bulan kalender penuh (sama dengan preset web) |
| `30_hari` | 30 hari terakhir termasuk hari ini |
| `custom` + `from`,`to` (`YYYY-MM-DD`) | maks. **366 hari** (termasuk kedua ujung); `from`+`to` tanpa `period` juga dianggap custom; `from` tanpa `to` (atau sebaliknya) → 422 `errors.to`/`errors.from` |

Jawaban selalu membawa `"period": { "preset": "bulan_ini", "from": "2026-10-01", "to": "2026-10-31", "days": 31, "label": "Bulan ini" }` (label custom: `"1 Okt 2026 – 9 Okt 2026"`).

**Filter opsional** (laporan penjualan): `warehouse_id`, `device_id` (HP kasir), `user_id` (pembuat nota/kasir). Dikembalikan apa adanya di `"filters": { "warehouse_id": null, "device_id": 2, "user_id": null }`. Id asing → angka nol, bukan galat.

**Daftar peringkat** (`by-product`, `by-customer`, `by-cashier`, `by-device`, `receivables`, `payables`): `limit` (default 20, maks. 100) + `cursor` (dari `next_cursor`; `null` = habis), plus `total_rows`/`totals.parties` = jumlah seluruh baris. Persen (`share`, `margin`, `gross_margin`) = string 1 desimal dengan titik, mis. `"42.5"` (web menampilkan koma).

| HTTP | `code` | Arti |
|---|---|---|
| 422 | — | Validasi (`errors.period`, `errors.from`, `errors.to`, `errors.limit`, `errors.as_of`, `errors.device_id`, …) |
| 422 | `periode_terlalu_panjang` | Rentang custom > 366 hari ("Rentang tanggal maksimal 366 hari. Persempit periodenya.") |
| 422 | `cursor_tidak_valid` | `cursor` rusak/diubah (juga `GET /reports/shifts`) → muat ulang dari awal |
| 404 | `tidak_ditemukan` | Shift bukan milik perusahaan ini |

### `GET /reports/overview`
Ubin beranda Laporan dalam satu panggilan (tanpa parameter).
```json
{
  "today":     { "date": "2026-10-09", "count": 63, "total": "8342382.50", "net": "7716950.00", "average": "132418.77", "gross_profit": "4674551.73", "margin": "60.5", "paid": "6639245.00", "outstanding": "1703137.50" },
  "yesterday": { "date": "2026-10-08", "count": 0, "total": "0.00", "net": "0.00", "average": "0.00", "gross_profit": "0.00", "margin": "0", "paid": "0.00", "outstanding": "0.00" },
  "month":     { "from": "2026-10-01", "to": "2026-10-31", "label": "Oktober 2026", "count": 84, "total": "142023242.50", "net": "…", "average": "…", "gross_profit": "…", "margin": "65.9", "paid": "…", "outstanding": "…" },
  "cash_balance": "1341050148.00",
  "receivables": { "outstanding_total": "62157067.50", "outstanding_count": 25, "overdue_total": "13677420.00", "overdue_count": 3 },
  "payables":    { "outstanding_total": "57526299.00", "outstanding_count": 9, "overdue_total": "3273150.00", "overdue_count": 1 },
  "stock": { "low_count": 5, "empty_count": 1 },
  "sparkline": [ { "date": "2026-09-26", "total": "0.00", "count": 0 }, "… 14 hari, terakhir = hari ini" ],
  "generated_at": "2026-10-09T15:02:11+07:00"
}
```
- `total` = omzet (total ditagih termasuk PPN), `net` = penjualan bersih (DPP), `average` = rata-rata per nota, `gross_profit` = laba kotor (net − HPP), `margin` = laba kotor ÷ net.
- `cash_balance` = saldo semua akun kas & bank dari buku besar per hari ini. `receivables`/`payables` = invoice/tagihan pemasok terbuka; `overdue_*` = lewat jatuh tempo. `stock.low_count` = barang stok > 0 tapi ≤ stok minimum (sama dengan widget web "Stok menipis"); `empty_count` = stok ≤ 0. `low_count + empty_count` = isi daftar `GET /records/stock?low=1` (ubin HP "Stok menipis/habis").
- Perusahaan baru/kosong menjawab 200 dengan angka nol.

### `GET /reports/sales/summary?period=&from=&to=&warehouse_id=&device_id=&user_id=`
```json
{
  "period": { "preset": "hari_ini", "from": "2026-10-09", "to": "2026-10-09", "days": 1, "label": "Hari ini" },
  "filters": { "warehouse_id": null, "device_id": null, "user_id": null },
  "totals": { "count": 63, "gross": "7811000.00", "discount": "94050.00", "net": "7716950.00", "tax": "625432.50", "total": "8342382.50", "paid": "6639245.00", "outstanding": "1703137.50", "cogs": "3042398.27", "gross_profit": "4674551.73", "margin": "60.5", "average": "132418.77", "customers": 8, "returns": "0.00", "unpaid_count": 9 },
  "series": { "unit": "hour", "points": [ { "key": "00", "label": "00:00", "count": 0, "net": "0.00", "total": "0.00" }, "… 24 jam" ] },
  "payments": [
    { "method": "cash", "label": "Tunai", "count": 50, "total": "5200145.00" },
    { "method": "transfer", "label": "Transfer bank", "count": 9, "total": "1439100.00" },
    { "method": "bon", "label": "Belum dibayar", "count": 9, "total": "1703137.50" }
  ]
}
```
- `totals` = `SalesReportService::summary` (`gross` sebelum diskon, `returns` = retur/nota kredit periode itu). `unpaid_count` = nota yang masih punya sisa.
- `series.unit` = `"hour"` (24 titik, `key` `"00"`–`"23"`) bila periodenya satu hari, selain itu `"day"` (satu titik per tanggal, `key` `YYYY-MM-DD`, `label` `"9 Okt"`); titik kosong tetap dikirim. Jam = waktu terbit di server (penjualan offline mengikuti jam sinkron).
- `payments` = uang yang diterima untuk nota periode ini per metode (`cash`, `transfer` selalu ada; `qris`, `giro`, `other` hanya bila terpakai), ditutup baris `bon` = sisa belum dibayar (`totals.outstanding`). `count` = jumlah **nota** yang dibayar (sebagian/penuh) dengan metode itu (satu nota bisa terhitung di dua metode); untuk `bon` = `unpaid_count`.

### `GET /reports/sales/by-product`, `/by-customer`, `/by-cashier`, `/by-device` (+ periode, filter, `limit`, `cursor`)
Peringkat berdasarkan penjualan bersih (`net`) terbesar. Bentuk umum:
```json
{ "period": {…}, "filters": {…}, "totals": { "count": 84, "net": "…", "tax": "…", "total": "…", "discount": "…", "cogs": "…", "gross_profit": "…", "margin": "65.9", … }, "total_rows": 21, "data": [ … ], "next_cursor": "eyJvZmZzZXQiOjIwfQ" }
```
`totals` per laporan: `by-customer`/`by-cashier`/`by-device` = kunci total web (`count`, `gross`, `discount`, `net`, `tax`, `total`, `paid`, `outstanding`, `cogs`, `gross_profit`, `margin`). `by-product` hanya `{ "net", "tax", "total", "discount", "cogs", "gross_profit", "margin" }` (`margin` = laba kotor ÷ net, ditambahkan API; web tidak menampilkannya di laporan per barang).
| Laporan | Baris `data[]` |
|---|---|
| `by-product` | `{ "id": 67, "name": "Kopi Susu Senja", "sku": "MNU-KSS", "type": "Barang", "unit": "gelas", "quantity": "900.000000", "lines": 15, "gross", "discount", "net", "tax", "total", "cogs", "average_price": "29000.00", "gross_profit", "share": "18.8" }` — `id` null & `type` "Tanpa katalog" untuk baris bebas; `quantity` dalam satuan dasar |
| `by-customer` | `{ "id": 17, "name": "Pelanggan Umum · Outlet Kemang", "count": 8, "gross", "discount", "net", "tax", "total", "paid", "outstanding", "cogs", "gross_profit", "margin": "69.7", "share": "43.1" }` — `outstanding` = piutang dari nota periode ini |
| `by-cashier` | sama dengan by-customer, `id` = user id pembuat nota, `name` = nama pengguna ("Tanpa pengguna" bila kosong) |
| `by-device` | sama + `code` (kode kasir, mis. `"K2"`); `name` = `"K2 · HP Rani"`; nota dari web dikumpulkan di satu baris `{ "id": null, "code": null, "name": "Web / tanpa HP" }` |

### `GET /reports/sales/by-hour` (+ periode, filter)
Selalu 24 baris urut jam 0–23 (bukan peringkat; `next_cursor` selalu `null`) untuk melihat jam ramai.
```json
{ "period": {…}, "filters": {…}, "totals": {…}, "peak_hour": 21, "data": [ { "hour": 0, "label": "00:00", "count": 0, "gross": "0.00", "discount": "0.00", "net": "0.00", "tax": "0.00", "total": "0.00", "paid": "0.00", "outstanding": "0.00", "cogs": "0.00", "gross_profit": "0.00", "margin": "0", "share": "0.0" }, "…" ], "next_cursor": null }
```
`peak_hour` = jam dengan `net` terbesar (`null` bila tidak ada penjualan).

### `GET /reports/receivables?as_of=&limit=&cursor=` dan `GET /reports/payables?…`
Umur piutang (invoice pelanggan) / hutang (tagihan pemasok) per tanggal `as_of` (default hari ini), dari `ReportService::receivablesAging` / `payablesAging`. Pihak diurutkan dari saldo terbesar.
```json
{
  "as_of": "2026-10-09",
  "buckets": [ { "key": "current", "label": "Belum jatuh tempo", "total": "48479647.50" }, { "key": "d1_30", "label": "1-30 hari", "total": "13677420.00" }, { "key": "d31_60", "label": "31-60 hari", "total": "0.00" }, { "key": "d61_90", "label": "61-90 hari", "total": "0.00" }, { "key": "over_90", "label": "> 90 hari", "total": "0.00" } ],
  "totals": { "current": "48479647.50", "d1_30": "13677420.00", "d31_60": "0.00", "d61_90": "0.00", "over_90": "0.00", "total": "62157067.50", "overdue": "13677420.00", "parties": 12 },
  "data": [ { "party_id": 23, "party": "Hotel Taman Cendana", "document_count": 6, "current": "11583597.50", "d1_30": "10347420.00", "d31_60": "0.00", "d61_90": "0.00", "over_90": "0.00", "total": "21931017.50", "overdue": "10347420.00" } ],
  "next_cursor": null
}
```
`overdue` = `total − current`. `party_id` = id pelanggan (receivables) / pemasok (payables).

### `GET /reports/profit-loss?period=…` dan `GET /reports/cash-flow?period=…`
Dari buku besar (`ReportService::profitAndLoss` / `cashFlow`), tanpa filter HP/kasir.
```json
{ "period": {…}, "revenue": "138765950.00", "cogs": "47258061.36", "gross_profit": "91507888.64", "gross_margin": "65.9", "operating_expense": "11356500.00", "operating_income": "80151388.64", "other_revenue": "0.00", "other_expense": "0.00", "total_revenue": "138765950.00", "total_expense": "58614561.36", "net_income": "80151388.64", "net_margin": "57.7",
  "sections": [ { "key": "operating_revenue", "label": "Pendapatan Usaha", "total": "138765950.00", "rows": [ { "code": "4-1000", "name": "Penjualan Menu Outlet", "amount": "109154200.00" } ] }, { "key": "cogs", … }, { "key": "operating_expense", … }, { "key": "other_revenue", … }, { "key": "other_expense", … } ] }
```
```json
{ "period": {…}, "opening": "1268150609.00", "net_change": "72899539.00", "closing": "1341050148.00",
  "categories": [ { "key": "operating", "label": "Aktivitas Operasi", "total": "72899539.00", "rows": [ { "code": "1-1300", "name": "Piutang Usaha", "amount": "135134185.00" } ] }, { "key": "investing", "label": "Aktivitas Investasi", "total": "0.00", "rows": [] }, { "key": "financing", "label": "Aktivitas Pendanaan", "total": "0.00", "rows": [] } ] }
```
Arus kas: `amount` negatif = kas keluar; `opening`/`closing` = saldo kas & bank awal/akhir periode.

### `GET /reports/shifts?period=&from=&to=&device_id=&user_id=&limit=&cursor=`
Shift kasir yang **sudah ditutup**, terbaru dulu (cursor pagination seperti `/ai/conversations`). Tanpa `period` = semua; dengan `period` = disaring per tanggal tutup. `"period"` di jawaban `null` bila tidak disaring.
```json
{ "period": null, "data": [ {
  "id": 13, "client_uuid": "ef9c0bca-…", "opened_at": "2026-10-09T14:55:38+07:00", "closed_at": "2026-10-09T18:30:00+07:00", "status": "closed",
  "opening_cash": "100000.00", "closing_cash": "300000.00", "expected_cash": "440975.00", "difference": "-140975.00",
  "summary": { "sales_count": 6, "sales_total": "456975.00", "cash_total": "340975.00", "transfer_total": "50000.00", "unpaid_total": "66000.00", "opening_cash": "100000.00", "expected_cash": "440975.00" },
  "device": { "id": 21, "code": "K21", "name": "HP Rani" }, "cashier": { "id": 13, "name": "Rani Kusumawardani" },
  "duration_minutes": 214, "sales_count": 6, "sales_total": "456975.00", "cash_total": "340975.00", "transfer_total": "50000.00", "notes": null
} ], "next_cursor": null }
```
`summary` (dan `expected_cash`/`difference`) = yang dihitung saat shift ditutup. `difference` = uang fisik − seharusnya (negatif = kurang).

### `GET /reports/shifts/{id}`
Rincian satu shift (boleh yang masih buka, `status: "open"`), untuk layar laporan shift / cetak ulang Z-report.
```json
{ "shift": { "…sama dengan baris daftar…" },
  "summary": { "sales_count": 6, "sales_total": "456975.00", "cash_total": "340975.00", "transfer_total": "50000.00", "unpaid_total": "66000.00", "opening_cash": "100000.00", "expected_cash": "440975.00" },
  "sales": [ { "id": 1356, "number": "POS-K21/000001", "time": "2026-10-09T14:55:39+07:00", "customer": "Pelanggan Umum", "total": "74000.00", "paid": "74000.00", "balance": "0.00", "status": "paid", "status_label": "Lunas", "methods": ["cash"] } ] }
```
`summary` di sini **dihitung ulang** dari penjualan yang sudah sampai di server (penjualan yang disinkron setelah shift ditutup ikut terhitung; bandingkan dengan `shift.summary`). `sales` maks. 500 nota, urut nomor; `status` ∈ `draft` (perlu ditinjau), `issued`, `partially_paid`, `paid`, `void`; `methods` = metode bayar yang dipakai.

## 8. Catatan 🏢

Baca dokumen perusahaan dari HP (PLAN-MOBILE §4.2 & §5.4). Kode: `app/Http/Controllers/Api/V1/Records/*`, `app/Http/Resources/Api/V1/Records/*`, `app/Services/Mobile/CashJournalService.php`, `app/Services/Mobile/RecordAttachments.php`; tes: `tests/Feature/Mobile/MobileRecordsTest.php`; uji langsung: `android/test_live/records_live_test.dart`.

**Aturan umum**

| Hal | Aturan |
|---|---|
| Hak akses | Sama dengan policy web per resource (tabel di bawah). Tidak berhak → 403 `tidak_berhak` ("Anda tidak punya akses catatan pembelian di {perusahaan}. Hubungi pemilik usaha."). Menu `records` di `GET /me` = `ViewAny:Invoice` **atau** stok **atau** `post-journal`; server tetap mengecek per bagian. |
| Isolasi | Hanya dokumen perusahaan `X-Tenant`. Id milik perusahaan lain → 404 `tidak_ditemukan` (bukan 403), termasuk lampiran, struk, PDF, dan void. |
| Daftar | `data[]` terbaru dulu (tanggal turun, lalu id turun) + `next_cursor` (string buram; `null` di halaman terakhir). Parameter umum: `cursor`, `limit` (1–50, default 25), `q` (cari, maks. 100 huruf, tidak peka kapital; `%`, `_`, `\` dicari apa adanya, bukan wildcard; bukan UTF-8 → 422 `errors.q`), `from` / `to` (`YYYY-MM-DD`, inklusif, `to ≥ from`). Salah isi → 422 validasi. `cursor` rusak/diubah → 422 `cursor_tidak_valid` ("Halaman tidak dikenali. Muat ulang daftar dari awal.") di semua daftar. |
| Rincian | Objek penuh di satu kunci (`sale`, `purchase`, `payment`, `customer`, `supplier`). |
| Angka | Uang `"12345.00"`, qty `"1.500000"`, tanggal `YYYY-MM-DD`, waktu ISO 8601 `+07:00`. |
| Lampiran | `attachments[]` = `{index, name, kind: image|pdf|file, url}`; `url` = `GET /records/attachments/{type}/{id}/{index}` (token + `X-Tenant`). |

| Bagian | Permission (sama dengan web) | Kasir bawaan | Viewer |
|---|---|---|---|
| `sales/*`, `payments` (masuk) | `ViewAny:Invoice` / `View:Invoice` | ✅ | 👁 |
| `sales/{id}/void` | `void-invoice` + aturan web (`menus.void_sale`) | — | — |
| `purchases/*`, `payments` (keluar) | `ViewAny:Bill` / `View:Bill` | — | 👁 |
| `cash` | `ViewAny:JournalEntry` **dan** (`view-reports` atau `post-journal`) | — | 👁 |
| `cash/accounts` | `ViewAny:Account` **dan** (`view-reports` atau `post-journal`) | — | 👁 |
| `stock`, `stock-movements` | `ViewAny:ProductService` | ✅ | 👁 |
| `customers/*` | `ViewAny:Customer` / `View:Customer` | ✅ | 👁 |
| `suppliers/*` | `ViewAny:Supplier` / `View:Supplier` | — | 👁 |

Saldo kas & bank (saldo awal/akhir, saldo berjalan, saldo akun) di web hanya terlihat dengan `view-reports` (Buku Besar, "Kas & bank saat ini"); di HP juga boleh dengan `post-journal` (menu `cash_journal`, PLAN-MOBILE §7.1 "Uang masuk/keluar"). Kasir dan admin gudang bawaan mendapat 403 walau boleh membuka jurnal/akun di web.

### `GET /records/sales`
Filter: `status` = `draft|issued|partially_paid|paid|void|outstanding` (`outstanding` = terbit atau dibayar sebagian), `source` = `web|pos|ai|telegram` (`web` juga mencakup data lama tanpa sumber), `customer_id`, `shift_id` (id shift kasir), `mine=1` (dibuat/diterbitkan pengguna ini), `q` (nomor nota, nama pelanggan, atau `client_uuid` utuh), `from`/`to` (tanggal nota).
```json
{
  "data": [{
    "id": 1365, "number": "POS-K22/000002", "client_uuid": "15eafd03-…", "date": "2026-10-09", "due_date": "2026-10-09",
    "status": "paid", "status_label": "Lunas", "source": "pos",
    "customer": { "id": 29, "name": "Pelanggan Umum", "phone": null },
    "currency": "IDR", "total": "26000.00", "amount_paid": "26000.00", "balance_due": "0.00", "items_count": 1,
    "cashier": "Rani Kusumawardani", "device": { "id": 22, "code": "K22", "name": "HP Kasir 1" }, "pos_shift_id": 4,
    "has_attachments": false, "issued_at": "2026-10-09T14:57:18+07:00", "created_at": "…", "updated_at": "…"
  }],
  "next_cursor": "eyJpc3N1ZV9kYXRlIjoi…"
}
```
`number` draft = `DRAFT-{id}`. `customer` `null` hanya untuk draft tanpa pelanggan; `cashier`/`device` `null` untuk invoice web tanpa HP. `status_label` = Draft · Terbit · Dibayar Sebagian · Lunas · Dibatalkan.

### `GET /records/sales/{id}`
`{ "sale": { …ringkasan di atas…, "is_opening", "prices_include_tax", "tax_name", "subtotal", "discount_total", "tax_total", "notes", "terms", "warehouse": {id, code, name}|null, "items": [...], "payments": [...], "credit_notes": [...], "verification": {...}|null, "void_reason", "voided_at", "attachments": [...], "links": {...}, "can": {...} } }`

- `items[]`: `{id, product_id, sku, description, quantity, unit, unit_price, discount_percent, tax_rate, discount_amount, net_amount, tax_amount, line_total}`
- `payments[]`: objek pembayaran (lihat `GET /records/payments`, selalu `kind: "in"`).
- `credit_notes[]` (retur yang dibuat di web): `{id, number, date, reason, restock, total}`
- `verification`: `{ "url": "https://infois.ai/verify/{uid}", "status": "valid|void" }` — tautan publik cek keaslian untuk tombol **Bagikan / Kirim WhatsApp**; `null` untuk draft atau bila verifikasi tidak ada.
- `links`: `{ "receipt": ".../records/sales/{id}/receipt", "pdf": ".../records/sales/{id}/pdf" }`
- `can`: `{ "void": bool, "return": false }` — `void` mengikuti `InvoicePolicy::void` web (hak `void-invoice`, status terbit/sebagian/lunas, **belum ada pembayaran**). `return` selalu `false` (lihat di bawah).

### `POST /records/sales/{id}/void`
Body `{ "reason": "Salah input" }` (wajib, maks. 200 huruf — sama dengan web). Memakai `InvoiceService::void` yang sama dengan web: jurnal dibalik, stok kembali, verifikasi publik ditandai batal. Jawab `200 { "sale": {…rincian…}, "message": "Penjualan dibatalkan" }`.

| HTTP | `code` | Arti |
|---|---|---|
| 403 | `tidak_berhak` | Tidak punya `void-invoice` (`menus.void_sale` = false) |
| 422 | `tidak_bisa_dibatalkan` | Status bukan terbit/sebagian/lunas (draft atau sudah dibatalkan) |
| 422 | `sudah_dibayar` | Sudah ada pembayaran → "Penjualan ini sudah menerima pembayaran. Batalkan pembayarannya lewat website terlebih dahulu." (aturan web yang sama) |
| 422 | `ditolak` | Ditolak pembukuan (mis. periode sudah ditutup); `message` dari service |
| 422 | — | `reason` kosong → validasi |

**Retur (`POST …/return`) tidak tersedia di HP**: nota kredit butuh pilih baris, qty, dan opsi stok kembali — dibuat lewat website (`CreditNoteService`). Aplikasi menampilkan "Retur dilakukan lewat website".

### `GET /records/sales/{id}/receipt`
Data struk untuk cetak ulang ESC/POS; `sale` berbentuk **sama dengan penjualan lokal HP** (`PosService` → `ReceiptBuilder.sale`), angka apa adanya dari server; pengaturan struk tetap dari `sync/pull.receipt`.
```json
{
  "sale": {
    "id": 1365, "client_uuid": "…", "number": "POS-K22/000002", "status": "paid", "source": "pos",
    "date": "2026-10-09", "created_at": "2026-10-09T14:57:18+07:00", "customer_id": 29, "customer_name": "Pelanggan Umum", "notes": null,
    "items": [{ "product_id": 68, "description": "Americano", "quantity": "1.000000", "unit": "gelas", "unit_price": "26000.00", "discount_percent": "0.00", "tax_rate": "0.00", "discount_amount": "0.00", "line_total": "26000.00" }],
    "payments": [{ "client_uuid": "…", "method": "cash", "amount": "26000.00", "tendered": null, "account_id": 127, "date": "2026-10-09" }],
    "subtotal": "26000.00", "discount_total": "0.00", "tax_total": "0.00", "total": "26000.00", "paid": "26000.00", "change": "0.00",
    "cashier": "Rani Kusumawardani", "tax_name": "PPN", "prices_include_tax": false, "verification_url": "https://infois.ai/verify/…"
  },
  "reprint": true
}
```
`tendered`/`change` tidak tersimpan di server (selalu `null`/`"0.00"`); `verification_url` `null` bila draft/tidak ada verifikasi. HP mencetak dengan label `-- CETAK ULANG --`.

### `GET /records/sales/{id}/pdf`
Byte PDF A4 (`Content-Type: application/pdf`, `Content-Disposition: attachment; filename="pos-k22000002.pdf"`), sama dengan tombol unduh di web (PDF tersimpan bila ada, kalau tidak dirender ulang). Untuk dibagikan ke WhatsApp/AirPrint.

### `GET /records/payments`
Gabungan **uang masuk** (pembayaran invoice, butuh `ViewAny:Invoice`) dan **uang keluar** (pembayaran tagihan, butuh `ViewAny:Bill`); jenis yang tidak berhak otomatis tidak ikut, bila tidak berhak keduanya → 403. Filter: `kind` = `in|out` (meminta jenis yang tidak berhak → 403), `method`, `account_id`, `document_id` (id invoice/tagihan, pakai bersama `kind`), `q` (referensi, nomor dokumen, nama pelanggan/pemasok), `from`/`to`. Urutan: tanggal turun → masuk sebelum keluar → id turun; `next_cursor` khusus endpoint ini (jangan dirakit sendiri).
```json
{ "data": [{
  "id": 2235, "kind": "in", "date": "2026-10-09", "amount": "26000.00", "base_amount": "26000.00", "currency": "IDR",
  "method": "cash", "method_label": "Tunai", "via": "payment", "reference": "Kasir HP K22",
  "account": { "id": 127, "code": "1-1100", "name": "Kas Outlet" },
  "document": { "type": "sale", "id": 1365, "number": "POS-K22/000002", "status": "paid" },
  "party": { "type": "customer", "id": 29, "name": "Pelanggan Umum" },
  "withholding_amount": "0.00", "has_attachments": false, "created_at": "…"
}], "next_cursor": null }
```
`via` = `payment` (uang sungguhan) · `deposit` (pakai uang muka) · `credit_note` / `debit_note` (pelunasan lewat nota kredit/debit). `method_label`: Tunai · Transfer bank · Giro/Cek · QRIS · Kartu · Lainnya (atau Uang muka / Nota kredit / Nota debit (retur) sesuai `via`). `document.type` = `sale|purchase`; `party.type` = `customer|supplier`.

### `GET /records/payments/{kind}/{id}`
`kind` = `in|out`. Hak = `View` dokumen induknya. `{ "payment": { …di atas…, "exchange_rate": "1.000000", "withholding_type", "journal": {id, number}|null, "deposit": {id, number}|null, "client_uuid" (hanya masuk), "attachments": [...] } }`

### `GET /records/purchases`
Filter: `status` = `draft|open|partially_paid|paid|void|outstanding`, `supplier_id`, `q` (nomor, nomor nota pemasok, nama pemasok), `from`/`to` (tanggal tagihan).
```json
{ "data": [{
  "id": 536, "number": "BILL/2026/10/0007", "supplier_reference": "SR-071026-0388", "date": "2026-10-07", "due_date": "2026-10-07",
  "status": "paid", "status_label": "Lunas", "supplier": { "id": 35, "name": "Toko Sumber Rejeki", "phone": "021-718-0455" },
  "currency": "IDR", "total": "299500.00", "amount_paid": "299500.00", "balance_due": "0.00", "overdue_days": 0, "items_count": 3,
  "has_attachments": false, "posted_at": "…", "created_at": "…", "updated_at": "…"
}], "next_cursor": null }
```
`status_label` = Draft · Belum Dibayar · Dibayar Sebagian · Lunas · Dibatalkan. `overdue_days` > 0 hanya untuk tagihan belum lunas yang lewat jatuh tempo.

### `GET /records/purchases/{id}`
`{ "purchase": { …ringkasan…, "is_opening", "subtotal", "tax_total", "notes", "warehouse", "items": [{id, product_id, sku, account: {id, code, name}|null, description, quantity, unit, unit_price, tax_rate, net_amount, tax_amount, line_total}], "payments": [...kind "out"...], "debit_notes": [{id, number, date, reason, total}], "void_reason", "voided_at", "attachments": [...] } }` — baca saja.

### `GET /records/cash`
Buku kas & bank: baris jurnal pada akun kas/bank dengan saldo berjalan per akun (saldo awal & arah saldo = Buku Besar web, `LedgerBalanceService`). Parameter: `from`/`to` (default 30 hari terakhir; lebih dari 366 hari termasuk kedua ujung → 422 `rentang_terlalu_panjang`; `from` setelah `to`/hari ini → 422 `errors.from`), `account_id` (satu akun; tidak ada → 404), `direction` = `in|out`, `q` (nomor jurnal, referensi, keterangan, lawan akun), `limit`, `cursor` (posisi di dalam periode — ganti periode/filter = mulai dari awal).
```json
{
  "data": [{
    "id": 16399, "entry_id": 5379, "date": "2026-10-09", "number": "JU/2026/03317", "reference": "Kasir HP K22",
    "description": "Terima pembayaran POS-K22/000002", "direction": "in", "amount": "26000.00",
    "account": { "id": 127, "code": "1-1100", "name": "Kas Outlet" }, "counterpart": "Piutang Usaha",
    "source": { "type": "payment_in", "label": "Pembayaran penjualan", "id": 2235 }, "balance": "26430645.00"
  }],
  "next_cursor": null,
  "period": { "from": "2026-09-10", "to": "2026-10-09" },
  "accounts": [{ "id": 127, "code": "1-1100", "name": "Kas Outlet", "kind": "cash", "opening": "26404645.00", "closing": "26430645.00" }],
  "totals": { "in": "26000.00", "out": "0.00", "opening": "…", "closing": "…" }
}
```
`source.type` = `sale` · `payment_in` · `purchase` · `payment_out` · `deposit` · `credit_note` · `debit_note` · `opname` · `revaluation` · `manual` · `other`; `source.id` = id dokumen (buka lewat `records/sales/{id}`, `records/payments/in/{id}`, dst.). `balance` = saldo akun itu **setelah** baris ini; `counterpart` = nama lawan akun di jurnal yang sama.

### `GET /records/cash/accounts`
`{ "as_of": "2026-10-09", "accounts": [{ "id", "code", "name", "kind": "cash|bank", "balance": "26430645.00" }], "total": "…" }` — saldo hari ini semua akun kas/bank aktif.

### `GET /records/stock-movements`
Kartu stok. Filter: `product_id`, `warehouse_id`, `type` (satu atau beberapa dipisah koma: `purchase, purchase_void, sale, sale_void, adjustment, sale_return, purchase_return, transfer_out, transfer_in, production_out, production_in`; tidak dikenal → 422), `q` (nama/SKU barang, keterangan), `from`/`to`.
```json
{ "data": [{
  "id": 16958, "date": "2026-10-09", "type": "sale", "type_label": "Penjualan", "direction": "out", "quantity": "-1.000000", "unit": "pcs",
  "product": { "id": 58, "sku": "KMS-C16", "name": "Cup Plastik 16 oz + Tutup" }, "warehouse": { "id": 6, "code": "GR", "name": "Gudang Roastery" },
  "unit_cost": "1169.94", "total_cost": "1169.94", "balance_quantity": "1790.000000", "warehouse_balance_quantity": "1653.000000", "average_cost": "1169.94",
  "reference": { "type": "sale", "id": 1365, "number": "POS-K22/000002" }, "description": "Penjualan POS-K22/000002", "created_at": "…"
}], "next_cursor": "…" }
```
`quantity` bertanda (+ masuk, − keluar); `total_cost` selalu positif. `type_label` = Pembelian · Batal pembelian · Penjualan · Batal penjualan · Stok opname · Retur penjualan · Retur pembelian · Transfer keluar/masuk · Bahan produksi · Hasil produksi. `reference.type` = `sale|purchase|opname|transfer|production|credit_note|debit_note|other`, `null` bila tanpa dokumen.

### `GET /records/stock`
Stok saat ini barang yang dilacak stoknya (aktif saja kecuali `include_inactive=1`), urut nama (`sort=quantity` → paling sedikit dulu). Filter: `q` (nama/SKU), `low=1` (menipis **atau habis**: ≤ stok minimum, atau stok ≤ 0 walau tanpa minimum — sama dengan `low_count + empty_count` di `GET /reports/overview`), `warehouse_id` (punya stok > 0 di gudang itu).
```json
{ "data": [{
  "id": 64, "sku": "RST-GAYO", "name": "Arabika Gayo Single Origin", "unit": "kg", "quantity": "1.175000", "minimum_stock": "3.000000",
  "low": true, "empty": false, "average_cost": "170372.30", "stock_value": "200187.45", "price": "330000.00",
  "warehouses": [{ "id": 7, "code": "KMG", "name": "Outlet Kemang", "quantity": "0.325000" }], "updated_at": "…"
}], "next_cursor": null, "low_count": 3 }
```
`low_count` = jumlah barang menipis/habis (definisi `low=1`, tanpa filter lain), untuk badge. Tanda per baris: `low` = ≤ stok minimum, `empty` = stok ≤ 0.

### `GET /records/customers`
Urut nama. Filter: `q` (nama, telepon, email, kontak), `has_receivable=1`, `overdue=1`, `to_collect=1` (sama dengan filter "Perlu ditagih" web: belum lunas & jatuh tempo lewat/dekat sesuai Otomatisasi › Penagihan).
```json
{ "data": [{
  "id": 30, "client_uuid": "…", "name": "Bu Verif Tester", "contact_person": null, "phone": "0812…", "email": null, "address": null, "npwp": null, "currency": "IDR",
  "invoices_count": 3, "outstanding_count": 3, "overdue_count": 0, "receivable": "1150900.00", "needs_collection": false, "created_at": "…", "updated_at": "…"
}], "next_cursor": null }
```
`receivable` = sisa piutang Rupiah (sama dengan kolom Piutang web); `invoices_count` tidak menghitung draft/batal. Tambah pelanggan tetap lewat `POST /sync/push` item `customer`.

### `GET /records/customers/{id}`
`{ "customer": { …di atas…, "notes", "outstanding_invoices": [...ringkasan penjualan, jatuh tempo terdekat dulu...], "last_payment": {…objek pembayaran…}|null, "deposits_available": "0.00" } }` — tombol **Kirim tagihan** memakai `outstanding_invoices[].id` → `records/sales/{id}` → `verification.url`.

### `GET /records/suppliers` · `GET /records/suppliers/{id}`
Sama dengan pelanggan untuk hutang: `bills_count`, `outstanding_count`, `overdue_count`, `payable`, `bank_info`; filter `q`, `has_payable=1`, `overdue=1`. Rincian: `outstanding_bills[]` (ringkasan pembelian), `last_payment`, `deposits_available`, `notes`.

### `GET /records/attachments/{type}/{id}/{index}`
File lampiran (inline, `Cache-Control: private, max-age=86400`). `type` = `invoice|bill|invoice-payment|bill-payment|journal|deposit|credit-note|debit-note|stock-opname|stock-transfer|sales-order|purchase-order|bank-reconciliation|fixed-asset` (sama dengan web). Hak = `View` dokumen induk (pembayaran mengikuti invoice/tagihannya); tidak berhak → 403 `tidak_berhak`; dokumen perusahaan lain / indeks salah / jenis tidak dikenal → 404 `tidak_ditemukan`.

### Aplikasi HP: tab Laporan & Catatan (implementasi klien)
Kode: `lib/data/reports_api.dart`, `lib/data/records_api.dart`, model `lib/domain/report_models.dart` / `record_models.dart` (parsing toleran: kunci yang hilang = nol/null), state `lib/state/reports_state.dart` / `records_state.dart`, layar `lib/ui/screens/laporan_screen.dart`, `report_screens.dart`, `catatan_screen.dart`, `record_detail_screens.dart`; tes `test/reports_flow_test.dart`, `test/records_flow_test.dart`, uji langsung `test_live/reports_records_live_test.dart`.

| Hal | Perilaku HP |
|---|---|
| Pemanggilan | Tab Laporan/Catatan baru memanggil server saat pertama dibuka (`LazyTab`, berkunci per bagian); tiap bagian Catatan juga malas. Tarik ke bawah = muat ulang (juga di daftar kosong/pendek); gulir ke bawah = `cursor` berikutnya. Daftar dibangun malas (hanya baris yang terlihat). Halaman lanjutan yang gagal menampilkan "Gagal memuat lanjutan · Coba lagi" di kaki daftar (tidak diulang otomatis saat menggulir); halaman lanjutan dari muatan lama (periode/filter sudah diganti atau ditarik ulang) dibuang. |
| Periode | Satu pilihan periode (`reportPeriodProvider`, default `bulan_ini`) dipakai beranda Laporan dan semua laporan rinci; "Pilih tanggal" = `period=custom&from&to` (HP menolak > 366 hari termasuk kedua ujung sebelum memanggil; buku Kas & Bank juga). Selama angka periode baru dimuat, angka lama diredupkan + garis muat. Ubin Sekilas (`/reports/overview`) tidak bergantung periode. |
| Hak akses Catatan | Bagian ditentukan dari `tenants[].permissions` di login/`GET /me` (`ViewAny:Invoice` → Penjualan & uang masuk, `ViewAny:Bill` → Pembelian & uang keluar, `ViewAny:JournalEntry` + menu `cash_journal` atau `reports` → Kas & Bank, `ViewAny:ProductService` → Stok, `ViewAny:Customer`, `ViewAny:Supplier`); sesi lama tanpa daftar permission memakai `menus` (`records`, `stock`, `cash_journal`). Bila menu dari sinkron berubah (atau sesi belum punya daftar permission), HP memanggil `GET /me` di belakang. Server tetap mengecek ulang (403 `tidak_berhak` ditampilkan sebagai "Belum punya akses"). Galat lain tampil sebagai kalimat biasa ("Data dari server belum bisa dibaca…"), bukan teks teknis. |
| Cetak ulang struk | `GET /records/sales/{id}/receipt` → `ReceiptBuilder.sale(..., reprint: true)` ke printer Bluetooth yang sama dengan kasir; pengaturan struk dari `sync/pull.receipt`. Laporan shift: `GET /reports/shifts/{id}` → `ReceiptBuilder.shiftReport` dengan ringkasan yang dihitung ulang. |
| Kirim WhatsApp / Bagikan | HP membuka `https://wa.me/<nomor 62…>?text=…` (url_launcher) dengan teks siap kirim (nota + `verification.url`, atau tagihan pelanggan dari `outstanding_invoices`); nomor pelanggan bila ada, kalau tidak WhatsApp meminta pilih kontak. Ringkasan laporan lewat menu Bagikan HP (share_plus). Bila WhatsApp/browser tidak ada, teks disalin ke papan klip sebagai cadangan. |
| PDF & lampiran | `GET /records/sales/{id}/pdf`, lampiran non-foto, dan file Tim AI (`GET /ai/attachments/...`) diunduh dengan token + `X-Tenant` (progres tampil), disimpan ke folder **Download** HP (Android 10+: MediaStore tanpa izin; Android 9 ke bawah: izin penyimpanan) dan salinan di folder aplikasi, lalu pesan "Tersimpan di Download" dengan tombol **Buka** (open_filex) dan **Bagikan** (share_plus). Foto lampiran ditampilkan langsung (`GET /records/attachments/...` dengan token). |
| Batal / retur | Tombol **Batalkan penjualan** hanya bila `can.void` true (alasan wajib); retur selalu diarahkan ke website. |
| Offline | Laporan & Catatan menampilkan "… butuh internet"; data terakhir yang sudah tampil tetap terlihat sampai dimuat ulang. |

## 9. Web terkait
- **Tim & Akses › Perangkat** (`/app/{tenant}/tim/perangkat`, permission `manage-members`): daftar HP, kode kasir, pengguna, gudang, terakhir sinkron, transaksi tertunda di HP, **Cabut akses / Izinkan lagi**, atur nama & gudang.
- **Tim & Akses › Perlu Ditinjau (Kasir HP)** (`/tim/perlu-ditinjau`, permission `issue-invoice`): penjualan `perlu_ditinjau` → **Proses ulang** (boleh ganti tanggal, mis. periode tutup buku) atau **Tandai selesai**.

## 10. Contoh cepat (curl)
```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/auth/login -H 'Accept: application/json' \
  -d email=owner@contoh.id -d password=rahasia -d device_name='HP Tes' -d device_uid=hp-tes-0001 | jq -r .token)
curl -s http://localhost:8000/api/v1/sync/pull -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.device, .products.ids'
curl -s -X POST http://localhost:8000/api/v1/pos/number-blocks -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json'
curl -s http://localhost:8000/api/v1/ai/overview -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.teams[].name, .coins'
curl -s 'http://localhost:8000/api/v1/reports/sales/summary?period=hari_ini' -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.totals, .payments'
RUN=$(curl -s -X POST http://localhost:8000/api/v1/ai/messages -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' \
  -F 'text=kopi susu 2 tunai' -F 'attachments[]=@nota.jpg' | jq -r .run_id)
curl -s http://localhost:8000/api/v1/ai/runs/$RUN -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.status, .proposals[].title'
curl -s 'http://localhost:8000/api/v1/records/sales?status=outstanding&limit=5' -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.data[].number, .next_cursor'
curl -s http://localhost:8000/api/v1/records/sales/1/pdf -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -o invoice.pdf
curl -s 'http://localhost:8000/api/v1/records/cash?from=2026-10-01&to=2026-10-31' -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.accounts, .data[0]'
```
