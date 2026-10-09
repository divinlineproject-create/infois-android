// Uji coba Catatan (API.md §8) langsung ke server Laravel sungguhan (bukan bagian `flutter test` biasa).
// Jalankan:
//   flutter test test_live/records_live_test.dart --dart-define=INFOIS_LIVE=http://127.0.0.1:8099 \
//     --dart-define=INFOIS_LIVE_EMAIL=pemilik@contoh.id --dart-define=INFOIS_LIVE_PASSWORD=rahasia
// (variabel lingkungan INFOIS_LIVE / INFOIS_LIVE_EMAIL / INFOIS_LIVE_PASSWORD juga bisa dipakai.)
//
// Memeriksa bentuk jawaban setiap endpoint /records/* persis seperti kontrak:
// daftar + kursor, rincian, struk (bentuk sama dengan penjualan lokal), PDF,
// pembayaran gabungan masuk/keluar, buku kas dengan saldo berjalan, stok, dan
// pelanggan/pemasok. Tidak mengubah data (void hanya dicoba pada nota yang
// sudah lunas, yang harus ditolak 422).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/domain/models.dart';

final _money = RegExp(r'^-?\d+\.\d{2}$');
final _qty = RegExp(r'^-?\d+\.\d{6}$');
final _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _time = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+07:00$');

String? _setting(String key, String define) => define.isNotEmpty ? define : Platform.environment[key];

List<Map<String, dynamic>> _rows(Map<String, dynamic> body, [String key = 'data']) =>
    [for (final row in body[key] as List) Map<String, dynamic>.from(row as Map)];

