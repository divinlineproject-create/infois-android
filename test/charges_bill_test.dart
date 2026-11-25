import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/core/money.dart';
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

/// Biaya tambahan nota (ongkos kirim, ...) dan cetak sebelum dibayar
/// (Cetak tagihan / Cetak list) dari panel pesanan. Sama dengan kasir web.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  const beras = Product(id: 5, name: 'Beras', unit: 'karung', price: '100000.00', taxRate: '11.00');
  const ongkir = CartCharge(key: 'c1', name: 'Ongkos kirim', amount: '15000.00');
  Cart contoh() => Cart(lines: [CartLine.fromProduct('a', beras)], notaDiscountPercent: '10.00', charges: const [ongkir]);

  Future<(LocalDb, PosService)> service({bool dining = true}) async {
    final local = await memoryDb();
    await seedMaster(local);
    await local.setJson(MetaKeys.tenant, {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00', 'pos_dining': dining});
    final accounts = (await local.getJson(MetaKeys.accounts))!;
    final pos = PosService(
      local: local,
      user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'),
      master: MasterData(
        tenant: TenantSettings.fromJson((await local.getJson(MetaKeys.tenant))!),
        receipt: ReceiptConfig.fromJson((await local.getJson(MetaKeys.receipt))!),
        accounts: [for (final account in accounts['items'] as List) CashAccount.fromJson(Map<String, dynamic>.from(account as Map))],
        menus: const Menus(pos: true),
        defaultCashId: 11,
        defaultTransferId: 12,
        productCount: 2,
      ),
    );
    return (local, pos);
  }

  group('hitungan', () {
    test('biaya tambahan ikut total, tidak kena diskon nota & pajak (paritas kasir web: 114.900)', () {
      final cart = contoh();
      final totals = cart.totals(pricesIncludeTax: false);
      expect(cart.chargesTotal, '15000.00');
      expect(totals.toJson(), {'subtotal': '115000.00', 'discount_total': '10000.00', 'tax_total': '9900.00', 'total': '114900.00'});
      expect(Money.sub(totals.subtotal, cart.chargesTotal), '100000.00', reason: 'Subtotal barang di panel.');

      // Harga termasuk pajak: biaya tetap utuh (tanpa pajak).
      expect(cart.totals(pricesIncludeTax: true).total, '105000.00', reason: '90.000 (sudah termasuk PPN) + 15.000.');

      expect(const Cart().chargesTotal, '0.00');
      expect(Cart(lines: [CartLine.fromProduct('a', beras)]).totals(pricesIncludeTax: false).total, '111000.00');
    });

    test('keranjang JSON & pesanan tersimpan membawa biaya; JSON lama tanpa charges = tanpa biaya', () async {
      final cart = contoh();
      final copy = Cart.fromJson(jsonDecode(jsonEncode(cart.toJson())) as Map<String, dynamic>);
      expect([for (final charge in copy.charges) (charge.key, charge.name, charge.amount)], [('c1', 'Ongkos kirim', '15000.00')]);
      expect(copy.totals(pricesIncludeTax: false).total, '114900.00');
      expect(copy.withCustomer(null).charges, hasLength(1), reason: 'Ganti pelanggan tidak menghapus biaya.');
      expect(copy.reopened().charges, hasLength(1));

      final legacy = Map<String, dynamic>.from(cart.toJson())..remove('charges');
      expect(Cart.fromJson(legacy).charges, isEmpty);

      final local = await memoryDb();
      addTearDown(local.close);
      final store = HeldOrderStore(local);
      final id = await store.save(cart, name: 'Antar sore', total: cart.totals(pricesIncludeTax: false).total);
      final held = (await store.find(id))!;
      expect(held.total, '114900.00');
      expect(held.cart.charges.single.name, 'Ongkos kirim');
    });

    test('tambah/hapus biaya di keranjang: nama dirapikan (maks. 60), nominal dinormalkan', () {
      final container = ProviderContainer(overrides: [workspaceProvider.overrideWith((ref) async => null)]);
      addTearDown(container.dispose);
      final cart = container.read(cartProvider.notifier)
        ..addCharge('  Ongkos kirim ', '15000')
        ..addCharge('   ', '1000')
        ..addCharge('x' * 80, '2500');
      final charges = container.read(cartProvider).charges;
      expect([for (final charge in charges) (charge.name.length, charge.amount)], [(12, '15000.00'), (60, '2500.00')]);
      expect(charges.first.name, 'Ongkos kirim');
      cart.removeCharge(charges.first.key);
      expect(container.read(cartProvider).charges.single.amount, '2500.00');
    });
  });

  group('penjualan & cetak', () {
    test('penjualan: biaya dikirim sebagai baris charge setelah barang; total = barang + biaya', () async {
      final (local, pos) = await service();
      addTearDown(local.close);
      final sale = await pos.checkout(clientUuid: PosService.newUuid(), cart: contoh(), payment: const PaymentInput(mode: PayMode.cash, cashReceived: '120000'));
      expect(sale['total'], '114900.00');
      expect(sale['change'], '5100.00');
      final push = (await OutboxStore(local).pending()).single.data;
      expect(push['total'], '114900.00');
      final items = [for (final item in push['items'] as List) Map<String, dynamic>.from(item as Map)];
      expect(items, hasLength(2));
      expect(items.first['discount_percent'], '10.00');
      expect(items.first, isNot(contains('charge')));
      expect(items.last, {'product_id': null, 'description': 'Ongkos kirim', 'quantity': '1.000000', 'unit': null, 'unit_price': '15000.00', 'discount_percent': '0.00', 'tax_rate': '0.00', 'charge': true});

      // Struk lunas: biaya tercetak sebagai baris biasa; list pesanan tanpa biaya.
      final builder = await ReceiptBuilder.create();
      const config = ReceiptConfig(companyName: 'Warung Tes');
      final receipt = latin1.decode(builder.sale(sale, config, width: 58), allowInvalid: true);
      expect(receipt, allOf(contains('Ongkos kirim'), contains('15.000'), contains('114.900'), contains('LUNAS')));
      final list = latin1.decode(builder.orderList(sale, config, width: 58), allowInvalid: true);
      expect(list, allOf(contains('LIST PESANAN'), contains('1 karung  Beras')));
      expect(list, isNot(contains('Ongkos kirim')));
      expect(ReceiptBuilder.plainText(sale, config), contains('Ongkos kirim'));
    });

    test('tagihan sebelum dibayar: TAGIHAN, Bukan bukti pembayaran, biaya di bagian total, BELUM DIBAYAR', () async {
      final (local, pos) = await service();
      addTearDown(local.close);
      final cart = contoh().copyWith(customer: const Customer(id: 7, name: 'Bu Ani'), orderType: OrderType.delivery, orderLabel: 'Antrian 4', note: 'Dikirim sore');
      final draft = pos.draft(cart, title: 'Antar sore', now: DateTime(2026, 11, 22, 10, 30));
      expect((draft['total'], draft['number']), ('114900.00', null));
      expect(draft['payments'], isEmpty);
      final builder = await ReceiptBuilder.create();
      const config = ReceiptConfig(companyName: 'Warung Tes', footerText: 'Terima kasih');
      final bill = latin1.decode(builder.bill(draft, config, width: 58), allowInvalid: true);
      for (final expected in ['Warung Tes', 'TAGIHAN', 'Bukan bukti pembayaran', 'Antar sore', '22/11/2026 10:30', 'Sari', 'Bu Ani', 'PESAN ANTAR - Antrian 4', 'Beras', '1 karung x 100.000', 'Subtotal', 'Rp 100.000', 'Diskon', 'Ongkos kirim', 'Rp 15.000', 'PPN', 'Rp 9.900', 'TOTAL', 'Rp 114.900', 'Sisa tagihan', 'BELUM DIBAYAR', 'Dikirim sore', 'Terima kasih']) {
        expect(bill, contains(expected), reason: expected);
      }
      for (final absent in ['LUNAS', 'Bayar -', 'Kembali', 'Pindai untuk cek keaslian']) {
        expect(bill, isNot(contains(absent)), reason: absent);
      }
      expect(bill.indexOf('Ongkos kirim'), greaterThan(bill.indexOf('Subtotal')), reason: 'Biaya di bagian total, bukan di daftar barang.');

      // Tanpa nama pesanan tersimpan: No "-"; list "Belum dibayar". Tanpa biaya & harga.
      final untitled = pos.draft(cart);
      final untitledBill = latin1.decode(builder.bill(untitled, config, width: 58), allowInvalid: true);
      expect(untitledBill, isNot(contains('Antar sore')));
      expect(untitledBill, isNot(contains('Menunggu nomor')), reason: 'Tagihan tanpa nama pesanan: No "-".');
      final list = latin1.decode(builder.orderList(untitled, config, width: 58), allowInvalid: true);
      for (final expected in ['LIST PESANAN', 'Belum dibayar', 'PESAN ANTAR - Antrian 4', '1 karung  Beras', 'Dikirim sore', 'Bu Ani']) {
        expect(list, contains(expected), reason: expected);
      }
      for (final absent in ['Ongkos kirim', '100.000', '15.000', 'TOTAL']) {
        expect(list, isNot(contains(absent)), reason: absent);
      }
      expect(await OutboxStore(local).pending(), isEmpty, reason: 'Cetak sebelum bayar tidak mencatat apa pun.');
    });

    test('tagihan saat fitur rumah makan mati: tanpa jenis pesanan & meja', () async {
      final (local, pos) = await service(dining: false);
      addTearDown(local.close);
      final draft = pos.draft(contoh().copyWith(orderType: OrderType.takeAway, orderLabel: 'Meja 3'));
      expect((draft['order_type'], draft['order_label']), (null, null));
      final builder = await ReceiptBuilder.create();
      final bill = latin1.decode(builder.bill(draft, const ReceiptConfig(companyName: 'Warung Tes'), width: 58), allowInvalid: true);
      expect(bill, isNot(contains('BAWA PULANG')));
      expect(bill, isNot(contains('Meja 3')));
    });
  });

  testWidgets('panel pesanan: Cetak tagihan/list hanya bila ada barang; biaya tambahan ditambah, tampil di total, dihapus', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, printer: true)).toJson()],
      }),
      'tenant_id': 1,
      'printer_mac': '00:11:22:33:44:55',
      'printer_name': 'RPP02N',
      'printer_width': 58,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = (await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: {'pos': true, 'printer': true});
      return db;
    }))!;
    final printer = FakePrinter();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(offlineServer())),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(printer),
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
    final container = ProviderScope.containerOf(tester.element(find.byType(KasirScreen)));

    // Keranjang kosong: tidak ada tombol cetak.
    expect(find.byKey(const Key('order-panel')), findsOneWidget);
    expect(find.byKey(const Key('cart-print-bill')), findsNothing);
    expect(find.byKey(const Key('cart-print-list')), findsNothing);

    await tap(find.byKey(const Key('product-1')));
    expect(inPanel(find.text('Cetak tagihan')), findsOneWidget);
    expect(inPanel(find.text('Cetak list')), findsOneWidget);
    expect(inPanel(find.text('Biaya tambahan')), findsOneWidget);

    // Dialog Biaya tambahan: pesan bila kosong, saran nama, nominal.
    await tap(find.byKey(const Key('order-charges')));
    for (final suggestion in ['Ongkos kirim', 'Biaya layanan', 'Biaya kemasan']) {
      expect(find.widgetWithText(ActionChip, suggestion), findsOneWidget);
    }
    expect(tester.widget<TextField>(find.byKey(const Key('charge-name'))).decoration?.hintText, 'mis. Ongkos kirim');
    await tap(find.byKey(const Key('charge-save')));
    expect(find.text('Isi nama biaya, mis. Ongkos kirim.'), findsOneWidget);
    await tap(find.widgetWithText(ActionChip, 'Ongkos kirim'));
    await tap(find.byKey(const Key('charge-save')));
    expect(find.text('Isi nominal biaya.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('charge-amount')), '15.000');
    await tap(find.byKey(const Key('charge-save')));
    expect(find.byKey(const Key('charge-save')), findsNothing);

    final charge = container.read(cartProvider).charges.single;
    expect((charge.name, charge.amount), ('Ongkos kirim', '15000.00'));
    expect(find.descendant(of: find.byKey(Key('charge-${charge.key}')), matching: find.text('Rp 15.000')), findsOneWidget);
    final totals = find.byKey(const Key('order-totals'));
    expect(find.descendant(of: totals, matching: find.text('Rp 18.000')), findsOneWidget, reason: 'Subtotal barang saja.');
    expect(find.descendant(of: totals, matching: find.text('Ongkos kirim')), findsOneWidget);
    expect(find.descendant(of: totals, matching: find.text('Rp 33.000')), findsOneWidget);
    expect(find.text('Bayar Rp 33.000'), findsOneWidget);

    // Cetak tagihan & list ke printer: tidak dicatat.
    await tap(find.byKey(const Key('cart-print-bill')));
    for (var i = 0; i < 4 && printer.printed.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }
    expect(printer.printed, hasLength(1));
    final bill = latin1.decode(printer.printed.single, allowInvalid: true);
    expect(bill, allOf(contains('TAGIHAN'), contains('BELUM DIBAYAR'), contains('Ongkos kirim'), contains('Rp 33.000')));
    expect(find.text('Tagihan tercetak.'), findsOneWidget);

    await tap(find.byKey(const Key('cart-print-list')));
    for (var i = 0; i < 4 && printer.printed.length < 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }
    expect(printer.printed, hasLength(2));
    final list = latin1.decode(printer.printed.last, allowInvalid: true);
    expect(list, allOf(contains('LIST PESANAN'), contains('Belum dibayar'), contains('Kopi susu')));
    expect(list, isNot(contains('Ongkos kirim')));
    expect(list, isNot(contains('18.000')));
    expect(await tester.runAsync(() => OutboxStore(local).pending()), isEmpty);

    // Hapus biaya (×), lalu hapus barang: tombol cetak hilang.
    await tap(find.byKey(Key('charge-remove-${charge.key}')));
    expect(container.read(cartProvider).charges, isEmpty);
    expect(find.text('Bayar Rp 18.000'), findsOneWidget);
    final minus = find.byWidgetPredicate((widget) => widget.key is ValueKey<String> && (widget.key! as ValueKey<String>).value.startsWith('minus-'));
    await tap(minus);
    expect(find.byKey(const Key('cart-print-bill')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(local.close);
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
