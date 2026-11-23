import 'dart:convert';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/printing/receipt_builder.dart';
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

/// Alamat pengiriman (hanya bila barang dikirim) dan Pengaturan kasir di
/// aplikasi (fitur rumah makan / kafe untuk semua kasir). Sama dengan kasir web.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  const ongkir = CartCharge(key: 'c1', name: 'Ongkos kirim', amount: '10000.00');
  const layanan = CartCharge(key: 'c2', name: 'Biaya layanan', amount: '2000.00');
  const alamat = 'Jl. Melati 5, RT 02\nDekat masjid';
  const bima = Customer(id: 8, name: 'Pak Bima', phone: '0813', address: 'Jl. Kenanga 12, Sukamaju');

  group('alamat pengiriman', () {
    test('hanya bila barang dikirim: Pesan antar, atau biaya kirim/antar/ongkir/ekspedisi', () {
      final base = Cart(lines: [CartLine.fromProduct('a', kopi)], deliveryAddress: alamat);
      expect(base.needsDelivery(), isFalse);
      expect(base.deliveryAddressFor(), isNull, reason: 'Tidak dikirim: alamat tidak dipakai.');
      expect(base.copyWith(charges: const [layanan]).needsDelivery(), isFalse);
      for (final name in ['Ongkos kirim', 'ONGKIR', 'Biaya antar', 'Ekspedisi JNE', 'Biaya kirim barang', 'Biaya pengiriman', 'Kurir']) {
        expect(base.copyWith(charges: [CartCharge(key: 'x', name: name, amount: '1')]).needsDelivery(), isTrue, reason: name);
      }
      final delivery = base.copyWith(orderType: OrderType.delivery);
      expect(delivery.needsDelivery(), isTrue);
      expect(delivery.deliveryAddressFor(), alamat);
      expect(delivery.needsDelivery(dining: false), isFalse, reason: 'Fitur rumah makan mati: jenis pesanan lama tidak dihitung.');
      expect(base.copyWith(charges: const [ongkir]).deliveryAddressFor(dining: false), alamat);
      expect(Cart(charges: const [ongkir], deliveryAddress: '   ').deliveryAddressFor(), isNull);
      expect(base.copyWith(deliveryAddress: '').deliveryAddress, isNull, reason: 'Kosong = hapus.');
      expect(base.copyWith(deliveryAddress: 'x' * 600).deliveryAddress, hasLength(500));
    });

    test('keranjang JSON & pesanan tersimpan membawa alamat; JSON lama tanpa kunci = tanpa alamat', () async {
      final cart = Cart(lines: [CartLine.fromProduct('a', kopi)], charges: const [ongkir], deliveryAddress: alamat, customer: bima);
      final copy = Cart.fromJson(jsonDecode(jsonEncode(cart.toJson())) as Map<String, dynamic>);
      expect(copy.deliveryAddress, alamat);
      expect(copy.customer?.address, 'Jl. Kenanga 12, Sukamaju');
      expect(copy.withCustomer(null).deliveryAddress, alamat);
      expect(Cart.fromJson(Map<String, dynamic>.from(cart.toJson())..remove('delivery_address')).deliveryAddress, isNull);

      final local = await memoryDb();
      addTearDown(local.close);
      final store = HeldOrderStore(local);
      final id = await store.save(cart, name: 'Kirim sore', total: '28000');
      expect((await store.find(id))!.cart.deliveryAddress, alamat);
    });

    test('pelanggan: alamat dari sync/pull ikut disimpan', () {
      final customer = Customer.fromJson({'id': 8, 'name': 'Pak Bima', 'address': 'Jl. Kenanga 12'});
      expect(Customer.fromJson(customer.toJson()).address, 'Jl. Kenanga 12');
    });

    test('penjualan: delivery_address dikirim (dirapikan) hanya bila barang dikirim; struk, tagihan, list mencetak "Kirim ke:"', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      await seedMaster(local);
      final pos = PosService(local: local, user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'), master: await _master(local));
      final builder = await ReceiptBuilder.create();
      const config = ReceiptConfig(companyName: 'Warung Tes');
      String text(List<int> bytes) => latin1.decode(bytes, allowInvalid: true);

      final delivered = Cart(lines: [CartLine.fromProduct('a', kopi)], charges: const [ongkir], deliveryAddress: '  $alamat  ');
      final sale = await pos.checkout(clientUuid: PosService.newUuid(), cart: delivered, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '30000'));
      expect(sale['delivery_address'], alamat);
      final draft = pos.draft(delivered);
      expect(draft['delivery_address'], alamat);
      for (final printed in [text(builder.sale(sale, config, width: 58)), text(builder.bill(draft, config, width: 58)), text(builder.orderList(draft, config, width: 58)), text(builder.orderList(sale, config, width: 58))]) {
        expect(printed, allOf(contains('Kirim ke:'), contains('Jl. Melati 5, RT 02'), contains('Dekat masjid')));
      }
      expect(ReceiptBuilder.plainText(sale, config), contains('Kirim ke: Jl. Melati 5, RT 02'));

      // Alamat terisi tapi barang tidak dikirim (biaya ongkir dihapus): tidak dikirim, tidak dicetak.
      final pickup = delivered.copyWith(charges: const [layanan]);
      final plain = await pos.checkout(clientUuid: PosService.newUuid(), cart: pickup, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '30000'));
      expect(plain['delivery_address'], isNull);
      expect(text(builder.sale(plain, config, width: 58)), isNot(contains('Kirim ke:')));
      expect(text(builder.bill(pos.draft(pickup), config, width: 58)), isNot(contains('Kirim ke:')));

      final pushed = [for (final item in await OutboxStore(local).pending()) item.data];
      expect(pushed.first['delivery_address'], alamat);
      expect(pushed.last, isNot(contains('delivery_address')));
    });
  });

  group('kasir', () {
    Future<(LocalDb, ProviderContainer, FakeServer)> pumpApp(
      WidgetTester tester, {
      Map<String, dynamic>? menus,
      Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body)? handler,
    }) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'session': jsonEncode({
          'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
          'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Pemilik', menus: Menus(pos: true, printer: true)).toJson()],
        }),
        'tenant_id': 1,
      });
      FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
      final storage = await AppStorage.load();
      final local = (await tester.runAsync(() async {
        final db = await memoryDb();
        await seedMaster(db, menus: menus ?? {'pos': true, 'printer': true});
        await db.upsertCustomers([bima]);
        return db;
      }))!;
      final server = FakeServer(handler ?? (_, __) => null);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          localDbOpenerProvider.overrideWithValue((_) async => local),
          apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
          connectivityStreamProvider.overrideWithValue(const Stream.empty()),
          printerTransportProvider.overrideWithValue(FakePrinter()),
        ],
        child: const InfoisApp(),
      ));
      await settle(tester);
      return (local, ProviderScope.containerOf(tester.element(find.byType(KasirScreen))), server);
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await settle(tester);
    }

    Finder inPanel(Finder finder) => find.descendant(of: find.byType(PosOrderPanel), matching: finder);

    testWidgets('baris Alamat pengiriman: hanya dengan Pesan antar / ongkos kirim; isian awal dari alamat pelanggan', (tester) async {
      final (local, container, _) = await pumpApp(tester);
      final cart = container.read(cartProvider.notifier);

      await tap(tester, find.byKey(const Key('product-1')));
      expect(find.byKey(const Key('order-delivery')), findsNothing);

      // Ongkos kirim → baris muncul.
      cart.addCharge('Ongkos kirim', '10000');
      await settle(tester);
      expect(inPanel(find.text('Alamat pengiriman')), findsOneWidget);
      expect(inPanel(find.text('Tercetak di tagihan, struk, dan list')), findsOneWidget);

      // Pelanggan dengan alamat: isian awal = alamat pelanggan.
      cart.setCustomer(bima);
      await settle(tester);
      await tap(tester, find.byKey(const Key('order-delivery')));
      expect(find.text('Alamat pengiriman'), findsWidgets);
      final field = tester.widget<TextField>(find.byKey(const Key('delivery-address-field')));
      expect(field.controller?.text, 'Jl. Kenanga 12, Sukamaju');
      expect(field.decoration?.hintText, 'Jalan, nomor, kelurahan, patokan');
      expect(field.maxLength, 500);
      await tester.enterText(find.byKey(const Key('delivery-address-field')), 'Jl. Kenanga 12, rumah pagar hijau');
      await tap(tester, find.byKey(const Key('text-save')));
      expect(container.read(cartProvider).deliveryAddress, 'Jl. Kenanga 12, rumah pagar hijau');
      expect(inPanel(find.text('Jl. Kenanga 12, rumah pagar hijau')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('order-delivery')), matching: find.text('Alamat pengiriman')), findsOneWidget);

      // Biaya dihapus: baris hilang (alamat tidak dikirim). Pesan antar: muncul lagi.
      cart.removeCharge(container.read(cartProvider).charges.single.key);
      await settle(tester);
      expect(find.byKey(const Key('order-delivery')), findsNothing);
      cart.setOrderType(OrderType.delivery);
      await settle(tester);
      expect(find.byKey(const Key('order-delivery')), findsOneWidget);

      // Isian awal yang sudah terisi = alamat keranjang, bukan alamat pelanggan.
      await tap(tester, find.byKey(const Key('order-delivery')));
      expect(tester.widget<TextField>(find.byKey(const Key('delivery-address-field'))).controller?.text, 'Jl. Kenanga 12, rumah pagar hijau');
      await tap(tester, find.text('Batal'));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('Pengaturan kasir tanpa hak mengelola: hanya printer', (tester) async {
      final (local, container, _) = await pumpApp(tester);
      GoRouter.of(tester.element(find.byType(KasirScreen))).push('/printer');
      await settle(tester);
      expect(find.text('Pengaturan kasir'), findsOneWidget);
      expect(find.text('Untuk semua kasir di usaha ini'), findsNothing);
      expect(find.byKey(const Key('pos-settings-dining')), findsNothing);
      expect(find.text('Printer kasir'), findsOneWidget);
      expect(find.text('Printer dapur'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('Pengaturan kasir: fitur rumah makan disimpan ke server lalu langsung dipakai; gagal = nilai lama', (tester) async {
      var fail = false;
      final (local, container, server) = await pumpApp(
        tester,
        menus: {'pos': true, 'printer': true, 'pos_settings': true},
        handler: (options, body) {
          if (options.path != 'pos/settings') {
            return null;
          }
          return fail
              ? {'_status': 403, 'message': 'Anda tidak punya hak mengubah pengaturan kasir.', 'code': 'tidak_berhak'}
              : {
                  'settings': {'shift_required': false, 'dining': body?['dining']},
                };
        },
      );
      expect((await tester.runAsync(() => container.read(masterDataProvider.future)))!.tenant.posDining, isTrue, reason: 'Server lama tanpa pos_dining.');
      GoRouter.of(tester.element(find.byType(KasirScreen))).push('/printer');
      await settle(tester);
      expect(find.text('Untuk semua kasir di usaha ini'), findsOneWidget);
      expect(find.text('Printer di perangkat ini'), findsOneWidget);
      expect(find.text('Fitur rumah makan / kafe (jenis pesanan, meja/antrian)'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNWidgets(3), reason: 'Fitur rumah makan + cetak struk otomatis + list dapur otomatis (tanpa pilihan shift wajib).');
      bool switchValue() => tester.widget<SwitchListTile>(find.byKey(const Key('pos-settings-dining'))).value;
      expect(switchValue(), isTrue);

      await tap(tester, find.byKey(const Key('pos-settings-dining')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      final request = server.requests.where((options) => options.path == 'pos/settings').single;
      expect(request.method, 'PUT');
      expect(request.data, {'dining': false});
      expect(switchValue(), isFalse);
      expect(find.text('Fitur rumah makan / kafe dimatikan untuk semua kasir.'), findsOneWidget);
      expect((await tester.runAsync(() => local.getJson(MetaKeys.tenant)))!['pos_dining'], isFalse);
      expect((await tester.runAsync(() => container.read(masterDataProvider.future)))!.tenant.posDining, isFalse);

      // Server menolak: pesan biasa, nilai tetap.
      fail = true;
      await tap(tester, find.byKey(const Key('pos-settings-dining')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      expect(find.text('Anda tidak punya hak mengubah pengaturan kasir.'), findsOneWidget);
      expect(switchValue(), isFalse);
      expect((await tester.runAsync(() => local.getJson(MetaKeys.tenant)))!['pos_dining'], isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('Pengaturan kasir offline: pesan butuh internet, nilai tetap', (tester) async {
      final (local, container, _) = await pumpApp(tester, menus: {'pos': true, 'printer': true, 'pos_settings': true});
      GoRouter.of(tester.element(find.byType(KasirScreen))).push('/printer');
      await settle(tester);
      await tap(tester, find.byKey(const Key('pos-settings-dining')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      expect(find.text('Butuh internet untuk mengubah pengaturan ini. Sambungkan internet lalu coba lagi.'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('pos-settings-dining'))).value, isTrue);
      expect((await tester.runAsync(() => container.read(masterDataProvider.future)))!.tenant.posDining, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });
  });
}

Future<MasterData> _master(LocalDb local) async {
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
