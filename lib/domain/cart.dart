import '../core/bcmath.dart';
import '../core/money.dart';
import 'models.dart';

/// Hasil hitung satu baris, sama bentuknya dengan `InvoiceCalculator::item()`.
class LineAmounts {
  const LineAmounts({
    required this.quantity,
    required this.unitPrice,
    required this.discountPercent,
    required this.taxRate,
    required this.grossAmount,
    required this.discountAmount,
    required this.netAmount,
    required this.taxAmount,
    required this.lineTotal,
  });

  final String quantity;
  final String unitPrice;
  final String discountPercent;
  final String taxRate;
  final String grossAmount;
  final String discountAmount;
  final String netAmount;
  final String taxAmount;
  final String lineTotal;

  Map<String, String> toJson() => {
        'quantity': quantity,
        'unit_price': unitPrice,
        'discount_percent': discountPercent,
        'tax_rate': taxRate,
        'gross_amount': grossAmount,
        'discount_amount': discountAmount,
        'net_amount': netAmount,
        'tax_amount': taxAmount,
        'line_total': lineTotal,
      };
}

class CartTotals {
  const CartTotals({required this.subtotal, required this.discountTotal, required this.taxTotal, required this.total});

  static const empty = CartTotals(subtotal: '0.00', discountTotal: '0.00', taxTotal: '0.00', total: '0.00');

  final String subtotal;
  final String discountTotal;
  final String taxTotal;
  final String total;

  Map<String, String> toJson() => {'subtotal': subtotal, 'discount_total': discountTotal, 'tax_total': taxTotal, 'total': total};
}

/// Port langsung dari `App\Services\Invoicing\InvoiceCalculator`: pembulatan
/// per baris, harga belum/sudah termasuk pajak. Diuji paritasnya dengan
/// fixture yang sama di server (test/fixtures/cart_parity.json).
class InvoiceCalculator {
  const InvoiceCalculator();

  LineAmounts item({
    required Object? quantity,
    required Object? unitPrice,
    Object? discountPercent,
    Object? taxRate,
    bool pricesIncludeTax = false,
  }) {
    final q = Money.normalize(quantity ?? 0, 6);
    final price = Money.normalize(unitPrice ?? 0);
    final discountRate = Money.normalize(discountPercent ?? 0);
    final rate = Money.normalize(taxRate ?? 0);

    var gross = Money.mul(q, price);
    var discount = Money.percent(gross, discountRate);
    var net = Money.sub(gross, discount);
    var tax = Money.percent(net, rate);
    var lineTotal = Money.add([net, tax]);

    if (pricesIncludeTax && Money.isPositive(rate)) {
      final divisor = bcadd('100', rate, 6);
      lineTotal = net;
      net = Money.round(bcdiv(bcmul(lineTotal, '100', 8), divisor, 8));
      tax = Money.sub(lineTotal, net);
      gross = Money.round(bcdiv(bcmul(Money.mul(q, price), '100', 8), divisor, 8));
      discount = Money.sub(gross, net);
    }

    return LineAmounts(
      quantity: q,
      unitPrice: price,
      discountPercent: discountRate,
      taxRate: rate,
      grossAmount: gross,
      discountAmount: discount,
      netAmount: net,
      taxAmount: tax,
      lineTotal: lineTotal,
    );
  }

  /// Subtotal & diskon dalam DPP (sebelum pajak): total = subtotal − diskon + pajak.
  CartTotals totals(Iterable<LineAmounts> lines) {
    var subtotal = '0';
    var discount = '0';
    var tax = '0';
    for (final line in lines) {
      subtotal = Money.add([subtotal, line.grossAmount]);
      discount = Money.add([discount, line.discountAmount]);
      tax = Money.add([tax, line.taxAmount]);
    }
    return CartTotals(
      subtotal: Money.normalize(subtotal),
      discountTotal: Money.normalize(discount),
      taxTotal: Money.normalize(tax),
      total: Money.add([Money.sub(subtotal, discount), tax]),
    );
  }
}

