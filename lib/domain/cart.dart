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

  /// Huruf besar untuk struk & list pesanan.
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

/// Add-on terpilih di satu baris (format `SaleAddons` server): barang
/// add-on, nama, dan qty per 1 satuan dasar barang. Harga baris tetap.
class LineAddon {
  const LineAddon({required this.productId, required this.name, this.quantity = '1.000000'});

  factory LineAddon.fromProductAddon(ProductAddon addon) => LineAddon(productId: addon.id, name: addon.name, quantity: addon.quantity);

  /// Null bila data tersimpan tidak valid ([cleanAddons] membuangnya).
  static LineAddon? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final name = cleanNote(raw['name']?.toString(), 120);
    if (name == null) {
      return null;
    }
    final id = raw['product_id'];
    return LineAddon(
      productId: id == null ? null : (id is int ? id : int.tryParse(id.toString())),
      name: name,
      quantity: Money.normalize(raw['quantity'] ?? '1', 6),
    );
  }

  final int? productId;
  final String name;
  final String quantity;

  String get key => productId != null ? 'id:$productId' : 'name:${name.toLowerCase()}';

  Map<String, dynamic> toJson() => {'product_id': productId, 'name': name, 'quantity': quantity};
}

/// Add-on yang dirapikan: data tidak valid dibuang, id/nama ganda cukup
/// sekali, paling banyak 20 (sama dengan `cleanAddons` kasir web).
List<LineAddon> cleanAddons(Iterable<Object?> raw) {
  final out = <LineAddon>[];
  final seen = <String>{};
  for (final item in raw) {
    final addon = item is LineAddon ? item : LineAddon.tryParse(item);
    if (addon == null || !seen.add(addon.key)) {
      continue;
    }
    out.add(addon);
    if (out.length >= 20) {
      break;
    }
  }
  return out;
}

/// Add-on terpilih ([selectedIds] = id barang add-on) urut seperti di Katalog.
List<LineAddon> addonsFor(Product product, Iterable<int> selectedIds) {
  final wanted = selectedIds.toSet();
  return [
    for (final addon in product.addons)
      if (wanted.contains(addon.id)) LineAddon.fromProductAddon(addon),
  ];
}

/// "Sambal hijau, Saus tomat" untuk keranjang & struk; null bila kosong.
String? addonsLabel(Iterable<Object?> addons) {
  final names = [for (final addon in cleanAddons(addons)) addon.name];
  return names.isEmpty ? null : names.join(', ');
}

