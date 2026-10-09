// Uji coba Laporan & Catatan (API.md §7–§8) langsung ke server Laravel sungguhan
// lewat klien Dart yang dipakai aplikasi (bukan bagian `flutter test` biasa).
// Jalankan:
//   flutter test test_live/reports_records_live_test.dart --dart-define=INFOIS_LIVE=http://127.0.0.1:8099 \
//     --dart-define=INFOIS_LIVE_EMAIL=pemilik@contoh.id --dart-define=INFOIS_LIVE_PASSWORD=rahasia \
//     --dart-define=INFOIS_LIVE_CASHIER_EMAIL=kasir@contoh.id --dart-define=INFOIS_LIVE_CASHIER_PASSWORD=rahasia
// (variabel lingkungan dengan nama yang sama juga bisa dipakai.)
//
// Memeriksa: ringkasan bulan ini berisi angka > 0 pada data demo, laporan
// per barang/jam/piutang/laba rugi/arus kas/shift terbaca model HP, daftar
// penjualan tidak kosong, rincian punya baris barang, JSON struk membentuk
// tiket ESC/POS lewat ReceiptBuilder, dan kasir tanpa hak laporan ditolak 403.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/data/records_api.dart';
import 'package:infois/data/reports_api.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/domain/report_models.dart';
import 'package:infois/services/printing/receipt_builder.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../test/support/fakes.dart' show preloadEscPosProfile;

String? _setting(String key, String define) => define.isNotEmpty ? define : Platform.environment[key];

final _money = RegExp(r'^-?\d+\.\d{2}$');

Future<({ApiClient client, TenantSummary tenant, String token})> _login(String server, String? email, String? password, String device) async {
  final login = await ApiClient(baseUrl: server).post('auth/login', data: {
    'email': email,
    'password': password,
    'device_name': device,
    'device_uid': 'hp-live-${device.hashCode}-${DateTime.now().millisecondsSinceEpoch}',
    'platform': 'android',
  });
  final tenants = [for (final item in login['tenants'] as List) TenantSummary.fromJson(Map<String, dynamic>.from(item as Map))];
  final tenant = tenants.first;
  final token = login['token'] as String;
  return (client: ApiClient(baseUrl: server, token: token, tenantId: tenant.id), tenant: tenant, token: token);
}

