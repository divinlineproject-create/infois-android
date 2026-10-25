import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';

import 'support/fakes.dart';

/// Paritas hitung keranjang HP dengan `InvoiceCalculator` & `priceFor` di
/// server. Fixture dibuat dari PHP dan juga dicek oleh
/// backoffice/tests/Feature/Mobile/PosCartParityTest.php.
void main() {
  final fixture = jsonDecode(File('test/fixtures/cart_parity.json').readAsStringSync()) as Map<String, dynamic>;
  const calculator = InvoiceCalculator();

  test('setiap baris sama persis dengan InvoiceCalculator::item()', () {
    final lines = fixture['lines'] as List;
    expect(lines, isNotEmpty);
    for (final (index, raw) in lines.indexed) {
      final item = raw as Map<String, dynamic>;
      final input = item['input'] as Map<String, dynamic>;
      final result = calculator.item(
        quantity: input['quantity'],
        unitPrice: input['unit_price'],
        discountPercent: input['discount_percent'],
        taxRate: input['tax_rate'],
        pricesIncludeTax: item['prices_include_tax'] as bool,
      );
      expect(result.toJson(), Map<String, String>.from(item['expected'] as Map), reason: 'baris #$index $input');
    }
  });

  test('total keranjang sama persis dengan InvoiceCalculator::totals()', () {
    for (final (index, raw) in (fixture['carts'] as List).indexed) {
      final cart = raw as Map<String, dynamic>;
      final inclusive = cart['prices_include_tax'] as bool;
      final lines = [
        for (final input in (cart['items'] as List).cast<Map<String, dynamic>>())
          calculator.item(
            quantity: input['quantity'],
            unitPrice: input['unit_price'],
            discountPercent: input['discount_percent'],
            taxRate: input['tax_rate'],
            pricesIncludeTax: inclusive,
          ),
      ];
      expect(calculator.totals(lines).toJson(), Map<String, String>.from(cart['expected'] as Map), reason: 'keranjang #$index');
    }
  });

  test('harga grosir bertingkat sama dengan ProductService::priceFor()', () {
    final data = Map<String, dynamic>.from(fixture['price_product'] as Map);
    final product = Product.fromJson({'id': 1, 'name': 'Kopi', ...data});
    for (final raw in fixture['prices'] as List) {
      final item = raw as Map<String, dynamic>;
      expect(product.priceFor(item['unit'] as String?, item['quantity'] as String), item['expected'], reason: '${item['unit']} x ${item['quantity']}');
    }
  });

  test('diskon nota digabung berurutan dengan diskon barang', () {
    expect(combineDiscounts('10', '5'), '14.50');
    expect(combineDiscounts('0', '5'), '5.00');
    expect(combineDiscounts('12.5', '0'), '12.50');
    expect(combineDiscounts('12.5', '7.5'), '19.06');
    expect(combineDiscounts('100', '10'), '100.00');
  });

  test('kode scan/ketik sama dengan kasir web: barang nonaktif ditolak', () async {
    final local = await memoryDb();
    addTearDown(local.close);
    await local.upsertProducts([
      for (final raw in (fixture['code_products'] as List).cast<Map<String, dynamic>>()) Product.fromJson({'unit': 'pcs', 'price': '1000', ...raw}),
    ]);
    final cases = (fixture['codes'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    expect(inactiveCodeMessage, 'Barang ini sudah dinonaktifkan.');
    for (final item in cases) {
      final found = await local.lookupCode(item['code'] as String);
      expect(found.product?.id, item['product_id'], reason: 'kode "${item['code']}"');
      expect(found.inactive?.id, item['inactive_id'], reason: 'kode "${item['code']}" (nonaktif)');
      expect(found.isInactive, item['inactive_id'] != null);
      expect((await local.productByCode(item['code'] as String))?.id, item['product_id']);
    }
  });
}
