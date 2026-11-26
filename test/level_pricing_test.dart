import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/domain/pos_ai.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/pos_item_sheet.dart';
import 'package:infois/ui/screens/pos_order_panel.dart';
import 'package:infois/ui/theme.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

/// Harga bertingkat per level pelanggan (Member, Reseller, …): data dari
/// sync/pull, harga otomatis di keranjang (dihitung ulang saat pelanggan
/// diganti), daftar "Harga bertingkat" di lembar barang, keterangan harga di
/// baris pesanan, dan catatan barang tanpa chip catatan cepat.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  // Sama dengan `price_product` di test/fixtures/cart_parity.json.
  final teh = Product.fromJson({
    'id': 5,
    'name': 'Teh kotak',
    'unit': 'pcs',
    'price': '25000.00',
    'units': [
      {'name': 'karton', 'factor': '24.000000', 'price': '550000.00'},
    ],
    'tiers': [
      {'unit': 'pcs', 'min_quantity': '10.000000', 'price': '23000.00'},
      {'unit': 'pcs', 'min_quantity': '50.000000', 'price': '21000.00'},
      {'unit': 'karton', 'min_quantity': '5.000000', 'price': '520000.00'},
    ],
    'level_tiers': [
      {'level_id': 1, 'level': 'Reseller', 'unit': 'pcs', 'min_quantity': '1.000000', 'price': '22000.00'},
      {'level_id': 1, 'level': 'Reseller', 'unit': 'pcs', 'min_quantity': '100.000000', 'price': '19000.00'},
      {'level_id': 1, 'level': 'Reseller', 'unit': 'karton', 'min_quantity': '1.000000', 'price': '500000.00'},
      {'level_id': 2, 'level': 'Member', 'unit': 'pcs', 'min_quantity': '1.000000', 'price': '24000.00'},
    ],
  });
  const reseller = Customer(id: 8, name: 'Toko Maju', phone: '0813', levelId: 1, level: 'Reseller');
  const member = Customer(id: 9, name: 'Pak Budi', levelId: 2, level: 'Member');
  const umum = Customer(id: 7, name: 'Bu Ani', phone: '0812');

  group('data', () {
    test('Product: level_tiers terbaca & tersimpan di cache; cache lama tanpa level_tiers tetap terbuka', () {
      expect(teh.tiers, hasLength(3));
      expect(teh.levelTiers.map((tier) => (tier.levelId, tier.level, tier.unit, tier.minQuantity, tier.price)).first, (1, 'Reseller', 'pcs', '1.000000', '22000.00'));
      expect(teh.hasTieredPrices, isTrue);
      final cached = Product.fromJson(jsonDecode(jsonEncode(teh.toJson())) as Map<String, dynamic>);
      expect(cached.toJson(), teh.toJson());
      expect(cached.levelTiers, hasLength(4));
      expect((teh.toJson()['tiers'] as List).first, {'unit': 'pcs', 'min_quantity': '10.000000', 'price': '23000.00'}, reason: 'Harga umum tetap bentuk lama.');

      final legacy = Product.fromJson({
        'id': 6,
        'name': 'Lama',
        'unit': 'pcs',
        'price': '1000',
        'tiers': [
          {'unit': 'pcs', 'min_quantity': '10', 'price': '900'},
        ],
      });
      expect(legacy.levelTiers, isEmpty);
      expect(legacy.hasTieredPrices, isTrue);
      expect(legacy.priceFor('pcs', '10', levelId: 1), '900.00');
      expect(const Product(id: 7, name: 'Polos', unit: 'pcs', price: '1').hasTieredPrices, isFalse);
      expect(const Product(id: 8, name: 'Level saja', unit: 'pcs', price: '1', levelTiers: [PriceTier(unit: 'pcs', minQuantity: '1', price: '1', levelId: 1)]).hasTieredPrices, isTrue);
    });

    test('Customer: level dari sync/pull ikut disimpan; pelanggan buatan HP tanpa level', () {
      final customer = Customer.fromJson({'id': 8, 'name': 'Toko Maju', 'phone': '0813', 'level_id': 1, 'level': 'Reseller'});
      expect(customer.levelId, 1);
      expect(customer.level, 'Reseller');
      expect(customer.nameWithLevel, 'Toko Maju · Reseller');
      final copy = Customer.fromJson(jsonDecode(jsonEncode(customer.toJson())) as Map<String, dynamic>);
      expect((copy.levelId, copy.level), (1, 'Reseller'));

      final plain = Customer.fromJson({'id': 7, 'name': 'Bu Ani', 'level_id': null, 'level': null});
      expect((plain.levelId, plain.level, plain.nameWithLevel), (null, null, 'Bu Ani'));
      final offline = Customer.fromJson({'client_uuid': 'u-1', 'name': 'Baru', 'pending': true});
      expect(offline.levelId, isNull);
      expect(offline.nameWithLevel, 'Baru');
    });

    test('asal harga: normal, grosir (dengan batasnya), atau level (dengan nama level)', () {
      final normal = teh.quoteFor('pcs', '1');
      expect((normal.price, normal.source, normal.tier, normal.level), ('25000.00', PriceSource.normal, null, null));

      final grosir = teh.quoteFor('pcs', '12');
      expect((grosir.price, grosir.source, grosir.tier?.minQuantity, grosir.level), ('23000.00', PriceSource.tier, '10.000000', null));

      final level = teh.quoteFor('PCS', '12', levelId: 1);
      expect((level.price, level.source, level.tier?.minQuantity, level.level), ('22000.00', PriceSource.level, '1.000000', 'Reseller'));

      // Harga Member lebih mahal dari harga grosir: harga grosir tetap dipakai.
      final memberGrosir = teh.quoteFor('pcs', '10', levelId: 2);
      expect((memberGrosir.price, memberGrosir.source), ('23000.00', PriceSource.tier));
      expect(teh.quoteFor('pcs', '1', levelId: 2).source, PriceSource.level);
      expect(teh.quoteFor('pcs', '1', levelId: 3).source, PriceSource.normal, reason: 'Level tanpa harga khusus.');
      expect(teh.quoteFor('pcs', '0.5', levelId: 1).source, PriceSource.normal, reason: 'Batas minimum level belum terpenuhi.');
      expect(teh.quoteFor(' karton ', '1', levelId: 1).price, '500000.00');
    });

    test('daftar harga bertingkat: satuan terpilih, hanya level pelanggan keranjang, urut jumlah', () {
      String rows(String unit, int? levelId) => [for (final tier in teh.tiersFor(unit, levelId: levelId)) '${tier.minQuantity.split('.').first}${tier.level == null ? '' : ' ${tier.level}'}'].join(', ');
      expect(rows('pcs', null), '10, 50');
      expect(rows('pcs', 1), '1 Reseller, 10, 50, 100 Reseller');
      expect(rows('pcs', 2), '1 Member, 10, 50');
      expect(rows('Karton', 1), '1 Reseller, 5');
      expect(rows('karton', 2), '5');
    });
  });

  group('keranjang', () {
    test('ganti pelanggan menghitung ulang harga otomatis; harga manual & baris tanpa barang tetap', () {
      final cart = Cart(lines: [
        CartLine.fromProduct('a', teh, quantity: '10'),
        CartLine.fromProduct('b', teh, unit: 'karton').copyWith(unitPrice: '480000', manualPrice: true),
        const CartLine(key: 'c', description: 'Ongkir', quantity: '1', unit: 'kali', unitPrice: '10000.00'),
      ]);
      List<String> prices(Cart cart) => [for (final line in cart.lines) line.unitPrice];
      expect(prices(cart), ['23000.00', '480000.00', '10000.00']);
      expect(cart.lines.first.priceLabel(cart.levelId), 'harga grosir');

      final asReseller = cart.withCustomer(reseller);
      expect(asReseller.customer?.name, 'Toko Maju');
      expect(asReseller.levelId, 1);
      expect(prices(asReseller), ['22000.00', '480000.00', '10000.00']);
      expect(asReseller.lines[1].manualPrice, isTrue);
      expect(asReseller.lines.first.priceLabel(asReseller.levelId), 'harga Reseller');
      expect(asReseller.lines[1].priceLabel(asReseller.levelId), isNull, reason: 'Harga manual tanpa keterangan.');
      expect(asReseller.lines[2].priceLabel(asReseller.levelId), isNull);

      expect(prices(asReseller.withCustomer(member)), ['23000.00', '480000.00', '10000.00']);
      expect(prices(asReseller.withCustomer(umum)), ['23000.00', '480000.00', '10000.00']);
      final cleared = asReseller.withCustomer(null);
      expect(cleared.customer, isNull);
      expect(prices(cleared), ['23000.00', '480000.00', '10000.00']);

      // Harga biasa (belum ada tingkat yang terpenuhi): tanpa keterangan.
      expect(CartLine.fromProduct('d', teh).priceLabel(null), isNull);
    });

    test('tambah, +/−, ubah jumlah, dan Input AI memakai level pelanggan keranjang', () {
      final container = ProviderContainer(overrides: [workspaceProvider.overrideWith((ref) async => null)]);
      addTearDown(container.dispose);
      final cart = container.read(cartProvider.notifier);
      List<String> prices() => [for (final line in container.read(cartProvider).lines) line.unitPrice];

      cart.add(teh);
      expect(prices(), ['25000.00']);
      cart.setCustomer(reseller);
      expect(prices(), ['22000.00'], reason: 'Pelanggan dipilih: baris yang sudah ada ikut harga level.');

      cart.add(teh, unit: 'karton');
      expect(prices(), ['22000.00', '500000.00']);
      cart.add(teh, quantity: '98');
      expect(container.read(cartProvider).lines.first.quantity, '99.000000');
      expect(prices().first, '21000.00', reason: 'Harga grosir umum (mulai 50) lebih murah dari harga Reseller mulai 1.');
      expect(container.read(cartProvider).lines.first.priceLabel(1), 'harga grosir');
      final key = container.read(cartProvider).lines.first.key;
      cart.step(key, 1);
      expect(prices().first, '19000.00', reason: '100 pcs: harga Reseller mulai 100.');
      cart.step(key, -1);
      expect(prices().first, '21000.00');
      cart.update(key, (line) => line.copyWith(quantity: '100', levelId: container.read(cartProvider).levelId));
      expect(prices().first, '19000.00');

      cart.setCustomer(null);
      expect(prices(), ['21000.00', '550000.00'], reason: 'Pelanggan umum: kembali ke harga umum.');

      cart.clear();
      cart.setCustomer(reseller);
      cart.applyAi(const PosAiResult(items: [PosAiItem(productId: 5, name: 'Teh kotak', quantity: '2.000000', unit: 'pcs')]), {5: teh});
      expect(prices(), ['22000.00']);
    });

    test('pesanan tersimpan membawa level pelanggan (pesanan dari versi lama tetap terbuka)', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      final store = HeldOrderStore(local);
      final cart = Cart(lines: [CartLine.fromProduct('a', teh, quantity: '10')]).withCustomer(reseller);
      final id = await store.save(cart, name: '', total: '220000');
      final held = (await store.find(id))!;
      expect(held.name, 'Toko Maju');
      expect(held.cart.customer?.levelId, 1);
      expect(held.cart.customer?.nameWithLevel, 'Toko Maju · Reseller');
      expect(held.cart.lines.single.product?.levelTiers, hasLength(4));
      expect(held.cart.lines.single.unitPrice, '22000.00');
      expect(held.cart.lines.single.priceLabel(held.cart.levelId), 'harga Reseller');

      final legacy = Cart.fromJson({
        'lines': [
          {'key': 'a', 'product': (Map<String, dynamic>.from(teh.toJson())..remove('level_tiers')), 'description': 'Teh kotak', 'quantity': '1', 'unit': 'pcs', 'unit_price': '25000'},
        ],
        'customer': {'id': 7, 'name': 'Bu Ani'},
      });
      expect(legacy.levelId, isNull);
      expect(legacy.lines.single.product?.levelTiers, isEmpty);
      expect(legacy.withCustomer(reseller).lines.single.unitPrice, '25000.00', reason: 'Barang dari cache lama belum punya harga level.');
    });

    test('database versi 3 dinaikkan ke 4: tarikan berikutnya penuh supaya harga level terisi', () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('infois_level');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/v3.db';
      final old = await databaseFactoryFfiNoIsolate.openDatabase(path, options: OpenDatabaseOptions(version: 3, onCreate: (db, _) async {
        await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
        await db.insert('meta', {'key': MetaKeys.cursor, 'value': '2026-11-01T00:00:00Z'});
        await db.insert('meta', {'key': MetaKeys.lastFullPull, 'value': '2026-11-01T00:00:00Z'});
        await db.insert('meta', {'key': 'x', 'value': 'tetap'});
      }));
      await old.close();

      final local = await LocalDb.open(path, factory: databaseFactoryFfiNoIsolate);
      addTearDown(local.close);
      expect(await local.getMeta(MetaKeys.cursor), isNull);
      expect(await local.getMeta(MetaKeys.lastFullPull), isNull);
      expect(await local.getMeta('x'), 'tetap');
    });
  });

  group('tampilan', () {
    Future<ProviderContainer> pumpSheet(WidgetTester tester, Product product, {Customer? customer}) async {
      final container = ProviderContainer(overrides: [workspaceProvider.overrideWith((ref) async => null)]);
      addTearDown(container.dispose);
      container.read(cartProvider.notifier).setCustomer(customer);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: PosItemSheet(product: product))),
      ));
      await tester.pump();
      return container;
    }

    Finder row(String key) => find.byKey(Key(key));
    bool active(WidgetTester tester, String key) => find.descendant(of: row(key), matching: find.byKey(const Key('price-row-check'))).evaluate().isNotEmpty;
    List<String> activeRows(WidgetTester tester) => [
          for (final key in ['price-row-normal', for (var i = 0; i < 6; i++) 'price-row-$i'])
            if (row(key).evaluate().isNotEmpty && active(tester, key)) key,
        ];

    testWidgets('lembar barang: Harga bertingkat dengan baris yang berlaku disorot, tanpa chip catatan cepat', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pumpSheet(tester, teh);

      expect(find.text('Harga bertingkat'), findsOneWidget);
      expect(find.descendant(of: row('price-row-normal'), matching: find.text('Harga normal')), findsOneWidget);
      expect(find.descendant(of: row('price-row-normal'), matching: find.text('Rp 25.000')), findsOneWidget);
      expect(find.descendant(of: row('price-row-0'), matching: find.text('Mulai 10 pcs')), findsOneWidget);
      expect(find.descendant(of: row('price-row-1'), matching: find.text('Mulai 50 pcs')), findsOneWidget);
      expect(row('price-row-2'), findsNothing, reason: 'Tanpa pelanggan: harga level tidak ditampilkan.');
      expect(find.textContaining('Reseller'), findsNothing);
      expect(activeRows(tester), ['price-row-normal']);

      for (var i = 0; i < 9; i++) {
        await tester.tap(find.byKey(const Key('item-qty-plus')));
        await tester.pump();
      }
      expect((tester.widget(find.byKey(const Key('item-qty'))) as Text).data, '10');
      expect(activeRows(tester), ['price-row-0']);
      expect(find.text('Tambah · Rp 230.000'), findsOneWidget);

      // Satuan karton: hanya tingkat karton.
      await tester.tap(find.byKey(const Key('item-unit-karton')));
      await tester.pump();
      expect(find.descendant(of: row('price-row-0'), matching: find.text('Mulai 5 karton')), findsOneWidget);
      expect(row('price-row-1'), findsNothing);
      expect(activeRows(tester), ['price-row-0']);

      // Catatan barang: isian bebas dengan contoh netral, tanpa chip.
      expect(find.byType(ActionChip), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const Key('item-note'))).decoration?.hintText, 'mis. warna, ukuran, atau permintaan khusus');
      for (final preset in ['Tanpa gula', 'Pedas', 'Dibungkus']) {
        expect(find.text(preset), findsNothing);
      }
    });

    testWidgets('lembar barang: baris level pelanggan keranjang diberi nama level', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pumpSheet(tester, teh, customer: reseller);

      expect(find.descendant(of: row('price-row-0'), matching: find.text('Mulai 1 pcs · Reseller')), findsOneWidget);
      expect(find.descendant(of: row('price-row-0'), matching: find.text('Rp 22.000')), findsOneWidget);
      expect(find.descendant(of: row('price-row-1'), matching: find.text('Mulai 10 pcs')), findsOneWidget);
      expect(find.descendant(of: row('price-row-3'), matching: find.text('Mulai 100 pcs · Reseller')), findsOneWidget);
      expect(find.textContaining('Member'), findsNothing, reason: 'Hanya level pelanggan keranjang.');
      expect(activeRows(tester), ['price-row-0']);
      expect(find.text('Tambah · Rp 22.000'), findsOneWidget);
    });

    testWidgets('lembar barang tanpa harga bertingkat: bagian Harga bertingkat tidak tampil', (tester) async {
      await pumpSheet(tester, kopi, customer: reseller);
      expect(find.text('Harga bertingkat'), findsNothing);
      expect(find.byKey(const Key('item-price-tiers')), findsNothing);
    });

    testWidgets('panel pesanan: pelanggan dengan level, harga ikut level, keterangan harga di baris', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'session': jsonEncode({
          'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
          'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, shift: true, addCustomer: true)).toJson()],
        }),
        'tenant_id': 1,
      });
      FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
      final storage = await AppStorage.load();
      final local = await tester.runAsync(() async {
        final db = await memoryDb();
        await seedMaster(db);
        await db.upsertProducts([teh]);
        await db.upsertCustomers([reseller]);
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

      Finder inPanel(Finder finder) => find.descendant(of: find.byType(PosOrderPanel), matching: finder);

      // Teh kotak punya satuan karton: ketuk = pilih satuan dulu.
      await tap(find.byKey(const Key('product-5')));
      await tap(find.byKey(const Key('unit-pick-pcs')));
      await tap(find.byKey(const Key('open-cart')));
      final container = ProviderScope.containerOf(tester.element(find.byType(PosOrderPanel)));
      final key = container.read(cartProvider).lines.single.key;
      // Panel bergulir (ListView malas): gulir ke atas bila baris barang tidak terbangun.
      Future<String> priceText() async {
        final finder = inPanel(find.byKey(Key('line-price-$key')));
        if (finder.evaluate().isEmpty) {
          await tester.drag(find.descendant(of: find.byType(PosOrderPanel), matching: find.byType(Scrollable)).first, const Offset(0, 3000));
          await settle(tester);
        }
        return (tester.widget(finder) as Text).data!;
      }

      expect(await priceText(), 'pcs × Rp 25.000');

      // Pilih pelanggan Reseller: level tampil di daftar dan di panel, harga turun.
      await tap(find.byKey(const Key('order-customer')));
      expect(find.text('Reseller · 0813'), findsOneWidget);
      expect(find.text('0812'), findsOneWidget, reason: 'Pelanggan tanpa level: hanya no. HP.');
      await tap(find.text('Toko Maju'));
      expect(inPanel(find.text('Toko Maju · Reseller')), findsOneWidget);
      expect(await priceText(), 'pcs × Rp 22.000 · harga Reseller');
      expect(inPanel(find.text('Rp 22.000')), findsWidgets);

      // Ubah jumlah lewat lembar ubah baris: tetap harga level.
      await tap(find.byKey(Key('line-tap-$key')));
      expect(find.text('Harga diubah manual'), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const Key('line-note'))).decoration?.hintText, 'mis. warna, ukuran, atau permintaan khusus');
      expect(find.byType(ActionChip), findsNothing);
      await tester.enterText(find.byKey(const Key('line-quantity')), '100');
      await tap(find.byKey(const Key('line-save')));
      expect(await priceText(), 'pcs × Rp 19.000 · harga Reseller');

      // Kembali ke pelanggan umum: harga grosir umum.
      await tap(find.byKey(const Key('order-customer')));
      await tap(find.text('Pelanggan umum'));
      expect(inPanel(find.text('Pelanggan umum')), findsOneWidget);
      expect(await priceText(), 'pcs × Rp 21.000 · harga grosir');
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
