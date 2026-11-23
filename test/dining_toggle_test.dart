import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/kasir_screen.dart';
import 'package:infois/ui/screens/pos_order_panel.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Fitur rumah makan / kafe bisa dimatikan (`tenant.pos_dining`): jenis
/// pesanan dan meja/antrian disembunyikan dan tidak dikirim; "Cetak list"
/// setelah bayar tetap ada (juga untuk toko eceran).
/// Pesanan tersimpan yang dibuka lagi memakai pelanggan & katalog terbaru.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  const tenantBase = {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'};

  Future<LocalDb> seeded({Object? dining = _missing, Future<void> Function(LocalDb local)? extra}) async {
    final local = await memoryDb();
    await seedMaster(local, menus: {'pos': true, 'printer': true, 'add_customer': true});
    await local.setJson(MetaKeys.tenant, {...tenantBase, if (dining != _missing) 'pos_dining': dining});
    await extra?.call(local);
    return local;
  }

  Future<ProviderContainer> pumpApp(WidgetTester tester, LocalDb local) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, printer: true, addCustomer: true)).toJson()],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(offlineServer())),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(FakePrinter()),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(KasirScreen)));
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await settle(tester);
  }

  Finder inPanel(Finder finder) => find.descendant(of: find.byType(PosOrderPanel), matching: finder);

  test('tenant.pos_dining: tidak ada / null = nyala (server lama); false = mati', () {
    expect(TenantSettings.fromJson(tenantBase).posDining, isTrue);
    expect(TenantSettings.fromJson({...tenantBase, 'pos_dining': null}).posDining, isTrue);
    expect(TenantSettings.fromJson({...tenantBase, 'pos_dining': true}).posDining, isTrue);
    expect(TenantSettings.fromJson({...tenantBase, 'pos_dining': false}).posDining, isFalse);
    expect(TenantSettings.fromJson({...tenantBase, 'pos_dining': 0}).posDining, isFalse);
    final off = TenantSettings.fromJson({...tenantBase, 'pos_dining': false});
    expect(TenantSettings.fromJson(off.toJson()).posDining, isFalse);
  });

  test('PosService: fitur rumah makan mati → order_type/order_label tidak dikirim walau keranjang lama membawanya', () async {
    for (final (dining, type, label) in [(false, null, null), (true, 'take_away', 'Meja 3')]) {
      final local = await seeded(dining: dining);
      addTearDown(local.close);
      final master = await loadMaster(local);
      expect(master.tenant.posDining, dining);
      final pos = PosService(local: local, user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'), master: master);
      final cart = Cart(lines: [CartLine.fromProduct('a', kopi)], orderType: OrderType.takeAway, orderLabel: 'Meja 3', note: 'Dikirim sore');
      final sale = await pos.checkout(clientUuid: PosService.newUuid(), cart: cart, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '20000'));
      expect((sale['order_type'], sale['order_label']), (type, label));
      final push = (await OutboxStore(local).pending()).single.data;
      expect(push.containsKey('order_type'), dining, reason: 'dining $dining');
      expect(push.containsKey('order_label'), dining);
      expect(push['notes'], 'Dikirim sore', reason: 'Catatan pesanan tetap terkirim.');
    }
  });

  testWidgets('fitur rumah makan mati: tanpa jenis pesanan & meja/antrian, Cetak list tetap ada; penjualan tanpa order_type', (tester) async {
    final local = (await tester.runAsync(() => seeded(dining: false)))!;
    final container = await pumpApp(tester, local);

    await tap(tester, find.byKey(const Key('product-1')));
    // Keranjang/pesanan tersimpan lama yang masih membawa jenis pesanan & meja.
    container.read(cartProvider.notifier)
      ..setOrderType(OrderType.takeAway)
      ..setOrderLabel('Meja 3');
    await settle(tester);
    expect(find.textContaining('Bawa pulang'), findsNothing, reason: 'Bilah keranjang tanpa jenis pesanan.');
    expect(find.textContaining('Meja 3'), findsNothing);

    await tap(tester, find.byKey(const Key('open-cart')));
    for (final key in ['order-type-dine_in', 'order-type-take_away', 'order-type-delivery', 'order-label']) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    expect(inPanel(find.text('Meja / antrian')), findsNothing);
    expect(inPanel(find.text('mis. dikirim sore, nota dipisah')), findsOneWidget);
    expect(inPanel(find.byKey(const Key('order-customer'))), findsOneWidget);

    await tap(tester, find.byKey(const Key('go-pay')));
    expect(find.byKey(const Key('pay-order-info')), findsNothing);
    await tap(tester, find.byKey(const Key('pay-submit')));
    expect(find.text('Penjualan tersimpan'), findsOneWidget);
    expect(find.byKey(const Key('print-receipt')), findsOneWidget);
    // "Cetak list" (dulu Pesanan dapur) dipakai juga untuk menyiapkan barang: selalu ada.
    expect(find.byKey(const Key('print-kitchen')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('print-kitchen')), matching: find.text('Cetak list')), findsOneWidget);
    expect(find.text('Pesanan dapur'), findsNothing);

    final push = (await tester.runAsync(() => OutboxStore(local).pending()))!.single.data;
    expect(push, isNot(contains('order_type')));
    expect(push, isNot(contains('order_label')));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(local.close);
  });

  testWidgets('server lama tanpa pos_dining: jenis pesanan, meja/antrian, dan Cetak list tetap tampil', (tester) async {
    final local = (await tester.runAsync(() => seeded()))!;
    await pumpApp(tester, local);

    await tap(tester, find.byKey(const Key('product-1')));
    await tap(tester, find.byKey(const Key('open-cart')));
    expect(find.byKey(const Key('order-type-take_away')), findsOneWidget);
    expect(find.byKey(const Key('order-label')), findsOneWidget);
    await tap(tester, find.byKey(const Key('order-type-take_away')));
    await tap(tester, find.byKey(const Key('order-label')));
    expect(find.widgetWithText(ActionChip, 'Meja'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Antrian'), findsNothing, reason: 'Nomor antrian otomatis (tanpa saran "Antrian").');
    expect(find.text('Atur daftar meja di web: Pengaturan Kasir.'), findsOneWidget, reason: 'Tanpa daftar meja: isian bebas + petunjuk.');
    await tester.enterText(find.byKey(const Key('order-label-field')), 'Meja 5');
    await tap(tester, find.byKey(const Key('text-save')));

    await tap(tester, find.byKey(const Key('go-pay')));
    expect(find.text('Bawa pulang · Meja 5'), findsOneWidget);
    await tap(tester, find.byKey(const Key('pay-submit')));
    expect(find.byKey(const Key('print-kitchen')), findsOneWidget);
    final push = (await tester.runAsync(() => OutboxStore(local).pending()))!.single.data;
    expect((push['order_type'], push['order_label']), ('take_away', 'Meja 5'));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(local.close);
  });

  group('pesanan tersimpan dibuka lagi', () {
    // Saat disimpan: harga lama, pelanggan belum punya level.
    const tehLama = Product(
      id: 5,
      name: 'Teh kotak',
      unit: 'pcs',
      price: '26000.00',
      tiers: [PriceTier(unit: 'pcs', minQuantity: '10.000000', price: '24000.00')],
    );
    // Sekarang di katalog HP: harga baru + harga Reseller.
    const tehBaru = Product(
      id: 5,
      name: 'Teh kotak',
      unit: 'pcs',
      price: '25000.00',
      units: [UnitOption(name: 'karton', factor: '24.000000', price: '550000.00')],
      tiers: [PriceTier(unit: 'pcs', minQuantity: '10.000000', price: '23000.00')],
      levelTiers: [PriceTier(unit: 'pcs', minQuantity: '1.000000', price: '22000.00', levelId: 1, level: 'Reseller')],
    );
    const tokoLama = Customer(id: 8, name: 'Toko Maju', phone: '0813');
    const tokoReseller = Customer(id: 8, name: 'Toko Maju', phone: '0813', levelId: 1, level: 'Reseller');

    Cart heldCart() => Cart(
          lines: [
            CartLine.fromProduct('a', tehLama, quantity: '10'),
            CartLine.fromProduct('b', tehLama, quantity: '2').copyWith(unitPrice: '20000', manualPrice: true),
            const CartLine(key: 'c', description: 'Ongkir', quantity: '1', unit: 'kali', unitPrice: '10000.00'),
          ],
          customer: tokoLama,
        );

    test('Cart.reopened: katalog & level terbaru; harga manual, baris tanpa barang, dan satuan yang hilang tetap', () {
      final cart = heldCart();
      expect([for (final line in cart.lines) line.unitPrice], ['24000.00', '20000.00', '10000.00']);

      final reopened = cart.reopened(customer: tokoReseller, catalog: {5: tehBaru});
      expect(reopened.customer?.nameWithLevel, 'Toko Maju · Reseller');
      expect([for (final line in reopened.lines) line.unitPrice], ['22000.00', '20000.00', '10000.00']);
      expect(reopened.lines.first.product?.levelTiers, hasLength(1), reason: 'Data barang diganti dengan katalog terbaru.');
      expect(reopened.lines.first.priceLabel(reopened.levelId), 'harga Reseller');
      expect(reopened.lines[1].manualPrice, isTrue);
      expect(identical(reopened.lines[1].product, tehLama), isTrue, reason: 'Baris harga manual tidak disentuh.');

      // Pelanggan tidak ada lagi di HP: data tersimpan tetap, harga ikut katalog terbaru.
      expect([for (final line in cart.reopened(catalog: {5: tehBaru}).lines) line.unitPrice], ['23000.00', '20000.00', '10000.00']);
      // Barang tidak ada lagi di katalog: data barang tersimpan yang dipakai.
      expect(cart.reopened(customer: tokoReseller).lines.first.unitPrice, '24000.00');

      // Satuan baris sudah dihapus dari barang: baris tetap (tidak jatuh ke harga satuan dasar).
      final karton = Cart(lines: [CartLine.fromProduct('k', tehBaru, unit: 'karton')]);
      const tanpaKarton = Product(id: 5, name: 'Teh kotak', unit: 'pcs', price: '25000.00');
      final kept = karton.reopened(catalog: {5: tanpaKarton}).lines.single;
      expect((kept.unit, kept.unitPrice, identical(kept.product, tehBaru)), ('karton', '550000.00', true));
    });

    test('LocalDb.customerFor: cocok id, atau client_uuid untuk pelanggan buatan HP', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      await local.upsertCustomers([tokoReseller, const Customer(clientUuid: 'u-1', name: 'Baru', pending: true)]);
      expect((await local.customerFor(tokoLama))?.level, 'Reseller');
      expect((await local.customerFor(const Customer(clientUuid: 'u-1', name: 'Baru')))?.name, 'Baru');
      expect(await local.customerFor(const Customer(id: 99, name: 'Hilang')), isNull);
    });

    testWidgets('kasir: daftar menampilkan level pelanggan; dibuka = level & katalog terbaru, harga manual tetap', (tester) async {
      String? heldId;
      final local = (await tester.runAsync(() => seeded(extra: (local) async {
            final store = HeldOrderStore(local);
            heldId = await store.save(heldCart(), name: '', total: '290000');
            await store.save(Cart(lines: [CartLine.fromProduct('m', kopi)], customer: const Customer(id: 9, name: 'Pak Budi', levelId: 2, level: 'Member')), name: 'Titipan sore', total: '18000');
            // Setelah disimpan: level pelanggan & harga barang berubah di web, lalu tersinkron.
            await local.upsertProducts([tehBaru]);
            await local.upsertCustomers([tokoReseller]);
          })))!;
      final container = await pumpApp(tester, local);

      await tap(tester, find.byKey(const Key('held-orders')));
      expect(find.textContaining('Pak Budi · Member'), findsOneWidget, reason: 'Nama pesanan lain: pelanggan "{nama} · {level}".');
      expect(find.textContaining('Toko Maju ·'), findsNothing, reason: 'Disimpan saat Toko Maju belum punya level.');

      await tap(tester, find.byKey(Key('held-$heldId')));
      final cart = container.read(cartProvider);
      expect(cart.heldId, heldId);
      expect(cart.customer?.levelId, 1);
      expect([for (final line in cart.lines) (line.unitPrice, line.manualPrice)], [('22000.00', false), ('20000.00', true), ('10000.00', false)]);

      await tap(tester, find.byKey(const Key('open-cart')));
      expect(inPanel(find.text('Toko Maju · Reseller')), findsOneWidget);
      expect((tester.widget(inPanel(find.byKey(const Key('line-price-a')))) as Text).data, 'pcs × Rp 22.000 · harga Reseller');
      expect((tester.widget(inPanel(find.byKey(const Key('line-price-b')))) as Text).data, 'pcs × Rp 20.000');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });
  });
}

const Object _missing = Object();

/// Data kasir dari database HP (sama dengan `masterDataProvider`).
Future<MasterData> loadMaster(LocalDb local) async {
  final accounts = (await local.getJson(MetaKeys.accounts))!;
  return MasterData(
    tenant: TenantSettings.fromJson((await local.getJson(MetaKeys.tenant))!),
    receipt: ReceiptConfig.fromJson((await local.getJson(MetaKeys.receipt))!),
    accounts: [for (final account in accounts['items'] as List) CashAccount.fromJson(Map<String, dynamic>.from(account as Map))],
    menus: const Menus(pos: true),
    defaultCashId: 11,
    defaultTransferId: 12,
    productCount: 2,
  );
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
