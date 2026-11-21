import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/kasir_screen.dart';
import 'package:infois/ui/screens/pos_item_sheet.dart';
import 'package:infois/ui/screens/pos_order_panel.dart';
import 'package:infois/ui/theme.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Kasir untuk toko eceran: barang bersatuan lain (mis. karton isi 6)
/// diketuk → pilih satuan, isi dihitung otomatis. Barang satu satuan tetap
/// langsung masuk. Satuan ditulis dengan isinya di keranjang & lembar barang.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  final air = Product.fromJson({
    'id': 5,
    'name': 'Air mineral',
    'unit': 'pcs',
    'price': '3500.00',
    'units': [
      {'name': 'karton', 'factor': '6.000000', 'price': '20000.00'},
    ],
    'tiers': [
      {'unit': 'karton', 'min_quantity': '2.000000', 'price': '19000.00'},
    ],
    'level_tiers': [
      {'level_id': 1, 'level': 'Reseller', 'unit': 'karton', 'min_quantity': '1.000000', 'price': '18500.00'},
    ],
  });
  const reseller = Customer(id: 8, name: 'Toko Maju', levelId: 1, level: 'Reseller');

  test('label satuan: satuan dasar polos, satuan lain dengan isinya', () {
    final options = air.unitOptions();
    expect([for (final option in options) air.unitLabel(option)], ['pcs', 'karton (isi 6 pcs)']);
    expect(air.hasOtherUnits, isTrue);
    expect(kopi.hasOtherUnits, isFalse);
    expect(air.unitLabelFor('KARTON'), 'karton (isi 6 pcs)');
    expect(air.unitLabelFor('pcs'), 'pcs');
    expect(air.unitLabelFor('dus'), 'dus', reason: 'Satuan yang tidak dikenal barang ini: apa adanya.');

    const pecahan = Product(id: 9, name: 'Kain', unit: '', price: '1000', units: [UnitOption(name: 'gulung', factor: '1.500000', price: '1400')]);
    expect([for (final option in pecahan.unitOptions()) pecahan.unitLabel(option)], ['unit', 'gulung (isi 1,5 unit)']);
    const ribuan = Product(id: 10, name: 'Paku', unit: 'pcs', price: '100', units: [UnitOption(name: 'dus', factor: '1000', price: '90000')]);
    expect(ribuan.unitLabel(ribuan.unitOptions().last), 'dus (isi 1.000 pcs)');

    expect(CartLine.fromProduct('a', air, unit: 'karton').unitLabel, 'karton (isi 6 pcs)');
    expect(CartLine.fromProduct('b', air).unitLabel, 'pcs');
    expect(const CartLine(key: 'c', description: 'Ongkir', quantity: '1', unit: 'kali', unitPrice: '10000').unitLabel, 'kali');
  });

  testWidgets('pilih satuan memakai harga level pelanggan keranjang', (tester) async {
    final container = ProviderContainer(overrides: [workspaceProvider.overrideWith((ref) async => null)]);
    addTearDown(container.dispose);
    container.read(cartProvider.notifier).setCustomer(reseller);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(builder: (context) => TextButton(onPressed: () => showPosUnitPicker(context, air), child: const Text('buka'))),
        ),
      ),
    ));
    await tester.tap(find.text('buka'));
    await settle(tester);

    Finder inButton(String unit, String text) => find.descendant(of: find.byKey(Key('unit-pick-$unit')), matching: find.text(text));
    expect(inButton('pcs', 'Rp 3.500'), findsOneWidget);
    expect(inButton('karton', 'Rp 18.500'), findsOneWidget, reason: 'Harga Reseller untuk 1 karton.');
    await tester.tap(find.byKey(const Key('unit-pick-karton')));
    await settle(tester);
    expect(find.byType(PosUnitPicker), findsNothing);
    final line = container.read(cartProvider).lines.single;
    expect((line.unit, line.quantity, line.unitPrice), ('karton', '1.000000', '18500.00'));
  });

  testWidgets('kasir: ketuk barang bersatuan lain → pilih satuan; barang satu satuan langsung masuk', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, shift: true)).toJson()],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db);
      await db.upsertProducts([air]);
      return db;
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local!),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(offlineServer())),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(FakePrinter()),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await settle(tester);
    }

    final container = ProviderScope.containerOf(tester.element(find.byType(KasirScreen)));
    List<(String, String, String)> lines() => [for (final line in container.read(cartProvider).lines) (line.unit, line.quantity, line.unitPrice)];

    // Barang satu satuan: langsung masuk, tanpa pilihan satuan.
    await tap(find.byKey(const Key('product-1')));
    expect(find.byType(PosUnitPicker), findsNothing);
    expect(lines(), [('gelas', '1.000000', '18000.00')]);

    // Barang bersatuan lain: lembar pilih satuan.
    await tap(find.byKey(const Key('product-5')));
    final picker = find.byType(PosUnitPicker);
    expect(picker, findsOneWidget);
    expect(find.descendant(of: picker, matching: find.text('Air mineral')), findsOneWidget);
    expect(find.text('Pilih satuan yang dibeli. Isi & stok dihitung otomatis.'), findsOneWidget);
    Finder inButton(String unit, String text) => find.descendant(of: find.byKey(Key('unit-pick-$unit')), matching: find.text(text));
    expect(inButton('pcs', 'pcs'), findsOneWidget);
    expect(inButton('pcs', 'Rp 3.500'), findsOneWidget);
    expect(inButton('karton', 'karton (isi 6 pcs)'), findsOneWidget);
    expect(inButton('karton', 'Rp 20.000'), findsOneWidget);
    expect(find.text('Atur jumlah & catatan'), findsOneWidget);
    expect(lines(), hasLength(1), reason: 'Belum ada yang masuk sebelum satuan dipilih.');

    await tap(find.byKey(const Key('unit-pick-karton')));
    expect(picker, findsNothing);
    expect(lines(), [('gelas', '1.000000', '18000.00'), ('karton', '1.000000', '20000.00')]);

    await tap(find.byKey(const Key('product-5')));
    await tap(find.byKey(const Key('unit-pick-pcs')));
    expect(lines().last, ('pcs', '1.000000', '3500.00'));

    // "Atur jumlah & catatan": lembar barang dengan label satuan berisi.
    await tap(find.byKey(const Key('product-5')));
    await tap(find.byKey(const Key('unit-pick-details')));
    expect(picker, findsNothing);
    expect(find.byKey(const Key('item-add')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('item-unit-karton')), matching: find.text('karton (isi 6 pcs)')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('item-unit-pcs')), matching: find.text('pcs')), findsOneWidget);
    await tap(find.byKey(const Key('item-unit-karton')));
    await tap(find.byKey(const Key('item-add')));
    expect(lines(), [('gelas', '1.000000', '18000.00'), ('karton', '2.000000', '19000.00'), ('pcs', '1.000000', '3500.00')]);

    // Keranjang: satuan dengan isinya; satuan dasar tetap polos.
    await tap(find.byKey(const Key('open-cart')));
    String priceText(int index) => (tester.widget(find.descendant(of: find.byType(PosOrderPanel), matching: find.byKey(Key('line-price-${container.read(cartProvider).lines[index].key}')))) as Text).data!;
    expect(priceText(0), 'gelas × Rp 18.000');
    expect(priceText(1), 'karton (isi 6 pcs) × Rp 19.000 · harga grosir');
    expect(priceText(2), 'pcs × Rp 3.500');
    await tester.pumpWidget(const SizedBox());
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
