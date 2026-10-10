import 'dart:convert';
import 'dart:io';

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
import 'package:infois/services/file_downloads.dart' show whatsappUri;
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/printing/receipt_builder.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/main.dart' show isPhoneSize;
import 'package:infois/ui/screens/kasir_screen.dart' show posUseTwoPane;
import 'package:infois/ui/screens/pos_order_panel.dart';
import 'package:infois/ui/widgets/pos_categories.dart';
import 'package:infois/ui/widgets/pos_keypad.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

/// Kasir sebagai POS: grid + keranjang, catatan per barang & per pesanan,
/// jenis pesanan + meja, simpan/lanjutkan pesanan, bayar dengan keypad,
/// tiket dapur, kirim struk WhatsApp, dan tata letak dua panel di tablet.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  Future<(LocalDb, FakePrinter, List<Uri>)> pumpApp(WidgetTester tester) async {
    const tenants = [TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, shift: true, printer: true, addCustomer: true))];
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [for (final tenant in tenants) tenant.toJson()],
      }),
      'tenant_id': 1,
      'printer_mac': '00:11:22:33:44:55',
      'printer_name': 'RPP02N',
      'printer_width': 58,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db);
      return db;
    });
    final printer = FakePrinter();
    final launched = <Uri>[];

    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local!),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(offlineServer())),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(printer),
        linkLauncherProvider.overrideWithValue((uri) async {
          launched.add(uri);
          return true;
        }),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    return (local!, printer, launched);
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> openShift(WidgetTester tester) async {
    await tap(tester, find.byKey(const Key('open-shift')));
    await tester.enterText(find.byKey(const Key('opening-cash')), '100000');
    await tap(tester, find.byKey(const Key('opening-save')));
  }

  Finder inPanel(Finder finder) => find.descendant(of: find.byType(PosOrderPanel), matching: finder);

  testWidgets('pesanan lengkap: catatan barang & pesanan, bawa pulang + meja, bayar keypad, dapur, WhatsApp', (tester) async {
    phone(tester);
    final (local, printer, launched) = await pumpApp(tester);
    await openShift(tester);

    // Grid: ketuk dua kali → badge qty 2 di tile.
    await tap(tester, find.byKey(const Key('product-1')));
    await tap(tester, find.byKey(const Key('product-1')));
    expect(find.descendant(of: find.byKey(const Key('product-badge-1')), matching: find.text('2')), findsOneWidget);

    // Tekan lama: jumlah 2 + catatan "pedas" → baris sendiri.
    await tester.longPress(find.byKey(const Key('product-2')));
    await settle(tester);
    await tap(tester, find.byKey(const Key('item-qty-plus')));
    expect((tester.widget(find.byKey(const Key('item-qty'))) as Text).data, '2');
    await tester.enterText(find.byKey(const Key('item-note')), 'pedas');
    await tap(tester, find.byKey(const Key('item-add')));
    expect(find.text('2 barang'), findsOneWidget);
    expect(find.text('Rp 69.300'), findsOneWidget);

    await tap(tester, find.byKey(const Key('open-cart')));
    expect(inPanel(find.text('pedas')), findsOneWidget);

    await tap(tester, find.byKey(const Key('order-type-take_away')));
    await tap(tester, find.byKey(const Key('order-label')));
    await tester.enterText(find.byKey(const Key('order-label-field')), 'Meja 5');
    await tap(tester, find.byKey(const Key('text-save')));
    expect(inPanel(find.text('Meja 5')), findsOneWidget);

    await tap(tester, find.byKey(const Key('order-note')));
    await tester.enterText(find.byKey(const Key('order-note-field')), 'Antar cepat');
    await tap(tester, find.byKey(const Key('text-save')));
    expect(inPanel(find.text('Antar cepat')), findsOneWidget);

    // Catatan barang lewat editor baris.
    await tap(tester, inPanel(find.text('Kopi susu')));
    await tester.enterText(find.byKey(const Key('line-note')), 'tanpa gula');
    await tap(tester, find.byKey(const Key('line-save')));
    expect(inPanel(find.text('tanpa gula')), findsOneWidget);

    await tap(tester, find.byKey(const Key('go-pay')));
    expect(find.byKey(const Key('pay-total')), findsOneWidget);
    expect(find.text('Bawa pulang · Meja 5'), findsOneWidget);

    // Keypad: 1 0 0 000 = 100.000 → kembali 30.700.
    for (final key in ['1', '0', '0', '000']) {
      await tap(tester, find.byKey(Key('key-$key')));
    }
    expect((tester.widget(find.byKey(const Key('pay-cash-value'))) as Text).data, 'Rp 100.000');
    expect((tester.widget(find.byKey(const Key('pay-change'))) as Text).data, 'Rp 30.700');
    await tap(tester, find.byKey(const Key('key-back')));
    expect(find.byKey(const Key('pay-short')), findsOneWidget, reason: 'Rp 10.000 kurang dari total.');
    await tap(tester, find.byKey(const Key('key-0')));
    await tap(tester, find.byKey(const Key('pay-submit')));

    expect(find.text('Penjualan tersimpan'), findsOneWidget);
    expect(find.text('BAWA PULANG - Meja 5'), findsOneWidget);
    expect(printer.printed, hasLength(1));
    final receipt = latin1.decode(printer.printed.single, allowInvalid: true);
    for (final expected in ['BAWA PULANG - Meja 5', '* tanpa gula', '* pedas', 'Catatan:', 'Antar cepat', 'Kembali', '30.700']) {
      expect(receipt, contains(expected));
    }

    final sale = (await tester.runAsync(() => OutboxStore(local).pending()))!.firstWhere((item) => item.type == 'sale').data;
    expect(sale['order_type'], 'take_away');
    expect(sale['order_label'], 'Meja 5');
    expect(sale['notes'], 'Antar cepat');
    expect(sale['total'], '69300.00');
    final items = [for (final item in sale['items'] as List) Map<String, dynamic>.from(item as Map)];
    expect(items.map((item) => item['note']), ['tanpa gula', 'pedas']);

    // Tiket dapur: tanpa harga, dengan catatan.
    await tap(tester, find.byKey(const Key('print-kitchen')));
    expect(printer.printed, hasLength(2));
    final ticket = latin1.decode(printer.printed.last, allowInvalid: true);
    for (final expected in ['PESANAN DAPUR', 'BAWA PULANG - Meja 5', 'Kopi susu', '>> tanpa gula', '>> pedas', 'Antar cepat']) {
      expect(ticket, contains(expected));
    }
    expect(ticket, isNot(contains('36.000')));
    expect(ticket, isNot(contains('TOTAL')));

    // Kirim struk WA ke nomor yang diketik.
    await tap(tester, find.byKey(const Key('send-wa')));
    await tester.enterText(find.byKey(const Key('wa-phone')), '0812-3456 789');
    await tap(tester, find.byKey(const Key('wa-send')));
    expect(launched, hasLength(1));
    expect(launched.single.host, 'wa.me');
    expect(launched.single.path, '/628123456789');
    expect(launched.single.queryParameters['text'], allOf(contains('Meja 5'), contains('Catatan: tanpa gula'), contains('*Total: Rp 69.300*')));

    await tap(tester, find.byKey(const Key('new-sale')));
    expect(find.byKey(const Key('open-cart')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('simpan pesanan, lanjutkan dari daftar, bayar → hilang dari daftar; hapus pesanan', (tester) async {
    phone(tester);
    final (local, _, _) = await pumpApp(tester);
    await openShift(tester);

    await tap(tester, find.byKey(const Key('product-1')));
    await tap(tester, find.byKey(const Key('open-cart')));
    await tap(tester, find.byKey(const Key('order-type-dine_in')));
    await tap(tester, find.byKey(const Key('hold-order')));
    await tester.enterText(find.byKey(const Key('hold-name')), 'Meja 3');
    await tap(tester, find.byKey(const Key('hold-save')));
    expect(find.byKey(const Key('open-cart')), findsNothing, reason: 'Keranjang kosong setelah disimpan.');

    var held = (await tester.runAsync(() => HeldOrderStore(local).all()))!;
    expect(held.single.name, 'Meja 3');
    expect(held.single.total, '18000.00');
    expect(held.single.cart.orderType, OrderType.dineIn);

    // Pesanan kedua lalu dihapus dari daftar.
    await tap(tester, find.byKey(const Key('product-2')));
    await tap(tester, find.byKey(const Key('open-cart')));
    await tap(tester, find.byKey(const Key('hold-order')));
    await tester.enterText(find.byKey(const Key('hold-name')), 'Pak Budi');
    await tap(tester, find.byKey(const Key('hold-save')));
    held = (await tester.runAsync(() => HeldOrderStore(local).all()))!;
    expect(held.map((order) => order.name), ['Meja 3', 'Pak Budi']);

    await tap(tester, find.byKey(const Key('held-orders')));
    expect(find.text('Pesanan tersimpan'), findsOneWidget);
    await tap(tester, find.byKey(Key('held-delete-${held.last.id}')));
    await tap(tester, find.byKey(const Key('held-delete-confirm')));
    expect(find.text('Pak Budi'), findsNothing);

    // Lanjutkan "Meja 3".
    await tap(tester, find.byKey(Key('held-${held.first.id}')));
    expect(find.byKey(const Key('open-cart')), findsOneWidget);
    expect(find.text('Makan di tempat'), findsOneWidget, reason: 'Jenis pesanan ikut tersimpan.');
    await tap(tester, find.byKey(const Key('open-cart')));
    expect(find.byKey(const Key('held-active')), findsOneWidget);
    await tap(tester, find.byKey(const Key('go-pay')));
    await tap(tester, find.byKey(const Key('quick-0')));
    await tap(tester, find.byKey(const Key('pay-submit')));
    expect(find.text('Penjualan tersimpan'), findsOneWidget);

    expect((await tester.runAsync(() => HeldOrderStore(local).all()))!, isEmpty, reason: 'Pesanan yang dibayar keluar dari daftar.');
    final sale = (await tester.runAsync(() => OutboxStore(local).pending()))!.firstWhere((item) => item.type == 'sale').data;
    expect(sale['order_type'], 'dine_in');
    expect(sale['order_label'], isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tablet/lanskap: dua panel, chip kelompok dari satuan, stepper di panel kanan', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    await openShift(tester);

    expect(find.byKey(const Key('order-panel')), findsOneWidget);
    expect(find.text('Belum ada pesanan'), findsOneWidget);
    expect(find.byKey(const Key('category-unit:gelas')), findsOneWidget);
    expect(find.byKey(const Key('category-unit:pcs')), findsOneWidget);

    await tap(tester, find.byKey(const Key('category-unit:pcs')));
    expect(find.byKey(const Key('product-1')), findsNothing);
    expect(find.byKey(const Key('product-2')), findsOneWidget);
    await tap(tester, find.byKey(const Key('category-all')));

    await tap(tester, find.byKey(const Key('product-1')));
    expect(find.byKey(const Key('open-cart')), findsNothing, reason: 'Tablet tidak memakai bilah keranjang.');
    expect(inPanel(find.text('Kopi susu')), findsOneWidget);
    final plus = find.byWidgetPredicate((widget) => widget.key is ValueKey<String> && (widget.key! as ValueKey<String>).value.startsWith('plus-'));
    await tap(tester, plus);
    expect(find.text('Bayar Rp 36.000'), findsOneWidget);
    await tap(tester, find.byKey(const Key('go-pay')));
    expect(find.byKey(const Key('key-1')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HP kecil (320 dp): grid, keranjang, bayar, dan layar selesai tanpa luber', (tester) async {
    tester.view.physicalSize = const Size(640, 1136);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    await openShift(tester);
    await tap(tester, find.byKey(const Key('product-1')));
    await tap(tester, find.byKey(const Key('product-2')));
    await tap(tester, find.byKey(const Key('open-cart')));
    await tap(tester, find.byKey(const Key('order-type-delivery')));
    await tap(tester, find.byKey(const Key('go-pay')));
    await tap(tester, find.byKey(const Key('quick-0')));
    await tap(tester, find.byKey(const Key('pay-submit')));
    expect(find.text('Penjualan tersimpan'), findsOneWidget);
    expect(find.byKey(const Key('send-wa')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HP miring / layar terbelah: tata letak HP (bukan dua panel yang tergencet), ketuk barang masuk pesanan', (tester) async {
    // HP miring 780×360 dp (di aplikasi HP dikunci tegak; ini jaga-jaga bila
    // tetap miring): tidak ada dua panel yang meluap.
    tester.view.physicalSize = const Size(2340, 1080);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    await openShift(tester);
    expect(find.byKey(const Key('order-panel')), findsNothing, reason: 'Terlalu pendek untuk dua panel.');

    // Layar terbelah lebar tetapi pendek (780×520 dp): tata letak HP, barang bisa diketuk.
    tester.view.physicalSize = const Size(2340, 1560);
    await settle(tester);
    expect(find.byKey(const Key('order-panel')), findsNothing);
    await tap(tester, find.byKey(const Key('product-1')));
    expect(find.text('Tim AI butuh internet'), findsNothing);
    expect(find.byKey(const Key('open-cart')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('huruf besar (1,3×) di HP 360 dp + kembalian sangat besar: tanpa luber', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(tester);
    await openShift(tester);
    await tap(tester, find.byKey(const Key('product-1')));
    await tap(tester, find.byKey(const Key('open-cart')));
    await tap(tester, find.byKey(const Key('go-pay')));
    await tester.scrollUntilVisible(find.byKey(const Key('key-000')), 150, scrollable: find.byType(Scrollable).last);
    for (final key in ['9', '9', '9', '000', '000']) {
      await tap(tester, find.byKey(Key('key-$key')));
    }
    expect(find.byKey(const Key('pay-change')), findsOneWidget);
    await tap(tester, find.byKey(const Key('pay-submit')));
    expect(find.text('Penjualan tersimpan'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('dua panel hanya bila lebar DAN tinggi cukup', () {
    expect(posUseTwoPane(const BoxConstraints(maxWidth: 1280, maxHeight: 660)), isTrue);
    expect(posUseTwoPane(const BoxConstraints(maxWidth: 780, maxHeight: 224)), isFalse);
    expect(posUseTwoPane(const BoxConstraints(maxWidth: 400, maxHeight: 800)), isFalse);
    expect(isPhoneSize(const Size(360, 780)), isTrue);
    expect(isPhoneSize(const Size(780, 360)), isTrue);
    expect(isPhoneSize(const Size(800, 1280)), isFalse);
  });

  group('logika POS', () {
    test('database HP versi lama (1) dinaikkan: tabel pesanan tersimpan dibuat, data lama tetap', () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('infois_upgrade');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/lama.db';
      final old = await databaseFactoryFfiNoIsolate.openDatabase(path, options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
        await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
        await db.insert('meta', {'key': 'x', 'value': 'tetap'});
      }));
      await old.close();

      final local = await LocalDb.open(path, factory: databaseFactoryFfiNoIsolate);
      addTearDown(local.close);
      expect(await local.getMeta('x'), 'tetap');
      final store = HeldOrderStore(local);
      await store.save(Cart(lines: [CartLine.fromProduct('a', kopi)]), name: 'Meja 1', total: '18000');
      expect((await store.all()).single.name, 'Meja 1');
    });

    test('keypad: angka, 000, hapus, batas 13 digit, nol di depan', () {
      expect(applyKeypad('', '0'), '0');
      expect(applyKeypad('0', '5'), '5');
      expect(applyKeypad('5', '000'), '5000');
      expect(applyKeypad('5000', 'back'), '500');
      expect(applyKeypad('500', 'clear'), '');
      expect(applyKeypad('1234567890123', '4'), '1234567890123');
    });

    test('nomor WhatsApp & tautan wa.me: satu aturan untuk struk kasir dan Catatan', () {
      expect(whatsappUri('x', phone: '0812-3456').path, '/628123456');
      expect(whatsappUri('x', phone: '+62 812 3456').path, '/628123456');
      expect(whatsappUri('x', phone: '812345678').path, '/62812345678');
      expect(whatsappUri('x', phone: '8123').path, '/', reason: 'Nomor tidak lengkap: WhatsApp meminta pilih kontak, bukan chat ke nomor salah.');
      expect(whatsappUri('x', phone: '').path, '/');
      expect(whatsappUri('halo', phone: null).toString(), 'https://wa.me/?text=halo');
    });

    test('kelompok barang diturunkan dari jenis & satuan', () {
      const jasa = Product(id: 3, name: 'Cuci', unit: 'kali', price: '5000', type: 'service');
      final categories = posCategories([kopi, roti, jasa]);
      expect(categories.map((category) => category.key), ['all', 'type:product', 'type:service', 'unit:gelas', 'unit:kali', 'unit:pcs']);
      expect(posCategories([kopi]).map((category) => category.key), ['all']);
    });

    test('keranjang: catatan memisahkan baris, json bolak-balik utuh', () {
      final container = ProviderContainer(overrides: [workspaceProvider.overrideWith((ref) async => null)]);
      addTearDown(container.dispose);
      final cart = container.read(cartProvider.notifier)
        ..add(kopi)
        ..add(kopi)
        ..add(kopi, note: 'tanpa gula')
        ..add(roti, quantity: '3')
        ..setOrderType(OrderType.delivery)
        ..setOrderLabel('  Antrian 12 ')
        ..setNote('Rumah pagar hijau');
      var state = container.read(cartProvider);
      expect(state.lines.map((line) => '${line.description}:${line.quantity}:${line.note}'), [
        'Kopi susu:2.000000:null',
        'Kopi susu:1.000000:tanpa gula',
        'Roti bakar:3.000000:null',
      ]);
      expect(state.totalQuantity, '6.000000');
      expect(state.quantityOf(1), '3.000000');
      expect(state.orderLabel, 'Antrian 12');

      final copy = Cart.fromJson(jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>);
      expect(copy.toJson(), state.toJson());
      expect(copy.totals(pricesIncludeTax: false).toJson(), state.totals(pricesIncludeTax: false).toJson());

      cart
        ..setOrderType(OrderType.delivery)
        ..setOrderLabel('')
        ..setNote('')
        ..setLineNote(state.lines[1].key, '');
      state = container.read(cartProvider);
      expect(state.orderType, isNull, reason: 'Pilih jenis yang sama lagi = batal pilih.');
      expect(state.orderLabel, isNull);
      expect(state.note, isNull);
      expect(state.lines[1].note, isNull);
    });

    test('struk & tiket dapur dari data penjualan (juga data server tanpa kolom baru)', () async {
      final builder = await ReceiptBuilder.create();
      final sale = {
        'number': 'POS-K1/000010',
        'created_at': '2026-10-07T03:00:00Z',
        'cashier': 'Sari',
        'customer_name': 'Bu Ani',
        'order_type': 'dine_in',
        'order_label': 'Meja 2',
        'notes': 'Ulang tahun',
        'items': [
          {'description': 'Kopi susu', 'quantity': '2.000000', 'unit': 'gelas', 'unit_price': '18000.00', 'discount_percent': '0.00', 'line_total': '36000.00', 'note': 'less ice'},
        ],
        'subtotal': '36000.00',
        'discount_total': '0.00',
        'tax_total': '0.00',
        'total': '36000.00',
        'change': '0.00',
        'payments': [
          {'method': 'transfer', 'amount': '36000.00'},
        ],
      };
      const config = ReceiptConfig(companyName: 'Warung Tes');
      final ticket = latin1.decode(builder.kitchenTicket(sale, config, width: 58), allowInvalid: true);
      for (final expected in ['PESANAN DAPUR', 'MAKAN DI TEMPAT - Meja 2', '2 gelas  Kopi susu', '>> less ice', 'Ulang tahun', 'Bu Ani']) {
        expect(ticket, contains(expected));
      }
      expect(ticket, isNot(contains('36.000')));

      final text = ReceiptBuilder.plainText(sale, config);
      expect(text, contains('Makan di tempat · Meja 2'));
      expect(text, contains('Catatan: less ice'));
      expect(text, contains('Transfer: Rp 36.000'));
      expect(text, contains('LUNAS'));

      // Cetak ulang dari server: catatan gabungan di `notes`, tanpa order_type.
      final reprint = latin1.decode(
        builder.sale({...sale, 'order_type': null, 'order_label': null, 'notes': 'Pesanan: Bawa pulang · Meja 2\n- Kopi susu: less ice'}, config, width: 58),
        allowInvalid: true,
      );
      expect(reprint, contains('Pesanan: Bawa pulang - Meja 2'));
      expect(reprint, isNot(contains('MAKAN DI TEMPAT')));
    });

    test('PosService: catatan & jenis pesanan masuk outbox; pesanan tersimpan dihapus saat dibayar', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      await seedMaster(local);
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
      final store = HeldOrderStore(local);
      var cart = Cart(lines: [CartLine.fromProduct('a', kopi, note: 'tanpa gula'), CartLine.fromProduct('b', roti)], orderType: OrderType.takeAway, orderLabel: 'Antrian 7', note: 'Cepat');
      final heldId = await store.save(cart, name: '', total: '34650');
      expect((await store.find(heldId))!.name, 'Antrian 7', reason: 'Nama bawaan dari label antrian.');
      cart = cart.copyWith(heldId: heldId);

      final sale = await pos.checkout(clientUuid: PosService.newUuid(), cart: cart, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '50000'));
      expect(sale['order_type'], 'take_away');
      final push = (await OutboxStore(local).pending()).single.data;
      expect(push['order_type'], 'take_away');
      expect(push['order_label'], 'Antrian 7');
      expect(push['notes'], 'Cepat');
      expect([for (final item in push['items'] as List) (item as Map)['note']], ['tanpa gula', null]);
      expect((push['items'] as List).last as Map, isNot(contains('note')), reason: 'Baris tanpa catatan tidak mengirim kunci note.');
      expect(await store.all(), isEmpty);
    });
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