void main() {
  final server = _setting('INFOIS_LIVE', const String.fromEnvironment('INFOIS_LIVE'));
  final email = _setting('INFOIS_LIVE_EMAIL', const String.fromEnvironment('INFOIS_LIVE_EMAIL'));
  final password = _setting('INFOIS_LIVE_PASSWORD', const String.fromEnvironment('INFOIS_LIVE_PASSWORD'));

  test('Catatan: penjualan → struk/PDF → pembayaran → pembelian → kas → stok → pelanggan/pemasok', () async {
    final login = await ApiClient(baseUrl: server!).post('auth/login', data: {
      'email': email,
      'password': password,
      'device_name': 'HP Live Test Catatan',
      'device_uid': 'hp-live-records-${DateTime.now().millisecondsSinceEpoch}',
      'platform': 'android',
    });
    final tenants = [for (final item in login['tenants'] as List) TenantSummary.fromJson(Map<String, dynamic>.from(item as Map))];
    final tenant = tenants.firstWhere((item) => item.menus.records, orElse: () => tenants.first);
    expect(tenant.menus.records, isTrue, reason: 'Akun uji harus punya menu Catatan.');
    final client = ApiClient(baseUrl: server, token: login['token'] as String, tenantId: tenant.id);

    // Penjualan: daftar, filter, kursor.
    final sales = await client.get('records/sales', query: {'limit': 3});
    final saleRows = _rows(sales);
    expect(saleRows, isNotEmpty, reason: 'Perusahaan uji harus punya penjualan.');
    for (final row in saleRows) {
      expect(row['number'], isNotEmpty);
      expect(row['date'], matches(_date));
      expect(row['total'], matches(_money));
      expect(row['amount_paid'], matches(_money));
      expect(row['balance_due'], matches(_money));
      expect(row['status'], isIn(['draft', 'issued', 'partially_paid', 'paid', 'void']));
      expect(row['source'], isIn(['web', 'pos', 'ai', 'telegram']));
      expect(row['status_label'], isNotEmpty);
      expect(row['created_at'], matches(_time));
    }
    if (sales['next_cursor'] != null) {
      final next = _rows(await client.get('records/sales', query: {'limit': 3, 'cursor': sales['next_cursor']}));
      expect(next.map((row) => row['id']), isNot(contains(saleRows.first['id'])), reason: 'Halaman berikutnya tidak mengulang.');
    }
    final paidSales = _rows(await client.get('records/sales', query: {'status': 'paid', 'limit': 1}));
    expect(paidSales.map((row) => row['status']), everyElement('paid'));

    // Rincian + struk + PDF.
    final saleId = saleRows.first['id'] as int;
    final sale = Map<String, dynamic>.from((await client.get('records/sales/$saleId'))['sale'] as Map);
    expect(sale['id'], saleId);
    expect(sale['items'], isA<List>());
    expect(sale['payments'], isA<List>());
    expect(sale['attachments'], isA<List>());
    expect(sale['can'], containsPair('return', false));
    expect(sale['links'], allOf(contains('receipt'), contains('pdf')));
    expect(sale['tax_name'], isNotEmpty);
    for (final item in _rows(sale, 'items')) {
      expect(item['quantity'], matches(_qty));
      expect(item['unit_price'], matches(_money));
      expect(item['line_total'], matches(_money));
    }

    final receipt = await client.get('records/sales/$saleId/receipt');
    expect(receipt['reprint'], isTrue);
    final receiptSale = Map<String, dynamic>.from(receipt['sale'] as Map);
    for (final key in ['number', 'created_at', 'customer_name', 'items', 'payments', 'subtotal', 'discount_total', 'tax_total', 'total', 'paid', 'change', 'tax_name', 'prices_include_tax']) {
      expect(receiptSale, contains(key), reason: 'ReceiptBuilder.sale memakai kunci "$key".');
    }
    expect(receiptSale['total'], sale['total']);

    final pdf = await client.bytes('${server.replaceFirst(RegExp(r'/$'), '')}/api/v1/records/sales/$saleId/pdf');
    expect(String.fromCharCodes(pdf.take(4)), '%PDF');

    // Void nota lunas harus ditolak dengan kode yang ramah (data tidak berubah).
    if (paidSales.isNotEmpty) {
      try {
        await client.post('records/sales/${paidSales.first['id']}/void', data: {'reason': 'uji otomatis'});
        fail('Void nota lunas harus ditolak.');
      } on ApiException catch (error) {
        expect(error.status, 422);
        expect(error.code, 'sudah_dibayar');
        expect(error.message, contains('website'));
      }
    }

    // Pembayaran gabungan masuk/keluar dengan kursor khusus.
    final payments = await client.get('records/payments', query: {'limit': 2});
    final paymentRows = _rows(payments);
    for (final row in paymentRows) {
      expect(row['kind'], isIn(['in', 'out']));
      expect(row['amount'], matches(_money));
      expect(row['method_label'], isNotEmpty);
      expect(row['via'], isIn(['payment', 'deposit', 'credit_note', 'debit_note']));
      expect(row['document'], isNotNull);
      final detail = Map<String, dynamic>.from((await client.get('records/payments/${row['kind']}/${row['id']}'))['payment'] as Map);
      expect(detail['id'], row['id']);
      expect(detail['exchange_rate'], matches(RegExp(r'^\d+\.\d{6}$')));
      expect(detail['attachments'], isA<List>());
    }
    if (payments['next_cursor'] != null) {
      final next = _rows(await client.get('records/payments', query: {'limit': 2, 'cursor': payments['next_cursor']}));
      expect(next.map((row) => '${row['kind']}-${row['id']}'), isNot(contains('${paymentRows.last['kind']}-${paymentRows.last['id']}')));
    }

    // Pembelian (bila berhak).
    try {
      final purchases = _rows(await client.get('records/purchases', query: {'limit': 2}));
      for (final row in purchases) {
        expect(row['status'], isIn(['draft', 'open', 'partially_paid', 'paid', 'void']));
        expect(row['total'], matches(_money));
        final detail = Map<String, dynamic>.from((await client.get('records/purchases/${row['id']}'))['purchase'] as Map);
        expect(detail['items'], isA<List>());
        expect(detail['payments'], isA<List>());
      }
    } on ApiException catch (error) {
      expect(error.status, 403);
      expect(error.code, 'tidak_berhak');
    }

    // Buku kas & saldo akun.
    final cash = await client.get('records/cash', query: {'limit': 5});
    expect(cash['period'], allOf(contains('from'), contains('to')));
    expect(cash['totals'], allOf(contains('in'), contains('out'), contains('opening'), contains('closing')));
    for (final account in _rows(cash, 'accounts')) {
      expect(account['kind'], isIn(['cash', 'bank']));
      expect(account['opening'], matches(_money));
      expect(account['closing'], matches(_money));
    }
    for (final row in _rows(cash)) {
      expect(row['direction'], isIn(['in', 'out']));
      expect(row['amount'], matches(_money));
      expect(row['balance'], matches(_money));
      expect(row['source'], allOf(contains('type'), contains('label')));
    }
    final balances = await client.get('records/cash/accounts');
    expect(balances['as_of'], matches(_date));
    expect(balances['total'], matches(_money));

    // Stok.
    final movements = _rows(await client.get('records/stock-movements', query: {'limit': 3}));
    for (final row in movements) {
      expect(row['quantity'], matches(_qty));
      expect(row['direction'], row['quantity'].toString().startsWith('-') ? 'out' : 'in');
      expect(row['type_label'], isNotEmpty);
    }
    final stock = await client.get('records/stock', query: {'limit': 3});
    expect(stock['low_count'], isA<int>());
    for (final row in _rows(stock)) {
      expect(row['quantity'], matches(_qty));
      expect(row['low'], isA<bool>());
      expect(row['warehouses'], isA<List>());
    }

    // Pelanggan & pemasok.
    final customers = _rows(await client.get('records/customers', query: {'limit': 2}));
    for (final row in customers) {
      expect(row['receivable'], matches(_money));
      expect(row['needs_collection'], isA<bool>());
      final detail = Map<String, dynamic>.from((await client.get('records/customers/${row['id']}'))['customer'] as Map);
      expect(detail['outstanding_invoices'], isA<List>());
      expect(detail['deposits_available'], matches(_money));
    }
    try {
      final suppliers = _rows(await client.get('records/suppliers', query: {'limit': 1}));
      for (final row in suppliers) {
        expect(row['payable'], matches(_money));
        final detail = Map<String, dynamic>.from((await client.get('records/suppliers/${row['id']}'))['supplier'] as Map);
        expect(detail['outstanding_bills'], isA<List>());
      }
    } on ApiException catch (error) {
      expect(error.status, 403);
    }

    // Dokumen perusahaan lain / id asing → 404 ramah.
    try {
      await client.get('records/sales/999999999');
      fail('Id asing harus 404.');
    } on ApiException catch (error) {
      expect(error.status, 404);
      expect(error.code, 'tidak_ditemukan');
      expect(error.message, 'Penjualan tidak ditemukan.');
    }
  }, timeout: const Timeout(Duration(minutes: 3)), skip: _setting('INFOIS_LIVE', const String.fromEnvironment('INFOIS_LIVE')) == null ? 'Set INFOIS_LIVE untuk menjalankan.' : false);
}