/// Gabungan diskon barang dan diskon nota (berurutan): 10% lalu 5% = 14,5%.
/// Hasilnya dibulatkan 2 angka seperti kolom `discount_percent` di server,
/// dan angka inilah yang dikirim, sehingga total HP = total server.
String combineDiscounts(String linePercent, String notaPercent) {
  final line = Money.normalize(linePercent);
  final nota = Money.normalize(notaPercent);
  if (Money.isZero(nota)) {
    return line;
  }
  if (Money.isZero(line)) {
    return nota;
  }
  final remaining = bcdiv(bcmul(bcsub('100', line, 6), bcsub('100', nota, 6), 12), '100', 12);
  return Money.normalize(bcsub('100', remaining, 12));
}

/// Jenis pesanan (disimpan sebagai `order_type` di server).
enum OrderType {
  dineIn('dine_in', 'Makan di tempat', 'MAKAN DI TEMPAT'),
  takeAway('take_away', 'Bawa pulang', 'BAWA PULANG'),
  delivery('delivery', 'Pesan antar', 'PESAN ANTAR');

  const OrderType(this.code, this.label, this.ticketLabel);

  final String code;
  final String label;

  /// Huruf besar untuk struk & tiket dapur.
  final String ticketLabel;

  static OrderType? fromCode(Object? code) {
    for (final type in values) {
      if (type.code == code) {
        return type;
      }
    }
    return null;
  }
}

/// Teks bebas yang dirapikan: spasi di ujung dibuang, kosong menjadi null.
String? cleanNote(String? text, [int max = 200]) {
  final value = (text ?? '').trim();
  if (value.isEmpty) {
    return null;
  }
  return value.length > max ? value.substring(0, max) : value;
}

class CartLine {
  const CartLine({
    required this.key,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.unitPrice,
    this.product,
    this.discountPercent = '0.00',
    this.taxRate = '0.00',
    this.manualPrice = false,
    this.note,
  });

  /// Baris baru dari katalog dengan harga satuan & harga grosir otomatis.
  factory CartLine.fromProduct(String key, Product product, {String quantity = '1.000000', String? unit, String? note}) {
    final option = product.optionFor(unit);
    return CartLine(
      key: key,
      product: product,
      description: product.name,
      quantity: Money.normalize(quantity, 6),
      unit: option.name,
      unitPrice: product.priceFor(option.name, quantity),
      taxRate: product.taxRate,
      note: cleanNote(note),
    );
  }

  factory CartLine.fromJson(Map<String, dynamic> json) => CartLine(
        key: json['key'].toString(),
        product: json['product'] is Map ? Product.fromJson(Map<String, dynamic>.from(json['product'] as Map)) : null,
        description: json['description']?.toString() ?? '',
        quantity: Money.normalize(json['quantity'], 6),
        unit: json['unit']?.toString() ?? '',
        unitPrice: Money.normalize(json['unit_price']),
        discountPercent: Money.normalize(json['discount_percent']),
        taxRate: Money.normalize(json['tax_rate']),
        manualPrice: json['manual_price'] == true,
        note: cleanNote(json['note']?.toString()),
      );

  final String key;
  final Product? product;
  final String description;
  final String quantity;
  final String unit;
  final String unitPrice;
  final String discountPercent;
  final String taxRate;

  /// Harga diubah manual oleh kasir: harga grosir tidak diterapkan otomatis lagi.
  final bool manualPrice;

  /// Catatan barang untuk dapur/struk ("tanpa gula", "less ice").
  final String? note;

  Map<String, dynamic> toJson() => {
        'key': key,
        'product': product?.toJson(),
        'description': description,
        'quantity': quantity,
        'unit': unit,
        'unit_price': unitPrice,
        'discount_percent': discountPercent,
        'tax_rate': taxRate,
        'manual_price': manualPrice,
        'note': note,
      };

  /// [note]: null = tidak berubah, '' = hapus catatan.
  CartLine copyWith({String? quantity, String? unit, String? unitPrice, String? discountPercent, bool? manualPrice, String? description, String? note}) {
    final nextQuantity = quantity == null ? this.quantity : Money.normalize(quantity, 6);
    final nextUnit = unit ?? this.unit;
    final nextManual = manualPrice ?? this.manualPrice;
    var nextPrice = unitPrice == null ? this.unitPrice : Money.normalize(unitPrice);
    if (unitPrice == null && !nextManual && product != null && (quantity != null || unit != null)) {
      nextPrice = product!.priceFor(nextUnit, nextQuantity);
    }
    return CartLine(
      key: key,
      product: product,
      description: description ?? this.description,
      quantity: nextQuantity,
      unit: nextUnit,
      unitPrice: nextPrice,
      discountPercent: discountPercent == null ? this.discountPercent : Money.normalize(discountPercent),
      taxRate: taxRate,
      manualPrice: nextManual,
      note: note == null ? this.note : cleanNote(note),
    );
  }

