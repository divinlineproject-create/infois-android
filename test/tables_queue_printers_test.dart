import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/printing/printer_service.dart';
import 'package:infois/services/printing/receipt_builder.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/kasir_screen.dart';
import 'package:infois/ui/screens/pos_held_orders.dart';
import 'package:infois/ui/screens/pos_order_panel.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Rumah makan: daftar meja dari web, nomor antrian harian per HP. Printer
/// kasir & printer produksi (Bluetooth / Wi-Fi, per kategori, bersamaan,
/// yang gagal disebut), QR struk.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  const tenantBase = {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'};
  const twoPrinters = {
    'printer_mac': 'AA:01',
    'printer_name': 'Printer Kasir',
    'printer_width': 58,
    'printer_kitchen_mac': 'BB:02',
    'printer_kitchen_name': 'Printer Dapur',
    'printer_kitchen_width': 80,
  };

  Future<MasterData> master(LocalDb local) async {
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

  group('data', () {
    test('tenant.pos_tables: daftar meja; tidak ada / kosong = isian bebas', () {
      final tables = TenantSettings.fromJson({
        ...tenantBase,
        'pos_tables': ['Meja 1', ' VIP 2 ', '', null],
      });
      expect(tables.posTables, ['Meja 1', 'VIP 2']);
      expect(TenantSettings.fromJson(tenantBase).posTables, isEmpty);
      expect(TenantSettings.fromJson(tables.toJson()).posTables, ['Meja 1', 'VIP 2']);
    });

    test('izin ubah harga (server lama = boleh), nama pesanan bawaan = nomor-meja-pelanggan, LUNAS tanpa blok hitam', () async {
      expect(Menus.fromJson({'pos': true}).editPrice, isTrue);
      expect(Menus.fromJson({'pos': true, 'edit_price': false}).editPrice, isFalse);
      expect(Menus.fromJson(const Menus(editPrice: false).toJson()).editPrice, isFalse);

      final now = DateTime(2026, 11, 26, 10, 5);
      expect(HeldOrderStore.defaultName(const Cart(queueNumber: '000012', orderLabel: 'Meja 5'), now), '000012-Meja 5');
      expect(HeldOrderStore.defaultName(const Cart(queueNumber: '000012'), now), '000012-Tanpa meja');
      expect(HeldOrderStore.defaultName(const Cart(queueNumber: '000012', orderLabel: 'Meja 01', customer: Customer(id: 3, name: 'Firmawan')), now), '000012-Meja 01-Firmawan');
      expect(HeldOrderStore.defaultName(const Cart(queueNumber: '000012', customer: Customer(name: 'Pelanggan Umum', isWalkIn: true)), now), '000012-Tanpa meja');
      expect(HeldOrderStore.defaultName(const Cart(orderLabel: 'Meja 5'), now), 'Meja 5');
      expect(HeldOrderStore.defaultName(const Cart(), now), 'Pesanan 10:05');
      expect(HeldOrderStore.isAutoName('000012-Meja 5', const Cart(queueNumber: '000012')), isTrue);
      expect(HeldOrderStore.isAutoName('Rombongan kantor', const Cart(queueNumber: '000012')), isFalse);
      HeldOrder held(String name, Cart cart) => HeldOrder(id: name, name: name, total: '0', itemCount: 1, createdAt: now, updatedAt: now, cart: cart);
      final orders = [
        held('000001-Meja 01-Firmawan', const Cart(queueNumber: '000001', orderLabel: 'Meja 01', customer: Customer(id: 3, name: 'Firmawan'))),
        held('000002-Meja 12', const Cart(queueNumber: '000002', orderLabel: 'Meja 12')),
        held('Rombongan', const Cart(queueNumber: '000003')),
      ];
      expect([for (final order in orders) if (HeldOrderStore.matches(order, 'meja 1')) order.name], ['000001-Meja 01-Firmawan', '000002-Meja 12']);
      expect([for (final order in orders) if (HeldOrderStore.matches(order, 'FIRMA')) order.name], ['000001-Meja 01-Firmawan']);
      expect([for (final order in orders) if (HeldOrderStore.matches(order, '000003')) order.name], ['Rombongan'], reason: 'Nomor pesanan dicari walau namanya diganti.');
      expect(matchingTables(['Meja 01', 'Meja 12', 'Teras 1'], ' 12 '), ['Meja 12']);
      expect(matchingTables(['Meja 01', 'Teras 1'], ''), ['Meja 01', 'Teras 1']);

      final builder = await ReceiptBuilder.create();
      final paid = {
        'number': 'POS-K1/000001',
        'created_at': now.toUtc().toIso8601String(),
        'items': [
          {'description': 'Kopi', 'quantity': '1', 'unit': 'gelas', 'unit_price': '10000', 'line_total': '10000'},
        ],
        'payments': [
          {'method': 'cash', 'amount': '10000'},
        ],
        'total': '10000',
      };
      final bytes = builder.sale(paid, const ReceiptConfig(companyName: 'Warung'), width: 58);
      expect(latin1.decode(bytes, allowInvalid: true), contains('LUNAS'));
      bool hasReverseOn(List<int> data) {
        for (var i = 0; i + 2 < data.length; i++) {
          if (data[i] == 0x1D && data[i + 1] == 0x42 && data[i + 2] == 0x01) {
            return true;
          }
        }
        return false;
      }

      expect(hasReverseOn(bytes), isFalse, reason: 'Cetak terbalik (blok hitam) tidak dipakai.');
    });

    test('nomor antrian: 6 angka per HP, naik, mulai lagi dari 000001 setelah tengah malam', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      await seedMaster(local);
      final pos = PosService(local: local, user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'), master: await master(local));
      final today = DateTime(2026, 11, 24, 23, 50);
      expect(await pos.nextQueueNumber(now: today), '000001');
      expect(await pos.nextQueueNumber(now: today), '000002');
      expect(await pos.nextQueueNumber(now: DateTime(2026, 11, 25, 0, 5)), '000001', reason: 'Hari baru.');

      // Data penjualan, cetak, dan keranjang JSON membawa nomor antrian (hanya rumah makan).
      final cart = Cart(lines: [CartLine.fromProduct('a', kopi)], queueNumber: '000012');
      expect(Cart.fromJson(jsonDecode(jsonEncode(cart.toJson())) as Map<String, dynamic>).queueNumber, '000012');
      expect(Cart.fromJson({'lines': []}).queueNumber, isNull);
      final sale = await pos.checkout(clientUuid: 'q-1', cart: cart, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '20000'));
      expect(sale['queue_number'], '000012');
      expect(PosService.pushData(sale)['queue_number'], '000012');
      final builder = await ReceiptBuilder.create();
      const config = ReceiptConfig(companyName: 'Warung Tes');
      expect(latin1.decode(builder.orderList(sale, config, width: 58), allowInvalid: true), contains('ANTRIAN 000012'));
      expect(latin1.decode(builder.sale(sale, config, width: 58), allowInvalid: true), contains('Antrian 000012'));
      expect(latin1.decode(builder.bill(pos.draft(cart), config, width: 58), allowInvalid: true), contains('Antrian 000012'));

      await local.setJson(MetaKeys.tenant, {...tenantBase, 'pos_dining': false});
      final retail = PosService(local: local, user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'), master: await master(local));
      final plain = await retail.checkout(clientUuid: 'q-2', cart: cart, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '20000'));
      expect(plain['queue_number'], isNull, reason: 'Fitur rumah makan mati: tanpa nomor antrian.');
      expect(PosService.pushData(plain), isNot(contains('queue_number')));
    });
  });

  group('printer kasir & produksi', () {
    Future<(ProviderContainer, _Printers, _Network)> printerContainer(Map<String, Object> prefs, {Set<String> failing = const {}, LocalDb? local}) async {
      SharedPreferences.setMockInitialValues(prefs);
      FlutterSecureStorage.setMockInitialValues({'device_uid': 'hp-tes'});
      final storage = await AppStorage.load();
      final printers = _Printers(failing: failing);
      final network = _Network();
      final container = ProviderContainer(overrides: [
        storageProvider.overrideWithValue(storage),
        printerTransportProvider.overrideWithValue(printers),
        networkPrinterProvider.overrideWithValue(network),
        workspaceProvider.overrideWith((ref) async => null),
        masterDataProvider.overrideWith((ref) async => local == null ? null : master(local)),
      ]);
      addTearDown(container.dispose);
      container.read(printerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return (container, printers, network);
    }

    test('pengaturan lama: printer kasir tetap; printer dapur lama jadi printer produksi "semua kategori"', () async {
      final (only, _, _) = await printerContainer({'printer_mac': 'AA:01', 'printer_name': 'RPP02N', 'printer_width': 58});
      final state = only.read(printerProvider);
      expect((state.printer?.mac, state.printer?.link), ('AA:01', PrinterLink.bluetooth));
      expect(state.production, isEmpty);
      expect(only.read(storageProvider).autoPrintKitchen, isFalse, reason: 'List otomatis bawaannya mati.');

      final (two, _, _) = await printerContainer(twoPrinters);
      final kitchen = two.read(printerProvider).production.single;
      expect((kitchen.name, kitchen.mac, kitchen.width, kitchen.categoryIds.length, kitchen.isWifi), ('Printer Dapur', 'BB:02', 80, 0, false));

      // Disimpan dalam bentuk baru (kunci lama dibersihkan), printer Wi-Fi ikut.
      await two.read(printerProvider.notifier).addProduction([const SavedPrinter(mac: '192.168.1.50', name: 'Bar', width: 58, link: PrinterLink.wifi, categoryIds: [2])]);
      final storage = two.read(storageProvider);
      expect(storage.prefs.getString('printer_kitchen_mac'), isNull);
      expect([for (final printer in storage.productionPrinters) '${printer.name}:${printer.linkLabel}:${printer.categoryIds}'], ['Printer Dapur:Bluetooth:[]', 'Bar:Wi-Fi 192.168.1.50:[2]']);
    });

    test('Bluetooth: dicetak berurutan (sambungan berpindah), bukan bersamaan; produksi gagal bukan struk gagal', () async {
      final (container, printers, _) = await printerContainer(twoPrinters);
      final notifier = container.read(printerProvider.notifier);
      final kitchen = container.read(printerProvider).production.single;
      printers.events.clear();
      final results = await Future.wait([notifier.printBytes([1]), notifier.send(kitchen, [2]), notifier.printBytes([3])]);
      expect(results, [PrintResult.printed, true, PrintResult.printed]);
      expect(printers.writes.map((write) => '${write.$1}:${write.$2.single}'), ['AA:01:1', 'BB:02:2', 'AA:01:3']);
      expect(printers.events, ['write:AA:01', 'disconnect', 'connect:BB:02', 'write:BB:02', 'disconnect', 'connect:AA:01', 'write:AA:01']);
      expect(printers.maxConcurrent, 1);

      printers.failing = {'BB:02'};
      expect(await notifier.send(kitchen, [4]), isFalse);
      expect(container.read(printerProvider).hasFailedJob, isFalse, reason: 'Gagal di dapur bukan struk gagal.');
      expect(await notifier.printBytes([5]), PrintResult.printed);
      expect(printers.writes.last.$1, 'AA:01');
    });

    test('Cetak list: semua printer produksi sekaligus, tiap printer hanya kategorinya; yang gagal disebut & bisa diulang', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      await seedMaster(local);
      final (container, printers, network) = await printerContainer({
        'printer_mac': 'AA:01',
        'printer_name': 'Kasir',
        'production_printers': jsonEncode([
          const SavedPrinter(id: 'd', mac: 'BB:02', name: 'Dapur', width: 58, categoryIds: [1]).toJson(),
          const SavedPrinter(id: 'b', mac: '10.0.0.5', name: 'Bar', width: 58, link: PrinterLink.wifi, categoryIds: [2]).toJson(),
          const SavedPrinter(id: 'c', mac: '10.0.0.6', name: 'Checker', width: 80, link: PrinterLink.wifi).toJson(),
        ]),
      }, local: local);
      final notifier = container.read(printerProvider.notifier);
      final sale = {
        'number': 'POS-K1/000009',
        'queue_number': '000009',
        'order_type': 'dine_in',
        'order_label': 'Meja 5',
        'created_at': DateTime(2026, 11, 26, 12).toUtc().toIso8601String(),
        'items': [
          {'product_id': 1, 'description': 'Nasi Goreng', 'quantity': '2', 'unit': 'porsi'},
          {'product_id': 2, 'description': 'Es Teh', 'quantity': '1', 'unit': 'gelas'},
          {'product_id': 3, 'description': 'Kerupuk', 'quantity': '1', 'unit': 'pcs'},
          {'product_id': null, 'description': 'Ongkir', 'quantity': '1', 'charge': true},
        ],
      };
      final categories = {1: 1, 2: 2, 3: 9};
      final result = await notifier.printProduction(sale, categoryOf: categories);
      expect((result.ok, result.unrouted.length), (true, 0));
      expect(result.printed.toSet(), {'Dapur', 'Bar', 'Checker'});
      String text(List<int> bytes) => latin1.decode(bytes, allowInvalid: true);
      final dapur = text(printers.writes.single.$2);
      expect(dapur, allOf(contains('DAPUR'), contains('ANTRIAN 000009'), contains('Meja 5'), contains('Nasi Goreng')));
      expect(dapur, isNot(anyOf(contains('Es Teh'), contains('Kerupuk'), contains('Ongkir'))));
      final bar = text(network.sent['10.0.0.5']!.single);
      expect(bar, allOf(contains('BAR'), contains('ANTRIAN 000009'), contains('Es Teh')));
      expect(bar, isNot(contains('Nasi Goreng')));
      expect(text(network.sent['10.0.0.6']!.single), allOf(contains('CHECKER'), contains('Nasi Goreng'), contains('Es Teh'), contains('Kerupuk')));
      expect(network.maxConcurrent, 2, reason: 'Printer Wi-Fi mencetak bersamaan.');

      // Bar mati: disebut, yang lain tetap tercetak; Ulangi hanya ke Bar.
      network.failing = {'10.0.0.5'};
      final partial = await notifier.printProduction(sale, categoryOf: categories);
      expect((partial.ok, partial.failedNames), (false, 'Bar'));
      expect(partial.printed.toSet(), {'Dapur', 'Checker'});
      expect(container.read(printerProvider).productionFailed, {'b'});
      network.failing = {};
      final before = (printers.writes.length, network.sent['10.0.0.6']!.length);
      final retried = await notifier.retryProduction();
      expect(retried.ok, isTrue);
      expect(retried.printed, ['Bar']);
      expect((printers.writes.length, network.sent['10.0.0.6']!.length), before, reason: 'Dapur & Checker tidak dicetak dua kali.');
      expect(container.read(printerProvider).productionFailed, isEmpty);

      // Tanpa checker: barang yang kategorinya tidak dicetak printer mana pun disebut.
      await notifier.removeProduction('c');
      final missing = await notifier.printProduction(sale, categoryOf: categories);
      expect(missing.unrouted, ['Kerupuk']);
    });

    test('tanpa printer produksi: satu list ke printer kasir; tanpa printer sama sekali = belum ada printer', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      await seedMaster(local);
      final (container, printers, _) = await printerContainer({'printer_mac': 'AA:01', 'printer_name': 'Kasir'}, local: local);
      final notifier = container.read(printerProvider.notifier);
      final sale = {
        'items': [
          {'product_id': 1, 'description': 'Nasi Goreng', 'quantity': '1'},
        ],
      };
      final result = await notifier.printProduction(sale);
      expect(result.ok, isTrue);
      expect(result.printed, ['Kasir']);
      expect(latin1.decode(printers.writes.single.$2, allowInvalid: true), contains('LIST PESANAN'));
      await notifier.forgetKasir();
      expect((await notifier.printProduction(sale)).noPrinter, isTrue);
    });

    test('struk: QR tautan sendiri dengan tulisan, atau QR cek keaslian', () async {
      final builder = await ReceiptBuilder.create();
      final sale = {
        'number': 'POS-K1/000001',
        'created_at': DateTime(2026, 11, 26).toUtc().toIso8601String(),
        'verification_url': 'https://verify.infois.test/abc',
        'items': const [],
        'payments': const [],
        'total': '0',
      };
      String text(ReceiptConfig config) => latin1.decode(builder.sale(sale, config, width: 58), allowInvalid: true);
      const verify = ReceiptConfig(companyName: 'Warung', showQr: true);
      expect(text(verify), allOf(contains('verify.infois.test/abc'), contains('Pindai untuk cek keaslian nota')));
      const link = ReceiptConfig(companyName: 'Warung', showQr: true, qrMode: 'link', qrLink: 'https://instagram.com/warung', qrCaption: 'Follow kami di Instagram');
      expect(text(link), allOf(contains('instagram.com/warung'), contains('Follow kami di Instagram')));
      expect(text(link), isNot(contains('verify.infois.test')));
      expect(ReceiptBuilder.plainText(sale, link), contains('Follow kami di Instagram https://instagram.com/warung'));
      const off = ReceiptConfig(companyName: 'Warung', qrMode: 'link', qrLink: 'https://instagram.com/warung');
      expect(text(off), isNot(contains('instagram.com')));
      expect(ReceiptConfig.fromJson({...link.toJson()}).customQrLink, 'https://instagram.com/warung');
    });
  });

  group('kasir', () {
    Future<(LocalDb, ProviderContainer, _Printers)> pumpApp(WidgetTester tester, {Map<String, dynamic>? tenant, Map<String, Object> prefs = const {}, Set<String> failing = const {}, _Network? network, Map<String, dynamic> menus = const {'pos': true, 'printer': true}}) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'session': jsonEncode({
          'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
          'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, printer: true)).toJson()],
        }),
        'tenant_id': 1,
        ...prefs,
      });
      FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
      final storage = await AppStorage.load();
      final local = (await tester.runAsync(() async {
        final db = await memoryDb();
        await seedMaster(db, menus: menus);
        await db.setJson(MetaKeys.tenant, tenant ?? tenantBase);
        await db.setMeta(LocalDb.categoriesKey, jsonEncode([
          {'id': 1, 'name': 'Makanan'},
          {'id': 2, 'name': 'Minuman'},
        ]));
        return db;
      }))!;
      final printers = _Printers(failing: failing);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          localDbOpenerProvider.overrideWithValue((_) async => local),
          apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(offlineServer())),
          connectivityStreamProvider.overrideWithValue(const Stream.empty()),
          printerTransportProvider.overrideWithValue(printers),
          networkPrinterProvider.overrideWithValue(network ?? _Network()),
        ],
        child: const InfoisApp(),
      ));
      await flush(tester);
      return (local, ProviderScope.containerOf(tester.element(find.byType(KasirScreen))), printers);
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await flush(tester);
    }

    testWidgets('Meja: pilih dari daftar meja usaha atau "Tanpa meja" (tanpa ketik bebas)', (tester) async {
      final (local, container, _) = await pumpApp(tester, tenant: {
        ...tenantBase,
        'pos_tables': ['Meja 1', 'Meja 2', 'VIP 2'],
      });
      await tap(tester, find.byKey(const Key('product-1')));
      expect(find.text('Pilih meja'), findsOneWidget);
      await tap(tester, find.byKey(const Key('order-label')));
      expect(find.byKey(const Key('order-label-field')), findsNothing);
      expect(find.text('Tanpa meja'), findsOneWidget);
      for (final table in ['Meja 1', 'Meja 2', 'VIP 2']) {
        expect(find.byKey(Key('table-$table')), findsOneWidget);
      }
      await tap(tester, find.byKey(const Key('table-VIP 2')));
      expect(container.read(cartProvider).orderLabel, 'VIP 2');
      expect(find.descendant(of: find.byKey(const Key('order-label')), matching: find.text('VIP 2')), findsOneWidget);

      await tap(tester, find.byKey(const Key('order-label')));
      await tap(tester, find.byKey(const Key('table-none')));
      expect(container.read(cartProvider).orderLabel, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('banyak meja: kotak cari muncul, Enter memilih bila tinggal satu meja', (tester) async {
      String? picked;
      final tables = [for (var i = 1; i <= 12; i++) 'Meja ${i.toString().padLeft(2, '0')}'];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () async => picked = await pickTable(context, tables, null), child: const Text('meja')))),
      ));
      await tester.tap(find.text('meja'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('table-search')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('table-search')), '1');
      await tester.pump();
      expect(find.byKey(const Key('table-none')), findsNothing, reason: 'Saat mencari, "Tanpa meja" disembunyikan.');
      expect(find.byKey(const Key('table-Meja 12')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('table-search')), '12');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(picked, 'Meja 12');

      await tester.tap(find.text('meja'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('table-none')));
      await tester.pumpAndSettle();
      expect(picked, '');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nomor antrian: sejak barang pertama, sekali per pesanan; tampil di pesanan tersimpan & riwayat; tercetak; dikirim', (tester) async {
      final (local, container, printers) = await pumpApp(tester, prefs: twoPrinters);
      // Barang pertama → antrian 000001, langsung tampil; disimpan dengan nomornya.
      await tap(tester, find.byKey(const Key('product-1')));
      expect(container.read(cartProvider).queueNumber, '000001');
      expect(find.text('Antrian 000001'), findsOneWidget);
      await tap(tester, find.byKey(const Key('hold-order')));
      await tap(tester, find.byKey(const Key('hold-save')));
      final held = (await tester.runAsync(() => HeldOrderStore(local).all()))!;
      expect(held.single.cart.queueNumber, '000001');
      await tap(tester, find.byKey(const Key('held-orders')));
      expect(held.single.name, '000001-Tanpa meja', reason: 'Nama bawaan = nomor pesanan + meja.');
      expect(tester.widget<Text>(find.byKey(Key('held-details-${held.single.id}'))).data, startsWith('1 barang'), reason: 'Nomor tidak diulang di keterangan.');
      Navigator.of(tester.element(find.byType(HeldOrdersSheet))).pop();
      await flush(tester);

      // Pesanan baru: 000002; Cetak list tidak memberi nomor baru; bayar memakai nomor yang sama.
      await tap(tester, find.byKey(const Key('product-2')));
      expect(container.read(cartProvider).queueNumber, '000002');
      await tap(tester, find.byKey(const Key('cart-print-list')));
      expect(container.read(cartProvider).queueNumber, '000002');
      expect(find.text('Antrian 000002'), findsOneWidget);
      final list = printers.writes.last;
      expect(list.$1, 'BB:02', reason: 'List ke printer dapur.');
      expect(latin1.decode(list.$2, allowInvalid: true), allOf(contains('PRINTER DAPUR'), contains('ANTRIAN 000002')));
      await tap(tester, find.byKey(const Key('cart-print-list')));
      expect(container.read(cartProvider).queueNumber, '000002', reason: 'Tidak diberi nomor baru.');

      GoRouter.of(tester.element(find.byType(KasirScreen))).push('/bayar');
      await flush(tester);
      await tap(tester, find.byKey(const Key('pay-submit')));
      expect(find.text('Penjualan tersimpan'), findsOneWidget);
      final receipt = printers.writes.last;
      expect(receipt.$1, 'AA:01', reason: 'Struk ke printer kasir.');
      expect(latin1.decode(receipt.$2, allowInvalid: true), contains('Antrian 000002'));
      final outbox = (await tester.runAsync(() => local.db.query('outbox', where: "type = 'sale'")))!;
      expect((jsonDecode(outbox.single['data'] as String) as Map)['queue_number'], '000002');

      // Riwayat nota: nomor antrian terlihat di daftar.
      await tap(tester, find.byKey(const Key('new-sale')));
      GoRouter.of(tester.element(find.byType(KasirScreen))).push('/riwayat');
      await flush(tester);
      expect(find.textContaining('Antrian 000002'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('list ke dapur otomatis setelah bayar: struk ke kasir lalu list ke dapur; dapur gagal disebut, struk tetap', (tester) async {
      for (final failing in [<String>{}, {'BB:02'}]) {
        final (local, container, printers) = await pumpApp(tester, prefs: {...twoPrinters, 'auto_print_kitchen': true}, failing: failing);
        container.read(cartProvider.notifier).add(kopi);
        GoRouter.of(tester.element(find.byType(KasirScreen))).push('/bayar');
        await flush(tester);
        await tap(tester, find.byKey(const Key('pay-submit')));
        expect(find.text('Penjualan tersimpan'), findsOneWidget);
        final receipt = printers.writes.firstWhere((write) => write.$1 == 'AA:01');
        expect(latin1.decode(receipt.$2, allowInvalid: true), contains('LUNAS'));
        if (failing.isEmpty) {
          expect(printers.writes.map((write) => write.$1), ['AA:01', 'BB:02'], reason: 'Berurutan: struk dulu, lalu list.');
          expect(latin1.decode(printers.writes.last.$2, allowInvalid: true), contains('PRINTER DAPUR'));
          expect(find.byKey(const Key('done-kitchen-failed')), findsNothing);
        } else {
          expect(printers.writes.map((write) => write.$1), ['AA:01']);
          expect(find.byKey(const Key('done-kitchen-failed')), findsOneWidget);
          expect(find.text('Belum tercetak: Printer Dapur'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(local.close);
      }
    });

    testWidgets('role tanpa izin ubah harga: harga & diskon terkunci, Diskon nota tidak ada; nama simpan = nomor pesanan + meja', (tester) async {
      final (local, container, _) = await pumpApp(tester, menus: {'pos': true, 'printer': true, 'edit_price': false});
      await tap(tester, find.byKey(const Key('product-1')));
      expect(find.byKey(const Key('order-discount')), findsNothing);
      final line = container.read(cartProvider).lines.single;
      await tap(tester, find.byKey(Key('line-tap-${line.key}')));
      expect(tester.widget<TextField>(find.byKey(const Key('line-price'))).enabled, isFalse);
      expect(tester.widget<TextField>(find.byKey(const Key('line-discount'))).enabled, isFalse);
      Navigator.of(tester.element(find.byKey(const Key('line-price')))).pop();
      await flush(tester);

      await tap(tester, find.byKey(const Key('hold-order')));
      expect(tester.widget<TextField>(find.byKey(const Key('hold-name'))).controller?.text, '${container.read(cartProvider).queueNumber}-Tanpa meja');
      expect(container.read(cartProvider).queueNumber, '000001');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('Pengaturan kasir: cari printer Wi-Fi, tambah beberapa sekaligus, beri nama & kategori', (tester) async {
      final network = _Network();
      final (local, container, _) = await pumpApp(tester, prefs: const {'printer_mac': 'AA:01', 'printer_name': 'Kasir'}, network: network);
      GoRouter.of(tester.element(find.byType(KasirScreen))).push('/printer');
      await flush(tester);
      expect(find.byKey(const Key('printer-kasir')), findsOneWidget);

      await tap(tester, find.byKey(const Key('printer-add-production')));
      await tap(tester, find.text('Wi-Fi'));
      await tap(tester, find.byKey(const Key('printer-wifi-search')));
      await tap(tester, find.byKey(const Key('printer-option-10.0.0.5')));
      await tap(tester, find.byKey(const Key('printer-option-10.0.0.6')));
      expect(find.text('Tambah 2 printer'), findsOneWidget);
      await tap(tester, find.byKey(const Key('printer-add-done')));
      final added = container.read(printerProvider).production;
      expect([for (final printer in added) '${printer.name}:${printer.mac}:${printer.isWifi}'], ['Printer 1:10.0.0.5:true', 'Printer 2:10.0.0.6:true']);

      // Ubah: nama "Bar", hanya kategori Minuman.
      await tap(tester, find.byKey(Key('printer-production-${added.first.id}')));
      await tester.enterText(find.byKey(const Key('printer-name')), 'Bar');
      await tap(tester, find.byKey(const Key('printer-category-2')));
      await tap(tester, find.byKey(const Key('printer-save')));
      final bar = container.read(printerProvider).production.first;
      expect(bar.name, 'Bar');
      expect(bar.categoryIds, [2]);
      expect(container.read(storageProvider).productionPrinters.first.categoryIds, [2]);
      expect(find.text('Minuman'), findsOneWidget);
      expect(find.text('Semua kategori'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });
  });
}

/// Printer Wi-Fi palsu: mencatat byte per IP dan berapa yang bersamaan.
class _Network implements NetworkPrinterTransport {
  Set<String> failing = {};
  final Map<String, List<List<int>>> sent = {};
  int _active = 0;
  int maxConcurrent = 0;

  @override
  Future<bool> send(String host, int port, List<int> bytes) async {
    _active++;
    maxConcurrent = _active > maxConcurrent ? _active : maxConcurrent;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (failing.contains(host)) {
        return false;
      }
      (sent[host] ??= []).add(bytes);
      return true;
    } finally {
      _active--;
    }
  }

  @override
  Future<List<String>> discover({int port = 9100}) async => const ['10.0.0.5', '10.0.0.6'];
}

/// Printer Bluetooth palsu: satu sambungan, mencatat urutan sambung/cetak.
class _Printers implements PrinterTransport {
  _Printers({Set<String> failing = const {}}) : failing = {...failing};

  Set<String> failing;
  final List<String> events = [];
  final List<(String, List<int>)> writes = [];
  String? _connected;
  int _active = 0;
  int maxConcurrent = 0;

  Future<T> _busy<T>(Future<T> Function() job) async {
    _active++;
    maxConcurrent = _active > maxConcurrent ? _active : maxConcurrent;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      return await job();
    } finally {
      _active--;
    }
  }

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> bluetoothOn() async => true;

  @override
  Future<List<PrinterDevice>> pairedDevices() async => const [PrinterDevice(name: 'Printer Kasir', mac: 'AA:01'), PrinterDevice(name: 'Printer Dapur', mac: 'BB:02')];

  @override
  Future<bool> connect(String mac) => _busy(() async {
        events.add('connect:$mac');
        if (failing.contains(mac)) {
          return false;
        }
        _connected = mac;
        return true;
      });

  @override
  Future<bool> isConnected() async => _connected != null;

  @override
  Future<bool> write(List<int> bytes) => _busy(() async {
        events.add('write:$_connected');
        if (_connected == null) {
          return false;
        }
        writes.add((_connected!, bytes));
        return true;
      });

  @override
  Future<void> disconnect() async {
    events.add('disconnect');
    _connected = null;
  }
}

/// Pump beberapa frame dan beri waktu nyata untuk database & printer.
Future<void> flush(WidgetTester tester, {int rounds = 5}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    for (var j = 0; j < 6; j++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}
