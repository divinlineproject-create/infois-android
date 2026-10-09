import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/master_data.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/domain/numbering.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/sync_engine.dart';

import 'support/fakes.dart';

Future<MasterData> masterFrom(LocalDb local) async {
  final accounts = (await local.getJson(MetaKeys.accounts))!;
  return MasterData(
    tenant: TenantSettings.fromJson((await local.getJson(MetaKeys.tenant))!),
    receipt: ReceiptConfig.fromJson((await local.getJson(MetaKeys.receipt))!),
    accounts: [for (final account in accounts['items'] as List) CashAccount.fromJson(Map<String, dynamic>.from(account as Map))],
    menus: Menus.fromJson(await local.getJson(MetaKeys.menus)),
    defaultCashId: accounts['default_cash_id'] as int,
    defaultTransferId: accounts['default_transfer_id'] as int,
    productCount: 2,
  );
}

Cart cartOf(List<(Product, String)> items, {Customer? customer, String nota = '0'}) => Cart(
      lines: [for (final (index, (product, quantity)) in items.indexed) CartLine.fromProduct('l$index', product, quantity: quantity)],
      customer: customer,
      notaDiscountPercent: nota,
    );

void main() {
  late LocalDb local;
  late OutboxStore outbox;
  late PosService pos;

  setUp(() async {
    local = await memoryDb();
    await seedMaster(local);
    outbox = OutboxStore(local);
    pos = PosService(local: local, user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'), master: await masterFrom(local));
  });

  tearDown(() => local.close());

  group('nomor nota offline', () {
    test('berurutan dari jatah perangkat lalu pindah ke jatah berikutnya', () {
      const blocks = [NumberBlock(id: 1, format: 'POS-K1/{SEQ:6}', start: 1, end: 2), NumberBlock(id: 2, format: 'POS-K1/{SEQ:6}', start: 501, end: 600)];
      final date = DateTime(2026, 10, 7);
      expect(NumberAllocator.next(blocks, 0, date)!.number, 'POS-K1/000001');
      expect(NumberAllocator.next(blocks, 1, date)!.number, 'POS-K1/000002');
      expect(NumberAllocator.next(blocks, 2, date)!.number, 'POS-K1/000501');
      expect(NumberAllocator.next(blocks, 600, date), isNull);
      expect(NumberAllocator.remaining(blocks, 1), 101);
      expect(NumberAllocator.render('KSR-K2-{YY}{MM}/{SEQ:5}', date, 42), 'KSR-K2-2610/00042');
    });
  });

  group('outbox', () {
    test('uuid yang sama hanya masuk sekali', () async {
      expect(await outbox.enqueue('customer', 'c-1', {'name': 'A'}), isTrue);
      expect(await outbox.enqueue('customer', 'c-1', {'name': 'A'}), isFalse);
      expect(await outbox.pendingCount(), 1);
    });

    test('jawaban server menentukan status lokal', () async {
      for (final uuid in ['a', 'b', 'c', 'd', 'e']) {
        await outbox.enqueue('sale', uuid, {'client_uuid': uuid});
      }
      await outbox.applyResults([
        {'client_uuid': 'a', 'status': 'ok'},
        {'client_uuid': 'b', 'status': 'duplikat'},
        {'client_uuid': 'c', 'status': 'perlu_ditinjau', 'message': 'Stok kurang'},
        {'client_uuid': 'd', 'status': 'ditolak', 'message': 'Tidak berhak'},
        {'client_uuid': 'e', 'status': 'ditolak', 'message': 'Server sibuk', 'retry': true},
      ]);
      final pending = await outbox.pending();
      expect(pending.map((item) => item.clientUuid), ['e']);
      expect(pending.single.attempts, 1);
      final problems = {for (final item in await outbox.problems()) item.clientUuid: item.status};
      expect(problems, {'c': OutboxStatus.review, 'd': OutboxStatus.rejected});
      expect(OutboxStore.backoff(0), const Duration(seconds: 5));
      expect(OutboxStore.backoff(10), const Duration(minutes: 5));
    });
  });

  group('bayar di kasir', () {
    test('tunai: nomor offline, kembalian, dan tombol bayar dua kali tetap satu nota', () async {
      final cart = cartOf([(kopi, '2'), (roti, '1')]);
      final first = await pos.checkout(clientUuid: 'sale-1', cart: cart, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '60000'));
      final again = await pos.checkout(clientUuid: 'sale-1', cart: cart, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '60000'));

      expect(first['number'], 'POS-K1/000001');
      expect(again['number'], 'POS-K1/000001');
      expect(first['total'], '52650.00');
      expect(first['tax_total'], '1650.00');
      expect(first['change'], '7350.00');
      expect(first['verification_url'], 'http://tes/verify/sale-1');
      expect(await outbox.pendingCount(), 1);
      expect((await local.recentSales()).length, 1);

      final pushed = (await outbox.pending()).single;
      expect(pushed.type, 'sale');
      expect(pushed.data['payments'], [
        {'client_uuid': (first['payments'] as List).first['client_uuid'], 'method': 'cash', 'amount': '52650.00', 'account_id': 11, 'tendered': '60000.00'},
      ]);
      expect(pushed.data['items'][1]['tax_rate'], '11.00');

      final second = await pos.checkout(clientUuid: 'sale-2', cart: cart, payment: const PaymentInput(mode: PayMode.transfer, transferAccountId: 12));
      expect(second['number'], 'POS-K1/000002');
    });

    test('bon wajib pelanggan; campuran membagi tunai dan transfer', () async {
      final cart = cartOf([(kopi, '1.5')]);
      expect(
        () => pos.checkout(clientUuid: 'bon-1', cart: cart, payment: const PaymentInput(mode: PayMode.bon)),
        throwsA(isA<CheckoutException>()),
      );

      final bon = await pos.checkout(clientUuid: 'bon-2', cart: cartOf([(kopi, '1.5')], customer: const Customer(id: 7, name: 'Bu Ani')), payment: const PaymentInput(mode: PayMode.bon));
      expect(bon['payments'], isEmpty);
      expect(bon['customer_id'], 7);

      final mixed = await pos.checkout(clientUuid: 'mix-1', cart: cart, payment: const PaymentInput(mode: PayMode.mixed, cashReceived: '10000', transferAccountId: 12));
      expect([for (final payment in mixed['payments'] as List) '${payment['method']}:${payment['amount']}'], ['cash:10000.00', 'transfer:17000.00']);
    });

    test('diskon nota digabung ke diskon barang dan ikut dikirim', () async {
      final cart = cartOf([(kopi, '1')], nota: '10');
      final sale = await pos.checkout(clientUuid: 'disc-1', cart: cart, payment: const PaymentInput(mode: PayMode.cash));
      expect(sale['total'], '16200.00');
      expect((await outbox.pending()).single.data['items'][0]['discount_percent'], '10.00');
    });

    test('jatah nomor habis: penjualan tetap tersimpan tanpa nomor', () async {
      for (final uuid in ['n1', 'n2', 'n3', 'n4']) {
        await pos.checkout(clientUuid: uuid, cart: cartOf([(kopi, '1')]), payment: const PaymentInput(mode: PayMode.cash));
      }
      final sales = await local.recentSales();
      expect(sales.where((sale) => sale['number'] == null).length, 1);
      expect(await outbox.pendingCount(), 4);
    });

    test('shift: uang seharusnya = uang awal + tunai', () async {
      final shift = await pos.openShift('100000');
      await pos.checkout(clientUuid: 's1', cart: cartOf([(kopi, '1')]), payment: const PaymentInput(mode: PayMode.cash, cashReceived: '20000'), shiftClientUuid: shift['client_uuid'] as String);
      await pos.checkout(clientUuid: 's2', cart: cartOf([(kopi, '1')]), payment: const PaymentInput(mode: PayMode.transfer, transferAccountId: 12), shiftClientUuid: shift['client_uuid'] as String);
      final report = await pos.closeShift(shift, '117000');
      expect(report['sales_count'], 2);
      expect(report['expected_cash'], '118000.00');
      expect(report['difference'], '-1000.00');
      expect(await local.openShift(), isNull);
      expect((await outbox.pending()).map((item) => item.type), ['shift_open', 'sale', 'sale', 'shift_close']);
    });
  });

  group('sinkron', () {
    test('kirim outbox berurutan, simpan nomor final, dan kirim ulang tidak dobel', () async {
      await pos.addCustomer(name: 'Pak Budi');
      await pos.checkout(clientUuid: 'sync-1', cart: cartOf([(kopi, '1')]), payment: const PaymentInput(mode: PayMode.cash));
      final received = <String>[];
      final server = FakeServer((options, body) {
        if (options.path != 'sync/push') {
          return null;
        }
        final results = <Map<String, dynamic>>[];
        for (final item in body!['items'] as List) {
          final uuid = item['client_uuid'] as String;
          results.add({
            'client_uuid': uuid,
            'type': item['type'],
            'status': received.contains(uuid) ? 'duplikat' : 'ok',
            if (item['type'] == 'sale') 'number': item['data']['number'],
            if (item['type'] == 'sale') 'verification_url': 'http://tes/verify/$uuid',
            if (item['type'] == 'customer') 'customer_id': 99,
          });
          received.add(uuid);
        }
        return {'results': results};
      });
      final engine = SyncEngine(api: fakeApi(server), local: local, outbox: outbox);

      final summary = await engine.pushAll();
      expect(summary.sent, 2);
      expect(received, [isNotEmpty, 'sync-1']);
      expect(await outbox.pendingCount(), 0);
      final sale = (await local.recentSales()).single;
      expect(sale['sync_status'], 'terkirim');
      expect(sale['number'], 'POS-K1/000001');
      final customers = await local.customers(query: 'budi');
      expect(customers.single.id, 99);

      // Kiriman ulang (mis. jawaban hilang di jalan) dijawab "duplikat".
      await outbox.retry('sync-1');
      await local.db.update('outbox', {'status': OutboxStatus.pending}, where: 'client_uuid = ?', whereArgs: ['sync-1']);
      expect((await engine.pushAll()).sent, 1);
      expect(await outbox.pendingCount(), 0);
    });

    test('gagal jaringan: outbox tetap menunggu dan percobaan dicatat', () async {
      await pos.checkout(clientUuid: 'off-1', cart: cartOf([(kopi, '1')]), payment: const PaymentInput(mode: PayMode.cash));
      final engine = SyncEngine(api: fakeApi(offlineServer()), local: local, outbox: outbox);

      final summary = await engine.pushAll();
      expect(summary.failed, isTrue);
      expect((await engine.ping()).ok, isFalse);
      final item = (await outbox.pending()).single;
      expect(item.attempts, 1);
      expect(item.lastError, contains('Tidak bisa terhubung'));
    });

    test('tarik data: nomor terakhir mengikuti last_used server (pasang ulang aplikasi tidak mengulang nomor)', () async {
      final server = FakeServer((options, body) {
        if (options.path != 'sync/pull') {
          return null;
        }
        return {
          'cursor': '2026-10-07T10:00:00.000000+07:00',
          'tenant': {'id': 1, 'name': 'Warung Tes'},
          'receipt': {'company': {'name': 'Warung Tes'}},
          'device': {'id': 3, 'code': 'K1'},
          'menus': {'pos': true},
          'user': {'id': 1, 'name': 'Sari'},
          'products': {'items': [], 'ids': [1, 2]},
          'customers': {'items': [], 'ids': [7]},
          'accounts': {'items': [], 'ids': []},
          'warehouses': {'items': [], 'ids': []},
          'number_blocks': [
            {'id': 1, 'format': 'POS-K1/{SEQ:6}', 'start': 1, 'end': 500, 'last_used': 8},
          ],
          'open_shift': null,
        };
      });
      final engine = SyncEngine(api: fakeApi(server), local: local, outbox: outbox);

      await engine.pull();
      expect(await local.getMeta(MetaKeys.lastNumberSeq), '8');
      final sale = await pos.checkout(clientUuid: 'after-reinstall', cart: cartOf([(kopi, '1')]), payment: const PaymentInput(mode: PayMode.cash));
      expect(sale['number'], 'POS-K1/000009');

      // Penghitung lokal yang sudah lebih jauh tidak dimundurkan.
      await local.setMeta(MetaKeys.lastNumberSeq, '20');
      await engine.pull();
      expect(await local.getMeta(MetaKeys.lastNumberSeq), '20');
    });

    test('kirim outbox memakai batas waktu panjang (50 nota bisa > 60 detik)', () async {
      await pos.checkout(clientUuid: 'slow-1', cart: cartOf([(kopi, '1')]), payment: const PaymentInput(mode: PayMode.cash));
      final server = FakeServer((options, body) => {
            'results': [
              for (final item in body!['items'] as List) {'client_uuid': item['client_uuid'], 'type': item['type'], 'status': 'ok'},
            ],
          });
      await SyncEngine(api: fakeApi(server), local: local, outbox: outbox).pushAll();
      final push = server.requests.single;
      expect(push.path, 'sync/push');
      expect(push.receiveTimeout, SyncEngine.pushTimeout);
    });

    test('tarik data: barang yang dihapus di server ikut hilang, jatah nomor baru disimpan', () async {
      final server = FakeServer((options, body) {
        switch (options.path) {
          case 'sync/pull':
            return {
              'cursor': '2026-10-07T10:00:00.000000+07:00',
              'tenant': {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': true, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'},
              'receipt': {'width': 80, 'company': {'name': 'Warung Tes'}, 'logo_url': null},
              'device': {'id': 3, 'code': 'K1', 'name': 'HP Tes'},
              'menus': {'pos': true},
              'user': {'id': 1, 'name': 'Sari'},
              'products': {
                'items': [
                  {'id': 1, 'name': 'Kopi susu', 'unit': 'gelas', 'price': '20000.00', 'tax_rate': '0.00', 'is_active': true, 'units': [], 'tiers': []},
                ],
                'ids': [1],
              },
              'customers': {'items': [], 'ids': []},
              'accounts': {'items': [], 'ids': []},
              'warehouses': {'items': [], 'ids': []},
              'number_blocks': [],
              'open_shift': null,
            };
          case 'pos/number-blocks':
            return {
              '_status': 201,
              'block': {'id': 9, 'format': 'POS-K1/{SEQ:6}', 'start': 4, 'end': 503},
            };
        }
        return null;
      });
      final engine = SyncEngine(api: fakeApi(server), local: local, outbox: outbox);

      // afterPush dipanggil setelah kirim outbox dan sebelum tarik data,
      // supaya header X-Outbox-Count request berikutnya sudah diperbarui.
      var requestsWhenPushed = -1;
      await engine.run(afterPush: () async => requestsWhenPushed = server.requests.length);
      expect(requestsWhenPushed, 0, reason: 'Outbox kosong: belum ada request saat afterPush.');
      expect(server.requests.where((request) => request.path == 'sync/pull'), hasLength(1));

      final products = await local.products();
      expect(products.map((product) => '${product.name}:${product.price}'), ['Kopi susu:20000.00']);
      expect(await local.customers(), isEmpty);
      expect(await local.getMeta(MetaKeys.cursor), '2026-10-07T10:00:00.000000+07:00');
      expect((await engine.numberBlocks()).single.start, 4);
      expect((await local.getJson(MetaKeys.tenant))!['prices_include_tax'], isTrue);
    });
  });
}
