import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/printing/receipt_builder.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Alur kasir lengkap di layar (offline): buka kasir, pilih barang, ubah
/// jumlah, bayar tunai dengan nominal cepat, struk tercetak, outbox terisi.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  Future<(LocalDb, FakePrinter)> pumpApp(WidgetTester tester, {List<TenantSummary>? tenants, int? tenantId = 1, bool loggedIn = true, Map<String, dynamic>? menus, bool seed = true, FakeServer? server}) async {
    final allTenants = tenants ?? const [TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, shift: true, printer: true, addCustomer: true))];
    SharedPreferences.setMockInitialValues({
      if (loggedIn)
        'session': jsonEncode({
          'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
          'tenants': [for (final tenant in allTenants) tenant.toJson()],
        }),
      if (tenantId != null) 'tenant_id': tenantId,
      'printer_mac': '00:11:22:33:44:55',
      'printer_name': 'RPP02N',
      'printer_width': 58,
    });
    FlutterSecureStorage.setMockInitialValues({if (loggedIn) 'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      if (seed) {
        await seedMaster(db, menus: menus);
      }
      return db;
    });
    final printer = FakePrinter();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local!),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server ?? offlineServer())),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(printer),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    return (local!, printer);
  }

  testWidgets('jual tunai offline: struk tercetak dan penjualan masuk outbox', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final (local, printer) = await pumpApp(tester);

    expect(find.text('Warung Tes'), findsWidgets);
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.text('Kasir belum dibuka'), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-shift')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('opening-cash')), '100000');
    await tester.tap(find.byKey(const Key('opening-save')));
    await settle(tester);
    expect(find.text('Kasir belum dibuka'), findsNothing);

    await tester.tap(find.byKey(const Key('product-1')));
    await tester.tap(find.byKey(const Key('product-2')));
    await tester.tap(find.byKey(const Key('product-1')));
    await settle(tester);
    expect(find.text('2 barang'), findsOneWidget);
    expect(find.text('Rp 52.650'), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-cart')));
    await settle(tester);
    expect(find.text('Keranjang'), findsOneWidget);
    await tester.tap(find.byKey(const Key('go-pay')));
    await settle(tester);

    expect(find.byKey(const Key('pay-total')), findsOneWidget);
    expect(find.text('Rp 52.650'), findsWidgets);
    expect(find.text('Uang pas'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('quick-3')));
    await tester.tap(find.byKey(const Key('quick-3')));
    await settle(tester);
    expect(find.text('Rp 7.350'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pay-submit')));
    await settle(tester);

    expect(find.text('Penjualan tersimpan'), findsOneWidget);
    expect(find.text('POS-K1/000001'), findsOneWidget);
    expect(printer.printed, hasLength(1));
    expect(latin1.decode(printer.printed.single, allowInvalid: true), contains('POS-K1/000001'));

    final pending = await tester.runAsync(() => OutboxStore(local).pending());
    expect(pending!.map((item) => item.type), ['shift_open', 'sale']);
    expect(pending.last.data['total'], '52650.00');

    await tester.tap(find.byKey(const Key('new-sale')));
    await settle(tester);
    expect(find.byKey(const Key('open-cart')), findsNothing, reason: 'Keranjang kosong lagi untuk transaksi baru.');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bon tanpa pelanggan ditolak dengan pesan jelas', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-shift')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('opening-save')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('product-1')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('open-cart')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('go-pay')));
    await settle(tester);
    await tester.tap(find.text('Bon'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('pay-submit')));
    await settle(tester);

    expect(find.text('Pilih pelanggan untuk penjualan bon (bayar nanti).'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('menu mengikuti hak akses: viewer tidak melihat Kasir', (tester) async {
    await pumpApp(
      tester,
      tenants: const [TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Viewer', menus: Menus(reports: true, records: true))],
      menus: {'reports': true, 'records': true},
    );
    expect(find.widgetWithText(NavigationDestination, 'Laporan'), findsOneWidget);
    expect(find.widgetWithText(NavigationDestination, 'Kasir'), findsNothing);
    expect(find.widgetWithText(NavigationDestination, 'Tim AI'), findsNothing);
    expect(find.widgetWithText(NavigationDestination, 'Akun'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('katalog kosong + server menolak: alasan tampil, bukan "Mengunduh…" selamanya', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final server = FakeServer((options, body) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          _ => {'_status': 403, 'message': 'Langganan perusahaan ini sedang tidak aktif. Kelola paket lewat website Infois.', 'code': 'langganan_tidak_aktif'},
        });
    await pumpApp(tester, seed: false, server: server);

    expect(find.text('Data barang belum bisa diunduh'), findsOneWidget);
    expect(find.textContaining('Langganan perusahaan ini sedang tidak aktif'), findsOneWidget);
    expect(find.text('Mengunduh data barang…'), findsNothing);
    expect(find.text('Coba lagi'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('katalog kosong + jawaban server rusak: sinkron berhenti dengan pesan, bukan menggantung', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final server = FakeServer((options, body) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          'sync/pull' => {'cursor': 'x', 'products': 'bukan-map'},
          _ => {'results': []},
        });
    await pumpApp(tester, seed: false, server: server);

    expect(find.text('Data barang belum bisa diunduh'), findsOneWidget);
    expect(find.textContaining('Sinkron gagal'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('belum login: tampil layar masuk', (tester) async {
    await pumpApp(tester, loggedIn: false, tenantId: null);
    expect(find.text('Masuk ke Infois'), findsOneWidget);
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('struk ESC/POS memuat nomor, total, LUNAS, dan footer', () async {
    final builder = await ReceiptBuilder.create();
    final bytes = builder.sale({
      'number': 'POS-K1/000009',
      'created_at': '2026-10-07T03:00:00Z',
      'cashier': 'Sari',
      'customer_name': 'Bu Ani',
      'items': [
        {'description': 'Kopi susu', 'quantity': '2.000000', 'unit': 'gelas', 'unit_price': '18000.00', 'discount_percent': '0.00', 'line_total': '36000.00'},
      ],
      'subtotal': '36000.00',
      'discount_total': '0.00',
      'tax_total': '0.00',
      'total': '36000.00',
      'change': '14000.00',
      'payments': [
        {'method': 'cash', 'amount': '36000.00', 'tendered': '50000.00'},
      ],
      'verification_url': 'http://tes/verify/abc',
    }, const ReceiptConfig(companyName: 'Warung Tes', address: 'Jl. Contoh 1', footerText: 'Terima kasih', showQr: true), width: 58);
    final text = latin1.decode(bytes, allowInvalid: true);
    for (final expected in ['Warung Tes', 'POS-K1/000009', 'Bu Ani', 'Kopi susu', '36.000', 'Kembali', '14.000', 'LUNAS', 'Terima kasih', 'http://tes/verify/abc']) {
      expect(text, contains(expected));
    }
    expect(ReceiptBuilder.clean('2 × Rp 1.000 · “ok”'), '2 x Rp 1.000 - "ok"');
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