  /// Isi satuan dasar per satuan baris (mis. karton = 24).
  String get unitFactor => product?.optionFor(unit).factor ?? '1.000000';
}

class Cart {
  const Cart({
    this.lines = const [],
    this.notaDiscountPercent = '0.00',
    this.customer,
    this.note,
    this.orderType,
    this.orderLabel,
    this.heldId,
  });

  factory Cart.fromJson(Map<String, dynamic> json) => Cart(
        lines: [for (final line in (json['lines'] as List? ?? const [])) CartLine.fromJson(Map<String, dynamic>.from(line as Map))],
        notaDiscountPercent: Money.normalize(json['nota_discount_percent']),
        customer: json['customer'] is Map ? Customer.fromJson(Map<String, dynamic>.from(json['customer'] as Map)) : null,
        note: cleanNote(json['note']?.toString(), 1000),
        orderType: OrderType.fromCode(json['order_type']),
        orderLabel: cleanNote(json['order_label']?.toString(), 40),
        heldId: json['held_id']?.toString(),
      );

  final List<CartLine> lines;
  final String notaDiscountPercent;
  final Customer? customer;

  /// Catatan pesanan (untuk seluruh nota).
  final String? note;
  final OrderType? orderType;

  /// Meja / nomor antrian ("Meja 5", "Antrian 12").
  final String? orderLabel;

  /// Id pesanan tersimpan yang sedang dibuka (null = pesanan baru).
  final String? heldId;

  bool get isEmpty => lines.isEmpty;

  /// Diskon efektif per baris yang dikirim ke server.
  String effectiveDiscount(CartLine line) => combineDiscounts(line.discountPercent, notaDiscountPercent);

  LineAmounts amountsFor(CartLine line, {required bool pricesIncludeTax}) => const InvoiceCalculator().item(
        quantity: line.quantity,
        unitPrice: line.unitPrice,
        discountPercent: effectiveDiscount(line),
        taxRate: line.taxRate,
        pricesIncludeTax: pricesIncludeTax,
      );

  CartTotals totals({required bool pricesIncludeTax}) =>
      const InvoiceCalculator().totals([for (final line in lines) amountsFor(line, pricesIncludeTax: pricesIncludeTax)]);

  /// Jumlah barang (per baris) untuk badge keranjang.
  int get itemCount => lines.length;

  /// Total qty semua baris (mis. "5" untuk 3 kopi + 2 roti).
  String get totalQuantity => Money.normalize(lines.fold<String>('0', (sum, line) => bcadd(sum, line.quantity, 6)), 6);

  /// Qty satu barang di keranjang (semua satuan & catatan).
  String quantityOf(int productId) =>
      Money.normalize(lines.where((line) => line.product?.id == productId).fold<String>('0', (sum, line) => bcadd(sum, line.quantity, 6)), 6);

  Map<String, dynamic> toJson() => {
        'lines': [for (final line in lines) line.toJson()],
        'nota_discount_percent': notaDiscountPercent,
        'customer': customer?.toJson(),
        'note': note,
        'order_type': orderType?.code,
        'order_label': orderLabel,
        'held_id': heldId,
      };

  /// [note] / [orderLabel]: null = tidak berubah, '' = hapus.
  Cart copyWith({
    List<CartLine>? lines,
    String? notaDiscountPercent,
    Customer? customer,
    bool clearCustomer = false,
    String? note,
    OrderType? orderType,
    bool clearOrderType = false,
    String? orderLabel,
    String? heldId,
  }) =>
      Cart(
        lines: lines ?? this.lines,
        notaDiscountPercent: notaDiscountPercent == null ? this.notaDiscountPercent : Money.normalize(notaDiscountPercent),
        customer: clearCustomer ? null : (customer ?? this.customer),
        note: note == null ? this.note : cleanNote(note, 1000),
        orderType: clearOrderType ? null : (orderType ?? this.orderType),
        orderLabel: orderLabel == null ? this.orderLabel : cleanNote(orderLabel, 40),
        heldId: heldId ?? this.heldId,
      );
}