/// Dua daftar add-on sama (tanpa melihat urutan).
bool sameAddons(Iterable<Object?> a, Iterable<Object?> b) {
  String keys(Iterable<Object?> list) => ([for (final addon in cleanAddons(list)) addon.key]..sort()).join('|');
  return keys(a) == keys(b);
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
    this.addons = const [],
  });

  /// Baris baru dari katalog dengan harga satuan & harga bertingkat
  /// otomatis; [levelId] = level pelanggan di keranjang (harga khusus level).
  factory CartLine.fromProduct(String key, Product product, {String quantity = '1.000000', String? unit, String? note, int? levelId, List<LineAddon> addons = const []}) {
    final option = product.optionFor(unit);
    return CartLine(
      key: key,
      product: product,
      description: product.name,
      quantity: Money.normalize(quantity, 6),
      unit: option.name,
      unitPrice: product.priceFor(option.name, quantity, levelId: levelId),
      taxRate: product.taxRate,
      note: cleanNote(note),
      addons: cleanAddons(addons),
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
        addons: cleanAddons(json['addons'] as List? ?? const []),
      );

  final String key;
  final Product? product;
  final String description;
  final String quantity;
  final String unit;
  final String unitPrice;
  final String discountPercent;
  final String taxRate;

  /// Harga diubah manual oleh kasir: harga bertingkat tidak diterapkan otomatis lagi.
  final bool manualPrice;

  /// Catatan barang untuk dapur/struk (mis. warna, ukuran, permintaan khusus).
  final String? note;

  /// Add-on terpilih (mis. sambal hijau): tercetak di bawah nama barang,
  /// stoknya dikurangi server, harga baris tetap.
  final List<LineAddon> addons;

  /// "Sambal hijau, Saus tomat"; null bila tanpa add-on.
  String? get addonsText => addonsLabel(addons);

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
        'addons': [for (final addon in addons) addon.toJson()],
      };

  /// [note]: null = tidak berubah, '' = hapus catatan. [addons]: null =
  /// tidak berubah. Jumlah/satuan yang berubah menghitung ulang harga
  /// otomatis dengan level pelanggan [levelId] (null = tanpa level).
  CartLine copyWith({String? quantity, String? unit, String? unitPrice, String? discountPercent, bool? manualPrice, String? description, String? note, int? levelId, List<LineAddon>? addons}) {
    final nextQuantity = quantity == null ? this.quantity : Money.normalize(quantity, 6);
    final nextUnit = unit ?? this.unit;
    final nextManual = manualPrice ?? this.manualPrice;
    var nextPrice = unitPrice == null ? this.unitPrice : Money.normalize(unitPrice);
    if (unitPrice == null && !nextManual && product != null && (quantity != null || unit != null)) {
      nextPrice = product!.priceFor(nextUnit, nextQuantity, levelId: levelId);
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
      addons: addons == null ? this.addons : cleanAddons(addons),
    );
  }

  /// Isi satuan dasar per satuan baris (mis. karton = 24).
  String get unitFactor => product?.optionFor(unit).factor ?? '1.000000';

  /// Satuan baris untuk keranjang: "pcs" atau "karton (isi 6 pcs)".
  String get unitLabel => product?.unitLabelFor(unit) ?? unit;

  /// Baris dengan data barang terbaru [current] dari katalog HP (pesanan
  /// tersimpan dibuka lagi). Harga manual, barang lain, atau satuan baris
  /// yang sudah tidak ada di barang itu: baris tetap.
  CartLine withCatalogProduct(Product? current) {
    final product = this.product;
    if (manualPrice || product == null || current == null || current.id != product.id || !current.hasUnit(unit)) {
      return this;
    }
    return CartLine(
      key: key,
      product: current,
      description: description,
      quantity: quantity,
      unit: unit,
      unitPrice: unitPrice,
      discountPercent: discountPercent,
      taxRate: taxRate,
      manualPrice: manualPrice,
      note: note,
      addons: addons,
    );
  }

  /// Harga otomatis dihitung ulang untuk level pelanggan [levelId] (pelanggan
  /// dipilih/diganti/dihapus). Harga manual dan baris tanpa barang tetap.
  CartLine repriced(int? levelId) {
    final product = this.product;
    if (manualPrice || product == null) {
      return this;
    }
    final price = product.priceFor(unit, quantity, levelId: levelId);
    return price == unitPrice ? this : copyWith(unitPrice: price);
  }

  /// Asal harga otomatis baris ini untuk level [levelId]; null bila harga
  /// manual, tanpa barang, atau harganya bukan hasil hitung otomatis.
  PriceQuote? priceQuote(int? levelId) {
    final product = this.product;
    if (manualPrice || product == null) {
      return null;
    }
    final quote = product.quoteFor(unit, quantity, levelId: levelId);
    return quote.price == unitPrice ? quote : null;
  }

  /// Keterangan harga di keranjang: "harga grosir" (harga bertingkat umum)
  /// atau "harga Reseller" (harga level); null untuk harga biasa/manual.
  String? priceLabel(int? levelId) {
    final quote = priceQuote(levelId);
    return switch (quote?.source) {
      PriceSource.tier => 'harga grosir',
      PriceSource.level => 'harga ${quote!.level ?? 'level'}',
      _ => null,
    };
  }
}