void main() {
  final server = _setting('INFOIS_LIVE', const String.fromEnvironment('INFOIS_LIVE'));
  final email = _setting('INFOIS_LIVE_EMAIL', const String.fromEnvironment('INFOIS_LIVE_EMAIL'));
  final password = _setting('INFOIS_LIVE_PASSWORD', const String.fromEnvironment('INFOIS_LIVE_PASSWORD'));
  final cashierEmail = _setting('INFOIS_LIVE_CASHIER_EMAIL', const String.fromEnvironment('INFOIS_LIVE_CASHIER_EMAIL'));
  final cashierPassword = _setting('INFOIS_LIVE_CASHIER_PASSWORD', const String.fromEnvironment('INFOIS_LIVE_CASHIER_PASSWORD'));

  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  test('Laporan: ringkasan → penjualan → peringkat → per jam → piutang → laba rugi → arus kas → shift', () async {
    final owner = await _login(server!, email, password, 'HP Live Test Laporan');
    expect(owner.tenant.menus.reports, isTrue, reason: 'Akun pemilik harus punya menu Laporan.');
    expect(owner.tenant.permissions, contains('view-reports'), reason: 'Daftar permission dikirim di login (dipakai untuk bagian Catatan).');
    final api = ReportsApi(owner.client);
    try {
      final overview = await api.overview();
      expect(overview.month.count, greaterThan(0), reason: 'Data demo harus punya nota bulan ini.');
      expect(double.parse(overview.month.total), greaterThan(0));
      expect(overview.month.total, matches(_money));
      expect(overview.month.label, isNotEmpty);
      expect(overview.sparkline, hasLength(14));
      expect(overview.cashBalance, matches(_money));
      expect(overview.generatedAt, isNotNull);

      const month = ReportPeriodChoice.bulanIni;
      final summary = await api.salesSummary(month);
      expect(summary.period.preset, 'bulan_ini');
      expect(summary.totals.count, overview.month.count, reason: 'Ringkasan bulan ini = ubin bulan ini.');
      expect(summary.totals.total, overview.month.total);
      expect(summary.seriesUnit, 'day');
      expect(summary.points.length, summary.period.days);
      expect(summary.payments.map((payment) => payment.method), containsAll(['cash', 'transfer', 'bon']));

      final today = await api.salesSummary(const ReportPeriodChoice('hari_ini'));
      expect(today.seriesUnit, 'hour');
      expect(today.points, hasLength(24));

      final custom = await api.salesSummary(ReportPeriodChoice('custom', from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 9)));
      expect(custom.period.preset, 'custom');
      expect(custom.period.days, 9);

      for (final kind in ReportsApi.rankedKinds) {
        final report = await api.ranked(kind, month, limit: 5);
        expect(report.rows.length, lessThanOrEqualTo(5));
        expect(report.totalRows, greaterThanOrEqualTo(report.rows.length));
        if (report.rows.isNotEmpty) {
          expect(report.totals.margin, isNot('0'), reason: '$kind: totals.margin dikirim server (dulu hilang di by-product).');
        }
        for (final row in report.rows) {
          expect(row.name, isNotEmpty);
          expect(row.net, matches(_money));
          expect(row.shareValue, inInclusiveRange(0, 100));
        }
        if (report.nextCursor != null) {
          final next = await api.ranked(kind, month, limit: 5, cursor: report.nextCursor);
          expect(next.rows.map((row) => '${row.id}-${row.name}'), isNot(contains('${report.rows.first.id}-${report.rows.first.name}')));
        }
      }
      final products = await api.ranked('by-product', month, limit: 3);
      expect(products.rows, isNotEmpty);
      expect(products.rows.first.quantity, isNotNull);

      final hourly = await api.ranked('by-hour', month);
      expect(hourly.rows, hasLength(24));
      expect(hourly.rows.map((row) => row.hour), [for (var h = 0; h < 24; h++) h]);
      expect(hourly.peakHour, isNotNull);

      final receivables = await api.aging('receivables', limit: 10);
      expect(receivables.buckets.map((bucket) => bucket.key), ['current', 'd1_30', 'd31_60', 'd61_90', 'over_90']);
      expect(receivables.total, overview.receivables.outstandingTotal, reason: 'Umur piutang = ubin piutang.');
      expect(receivables.rows.length, lessThanOrEqualTo(10));
      final payables = await api.aging('payables');
      expect(payables.total, overview.payables.outstandingTotal);

      final profitLoss = await api.profitLoss(month);
      expect(profitLoss.sections.map((section) => section.key), ['operating_revenue', 'cogs', 'operating_expense', 'other_revenue', 'other_expense']);
      expect(profitLoss.revenue, summary.totals.net, reason: 'Pendapatan buku besar = penjualan bersih bulan ini pada data demo.');
      expect(profitLoss.netIncome, matches(_money));

      final cashFlow = await api.cashFlow(month);
      expect(cashFlow.categories.map((category) => category.key), ['operating', 'investing', 'financing']);
      expect(cashFlow.closing, overview.cashBalance, reason: 'Saldo akhir arus kas bulan ini = saldo kas hari ini.');

      final shifts = await api.shifts(limit: 5);
      expect(shifts.period, isNull);
      for (final shift in shifts.items) {
        expect(shift.status, 'closed');
        expect(shift.closedAt, isNotNull);
        final detail = await api.shift(shift.id);
        expect(detail.shift.id, shift.id);
        expect(detail.summary.expectedCash, matches(_money));
        expect(detail.sales.length, lessThanOrEqualTo(500));
        final ticket = ReceiptBuilder(await ReceiptBuilder.create().then((builder) => builder.profile)).shiftReport(shift.toPrintMap(detail.summary), const ReceiptConfig(companyName: 'Uji'));
        expect(String.fromCharCodes(ticket.where((byte) => byte >= 32 && byte < 127)), contains('LAPORAN TUTUP KASIR'));
      }
      final filtered = await api.shifts(period: month, limit: 5);
      expect(filtered.period?.preset, 'bulan_ini');

      try {
        await api.ranked('by-product', month, limit: 101);
        fail('limit > 100 harus 422.');
      } on ApiException catch (error) {
        expect(error.status, 422);
      }
      try {
        await api.ranked('by-product', month, cursor: 'rusak');
        fail('cursor rusak harus 422.');
      } on ApiException catch (error) {
        expect(error.status, 422);
        expect(error.code, 'cursor_tidak_valid');
      }
      try {
        await api.shift(999999999);
        fail('Shift asing harus 404.');
      } on ApiException catch (error) {
        expect(error.status, 404);
        expect(error.code, 'tidak_ditemukan');
      }
    } finally {
      await owner.client.post('auth/logout');
    }
  }, timeout: const Timeout(Duration(minutes: 3)), skip: server == null ? 'Set INFOIS_LIVE untuk menjalankan.' : false);

  test('Catatan: daftar penjualan → rincian berisi barang → struk membentuk tiket ESC/POS', () async {
    final owner = await _login(server!, email, password, 'HP Live Test Catatan HP');
    final api = RecordsApi(owner.client);
    try {
      final page = await api.sales(limit: 5);
      expect(page.items, isNotEmpty, reason: 'Data demo harus punya penjualan.');
      expect(page.items.first.number, isNotEmpty);
      expect(page.items.first.total, matches(_money));
      if (page.nextCursor != null) {
        final next = await api.sales(limit: 5, cursor: page.nextCursor);
        expect(next.items.map((sale) => sale.id), isNot(contains(page.items.first.id)));
      }
      final withItems = page.items.firstWhere((sale) => sale.itemsCount > 0, orElse: () => page.items.first);
      final detail = await api.sale(withItems.id);
      expect(detail.summary.id, withItems.id);
      expect(detail.items, isNotEmpty, reason: 'Rincian penjualan harus punya baris barang.');
      expect(detail.items.first.description, isNotEmpty);
      expect(detail.items.first.lineTotal, matches(_money));
      expect(detail.receiptLink, isNotNull);
      expect(detail.canReturn, isFalse);

      final receipt = await api.receipt(withItems.id);
      final builder = await ReceiptBuilder.create();
      final ticket = builder.sale(receipt, const ReceiptConfig(companyName: 'Uji Live', showQr: true), reprint: true);
      final text = String.fromCharCodes(ticket.where((byte) => byte >= 32 && byte < 127));
      expect(text, contains(ReceiptBuilder.clean(withItems.number)));
      expect(text, contains('CETAK ULANG'));
      expect(text, contains(ReceiptBuilder.clean(detail.items.first.description).substring(0, 5)));
      expect(ticket.length, greaterThan(200));

      final pdf = await api.salePdf(withItems.id);
      expect(String.fromCharCodes(pdf.take(4)), '%PDF');

      final payments = await api.payments(limit: 3);
      for (final payment in payments.items) {
        expect(payment.kind, isIn(['in', 'out']));
        final full = await api.payment(payment.kind, payment.id);
        expect(full.exchangeRate, isNotNull);
      }
      final cash = await api.cash(limit: 3);
      expect(cash.extra, contains('accounts'));
      final stock = await api.stock(limit: 3);
      expect(stock.extra['low_count'], isA<int>());
      final customers = await api.customers(limit: 3);
      if (customers.items.isNotEmpty) {
        final customer = await api.customer(customers.items.first.id);
        expect(customer.id, customers.items.first.id);
      }
    } finally {
      await owner.client.post('auth/logout');
    }
  }, timeout: const Timeout(Duration(minutes: 3)), skip: server == null ? 'Set INFOIS_LIVE untuk menjalankan.' : false);

  test('Kasir tanpa hak laporan: /reports ditolak 403 tidak_berhak, Catatan penjualan tetap boleh', () async {
    final cashier = await _login(server!, cashierEmail, cashierPassword, 'HP Live Test Kasir');
    expect(cashier.tenant.menus.reports, isFalse, reason: 'Akun kasir uji tidak boleh punya menu Laporan.');
    expect(cashier.tenant.permissions, isNot(contains('view-reports')));
    try {
      for (final path in ['reports/overview', 'reports/sales/summary', 'reports/shifts']) {
        try {
          await cashier.client.get(path);
          fail('$path harus ditolak untuk kasir.');
        } on ApiException catch (error) {
          expect(error.status, 403, reason: path);
          expect(error.code, 'tidak_berhak');
          expect(error.message, contains('laporan'));
        }
      }
      final sales = await RecordsApi(cashier.client).sales(limit: 1);
      expect(sales.items, isNotEmpty, reason: 'Kasir boleh melihat penjualan.');
      try {
        await RecordsApi(cashier.client).purchases(limit: 1);
        fail('Kasir tidak berhak pembelian.');
      } on ApiException catch (error) {
        expect(error.status, 403);
        expect(error.code, 'tidak_berhak');
      }
      for (final path in ['records/cash', 'records/cash/accounts']) {
        try {
          await cashier.client.get(path);
          fail('$path: saldo kas & bank butuh hak laporan / catat kas.');
        } on ApiException catch (error) {
          expect(error.status, 403, reason: path);
          expect(error.code, 'tidak_berhak');
        }
      }
    } finally {
      await cashier.client.post('auth/logout');
    }
  }, timeout: const Timeout(Duration(minutes: 2)), skip: server == null || cashierEmail == null ? 'Set INFOIS_LIVE dan INFOIS_LIVE_CASHIER_EMAIL untuk menjalankan.' : false);
}
