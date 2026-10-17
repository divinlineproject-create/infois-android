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
import 'package:infois/services/file_downloads.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';

/// Aplikasi HP dimatikan sementara oleh admin (503 `kanal_pemeliharaan`):
/// pesannya tampil jelas, pengguna tidak dikeluarkan, transaksi offline tetap
/// di antrean dan terkirim setelah kanal dibuka lagi. Juga: bahan baku yang
/// tampil di kasir diberi label.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  setUp(mockClipboard);

  const maintenanceMessage = 'Aplikasi HP Infois sedang dalam pemeliharaan. Penjualan yang tersimpan di HP tetap aman dan terkirim otomatis setelah selesai.';

  Future<({ProviderContainer container, LocalDb local})> pumpApp(WidgetTester tester, FakeServer server, {Future<void> Function(LocalDb local)? seed}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Pemilik', menus: Menus(pos: true)).toJson()],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = (await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: {'pos': true});
      await seed?.call(db);
      return db;
    }))!;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(FakePrinter()),
        filePlatformProvider.overrideWithValue(FakeFilePlatform()),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    return (container: ProviderScope.containerOf(tester.element(find.byType(InfoisApp))), local: local);
  }

  Map<String, dynamic> pull({List<Map<String, dynamic>> products = const [], List<int>? ids}) => {
        'cursor': 'c1',
        'full': true,
        'tenant': {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'},
        'receipt': {'width': 58, 'company': {'name': 'Warung Tes'}},
        'device': {'id': 3, 'code': 'K1', 'name': 'HP Tes'},
        'menus': {'pos': true},
        'products': {'items': products, 'ids': ids ?? [for (final product in products) product['id'] as int]},
        'customers': {'items': [], 'ids': [7]},
        'accounts': {'items': [], 'ids': [], 'default_cash_id': 11, 'default_transfer_id': 12},
        'warehouses': {'items': [], 'ids': []},
        'number_blocks': [],
        'open_shift': null,
      };

  testWidgets('pemeliharaan: spanduk berisi pesan server, tetap masuk, antrean aman; dibuka lagi → terkirim dan spanduk hilang', (tester) async {
    var closed = true;
    final pushed = <String>[];
    final server = FakeServer((options, body) {
      if (options.path == 'ping') {
        return {'ok': true, 'min_app_version': '1.0.0'};
      }
      if (closed) {
        return {'_status': 503, 'code': 'kanal_pemeliharaan', 'message': maintenanceMessage};
      }
      switch (options.path) {
        case 'sync/push':
          return {
            'results': [
              for (final item in body!['items'] as List) {'client_uuid': item['client_uuid'], 'type': item['type'], 'status': 'ok', 'number': 'POS-K1/000001'},
            ]..forEach((result) => pushed.add(result['client_uuid'] as String)),
          };
        case 'sync/pull':
          return pull(products: [kopi.toJson(), roti.toJson()]);
      }
      return null;
    });
    final app = await pumpApp(tester, server, seed: (local) => OutboxStore(local).enqueue('customer', 'pel-1', {'client_uuid': 'pel-1', 'name': 'Pak Budi'}));

    expect(find.byKey(const Key('maintenance-banner')), findsOneWidget);
    expect(find.text('Aplikasi sedang pemeliharaan'), findsOneWidget);
    expect(find.text(maintenanceMessage), findsOneWidget);
    expect(find.byKey(const Key('maintenance-pending')), findsOneWidget);
    expect(app.container.read(sessionProvider).value!.loggedIn, isTrue, reason: 'Pemeliharaan tidak mengeluarkan pengguna.');
    expect(app.container.read(syncProvider).maintenance, maintenanceMessage);
    final item = (await tester.runAsync(() => OutboxStore(app.local).pending()))!.single;
    expect(item.clientUuid, 'pel-1');
    expect(item.attempts, 0);

    closed = false;
    await tester.tap(find.byKey(const Key('maintenance-retry')));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);
    }
    expect(pushed, ['pel-1']);
    expect(find.byKey(const Key('maintenance-banner')), findsNothing);
    expect(app.container.read(maintenanceProvider), isNull);
    expect(app.container.read(syncProvider).pending, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kasir: bahan baku yang ditampilkan di POS diberi label "Bahan baku"', (tester) async {
    final server = FakeServer((options, body) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          'sync/push' => {'results': []},
          'sync/pull' => pull(products: [
              kopi.toJson(),
              {'id': 6, 'name': 'Gula aren', 'type': 'product', 'kind': 'raw_material', 'kind_label': 'Bahan baku', 'unit': 'kg', 'price': '30000.00', 'tax_rate': '0.00', 'track_inventory': true, 'stock_quantity': '4.000000', 'is_active': true, 'units': [], 'tiers': []},
            ]),
          _ => null,
        });
    await pumpApp(tester, server);
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await settle(tester);
    }

    expect(find.byKey(const Key('product-6')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('product-kind-6')), matching: find.text('Bahan baku')), findsOneWidget);
    expect(find.byKey(const Key('product-kind-1')), findsNothing, reason: 'Barang jadi tanpa label.');
    expect(find.byKey(const Key('product-2')), findsNothing, reason: 'Roti tidak ada lagi di ids: dihapus dari kasir.');
    await tester.pumpWidget(const SizedBox());
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
