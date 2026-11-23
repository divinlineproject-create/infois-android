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
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Rumah makan: daftar meja dari web, nomor antrian harian per HP. Printer
/// kasir & printer dapur (list ke dapur, berurutan, otomatis setelah bayar).
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

  group('printer kasir & dapur', () {
    Future<(ProviderContainer, _Printers)> printerContainer(Map<String, Object> prefs, {Set<String> failing = const {}}) async {
      SharedPreferences.setMockInitialValues(prefs);
      FlutterSecureStorage.setMockInitialValues({'device_uid': 'hp-tes'});
      final storage = await AppStorage.load();
      final printers = _Printers(failing: failing);
      final container = ProviderContainer(overrides: [
        storageProvider.overrideWithValue(storage),
        printerTransportProvider.overrideWithValue(printers),
        workspaceProvider.overrideWith((ref) async => null),
      ]);
      addTearDown(container.dispose);
      container.read(printerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return (container, printers);
    }

    test('pengaturan printer lama = printer kasir; tanpa printer dapur list ke printer kasir', () async {
      final (container, _) = await printerContainer({'printer_mac': 'AA:01', 'printer_name': 'RPP02N', 'printer_width': 58});
      final state = container.read(printerProvider);
      expect((state.printer?.mac, state.kitchen), ('AA:01', null));
      expect(state.printerFor(PrinterRole.dapur)?.mac, 'AA:01');
      expect(container.read(storageProvider).autoPrintKitchen, isFalse, reason: 'List dapur otomatis bawaannya mati.');
    });

    test('dua printer: dicetak berurutan (Bluetooth berpindah), bukan bersamaan; dapur gagal tidak menahan kasir', () async {
      final (container, printers) = await printerContainer(twoPrinters);
      final notifier = container.read(printerProvider.notifier);
      printers.events.clear();
      final results = await Future.wait([
        notifier.printBytes([1], role: PrinterRole.kasir),
        notifier.printBytes([2], role: PrinterRole.dapur),
        notifier.printBytes([3], role: PrinterRole.kasir),
      ]);
      expect(results, everyElement(PrintResult.printed));
      expect(printers.writes.map((write) => '${write.$1}:${write.$2.single}'), ['AA:01:1', 'BB:02:2', 'AA:01:3']);
      expect(printers.events, ['write:AA:01', 'disconnect', 'connect:BB:02', 'write:BB:02', 'disconnect', 'connect:AA:01', 'write:AA:01']);
      expect(printers.maxConcurrent, 1);

      printers.failing = {'BB:02'};
      final kitchen = await notifier.printBytes([4], role: PrinterRole.dapur);
      expect(kitchen, PrintResult.failed);
      expect(container.read(printerProvider).kitchenMessage, kitchenPrinterFailedMessage);
      expect(container.read(printerProvider).hasFailedJob, isFalse, reason: 'Gagal di dapur bukan struk gagal.');
      expect(await notifier.printBytes([5]), PrintResult.printed);
      expect(printers.writes.last.$1, 'AA:01');
      expect(kitchenPrinterFailedMessage, startsWith('Printer dapur belum tersambung'));
    });
  });

  group('kasir', () {
    Future<(LocalDb, ProviderContainer, _Printers)> pumpApp(WidgetTester tester, {Map<String, dynamic>? tenant, Map<String, Object> prefs = const {}, Set<String> failing = const {}}) async {
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
        await seedMaster(db, menus: {'pos': true, 'printer': true});
        await db.setJson(MetaKeys.tenant, tenant ?? tenantBase);
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

    testWidgets('nomor antrian: sekali per pesanan saat Simpan / Cetak list / bayar; tercetak di list & struk; dikirim', (tester) async {
      final (local, container, printers) = await pumpApp(tester, prefs: twoPrinters);
      // Simpan pesanan → antrian 000001.
      await tap(tester, find.byKey(const Key('product-1')));
      await tap(tester, find.byKey(const Key('hold-order')));
      await tap(tester, find.byKey(const Key('hold-save')));
      final held = (await tester.runAsync(() => HeldOrderStore(local).all()))!;
      expect(held.single.cart.queueNumber, '000001');

      // Pesanan baru: Cetak list → 000002, tampil di kepala panel; bayar memakai nomor yang sama.
      await tap(tester, find.byKey(const Key('product-2')));
      expect(container.read(cartProvider).queueNumber, isNull);
      await tap(tester, find.byKey(const Key('cart-print-list')));
      expect(container.read(cartProvider).queueNumber, '000002');
      expect(find.text('Antrian 000002'), findsOneWidget);
      final list = printers.writes.last;
      expect(list.$1, 'BB:02', reason: 'List ke printer dapur.');
      expect(latin1.decode(list.$2, allowInvalid: true), allOf(contains('LIST PESANAN'), contains('ANTRIAN 000002')));
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
          expect(latin1.decode(printers.writes.last.$2, allowInvalid: true), contains('LIST PESANAN'));
          expect(find.byKey(const Key('done-kitchen-failed')), findsNothing);
        } else {
          expect(printers.writes.map((write) => write.$1), ['AA:01']);
          expect(find.byKey(const Key('done-kitchen-failed')), findsOneWidget);
          expect(find.textContaining('Printer dapur belum tersambung'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(local.close);
      }
    });
  });
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
