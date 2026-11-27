import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/printing/receipt_builder.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/pos_item_sheet.dart';
import 'package:infois/ui/theme.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'support/fakes.dart';

/// Add-on barang (mis. box nasi ayam + sambal hijau / saus): dipilih kasir
/// seperti satuan, tidak menambah harga, ikut terkirim ke server (stoknya
/// dikurangi di sana), tersimpan di pesanan tersimpan, dan tercetak di
/// struk & list pesanan. Sama dengan kasir web.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  final box = Product.fromJson({
    'id': 7,
    'name': 'Box nasi ayam',
    'unit': 'box',
    'price': '20000.00',
    'addons': [
      {'id': 21, 'name': 'Sambal hijau', 'unit': 'sachet', 'quantity': '1.000000'},
      {'id': 22, 'name': 'Saus tomat', 'unit': 'sachet', 'quantity': '2.000000'},
      {'id': null, 'name': 'tanpa id'},
    ],
  });

  test('katalog: add-on dibaca dari sync/pull, cache lama tanpa add-on tetap terbaca', () {
    expect(box.hasAddons, isTrue);
    expect([for (final addon in box.addons) (addon.id, addon.name, addon.quantity)], [(21, 'Sambal hijau', '1.000000'), (22, 'Saus tomat', '2.000000')]);
    expect(Product.fromJson(box.toJson()).addons.length, 2);
    expect(Product.fromJson(Map<String, dynamic>.from(box.toJson())..remove('addons')).hasAddons, isFalse);
    expect(kopi.hasAddons, isFalse);
  });

  test('keranjang: add-on sama digabung, berbeda jadi baris sendiri, harga tetap; JSON pesanan tersimpan membawa add-on', () {
    final container = ProviderContainer(overrides: [workspaceProvider.overrideWith((ref) async => null)]);
    addTearDown(container.dispose);
    final cart = container.read(cartProvider.notifier);

    cart.add(box, addons: addonsFor(box, [22, 21]));
    cart.add(box, addons: addonsFor(box, [21, 22]));
    cart.add(box);
    final lines = container.read(cartProvider).lines;
    expect(lines.length, 2);
    expect((lines.first.quantity, lines.first.addonsText), ('2.000000', 'Sambal hijau, Saus tomat'), reason: 'Urut seperti di Katalog.');
    expect(lines.last.addons, isEmpty);
    expect(container.read(cartProvider).totals(pricesIncludeTax: false).total, '60000.00', reason: 'Harga add-on tidak ditambahkan.');

    final copy = Cart.fromJson(jsonDecode(jsonEncode(container.read(cartProvider).toJson())) as Map<String, dynamic>);
    expect(copy.lines.first.addonsText, 'Sambal hijau, Saus tomat');
    expect(CartLine.fromJson(Map<String, dynamic>.from(lines.first.toJson())..remove('addons')).addons, isEmpty, reason: 'Pesanan tersimpan lama tanpa add-on.');

    final edited = lines.first.copyWith(addons: addonsFor(box, [22]));
    expect(edited.addonsText, 'Saus tomat');
    expect(lines.first.copyWith(quantity: '3').addonsText, 'Sambal hijau, Saus tomat', reason: 'Add-on tetap bila tidak diubah.');
    expect(sameAddons([const LineAddon(productId: 1, name: 'A'), const LineAddon(productId: 2, name: 'B')], [const LineAddon(productId: 2, name: 'B'), const LineAddon(productId: 1, name: 'A')]), isTrue);
    expect(addonsLabel(const []), isNull);
  });

  test('penjualan: add-on ikut dikirim ke server dan tercetak di struk, list pesanan, dan teks WhatsApp', () async {
    final local = await memoryDb();
    addTearDown(local.close);
    await seedMaster(local);
    final pos = PosService(local: local, user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'), master: await _master(local));
    final cart = Cart(lines: [
      CartLine.fromProduct('a', box, quantity: '2', note: 'pedas', addons: addonsFor(box, [21, 22])),
      CartLine.fromProduct('b', kopi),
    ]);

    final sale = await pos.checkout(clientUuid: PosService.newUuid(), cart: cart, payment: const PaymentInput(mode: PayMode.cash, cashReceived: '60000'));
    expect(sale['total'], '58000.00');
    final pushed = (await OutboxStore(local).pending()).single.data;
    final items = pushed['items'] as List;
    expect(items.first['addons'], [
      {'product_id': 21, 'name': 'Sambal hijau', 'quantity': '1.000000'},
      {'product_id': 22, 'name': 'Saus tomat', 'quantity': '2.000000'},
    ]);
    expect((items.last as Map).containsKey('addons'), isFalse);

    final builder = await ReceiptBuilder.create();
    const config = ReceiptConfig(companyName: 'Warung Tes');
    String text(List<int> bytes) => latin1.decode(bytes, allowInvalid: true);
    expect(text(builder.sale(sale, config, width: 58)), allOf(contains('+ Sambal hijau, Saus tomat'), contains('* pedas')));
    expect(text(builder.orderList(sale, config, width: 58)), allOf(contains('+ Sambal hijau, Saus tomat'), contains('>> pedas')));
    expect(text(builder.bill(pos.draft(cart), config, width: 58)), contains('+ Sambal hijau, Saus tomat'));
    expect(ReceiptBuilder.plainText(sale, config), contains('  + Sambal hijau, Saus tomat\n  Catatan: pedas'));
  });

  testWidgets('ketuk barang ber-add-on: pilih add-on lalu Tambah; "Atur jumlah & catatan" membawa pilihan', (tester) async {
    final container = ProviderContainer(overrides: [workspaceProvider.overrideWith((ref) async => null)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(builder: (context) => TextButton(onPressed: () => showPosUnitPicker(context, box), child: const Text('buka'))),
        ),
      ),
    ));
    await tester.tap(find.text('buka'));
    await settle(tester);

    expect(find.byKey(const Key('addon-chip-21')), findsOneWidget);
    expect(find.byKey(const Key('unit-pick-box')), findsNothing, reason: 'Tanpa satuan lain: cukup tombol Tambah.');
    await tester.tap(find.byKey(const Key('addon-chip-22')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('addon-pick-add')));
    await settle(tester);
    expect(find.byType(PosUnitPicker), findsNothing);
    final line = container.read(cartProvider).lines.single;
    expect((line.quantity, line.unitPrice, line.addonsText), ('1.000000', '20000.00', 'Saus tomat'));

    await tester.tap(find.text('buka'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('addon-chip-21')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('unit-pick-details')));
    await settle(tester);
    expect(find.byType(PosItemSheet), findsOneWidget);
    expect(tester.widget<FilterChip>(find.byKey(const Key('addon-chip-21'))).selected, isTrue, reason: 'Pilihan dari lembar add-on terbawa.');
    await tester.tap(find.byKey(const Key('item-qty-plus')));
    await tester.ensureVisible(find.byKey(const Key('item-add')));
    await tester.tap(find.byKey(const Key('item-add')));
    await settle(tester);
    final added = container.read(cartProvider).lines.last;
    expect((added.quantity, added.addonsText), ('2.000000', 'Sambal hijau'));
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
