// Uji coba langsung ke server Laravel sungguhan (bukan bagian `flutter test` biasa).
// Jalankan: INFOIS_LIVE=http://127.0.0.1:8099 INFOIS_LIVE_EMAIL=... INFOIS_LIVE_PASSWORD=... flutter test test_live
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/master_data.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final server = Platform.environment['INFOIS_LIVE'];

  test('login → tarik data → jual offline → kirim → kirim ulang (duplikat)', () async {
    sqfliteFfiInit();
    final login = await ApiClient(baseUrl: server!).post('auth/login', data: {
      'email': Platform.environment['INFOIS_LIVE_EMAIL'],
      'password': Platform.environment['INFOIS_LIVE_PASSWORD'],
      'device_name': 'HP Live Test',
      'device_uid': 'hp-live-${DateTime.now().millisecondsSinceEpoch}',
      'platform': 'android',
    });
    final tenant = TenantSummary.fromJson(Map<String, dynamic>.from((login['tenants'] as List).first as Map));
    expect(tenant.menus.pos, isTrue);

    final local = await LocalDb.open(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final outbox = OutboxStore(local);
    final api = ApiClient(baseUrl: server, token: login['token'] as String, tenantId: tenant.id);
    final engine = SyncEngine(api: api, local: local, outbox: outbox);

    expect((await engine.ping()).ok, isTrue);
    await engine.run();
    final products = await local.products();
    expect(products.map((product) => product.name), containsAll(['Kopi bubuk', 'Es teh']));
    final blocks = await engine.numberBlocks();
    expect(blocks, isNotEmpty);

    final accounts = (await local.getJson(MetaKeys.accounts))!;
    final master = MasterData(
      tenant: TenantSettings.fromJson((await local.getJson(MetaKeys.tenant))!),
      receipt: ReceiptConfig.fromJson((await local.getJson(MetaKeys.receipt))!),
      accounts: [for (final account in accounts['items'] as List) CashAccount.fromJson(Map<String, dynamic>.from(account as Map))],
      menus: Menus.fromJson(await local.getJson(MetaKeys.menus)),
      defaultCashId: accounts['default_cash_id'] as int?,
      defaultTransferId: accounts['default_transfer_id'] as int?,
    );
    final pos = PosService(local: local, user: const SessionUser(id: 0, name: 'Kasir Live', email: ''), master: master);
    final kopi = products.firstWhere((product) => product.name == 'Kopi bubuk');
    final teh = products.firstWhere((product) => product.name == 'Es teh');
    final shift = await pos.openShift('50000');
    final cart = Cart(lines: [
      CartLine.fromProduct('a', kopi, quantity: '12'),
      CartLine.fromProduct('b', teh, quantity: '1.5'),
    ], notaDiscountPercent: '5');
    expect(cart.lines.first.unitPrice, '23000.00', reason: 'harga grosir >= 10');
    final customer = await pos.addCustomer(name: 'Pelanggan Live');
    final sale = await pos.checkout(
      clientUuid: PosService.newUuid(),
      cart: cart.copyWith(customer: customer),
      payment: PaymentInput(mode: PayMode.mixed, cashReceived: '100000', transferAccountId: master.defaultTransferId),
      shiftClientUuid: shift['client_uuid'] as String,
    );
    await pos.closeShift(shift, '150000');

    final summary = await engine.pushAll();
    expect(summary.failed, isFalse);
    expect(summary.rejected, 0, reason: (await outbox.problems()).map((item) => item.lastError).join(', '));
    final synced = (await local.recentSales()).single;
    expect(synced['sync_status'], 'terkirim');
    expect(synced['number'], sale['number']);
    expect(synced['invoice_status'], 'paid');
    expect(synced['verification_url'], endsWith(sale['client_uuid'] as String));

    // Kirim ulang item yang sama → server menjawab duplikat, tidak dobel.
    await local.db.update('outbox', {'status': OutboxStatus.pending}, where: 'client_uuid = ?', whereArgs: [sale['client_uuid']]);
    final again = await api.post('sync/push', data: {'items': [for (final item in await outbox.pending()) item.toPush()]});
    expect((again['results'] as List).single['status'], 'duplikat');

    // Stok kopi berkurang 12 di server.
    await engine.pull(forceFull: true);
    final after = (await local.products()).firstWhere((product) => product.name == 'Kopi bubuk');
    expect(after.stockQuantity, '8.000000');
    // ignore: avoid_print
    print('OK ${sale['number']} total ${sale['total']}');
  }, skip: server == null ? 'Set INFOIS_LIVE untuk uji langsung ke server.' : false, timeout: const Timeout(Duration(minutes: 2)));
}
