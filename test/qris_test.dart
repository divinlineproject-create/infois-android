import 'dart:convert';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/domain/qris.dart';
import 'package:infois/domain/report_models.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/printing/receipt_builder.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/kasir_screen.dart';
import 'package:infois/ui/screens/pay_screen.dart' show qrisOfflineMessage;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Bayar QRIS dinamis (akun DOKU perusahaan) di layar Bayar: QR dibuat di
/// server, statusnya ditanyakan tiap 3 detik, dibayar → penjualan langsung
/// dikirim dengan pembayaran `qris`. Sama dengan kasir web.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  final png = 'data:image/png;base64,${base64Encode(img.encodePng(img.Image(width: 4, height: 4)))}';
  final qrContent = '00020101021226${'6' * 300}6304ABCD';
  final expires = DateTime(2026, 11, 24, 14, 35);

  Map<String, dynamic> qrisJson({String status = 'pending', String amount = '18000.00', int id = 31, String? label}) => {
        'id': id,
        'status': status,
        'status_label': label ?? switch (status) { 'paid' => 'Dibayar', 'expired' => 'Kedaluwarsa', 'canceled' => 'Dibatalkan', _ => 'Menunggu pembayaran' },
        'amount': amount,
        if (status == 'pending') 'qr_content': qrContent,
        if (status == 'pending') 'qr_image': png,
        'expires_at': expires.toUtc().toIso8601String(),
        'paid_at': status == 'paid' ? '2026-11-24T07:31:00Z' : null,
        'issuer': status == 'paid' ? 'GoPay' : null,
        'reference': status == 'paid' ? 'REF-1' : null,
        'invoice_id': null,
      };

  group('data', () {
    test('tenant.qris: tidak ada = mati; enabled & print_on_bill terbaca', () {
      const base = {'id': 1, 'name': 'Warung'};
      final off = TenantSettings.fromJson(base);
      expect((off.qrisEnabled, off.qrisPrintOnBill), (false, false));
      final on = TenantSettings.fromJson({
        ...base,
        'qris': {'enabled': true, 'print_on_bill': true},
      });
      expect((on.qrisEnabled, on.qrisPrintOnBill), (true, true));
      expect(TenantSettings.fromJson(on.toJson()).qrisEnabled, isTrue);
    });

    test('objek qris: status, gambar QR, gabung jawaban status tanpa gambar', () {
      final pending = QrisPayment.fromJson(qrisJson());
      expect((pending.id, pending.isPending, pending.amount, pending.qrContent), (31, true, '18000.00', qrContent));
      expect(pending.imageBytes, isNotEmpty);
      final paid = pending.merge(QrisPayment.fromJson(qrisJson(status: 'paid')));
      expect((paid.isPaid, paid.issuer, paid.qrContent, paid.isOver), (true, 'GoPay', qrContent, false));
      expect(QrisPayment.fromJson(qrisJson(status: 'expired')).isOver, isTrue);
      expect(QrisPayment.fromJson({...qrisJson(), 'qr_image': 'data:image/png;base64,***'}).imageBytes, isNull);
    });

    test('pembayaran qris di penjualan: qris_payment_id dikirim; struk "Bayar - QRIS"; laporan shift baris QRIS', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      await seedMaster(local);
      final pos = PosService(local: local, user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'), master: await _master(local));
      expect(() => pos.buildPayments('18000', const PaymentInput(mode: PayMode.qris)), throwsA(isA<CheckoutException>()));

      final shift = await pos.openShift('100000');
      final cart = Cart(lines: [CartLine.fromProduct('a', kopi)]);
      final sale = await pos.checkout(clientUuid: 'q-1', cart: cart, payment: const PaymentInput(mode: PayMode.qris, qrisPaymentId: 31), shiftClientUuid: shift['client_uuid'] as String);
      expect(sale['change'], '0.00');
      final push = (await _outbox(local)).last;
      final payment = Map<String, dynamic>.from((push['payments'] as List).single as Map);
      expect(payment['client_uuid'], isNotEmpty);
      expect({...payment}..remove('client_uuid'), {'method': 'qris', 'amount': '18000.00', 'account_id': 11, 'qris_payment_id': 31});
      await pos.checkout(clientUuid: 'c-1', cart: cart, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '20000'), shiftClientUuid: shift['client_uuid'] as String);

      final builder = await ReceiptBuilder.create();
      const config = ReceiptConfig(companyName: 'Warung Tes');
      expect(latin1.decode(builder.sale(sale, config, width: 58), allowInvalid: true), allOf(contains('Bayar - QRIS'), contains('LUNAS')));
      expect(ReceiptBuilder.plainText(sale, config), contains('QRIS: Rp 18.000'));

      final summary = await pos.shiftSummary(shift);
      expect((summary['qris_total'], summary['cash_total'], summary['transfer_total'], summary['expected_cash']), ('18000.00', '18000.00', '0.00', '118000.00'));
      final report = await pos.closeShift(shift, '118000');
      final printed = latin1.decode(builder.shiftReport(report, config, width: 58), allowInvalid: true);
      expect(printed, contains('QRIS'));
      expect(printed.indexOf('QRIS'), greaterThan(printed.indexOf('Transfer')));
      // Tanpa QRIS: tidak ada baris QRIS.
      expect(latin1.decode(builder.shiftReport({...report, 'qris_total': '0.00'}, config, width: 58), allowInvalid: true), isNot(contains('QRIS')));

      // Ringkasan shift dari server: qris_total bila ada, server lama = 0.
      expect(ShiftSummary.fromJson({'qris_total': '25000.00'}).qrisTotal, '25000.00');
      expect(ShiftSummary.fromJson(const {}).qrisTotal, '0.00');
    });

    test('Cetak QR: tagihan + "Bayar dengan QRIS", perintah QR ESC/POS berisi isi QR (panjang dua byte), petunjuk scan', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      await seedMaster(local);
      final pos = PosService(local: local, user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'), master: await _master(local));
      final draft = {
        ...pos.draft(Cart(lines: [CartLine.fromProduct('a', kopi)])),
        'qris': {'content': qrContent, 'amount': '18000.00'},
      };
      final builder = await ReceiptBuilder.create();
      final bytes = builder.bill(draft, const ReceiptConfig(companyName: 'Warung Tes'), width: 58);
      final text = latin1.decode(bytes, allowInvalid: true);
      for (final expected in ['TAGIHAN', 'BELUM DIBAYAR', 'Bayar dengan QRIS', 'Scan dengan aplikasi bank / e-wallet', qrContent]) {
        expect(text, contains(expected), reason: expected.length > 40 ? 'isi QR' : expected);
      }
      final length = qrContent.length + 3;
      expect(_indexOf(bytes, [0x1D, 0x28, 0x6B, length & 0xFF, length >> 8, 0x31, 0x50, 0x30]), greaterThanOrEqualTo(0), reason: 'Simpan data QR (GS ( k) dengan panjang > 255.');
      expect(_indexOf(bytes, [0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]), greaterThan(0), reason: 'Cetak QR.');
      // Tagihan biasa: tanpa blok QRIS.
      expect(latin1.decode(builder.bill(pos.draft(Cart(lines: [CartLine.fromProduct('a', kopi)])), const ReceiptConfig(companyName: 'Warung Tes'), width: 58), allowInvalid: true), isNot(contains('Bayar dengan QRIS')));
    });
  });

  group('layar Bayar', () {
    late List<RequestOptions> requests;
    late List<Map<String, dynamic>> pushed;

    Future<(LocalDb, ProviderContainer, FakePrinter)> pumpApp(
      WidgetTester tester, {
      Map<String, dynamic>? qris,
      required Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) handler,
    }) async {
      requests = [];
      pushed = [];
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
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
        await db.setJson(MetaKeys.tenant, {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00', if (qris != null) 'qris': qris});
        return db;
      }))!;
      final printer = FakePrinter();
      final server = FakeServer((options, body) {
        requests.add(options);
        if (options.path == 'sync/push') {
          pushed.add(body!);
        }
        return handler(options, body);
      });
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
      await flush(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(KasirScreen)));
      container.read(cartProvider.notifier).add(kopi);
      GoRouter.of(tester.element(find.byType(KasirScreen))).push('/bayar');
      await flush(tester);
      return (local, container, printer);
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await flush(tester);
    }

    String payLabel(WidgetTester tester) => (tester.widget(find.descendant(of: find.byKey(const Key('pay-submit')), matching: find.byType(Text))) as Text).data!;
    bool payEnabled(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const Key('pay-submit'))).onPressed != null;
    Iterable<RequestOptions> qrisCalls(String method) => requests.where((options) => options.path.startsWith('pos/qris') && options.method == method);

    Map<String, dynamic>? Function(RequestOptions, Map<String, dynamic>?) server({
      required String Function() status,
      Map<String, dynamic> Function()? push,
      Map<String, dynamic>? Function()? create,
    }) =>
        (options, body) {
          if (options.path == 'ping') {
            return {'ok': true, 'min_app_version': '1.0.0'};
          }
          if (options.path == 'pos/qris' && options.method == 'POST') {
            return create == null ? {'_status': 201, 'qris': qrisJson()} : create();
          }
          if (options.path.startsWith('pos/qris/') && options.method == 'GET') {
            return {'qris': qrisJson(status: status())};
          }
          if (options.path.startsWith('pos/qris/') && options.method == 'DELETE') {
            return {'qris': qrisJson(status: 'canceled')};
          }
          if (options.path == 'sync/push') {
            final extra = push?.call() ?? {'status': 'ok'};
            return {
              'results': [
                for (final item in body!['items'] as List) {'client_uuid': item['client_uuid'], 'type': item['type'], ...extra},
              ],
            };
          }
          return null;
        };

    testWidgets('QRIS mati: tidak ada pilihan QRIS', (tester) async {
      final (local, _, _) = await pumpApp(tester, handler: (_, __) => null);
      expect(find.text('Tunai'), findsOneWidget);
      expect(find.text('QRIS'), findsNothing);
      expect(find.byIcon(Icons.qr_code), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('QRIS: buat QR → menunggu → dibayar → penjualan langsung dikirim dengan pembayaran qris', (tester) async {
      var status = 'pending';
      final (local, _, printer) = await pumpApp(tester, qris: {'enabled': true, 'print_on_bill': false}, handler: server(status: () => status));
      await tap(tester, find.text('QRIS'));
      expect(qrisCalls('POST').single.data, {'amount': '18000.00'});
      expect(find.byKey(const Key('qris-image')), findsOneWidget);
      expect(find.byKey(const Key('qris-amount')), findsOneWidget);
      expect(find.text('Scan dengan aplikasi bank / e-wallet · berlaku sampai 14:35'), findsOneWidget);
      expect(find.text('Menunggu pembayaran…'), findsOneWidget);
      expect(find.byKey(const Key('qris-print')), findsNothing, reason: 'print_on_bill mati.');
      expect(find.byKey(const Key('key-1')), findsNothing, reason: 'Tanpa keypad tunai.');
      expect(payLabel(tester), 'Menunggu pembayaran QRIS…');
      expect(payEnabled(tester), isFalse);

      // Dicek tiap 3 detik: masih menunggu.
      await tester.pump(const Duration(seconds: 3));
      await flush(tester);
      expect(qrisCalls('GET'), hasLength(1));
      expect(pushed, isEmpty);

      // Dibayar → simpan + kirim langsung → struk.
      status = 'paid';
      await tester.pump(const Duration(seconds: 3));
      await flush(tester, rounds: 10);
      expect(find.text('Penjualan tersimpan'), findsOneWidget);
      final sale = pushed.expand((body) => body['items'] as List).firstWhere((item) => item['type'] == 'sale')['data'] as Map;
      final payment = (sale['payments'] as List).single as Map;
      expect((payment['method'], payment['amount'], payment['qris_payment_id'], payment['account_id']), ('qris', '18000.00', 31, 11));
      expect(sale['total'], '18000.00');
      expect(latin1.decode(printer.printed.last, allowInvalid: true), contains('Bayar - QRIS'));
      expect(qrisCalls('DELETE'), isEmpty, reason: 'QR yang dibayar tidak dibatalkan.');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('QRIS dibayar tapi penjualan ditolak server: pesan tampil, QR tetap, Simpan penjualan dicoba lagi', (tester) async {
      var reject = true;
      final (local, container, _) = await pumpApp(
        tester,
        qris: {'enabled': true},
        handler: server(status: () => 'paid', push: () => reject ? {'status': 'ditolak', 'message': 'QRIS belum dibayar (Menunggu pembayaran).'} : {'status': 'ok'}),
      );
      await tap(tester, find.text('QRIS'));
      await tester.pump(const Duration(seconds: 3));
      await flush(tester, rounds: 10);
      expect(find.text('QRIS belum dibayar (Menunggu pembayaran).'), findsOneWidget);
      expect(find.text('Pembayaran diterima · GoPay'), findsOneWidget);
      expect(payLabel(tester), 'Simpan penjualan');
      expect(payEnabled(tester), isTrue);
      expect(container.read(cartProvider).lines, hasLength(1), reason: 'Keranjang tetap.');

      reject = false;
      await tap(tester, find.byKey(const Key('pay-submit')));
      await flush(tester, rounds: 10);
      expect(find.text('Penjualan tersimpan'), findsOneWidget);
      final uuids = [for (final body in pushed) for (final item in body['items'] as List) if (item['type'] == 'sale') item['client_uuid']];
      expect(uuids, hasLength(2));
      expect(uuids.toSet(), hasLength(1), reason: 'Penjualan yang sama dikirim ulang (tidak dobel).');
      expect(container.read(cartProvider).isEmpty, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('QRIS gagal dibuat: pesan server + Coba lagi; offline: QRIS butuh internet', (tester) async {
      var offline = false;
      final (local, _, _) = await pumpApp(
        tester,
        qris: {'enabled': true},
        handler: (options, body) {
          if (options.path == 'pos/qris') {
            return offline ? null : {'_status': 422, 'code': 'qris_gagal', 'message': 'QRIS hanya untuk total tanpa sen.'};
          }
          return null;
        },
      );
      await tap(tester, find.text('QRIS'));
      expect(find.text('QRIS hanya untuk total tanpa sen.'), findsOneWidget);
      expect(find.text('Coba lagi'), findsOneWidget);
      expect(payEnabled(tester), isFalse);

      offline = true;
      await tap(tester, find.byKey(const Key('qris-retry')));
      expect(find.text(qrisOfflineMessage), findsOneWidget);
      expect(qrisOfflineMessage, 'QRIS butuh internet. Sambungkan internet lalu coba lagi.');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('Batalkan QR: DELETE ke server, kembali ke Tunai; keluar dari Bayar juga membatalkan', (tester) async {
      final (local, _, _) = await pumpApp(tester, qris: {'enabled': true}, handler: server(status: () => 'pending'));
      await tap(tester, find.text('QRIS'));
      await tap(tester, find.byKey(const Key('qris-cancel')));
      expect(qrisCalls('DELETE').single.path, 'pos/qris/31');
      expect(find.byKey(const Key('qris-panel')), findsNothing);
      expect(find.byKey(const Key('key-1')), findsOneWidget, reason: 'Kembali ke Tunai (keypad).');

      // Pindah ke Transfer saat QR menunggu: dibatalkan juga.
      await tap(tester, find.text('QRIS'));
      await tap(tester, find.text('Transfer'));
      expect(qrisCalls('DELETE'), hasLength(2));

      // Keluar dari layar Bayar saat QR menunggu.
      await tap(tester, find.text('QRIS'));
      await tester.binding.handlePopRoute();
      await flush(tester);
      expect(find.byKey(const Key('pay-submit')), findsNothing);
      expect(qrisCalls('DELETE'), hasLength(3));
      // Tidak ada pengecekan lagi setelah keluar.
      final gets = qrisCalls('GET').length;
      await tester.pump(const Duration(seconds: 7));
      await flush(tester);
      expect(qrisCalls('GET'), hasLength(gets));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });

    testWidgets('QR kedaluwarsa: label status + Buat QR baru; Cetak QR saat print_on_bill', (tester) async {
      var status = 'pending';
      final (local, _, printer) = await pumpApp(tester, qris: {'enabled': true, 'print_on_bill': true}, handler: server(status: () => status));
      await tap(tester, find.text('QRIS'));
      expect(find.text('Cetak QR'), findsOneWidget);
      await tap(tester, find.byKey(const Key('qris-print')));
      final bill = latin1.decode(printer.printed.last, allowInvalid: true);
      expect(bill, allOf(contains('TAGIHAN'), contains('Bayar dengan QRIS'), contains(qrContent), contains('Scan dengan aplikasi bank / e-wallet')));
      expect(pushed, isEmpty, reason: 'Cetak QR tidak mencatat penjualan.');

      status = 'expired';
      await tester.pump(const Duration(seconds: 3));
      await flush(tester);
      expect(find.text('Kedaluwarsa'), findsOneWidget);
      expect(find.byKey(const Key('qris-image')), findsNothing);
      expect(find.text('Cetak QR'), findsNothing);
      expect(find.text('Buat QR baru'), findsOneWidget);
      expect(payEnabled(tester), isFalse);

      status = 'pending';
      await tap(tester, find.byKey(const Key('qris-new')));
      expect(qrisCalls('POST'), hasLength(2));
      expect(find.byKey(const Key('qris-image')), findsOneWidget);
      // QR menunggu dibatalkan dulu (request DELETE selesai sebelum tes berakhir).
      await tap(tester, find.byKey(const Key('qris-cancel')));
      expect(qrisCalls('DELETE'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(local.close);
    });
  });
}

/// Pump beberapa frame dan beri waktu nyata untuk request & database.
Future<void> flush(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    for (var j = 0; j < 6; j++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return i;
    }
  }
  return -1;
}

Future<List<Map<String, dynamic>>> _outbox(LocalDb local) async {
  final rows = await local.db.query('outbox', where: "type = 'sale'", orderBy: 'seq ASC');
  return [for (final row in rows) Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map)];
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
