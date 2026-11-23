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
import 'package:infois/domain/models.dart';
import 'package:infois/services/printing/receipt_builder.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/kasir_screen.dart';
import 'package:infois/ui/screens/shift_screens.dart';
import 'package:infois/ui/theme.dart' show warningText;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Uang tunai kasir (Pengaturan Kasir › "Uang tunai kasir" di web): akun
/// laci tampil di layar Bayar, uang awal & setoran otomatis dari server
/// (`cash_transfers`) tampil di Tutup kasir dan tercetak di laporan.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  const note = 'Setoran belum tercatat otomatis: akun Kas tidak aktif. Catat lewat Kas & Bank › Pindah Uang.';
  Map<String, dynamic> transfersJson({bool withNote = false}) => {
        'float': {'number': 'TRF/2026/0001', 'amount': '200000.00', 'from': 'Kas', 'to': 'Kas Kasir', 'status': 'Tercatat'},
        'deposit': {'number': 'TRF/2026/0002', 'amount': '240000.00', 'from': 'Kas Kasir', 'to': 'Kas', 'status': 'Menunggu persetujuan'},
        'note': withNote ? note : null,
      };

  group('data & cetak', () {
    test('cash_transfers: uang awal, setoran, catatan; data shift lama tanpa kunci = tidak ada', () {
      final transfers = ShiftCashTransfers.fromJson(transfersJson(withNote: true))!;
      expect((transfers.float!.number, transfers.float!.amount, transfers.float!.from, transfers.float!.to, transfers.float!.status), ('TRF/2026/0001', '200000.00', 'Kas', 'Kas Kasir', 'Tercatat'));
      expect(transfers.deposit!.status, 'Menunggu persetujuan');
      expect(transfers.note, note);
      expect(ShiftCashTransfers.fromJson(transfers.toJson())!.deposit!.amount, '240000.00');

      final old = {'id': 5, 'client_uuid': 's-1', 'opened_at': '2026-11-24T01:00:00Z', 'opening_cash': '200000.00'};
      expect(ShiftCashTransfers.fromJson(old['cash_transfers']), isNull);
      expect(ShiftCashTransfers.fromJson({'float': null, 'deposit': null, 'note': null})!.isEmpty, isTrue);

      expect(cashTransferLine('Uang awal', transfers.float!), 'Uang awal Rp 200.000: Kas → Kas Kasir (TRF/2026/0001, tercatat)');
      expect(cashTransferLine('Setoran', transfers.deposit!), 'Setoran Rp 240.000: Kas Kasir → Kas (TRF/2026/0002, menunggu persetujuan)');
      expect(cashTransferLine('Setoran', const CashTransfer(amount: '1000.00')), 'Setoran Rp 1.000');
    });

    test('laporan tutup kasir tercetak: uang awal & setoran setelah Selisih, lalu catatan; server lama tanpa baris itu', () async {
      final builder = await ReceiptBuilder.create();
      const config = ReceiptConfig(companyName: 'Warung Tes');
      final report = {
        'cashier': 'Sari',
        'opened_at': '2026-11-24T01:00:00Z',
        'closed_at': '2026-11-24T10:00:00Z',
        'sales_count': 3,
        'sales_total': '90000.00',
        'cash_total': '40000.00',
        'transfer_total': '50000.00',
        'unpaid_total': '0.00',
        'opening_cash': '200000.00',
        'expected_cash': '240000.00',
        'closing_cash': '240000.00',
        'difference': '0.00',
      };
      final printed = latin1.decode(builder.shiftReport({...report, 'cash_transfers': transfersJson(withNote: true)}, config, width: 58), allowInvalid: true);
      for (final expected in ['Selisih', 'Uang awal ke', 'Rp 200.000', 'Setoran ke', 'Rp 240.000', 'Setoran belum tercatat otomatis', 'Kas & Bank > Pindah Uang.']) {
        expect(printed, contains(expected), reason: expected);
      }
      expect(printed.indexOf('Uang awal ke'), greaterThan(printed.indexOf('Selisih')));
      expect(printed.indexOf('Setoran ke'), greaterThan(printed.indexOf('Uang awal ke')));
      expect(printed.indexOf('Setoran belum tercatat'), greaterThan(printed.indexOf('Setoran ke')));

      final old = latin1.decode(builder.shiftReport(report, config, width: 58), allowInvalid: true);
      expect(old, contains('Selisih'));
      expect(old, isNot(contains('Uang awal ke')));
      expect(old, isNot(contains('Setoran ke')));
    });
  });

  group('kasir', () {
    Future<(LocalDb, ProviderContainer, FakePrinter)> pumpApp(
      WidgetTester tester, {
      Map<String, dynamic>? accounts,
      Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body)? handler,
      Future<void> Function(LocalDb local)? extra,
    }) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'session': jsonEncode({
          'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
          'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, shift: true, printer: true)).toJson()],
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
        await seedMaster(db, menus: {'pos': true, 'shift': true, 'printer': true});
        if (accounts != null) {
          await db.setJson(MetaKeys.accounts, accounts);
        }
        await extra?.call(db);
        return db;
      }))!;
      final printer = FakePrinter();
      final server = FakeServer(handler ?? (_, __) => null);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          localDbOpenerProvider.overrideWithValue((_) async => local),
          apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
          connectivityStreamProvider.overrideWithValue(const Stream.empty()),
          printerTransportProvider.overrideWithValue(printer),
        ],
        child: const InfoisApp(),
      ));
      await settle(tester);
      // Sinkron saat aplikasi dibuka selesai dulu.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await settle(tester);
      }
      return (local, ProviderScope.containerOf(tester.element(find.byType(KasirScreen))), printer);
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await settle(tester);
    }

    Future<void> openPay(WidgetTester tester, ProviderContainer container) async {
      container.read(cartProvider.notifier).add(kopi);
      GoRouter.of(tester.element(find.byType(KasirScreen))).push('/bayar');
      await settle(tester);
    }

    testWidgets('Bayar: lebih dari satu akun kas → "Uang tunai masuk ke: Kas Kasir" untuk tunai & campur', (tester) async {
      final (local, container, _) = await pumpApp(tester, accounts: {
        'items': [
          {'id': 11, 'code': '1-1100', 'name': 'Kas', 'kind': 'cash'},
          {'id': 13, 'code': '1-1110', 'name': 'Kas Kasir', 'kind': 'cash'},
          {'id': 12, 'code': '1-1200', 'name': 'Bank BCA', 'kind': 'bank'},
        ],
        'default_cash_id': 13,
        'default_transfer_id': 12,
      });
      await openPay(tester, container);
      expect(find.text('Uang tunai masuk ke: Kas Kasir'), findsOneWidget);
      await tap(tester, find.text('Transfer'));
      expect(find.byKey(const Key('pay-cash-account')), findsNothing);
      await tap(tester, find.text('Campur'));
      expect(find.text('Uang tunai masuk ke: Kas Kasir'), findsOneWidget);
      await tap(tester, find.text('Bon'));
      expect(find.byKey(const Key('pay-cash-account')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('Bayar: satu akun kas → tanpa keterangan akun', (tester) async {
      final (local, container, _) = await pumpApp(tester);
      await openPay(tester, container);
      expect(find.byKey(const Key('pay-total')), findsOneWidget);
      expect(find.byKey(const Key('pay-cash-account')), findsNothing);
      expect(find.textContaining('Uang tunai masuk ke'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    Future<void> closeShift(WidgetTester tester) async {
      GoRouter.of(tester.element(find.byType(KasirScreen))).push('/tutup-kasir');
      await settle(tester);
      for (var i = 0; i < 3 && find.byType(TextField).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await settle(tester);
      }
      await tester.enterText(find.byType(TextField), '240000');
      await tap(tester, find.text('Tutup kasir & cetak laporan'));
      for (var i = 0; i < 10 && find.text('Kasir ditutup').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await settle(tester);
      }
      expect(find.text('Kasir ditutup'), findsOneWidget);
    }

    Future<void> seedShift(LocalDb local) => local.saveShift({'client_uuid': 'shift-1', 'opened_at': '2026-11-24T01:00:00Z', 'closed_at': null, 'opening_cash': '200000.00', 'closing_cash': null, 'cashier': 'Sari'});

    Map<String, dynamic>? Function(RequestOptions, Map<String, dynamic>?) server({required bool transfers}) => (options, body) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          'sync/push' => {
              'results': [
                for (final item in body!['items'] as List)
                  {
                    'client_uuid': item['client_uuid'],
                    'type': item['type'],
                    'status': 'ok',
                    if (item['type'] == 'shift_close')
                      'shift': {
                        'id': 5,
                        'client_uuid': (item['data'] as Map)['shift_client_uuid'],
                        'opened_at': '2026-11-24T01:00:00Z',
                        'opening_cash': '200000.00',
                        'closing_cash': '240000.00',
                        if (transfers) 'cash_transfers': transfersJson(withNote: true),
                      },
                  },
              ],
            },
          _ => null,
        };

    testWidgets('Tutup kasir: uang awal & setoran otomatis dari server tampil, catatan berwarna peringatan, ikut tercetak', (tester) async {
      final (local, _, printer) = await pumpApp(tester, handler: server(transfers: true), extra: seedShift);
      await closeShift(tester);

      expect(find.text('Uang awal Rp 200.000: Kas → Kas Kasir (TRF/2026/0001, tercatat)'), findsOneWidget);
      expect(find.text('Setoran Rp 240.000: Kas Kasir → Kas (TRF/2026/0002, menunggu persetujuan)'), findsOneWidget);
      final noteText = tester.widget<Text>(find.byKey(const Key('shift-transfer-note')));
      expect(noteText.data, note);
      expect(noteText.style?.color, warningText(tester.element(find.byKey(const Key('shift-transfer-note')))));

      expect(printer.printed, isNotEmpty);
      final report = latin1.decode(printer.printed.last, allowInvalid: true);
      expect(report, allOf(contains('LAPORAN TUTUP KASIR'), contains('Uang awal ke'), contains('Setoran ke'), contains('Rp 240.000'), contains('Setoran belum tercatat otomatis')));
      final stored = (await tester.runAsync(() => local.shift('shift-1')))!;
      expect((stored['server'] as Map)['cash_transfers'], isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('Tutup kasir: server lama (tanpa cash_transfers) atau offline → tanpa baris pindah uang', (tester) async {
      for (final handler in [server(transfers: false), null]) {
        final (local, _, printer) = await pumpApp(tester, handler: handler, extra: seedShift);
        await closeShift(tester);
        expect(find.byKey(const Key('shift-transfers')), findsNothing);
        expect(find.textContaining('Uang awal Rp'), findsNothing);
        expect(printer.printed, isNotEmpty);
        expect(latin1.decode(printer.printed.last, allowInvalid: true), isNot(contains('Setoran ke')));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(local.close);
      }
    });
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
