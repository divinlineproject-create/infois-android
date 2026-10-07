# Infois Mobile API — v1

Kontrak API antara aplikasi HP (Flutter, folder `android/`) dan `backoffice` (Laravel).
Semua endpoint ada di bawah **`/api/v1`**, berformat JSON, pesan galat dalam Bahasa Indonesia.

- Kode: `backoffice/routes/api.php`, `app/Http/Controllers/Api/V1/*`, `app/Services/Mobile/*`.
- Tes: `backoffice/tests/Feature/Mobile/*`.

## 1. Aturan umum

| Hal | Aturan |
|---|---|
| Autentikasi | Token Sanctum per **user + HP**: `Authorization: Bearer <token>`. Token terikat ke `device_uid` (ID pemasangan aplikasi). |
| Perusahaan | Dikirim per request: header **`X-Tenant: <id atau slug>`**. Wajib untuk semua endpoint bertanda 🏢. |
| Pengecekan 🏢 | user anggota perusahaan → langganan aktif (`hasActiveAccess()`) → HP belum dicabut → konteks tenant + team permission diaktifkan. |
| Header opsional | `X-App-Version: 1.0.0` (dicatat di Perangkat), `X-Outbox-Count: 3` (jumlah transaksi tertunda di HP, tampil di web). |
| Hak akses | Sama persis dengan web (role & permission per perusahaan, termasuk role custom). Server selalu mengecek ulang. |
| Angka | Uang = string desimal 2 angka (`"52650.00"`), qty = 6 angka (`"1.500000"`). Kirim string, bukan float. |
| Waktu | ISO 8601. `date` = `YYYY-MM-DD` (tanggal lokal HP). |

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
Login ulang dengan `device_uid` yang sama mengganti token lama HP itu. Jawaban = token + isi `GET /me`:
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
- Nomor: dipakai bila `number_seq` ada di jatah HP dan belum terpakai; bila tidak, server memberi nomor baru (+ `warnings`).
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

## 6. Web terkait
- **Tim & Akses › Perangkat** (`/app/{tenant}/tim/perangkat`, permission `manage-members`): daftar HP, kode kasir, pengguna, gudang, terakhir sinkron, transaksi tertunda di HP, **Cabut akses / Izinkan lagi**, atur nama & gudang.
- **Tim & Akses › Perlu Ditinjau (Kasir HP)** (`/tim/perlu-ditinjau`, permission `issue-invoice`): penjualan `perlu_ditinjau` → **Proses ulang** (boleh ganti tanggal, mis. periode tutup buku) atau **Tandai selesai**.

## 7. Contoh cepat (curl)
```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/auth/login -H 'Accept: application/json' \
  -d email=owner@contoh.id -d password=rahasia -d device_name='HP Tes' -d device_uid=hp-tes-0001 | jq -r .token)
curl -s http://localhost:8000/api/v1/sync/pull -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json' | jq '.device, .products.ids'
curl -s -X POST http://localhost:8000/api/v1/pos/number-blocks -H "Authorization: Bearer $TOKEN" -H 'X-Tenant: 1' -H 'Accept: application/json'
```
