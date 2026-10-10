// Uji langsung ke server Laravel: penjualan kasir dengan catatan barang,
// catatan pesanan, jenis pesanan, dan meja tersimpan di invoice web.
// Jalankan: INFOIS_LIVE=http://127.0.0.1:8099 INFOIS_LIVE_EMAIL=rani@kopisenja.example \
//   INFOIS_LIVE_PASSWORD=... flutter test test_live/pos_order_live_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/core/money.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/master_data.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/printing/receipt_builder.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final server = Platform.environment['INFOIS_LIVE'];

  test('jual dengan catatan & jenis pesanan → kirim → invoice web memuat catatan', () async {
    sqfliteFfiInit();
    await initializeDateFormatting('id_ID');
    final login = await ApiClient(baseUrl: server!).post('auth/login', data: {
      'email': Platform.environment['INFOIS_LIVE_EMAIL'],
      'password': Platform.environment['INFOIS_LIVE_PASSWORD'],
      'device_name': 'HP Live POS',
      'device_uid': 'hp-live-pos-${DateTime.now().millisecondsSinceEpoch}',
      'platform': 'android',
    });
    final tenants = [for (final item in login['tenants'] as List) TenantSummary.fromJson(Map<String, dynamic>.from(item as Map))];
    final tenant = tenants.firstWhere((tenant) => tenant.menus.pos);

    final local = await LocalDb.open(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final outbox = OutboxStore(local);
    final api = ApiClient(baseUrl: server, token: login['token'] as String, tenantId: tenant.id);
    final engine = SyncEngine(api: api, local: local, outbox: outbox);
    await engine.run();
    await engine.numberBlocks();

    final accounts = (await local.getJson(MetaKeys.accounts))!;
    final master = MasterData(
      tenant: TenantSettings.fromJson((await local.getJson(MetaKeys.tenant))!),
      receipt: ReceiptConfig.fromJson((await local.getJson(MetaKeys.receipt))!),
      accounts: [for (final account in accounts['items'] as List) CashAccount.fromJson(Map<String, dynamic>.from(account as Map))],
      menus: Menus.fromJson(await local.getJson(MetaKeys.menus)),
      defaultCashId: accounts['default_cash_id'] as int?,
      defaultTransferId: accounts['default_transfer_id'] as int?,
    );
    // Barang tanpa stok (jasa/racikan) atau dengan stok cukup supaya langsung tercatat.
    final products = (await local.products()).where((product) => !product.trackInventory || Money.compare(product.stockQuantity, '5') >= 0).toList();
    expect(products.length, greaterThanOrEqualTo(2));

    final pos = PosService(local: local, user: const SessionUser(id: 0, name: 'Kasir Live', email: ''), master: master);
    final cart = Cart(
      lines: [
        CartLine.fromProduct('a', products[0], note: 'tanpa gula'),
        CartLine.fromProduct('b', products[1]),
      ],
      orderType: OrderType.takeAway,
      orderLabel: 'Meja 9',
      note: 'Pisahkan sendok',
    );
    final total = cart.totals(pricesIncludeTax: master.tenant.pricesIncludeTax).total;
    final sale = await pos.checkout(clientUuid: PosService.newUuid(), cart: cart, payment: PaymentInput(mode: PayMode.cash, cashReceived: total));

    final summary = await engine.pushAll();
    expect(summary.rejected, 0, reason: (await outbox.problems()).map((item) => item.lastError).join(', '));
    final synced = (await local.recentSales()).single;
    expect(synced['sync_status'], 'terkirim');
    final row = (await local.db.query('outbox', where: 'client_uuid = ?', whereArgs: [sale['client_uuid']])).single;
    final invoiceId = (jsonDecode(row['result'] as String) as Map)['invoice_id'] as int;

    final detail = Map<String, dynamic>.from((await api.get('records/sales/$invoiceId'))['sale'] as Map);
    expect(detail['notes'], 'Pesanan: Bawa pulang · Meja 9\nCatatan: Pisahkan sendok\n- ${products[0].name}: tanpa gula');

    // Cetak ulang dari server memuat catatan gabungan.
    final receipt = Map<String, dynamic>.from((await api.get('records/sales/$invoiceId/receipt'))['sale'] as Map);
    expect(receipt['notes'], detail['notes']);
    expect(ReceiptBuilder.plainText(receipt, master.receipt), contains('Pisahkan sendok'));
    // ignore: avoid_print
    print('OK ${sale['number']} → invoice $invoiceId');
    await local.close();
  }, skip: server == null ? 'Set INFOIS_LIVE untuk uji langsung ke server.' : false, timeout: const Timeout(Duration(minutes: 2)));
}