/// Biaya tambahan nota (ongkos kirim, biaya layanan, ...): 1 × [amount],
/// tanpa diskon & pajak, tidak kena diskon nota. Dikirim sebagai baris
/// `charge` (server membukukan ke Pendapatan Jasa).
class CartCharge {
  const CartCharge({required this.key, required this.name, required this.amount});

  factory CartCharge.fromJson(Map<String, dynamic> json) =>
      CartCharge(key: json['key']?.toString() ?? '', name: cleanNote(json['name']?.toString(), 60) ?? '', amount: Money.normalize(json['amount']));

  /// Contoh nama biaya di dialog "Biaya tambahan".
  static const suggestions = ['Ongkos kirim', 'Biaya layanan', 'Biaya kemasan'];

  final String key;
  final String name;
  final String amount;

  /// Hitungan baris (1 × nominal, tanpa diskon & pajak).
  LineAmounts amounts({required bool pricesIncludeTax}) =>
      const InvoiceCalculator().item(quantity: '1', unitPrice: amount, discountPercent: '0', taxRate: '0', pricesIncludeTax: pricesIncludeTax);

  Map<String, dynamic> toJson() => {'key': key, 'name': name, 'amount': amount};
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
    this.charges = const [],
    this.deliveryAddress,
    this.queueNumber,
  });

  factory Cart.fromJson(Map<String, dynamic> json) => Cart(
        lines: [for (final line in (json['lines'] as List? ?? const [])) CartLine.fromJson(Map<String, dynamic>.from(line as Map))],
        notaDiscountPercent: Money.normalize(json['nota_discount_percent']),
        customer: json['customer'] is Map ? Customer.fromJson(Map<String, dynamic>.from(json['customer'] as Map)) : null,
        note: cleanNote(json['note']?.toString(), 1000),
        orderType: OrderType.fromCode(json['order_type']),
        orderLabel: cleanNote(json['order_label']?.toString(), 40),
        heldId: json['held_id']?.toString(),
        deliveryAddress: cleanNote(json['delivery_address']?.toString(), 500),
        queueNumber: cleanNote(json['queue_number']?.toString(), 10),
        // Keranjang/pesanan tersimpan lama tanpa `charges`: tanpa biaya tambahan.
        charges: [
          for (final charge in (json['charges'] as List? ?? const []))
            if (charge is Map) CartCharge.fromJson(Map<String, dynamic>.from(charge)),
        ],
      );

  final List<CartLine> lines;
  final String notaDiscountPercent;
  final Customer? customer;

  /// Biaya tambahan nota (ongkos kirim, ...), di luar barang.
  final List<CartCharge> charges;

  /// Alamat pengiriman (hanya dipakai bila barang dikirim, lihat [needsDelivery]).
  final String? deliveryAddress;

  /// Nomor antrian ("000012", per HP, mulai lagi tiap tengah malam): diberi
  /// sekali per pesanan saat Simpan, Cetak list, atau bayar (rumah makan).
  final String? queueNumber;

  /// Nama biaya yang berarti barang dikirim (ongkos kirim, biaya antar, ...).
  static final deliveryChargePattern = RegExp('kirim|pengiriman|antar|ongkir|ekspedisi|kurir', caseSensitive: false);

  /// Catatan pesanan (untuk seluruh nota).
  final String? note;
  final OrderType? orderType;

  /// Meja / nomor antrian ("Meja 5", "Antrian 12").
  final String? orderLabel;

  /// Id pesanan tersimpan yang sedang dibuka (null = pesanan baru).
  final String? heldId;

  bool get isEmpty => lines.isEmpty;

  /// Barang dikirim: jenis pesanan Pesan antar (hanya bila fitur rumah makan
  /// nyala, [dining]) atau ada biaya kirim/pengiriman/antar/ongkir/ekspedisi/kurir. Sama
  /// dengan `needsDelivery` kasir web.
  bool needsDelivery({bool dining = true}) => (dining && orderType == OrderType.delivery) || charges.any((charge) => deliveryChargePattern.hasMatch(charge.name));

  /// Alamat yang dicetak & dikirim ke server: hanya bila barang dikirim.
  String? deliveryAddressFor({bool dining = true}) => needsDelivery(dining: dining) ? cleanNote(deliveryAddress, 500) : null;

  /// Level pelanggan keranjang untuk harga khusus level (null = tanpa level).
  int? get levelId => customer?.levelId;

  /// Ganti pelanggan (null = pelanggan umum) dan hitung ulang harga otomatis
  /// semua baris dengan level pelanggan barunya.
  Cart withCustomer(Customer? customer) {
    final next = customer == null ? copyWith(clearCustomer: true) : copyWith(customer: customer);
    return next.copyWith(lines: [for (final line in next.lines) line.repriced(next.levelId)]);
  }

  /// Pesanan tersimpan dibuka lagi: data barang terbaru dari [catalog] (per
  /// id) dan pelanggan terbaru [customer] (level bisa berubah; null = data
  /// tersimpan tetap dipakai), lalu harga otomatis dihitung ulang lewat
  /// [withCustomer]. Harga manual tetap.
  Cart reopened({Customer? customer, Map<int, Product> catalog = const {}}) {
    final refreshed = copyWith(lines: [for (final line in lines) line.withCatalogProduct(catalog[line.product?.id])]);
    return refreshed.withCustomer(customer ?? this.customer);
  }

  /// Diskon efektif per baris yang dikirim ke server.
  String effectiveDiscount(CartLine line) => combineDiscounts(line.discountPercent, notaDiscountPercent);

  LineAmounts amountsFor(CartLine line, {required bool pricesIncludeTax}) => const InvoiceCalculator().item(
        quantity: line.quantity,
        unitPrice: line.unitPrice,
        discountPercent: effectiveDiscount(line),
        taxRate: line.taxRate,
        pricesIncludeTax: pricesIncludeTax,
      );

  /// Total nota (sama dengan `InvoiceCalculator::totals` di server dan
  /// `totalsFor` kasir web): barang dengan diskon nota + biaya tambahan.
  CartTotals totals({required bool pricesIncludeTax}) => const InvoiceCalculator().totals([
        for (final line in lines) amountsFor(line, pricesIncludeTax: pricesIncludeTax),
        for (final charge in charges) charge.amounts(pricesIncludeTax: pricesIncludeTax),
      ]);

  /// Jumlah biaya tambahan (sudah termasuk di [totals]); subtotal barang =
  /// subtotal − ini.
  String get chargesTotal => Money.add([for (final charge in charges) charge.amount]);

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
        'charges': [for (final charge in charges) charge.toJson()],
        'delivery_address': deliveryAddress,
        'queue_number': queueNumber,
      };

  /// [note] / [orderLabel] / [deliveryAddress]: null = tidak berubah, '' = hapus.
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
    List<CartCharge>? charges,
    String? deliveryAddress,
    String? queueNumber,
  }) =>
      Cart(
        lines: lines ?? this.lines,
        charges: charges ?? this.charges,
        deliveryAddress: deliveryAddress == null ? this.deliveryAddress : cleanNote(deliveryAddress, 500),
        queueNumber: queueNumber ?? this.queueNumber,
        notaDiscountPercent: notaDiscountPercent == null ? this.notaDiscountPercent : Money.normalize(notaDiscountPercent),
        customer: clearCustomer ? null : (customer ?? this.customer),
        note: note == null ? this.note : cleanNote(note, 1000),
        orderType: clearOrderType ? null : (orderType ?? this.orderType),
        orderLabel: orderLabel == null ? this.orderLabel : cleanNote(orderLabel, 40),
        heldId: heldId ?? this.heldId,
      );
}
