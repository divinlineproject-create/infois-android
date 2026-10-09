import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/reports_state.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/widgets/report_widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Tab Laporan: ubin ringkasan, ganti periode memuat ulang, peringkat
/// barang dengan porsi, offline, dan hak akses.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  const owner = TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Pemilik', menus: Menus(pos: true, shift: true, ai: true, reports: true, records: true), permissions: ['view-reports', 'ViewAny:Invoice']);

  Future<void> pumpApp(WidgetTester tester, {required FakeServer server, Map<String, dynamic>? menus, List<TenantSummary> tenants = const [owner]}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [for (final tenant in tenants) tenant.toJson()],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: menus);
      return db;
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local!),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(FakePrinter()),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
  }

  late List<String> clipboard;
  setUp(() => clipboard = mockClipboard());

  Future<void> openLaporan(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(NavigationDestination, 'Laporan'));
    await settle(tester);
  }

  testWidgets('ringkasan: ubin hari ini/bulan ini tampil, ganti periode memuat ulang ringkasan', (tester) async {
    final server = FakeServer(reportsHandler());
    await pumpApp(tester, server: server);
    expect(server.requests.where((request) => request.path.startsWith('reports/')), isEmpty, reason: 'Tab Laporan belum dibuka: belum memanggil server.');

    await openLaporan(tester);
    expect(server.requests.where((request) => request.path == 'reports/overview'), hasLength(1));
    expect(find.byKey(const Key('tile-today')), findsOneWidget);
    expect(find.text('Rp 8.342.382,50'), findsWidgets, reason: 'Omzet hari ini dari /reports/overview.');
    expect(find.text('Penjualan · Bulan ini'), findsOneWidget);
    expect(find.text('Rp 142.023.242,50'), findsWidgets, reason: 'Omzet periode bulan ini.');
    expect(find.textContaining('margin 65,9%'), findsOneWidget);
    expect(find.text('Tunai · 50 nota'), findsOneWidget);
    expect(find.text('Barang terlaris'), findsOneWidget);
    expect(find.textContaining('token'), findsNothing);

    final summaryCalls = server.requests.where((request) => request.path == 'reports/sales/summary').toList();
    expect(summaryCalls, hasLength(1));
    expect(summaryCalls.single.queryParameters['period'], 'bulan_ini');

    await tester.tap(find.byKey(const Key('period-hari_ini')));
    await settle(tester);
    final afterSwitch = server.requests.where((request) => request.path == 'reports/sales/summary').toList();
    expect(afterSwitch, hasLength(2), reason: 'Ganti periode memuat ulang ringkasan.');
    expect(afterSwitch.last.queryParameters['period'], 'hari_ini');
    expect(find.text('Penjualan · Hari ini'), findsOneWidget);
    expect(find.byKey(const Key('period-total')), findsOneWidget);
    expect((tester.widget(find.byKey(const Key('period-total'))) as Text).data, 'Rp 8.342.382,50');
    expect(server.requests.where((request) => request.path == 'reports/overview'), hasLength(1), reason: 'Ubin sekilas tidak bergantung periode.');

    await tester.tap(find.byKey(const Key('share-summary')));
    await settle(tester);
    expect(find.textContaining('disalin'), findsOneWidget);
    expect(clipboard.single, contains('Omzet: Rp 8.342.382,50'));
    expect(clipboard.single, contains('Tunai: Rp 5.200.145 (50 nota)'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('barang terlaris: baris peringkat dengan porsi dan total mengikuti periode', (tester) async {
    final server = FakeServer(reportsHandler());
    await pumpApp(tester, server: server);
    await openLaporan(tester);

    await tapVisible(tester, find.byKey(const Key('period-kemarin')));
    await settle(tester);
    await tapVisible(tester, find.byKey(const Key('report-by-product')));
    await settle(tester);

    final call = server.requests.where((request) => request.path == 'reports/sales/by-product').single;
    expect(call.queryParameters['period'], 'kemarin', reason: 'Periode yang dipilih ikut ke laporan rinci.');
    expect(call.queryParameters['limit'].toString(), '20');
    expect(find.text('Kopi Susu Senja'), findsOneWidget);
    expect(find.text('Rp 26.100.000'), findsOneWidget);
    expect(find.textContaining('18,8%'), findsOneWidget);
    expect(find.textContaining('900 gelas'), findsOneWidget);
    expect(find.byType(ShareBar), findsNWidgets(2));
    expect(find.text('Total · 21 baris'), findsOneWidget);
    expect(find.byKey(const Key('rank-1')), findsOneWidget);
    expect(find.byKey(const Key('rank-2')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shift kasir: daftar lalu rincian dengan nota dan tombol cetak ulang', (tester) async {
    final server = FakeServer(reportsHandler());
    await pumpApp(tester, server: server);
    await openLaporan(tester);
    await tapVisible(tester, find.byKey(const Key('report-shift')));
    await settle(tester);
    expect(find.byKey(const Key('shift-13')), findsOneWidget);
    expect(find.textContaining('Kurang 141 rb'), findsOneWidget);

    await tester.tap(find.byKey(const Key('shift-13')));
    await settle(tester);
    expect(find.text('POS-K21/000001'), findsOneWidget);
    expect(find.text('Rp 440.975'), findsWidgets);
    expect(find.byKey(const Key('print-shift')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offline: tab Laporan menjelaskan butuh internet', (tester) async {
    await pumpApp(tester, server: offlineServer());
    await openLaporan(tester);
    expect(find.text('Laporan butuh internet'), findsOneWidget);
    expect(find.text('Coba lagi'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ganti periode: angka periode lama diredupkan sampai angka periode baru datang', (tester) async {
    final server = GatedServer(reportsHandler());
    await pumpApp(tester, server: server);
    await openLaporan(tester);
    expect(find.byKey(const Key('reloading')), findsNothing);

    final slow = Completer<void>();
    server.hold((options) => options.path == 'reports/sales/summary' && options.queryParameters['period'] == 'hari_ini', slow);
    await tester.tap(find.byKey(const Key('period-hari_ini')));
    await settle(tester);
    expect(find.text('Penjualan · Hari ini'), findsOneWidget);
    expect(find.byKey(const Key('reloading')), findsOneWidget, reason: 'Ada tanda sedang memuat.');
    final dimmed = tester.widget<AnimatedOpacity>(find.ancestor(of: find.byKey(const Key('period-total')), matching: find.byType(AnimatedOpacity)).first);
    expect(dimmed.opacity, lessThan(1), reason: 'Angka bulan ini tidak tampil seolah angka hari ini.');

    slow.complete();
    await settle(tester);
    expect(find.byKey(const Key('reloading')), findsNothing);
    expect((tester.widget(find.byKey(const Key('period-total'))) as Text).data, 'Rp 8.342.382,50');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('peringkat: halaman lanjutan periode lama dibuang setelah periode diganti', (tester) async {
    final server = GatedServer(pagedProductsHandler(reportsHandler()));
    await pumpApp(tester, server: server);
    await openLaporan(tester);
    await tapVisible(tester, find.byKey(const Key('report-by-product')));
    await settle(tester);
    expect(find.text('Bulan ini A'), findsOneWidget);

    final slow = Completer<void>();
    server.hold((options) => options.path == 'reports/sales/by-product' && options.queryParameters['cursor'] == 'p2', slow);
    final container = ProviderScope.containerOf(tester.element(find.text('Bulan ini A')));
    unawaited(container.read(rankedReportProvider('by-product').notifier).loadMore());
    await settle(tester);
    await tester.tap(find.byKey(const Key('period-kemarin')).last);
    await settle(tester);
    expect(find.text('Kemarin A'), findsOneWidget);

    slow.complete();
    await settle(tester);
    expect(find.text('Kemarin A'), findsOneWidget);
    expect(find.text('Lama halaman 2'), findsNothing, reason: 'Halaman 2 bulan ini tidak ditempel ke daftar kemarin.');
    expect(find.text('Bulan ini A'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('peringkat: halaman lanjutan gagal → tombol Coba lagi di kaki daftar', (tester) async {
    var failures = 1;
    final base = pagedProductsHandler(reportsHandler());
    final server = FakeServer((options, body) {
      if (options.queryParameters['cursor'] == 'p2' && failures-- > 0) {
        return null;
      }
      return base(options, body);
    });
    await pumpApp(tester, server: server);
    await openLaporan(tester);
    await tapVisible(tester, find.byKey(const Key('report-by-product')));
    await settle(tester);

    final container = ProviderScope.containerOf(tester.element(find.text('Bulan ini A')));
    unawaited(container.read(rankedReportProvider('by-product').notifier).loadMore());
    await settle(tester);
    expect(find.byKey(const Key('load-more-retry')), findsOneWidget);
    expect(find.textContaining('Gagal memuat lanjutan'), findsOneWidget);

    // Gulir lagi tidak mengulang otomatis; hanya tombol.
    unawaited(container.read(rankedReportProvider('by-product').notifier).loadMore());
    await settle(tester);
    expect(server.requests.where((request) => request.queryParameters['cursor'] == 'p2'), hasLength(1));

    await tapVisible(tester, find.byKey(const Key('load-more-retry')));
    await settle(tester);
    expect(server.requests.where((request) => request.queryParameters['cursor'] == 'p2'), hasLength(2));
    expect(find.text('Lama halaman 2'), findsOneWidget);
    expect(find.byKey(const Key('load-more-retry')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stok: ubin menghitung menipis + habis, sama dengan daftar yang dibuka', (tester) async {
    final server = FakeServer(reportsHandler());
    await pumpApp(tester, server: server);
    await openLaporan(tester);
    await tester.ensureVisible(find.text('Stok menipis/habis'));
    expect(find.text('6 barang'), findsOneWidget, reason: 'low_count 5 + empty_count 1.');
    expect(find.text('1 habis · 5 menipis'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kasir tanpa hak laporan: tab Laporan tidak tampil dan /reports tidak dipanggil', (tester) async {
    final server = FakeServer(reportsHandler(menus: {'pos': true, 'shift': true, 'records': true}));
    await pumpApp(
      tester,
      server: server,
      tenants: const [TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, shift: true, records: true), permissions: ['ViewAny:Invoice'])],
      menus: {'pos': true, 'shift': true, 'records': true},
    );
    expect(find.widgetWithText(NavigationDestination, 'Laporan'), findsNothing);
    expect(find.widgetWithText(NavigationDestination, 'Catatan'), findsOneWidget);
    expect(server.requests.where((request) => request.path.startsWith('reports/')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Server palsu: ping + sinkron minimal dan endpoint Laporan (API.md › 7).
Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) reportsHandler({Map<String, dynamic>? menus}) {
  return (options, body) {
    final path = options.path;
    final period = options.queryParameters['period']?.toString() ?? 'bulan_ini';
    switch (path) {
      case 'ping':
        return {'ok': true, 'min_app_version': '1.0.0'};
      case 'sync/pull':
        return {
          'cursor': 'c1',
          'full': true,
          'tenant': {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'},
          'receipt': {'width': 58, 'company': {'name': 'Warung Tes'}},
          'device': {'id': 3, 'code': 'K1', 'name': 'HP Tes'},
          'menus': menus ?? {'pos': true, 'shift': true, 'ai': true, 'reports': true, 'records': true, 'printer': true},
          'products': {'items': [], 'ids': [1, 2]},
          'customers': {'items': [], 'ids': [7]},
          'accounts': {'items': [], 'ids': [], 'default_cash_id': null, 'default_transfer_id': null},
          'warehouses': {'items': [], 'ids': []},
          'number_blocks': [],
          'open_shift': null,
        };
      case 'sync/push':
        return {'results': []};
      case 'reports/overview':
        return {
          'today': {'date': '2026-10-09', 'count': 63, 'total': '8342382.50', 'net': '7716950.00', 'average': '132418.77', 'gross_profit': '4674551.73', 'margin': '60.5', 'paid': '6639245.00', 'outstanding': '1703137.50'},
          'yesterday': {'date': '2026-10-08', 'count': 0, 'total': '0.00', 'net': '0.00', 'average': '0.00', 'gross_profit': '0.00', 'margin': '0', 'paid': '0.00', 'outstanding': '0.00'},
          'month': {'from': '2026-10-01', 'to': '2026-10-31', 'label': 'Oktober 2026', 'count': 84, 'total': '142023242.50', 'net': '138765950.00', 'average': '1690752.89', 'gross_profit': '91507888.64', 'margin': '65.9', 'paid': '120844045.00', 'outstanding': '21179197.50'},
          'cash_balance': '1341050148.00',
          'receivables': {'outstanding_total': '62157067.50', 'outstanding_count': 25, 'overdue_total': '13677420.00', 'overdue_count': 3},
          'payables': {'outstanding_total': '57526299.00', 'outstanding_count': 9, 'overdue_total': '3273150.00', 'overdue_count': 1},
          'stock': {'low_count': 5, 'empty_count': 1},
          'sparkline': [for (var i = 0; i < 14; i++) {'date': '2026-09-${26 + i}', 'total': '${(i + 1) * 1000000}.00', 'count': i}],
          'generated_at': '2026-10-09T15:02:11+07:00',
        };
      case 'reports/sales/summary':
        final today = period == 'hari_ini';
        return {
          'period': periodJson(period),
          'filters': {'warehouse_id': null, 'device_id': null, 'user_id': null},
          'totals': today
              ? {'count': 63, 'gross': '7811000.00', 'discount': '94050.00', 'net': '7716950.00', 'tax': '625432.50', 'total': '8342382.50', 'paid': '6639245.00', 'outstanding': '1703137.50', 'cogs': '3042398.27', 'gross_profit': '4674551.73', 'margin': '60.5', 'average': '132418.77', 'customers': 8, 'returns': '0.00', 'unpaid_count': 9}
              : {'count': 84, 'gross': '138860000.00', 'discount': '94050.00', 'net': '138765950.00', 'tax': '3257292.50', 'total': '142023242.50', 'paid': '120844045.00', 'outstanding': '21179197.50', 'cogs': '47258061.36', 'gross_profit': '91507888.64', 'margin': '65.9', 'average': '1690752.89', 'customers': 20, 'returns': '0.00', 'unpaid_count': 12},
          'series': today
              ? {'unit': 'hour', 'points': [for (var h = 0; h < 24; h++) {'key': h.toString().padLeft(2, '0'), 'label': '${h.toString().padLeft(2, '0')}:00', 'count': h == 10 ? 30 : 0, 'net': h == 10 ? '7716950.00' : '0.00', 'total': h == 10 ? '8342382.50' : '0.00'}]}
              : {'unit': 'day', 'points': [for (var d = 1; d <= 9; d++) {'key': '2026-10-0$d', 'label': '$d Okt', 'count': d, 'net': '${d * 1000000}.00', 'total': '${d * 1100000}.00'}]},
          'payments': [
            {'method': 'cash', 'label': 'Tunai', 'count': 50, 'total': '5200145.00'},
            {'method': 'transfer', 'label': 'Transfer bank', 'count': 9, 'total': '1439100.00'},
            {'method': 'bon', 'label': 'Belum dibayar', 'count': 9, 'total': '1703137.50'},
          ],
        };
      case 'reports/sales/by-product':
        return {
          'period': periodJson(period),
          'filters': {'warehouse_id': null, 'device_id': null, 'user_id': null},
          'totals': {'net': '138765950.00', 'tax': '3257292.50', 'total': '142023242.50', 'discount': '94050.00', 'cogs': '47258061.36', 'gross_profit': '91507888.64', 'margin': '65.9'},
          'total_rows': 21,
          'data': [
            {'id': 67, 'name': 'Kopi Susu Senja', 'sku': 'MNU-KSS', 'type': 'Barang', 'unit': 'gelas', 'quantity': '900.000000', 'lines': 15, 'gross': '26100000.00', 'discount': '0.00', 'net': '26100000.00', 'tax': '0.00', 'total': '26100000.00', 'cogs': '7453076.80', 'average_price': '29000.00', 'gross_profit': '18646923.20', 'share': '18.8'},
            {'id': 63, 'name': 'Kopi Senja Espresso Blend', 'sku': 'RST-BLEND', 'type': 'Barang', 'unit': 'kg', 'quantity': '82.500000', 'lines': 22, 'gross': '21686000.00', 'discount': '0.00', 'net': '21686000.00', 'tax': '2385460.00', 'total': '24071460.00', 'cogs': '11799542.54', 'average_price': '262860.61', 'gross_profit': '9886457.46', 'share': '15.6'},
          ],
          'next_cursor': null,
        };
      case 'reports/shifts':
        return {
          'period': periodJson(period),
          'data': [shiftJson()],
          'next_cursor': null,
        };
      case 'reports/shifts/13':
        return {
          'shift': shiftJson(),
          'summary': {'sales_count': 6, 'sales_total': '456975.00', 'cash_total': '340975.00', 'transfer_total': '50000.00', 'unpaid_total': '66000.00', 'opening_cash': '100000.00', 'expected_cash': '440975.00'},
          'sales': [
            {'id': 1356, 'number': 'POS-K21/000001', 'time': '2026-10-09T14:55:39+07:00', 'customer': 'Pelanggan Umum', 'total': '74000.00', 'paid': '74000.00', 'balance': '0.00', 'status': 'paid', 'status_label': 'Lunas', 'methods': ['cash']},
          ],
        };
    }
    return {'_status': 404, 'message': 'Tidak ditemukan: $path', 'code': 'tidak_ditemukan'};
  };
}

/// Barang terlaris dua halaman: bulan ini punya halaman 2 (`p2`), kemarin satu halaman.
Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) pagedProductsHandler(Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) base) {
  return (options, body) {
    if (options.path != 'reports/sales/by-product') {
      return base(options, body);
    }
    final period = options.queryParameters['period']?.toString() ?? 'bulan_ini';
    final cursor = options.queryParameters['cursor']?.toString();
    final name = cursor == 'p2' ? 'Lama halaman 2' : (period == 'kemarin' ? 'Kemarin A' : 'Bulan ini A');
    return {
      'period': periodJson(period),
      'filters': {'warehouse_id': null, 'device_id': null, 'user_id': null},
      'totals': {'net': '100.00', 'tax': '0.00', 'total': '100.00', 'discount': '0.00', 'cogs': '50.00', 'gross_profit': '50.00', 'margin': '50.0'},
      'total_rows': 2,
      'data': [
        {'id': cursor == 'p2' ? 2 : 1, 'name': name, 'unit': 'pcs', 'quantity': '1.000000', 'lines': 1, 'net': '50.00', 'total': '50.00', 'cogs': '25.00', 'gross_profit': '25.00', 'share': '50.0'},
      ],
      'next_cursor': cursor == null && period == 'bulan_ini' ? 'p2' : null,
    };
  };
}

Map<String, dynamic> periodJson(String preset) => switch (preset) {
      'hari_ini' => {'preset': 'hari_ini', 'from': '2026-10-09', 'to': '2026-10-09', 'days': 1, 'label': 'Hari ini'},
      'kemarin' => {'preset': 'kemarin', 'from': '2026-10-08', 'to': '2026-10-08', 'days': 1, 'label': 'Kemarin'},
      _ => {'preset': 'bulan_ini', 'from': '2026-10-01', 'to': '2026-10-31', 'days': 31, 'label': 'Bulan ini'},
    };

Map<String, dynamic> shiftJson() => {
      'id': 13,
      'client_uuid': 'ef9c0bca-1',
      'opened_at': '2026-10-09T14:55:38+07:00',
      'closed_at': '2026-10-09T18:30:00+07:00',
      'status': 'closed',
      'opening_cash': '100000.00',
      'closing_cash': '300000.00',
      'expected_cash': '440975.00',
      'difference': '-140975.00',
      'summary': {'sales_count': 6, 'sales_total': '456975.00', 'cash_total': '340975.00', 'transfer_total': '50000.00', 'unpaid_total': '66000.00', 'opening_cash': '100000.00', 'expected_cash': '440975.00'},
      'device': {'id': 21, 'code': 'K21', 'name': 'HP Rani'},
      'cashier': {'id': 13, 'name': 'Rani Kusumawardani'},
      'duration_minutes': 214,
      'sales_count': 6,
      'sales_total': '456975.00',
      'cash_total': '340975.00',
      'transfer_total': '50000.00',
      'notes': null,
    };

/// Gulir sampai terlihat, gambar ulang, lalu ketuk.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator berputar).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
