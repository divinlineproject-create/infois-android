import '../core/bcmath.dart';
import '../core/format.dart';
import '../core/money.dart';

/// Data master dari server (lihat API.md › sync/pull). Semua angka uang/qty
/// disimpan sebagai string desimal.

String _s(Object? value, [String fallback = '']) => value == null ? fallback : value.toString();

bool _b(Object? value) => value == true || value == 1 || value == '1' || value == 'true';

int? _i(Object? value) => value == null ? null : (value is int ? value : int.tryParse(value.toString()));

String? _blank(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

class UnitOption {
  const UnitOption({required this.name, required this.factor, required this.price});

  factory UnitOption.fromJson(Map<String, dynamic> json) =>
      UnitOption(name: _s(json['name']), factor: Money.normalize(json['factor'], 6), price: Money.normalize(json['price']));

  final String name;
  final String factor;
  final String price;

  Map<String, dynamic> toJson() => {'name': name, 'factor': factor, 'price': price};
}

/// Satu tingkat harga: mulai [minQuantity] [unit] harganya [price].
/// [levelId] null = harga bertingkat umum (`tiers`, untuk semua pelanggan);
/// terisi = harga khusus level pelanggan (`level_tiers`, mis. Reseller).
class PriceTier {
  const PriceTier({required this.unit, required this.minQuantity, required this.price, this.levelId, this.level});

  factory PriceTier.fromJson(Map<String, dynamic> json) => PriceTier(
        unit: _s(json['unit']),
        minQuantity: Money.normalize(json['min_quantity'], 6),
        price: Money.normalize(json['price']),
        levelId: _i(json['level_id']),
        level: _blank(json['level']),
      );

  final String unit;
  final String minQuantity;
  final String price;

  /// Level pelanggan pemilik harga ini (null = harga umum).
  final int? levelId;

  /// Nama level, mis. "Reseller".
  final String? level;

  Map<String, dynamic> toJson() => {
        if (levelId != null) 'level_id': levelId,
        if (levelId != null) 'level': level,
        'unit': unit,
        'min_quantity': minQuantity,
        'price': price,
      };
}

/// Asal harga satuan otomatis di kasir.
enum PriceSource {
  /// Harga satuan biasa (belum ada tingkat yang terpenuhi).
  normal,

  /// Harga bertingkat umum (harga grosir).
  tier,

  /// Harga khusus level pelanggan.
  level,
}

/// Harga satuan otomatis beserta asalnya (lihat [Product.quoteFor]).
class PriceQuote {
  const PriceQuote({required this.price, required this.source, this.tier});

  final String price;
  final PriceSource source;

  /// Tingkat harga yang dipakai; null untuk [PriceSource.normal].
  final PriceTier? tier;

  /// Nama level bila harga level yang dipakai.
  String? get level => source == PriceSource.level ? tier?.level : null;
}

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.unit,
    required this.price,
    this.sku,
    this.type = 'product',
    this.taxRate = '0.00',
    this.trackInventory = false,
    this.stockQuantity,
    this.minimumStock,
    this.hasComposition = false,
    this.isActive = true,
    this.units = const [],
    this.tiers = const [],
    this.levelTiers = const [],
    this.kind,
    this.kindLabel,
    this.barcode,
    this.categoryId,
    this.categoryName,
    this.hasPhoto = false,
    this.photoVersion,
    this.photoUrl,
    this.photoThumbUrl,
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    final category = json['category'] is Map ? Map<String, dynamic>.from(json['category'] as Map) : null;
    final photoUrl = _blank(json['photo_url']);
    return Product(
        id: _i(json['id'])!,
        sku: json['sku']?.toString(),
        name: _s(json['name']),
        type: _s(json['type'], 'product'),
        unit: _s(json['unit'], 'unit'),
        price: Money.normalize(json['price']),
        taxRate: Money.normalize(json['tax_rate']),
        trackInventory: _b(json['track_inventory']),
        stockQuantity: json['stock_quantity'] == null ? null : Money.normalize(json['stock_quantity'], 6),
        minimumStock: json['minimum_stock'] == null ? null : Money.normalize(json['minimum_stock'], 6),
        hasComposition: _b(json['has_composition']),
        isActive: json['is_active'] == null ? true : _b(json['is_active']),
        units: [for (final unit in (json['units'] as List? ?? const [])) UnitOption.fromJson(Map<String, dynamic>.from(unit as Map))],
        tiers: [for (final tier in (json['tiers'] as List? ?? const [])) PriceTier.fromJson(Map<String, dynamic>.from(tier as Map))],
        // Server/cache lama tanpa `level_tiers`: tanpa harga level.
        levelTiers: [
          for (final tier in (json['level_tiers'] as List? ?? const []))
            if (tier is Map && _i(tier['level_id']) != null) PriceTier.fromJson(Map<String, dynamic>.from(tier)),
        ],
        kind: (json['kind']?.toString() ?? '').isEmpty ? null : json['kind'].toString(),
        kindLabel: (json['kind_label']?.toString() ?? '').trim().isEmpty ? null : json['kind_label'].toString(),
        barcode: _blank(json['barcode']),
        categoryId: _i(json['category_id']) ?? _i(category?['id']),
        categoryName: _blank(json['category_name']) ?? _blank(category?['name']),
        // Server lama tanpa `has_photo`: ada photo_url = ada foto.
        hasPhoto: json.containsKey('has_photo') ? _b(json['has_photo']) : photoUrl != null,
        photoVersion: _blank(json['photo_version']),
        photoUrl: photoUrl,
        photoThumbUrl: _blank(json['photo_thumb_url']),
      );
  }

  final int id;
  final String? sku;
  final String name;
  final String type;
  final String unit;
  final String price;
  final String taxRate;
  final bool trackInventory;
  final String? stockQuantity;
  final String? minimumStock;
  final bool hasComposition;
  final bool isActive;
  final List<UnitOption> units;

  /// Harga bertingkat umum (untuk semua pelanggan).
  final List<PriceTier> tiers;

  /// Harga bertingkat khusus level pelanggan (`level_tiers`).
  final List<PriceTier> levelTiers;

  /// Jenis asli di Katalog web: `product` | `service` | `raw_material`
  /// (bahan baku dikirim sebagai [type] `product`); null dari server lama.
  final String? kind;

  /// Label jenis dari server, mis. "Bahan baku".
  final String? kindLabel;

  /// Barcode dari Katalog web (scan kamera / scanner), atau null.
  final String? barcode;

  /// Kategori barang di Katalog web; null = tanpa kategori.
  final int? categoryId;
  final String? categoryName;

  /// Barang punya foto di web. [photoVersion] berubah setiap foto diganti
  /// (kunci cache foto di HP).
  final bool hasPhoto;
  final String? photoVersion;
  final String? photoUrl;
  final String? photoThumbUrl;

  /// Bahan baku yang dicentang "Tampilkan di POS" di web.
  bool get isRawMaterial => kind == 'raw_material';

  Map<String, dynamic> toJson() => {
        'id': id,
        'sku': sku,
        'name': name,
        'type': type,
        'unit': unit,
        'price': price,
        'tax_rate': taxRate,
        'track_inventory': trackInventory,
        'stock_quantity': stockQuantity,
        'minimum_stock': minimumStock,
        'has_composition': hasComposition,
        'is_active': isActive,
        'units': [for (final unit in units) unit.toJson()],
        'tiers': [for (final tier in tiers) tier.toJson()],
        'level_tiers': [for (final tier in levelTiers) tier.toJson()],
        'kind': kind,
        'kind_label': kindLabel,
        'barcode': barcode,
        'category_id': categoryId,
        'category_name': categoryName,
        'has_photo': hasPhoto,
        'photo_version': photoVersion,
        'photo_url': photoUrl,
        'photo_thumb_url': photoThumbUrl,
      };

  /// Satuan dasar (isi 1) + satuan lain, sama dengan `ProductService::unitOptions()`.
  List<UnitOption> unitOptions() => [UnitOption(name: unit.isEmpty ? 'unit' : unit, factor: '1.000000', price: price), ...units];

  UnitOption optionFor(String? unitName) {
    final options = unitOptions();
    if (unitName != null && unitName.trim().isNotEmpty) {
      for (final option in options) {
        if (_sameUnit(option.name, unitName)) {
          return option;
        }
      }
    }
    return options.first;
  }

  /// Punya satuan lain selain satuan dasar (mis. karton isi 6): kasir
  /// memilih satuan saat barang diketuk.
  bool get hasOtherUnits => units.isNotEmpty;

  /// Label satuan untuk kasir: "pcs" (satuan dasar) atau "karton (isi 6
  /// pcs)", sama dengan `unitOptionLabel` kasir web.
  String unitLabel(UnitOption option) => Money.compare(option.factor, '1') == 0 ? option.name : '${option.name} (isi ${qty(option.factor)} ${unitOptions().first.name})';

  /// Label satuan [unitName] milik barang ini; satuan yang tidak dikenal
  /// barang ini ditulis apa adanya.
  String unitLabelFor(String unitName) {
    for (final option in unitOptions()) {
      if (_sameUnit(option.name, unitName)) {
        return unitLabel(option);
      }
    }
    return unitName;
  }

  /// Barang punya satuan [unitName] (satuan dasar atau satuan lain).
  bool hasUnit(String unitName) => unitOptions().any((option) => _sameUnit(option.name, unitName));

  /// Ada harga bertingkat (umum atau level pelanggan).
  bool get hasTieredPrices => tiers.isNotEmpty || levelTiers.isNotEmpty;

  /// Harga jual per satuan untuk jumlah tertentu. Port dari
  /// `ProductService::priceFor()` (sama dengan kasir web).
  String priceFor(String? unitName, String quantity, {int? levelId}) => quoteFor(unitName, quantity, levelId: levelId).price;

  /// Harga jual per satuan + asalnya: harga satuan itu, lalu harga
  /// bertingkat umum dengan batas minimum tertinggi yang terpenuhi. Pelanggan
  /// dengan level ([levelId]): harga bertingkat levelnya (batas tertinggi
  /// yang terpenuhi) dipakai bila lebih murah, jadi pelanggan level tidak
  /// pernah membayar lebih mahal dari pelanggan umum.
  PriceQuote quoteFor(String? unitName, String quantity, {int? levelId}) {
    final option = optionFor(unitName);
    final normalizedQuantity = Money.normalize(quantity.isEmpty ? '0' : quantity, 6);
    final general = _bestTier(tiers, option.name, normalizedQuantity);
    var quote = general == null
        ? PriceQuote(price: Money.normalize(option.price), source: PriceSource.normal)
        : PriceQuote(price: Money.normalize(general.price), source: PriceSource.tier, tier: general);
    if (levelId != null) {
      final level = _bestTier(levelTiers.where((tier) => tier.levelId == levelId), option.name, normalizedQuantity);
      if (level != null && Money.compare(level.price, quote.price) < 0) {
        quote = PriceQuote(price: Money.normalize(level.price), source: PriceSource.level, tier: level);
      }
    }
    return quote;
  }

  /// Tingkat harga satuan [unitName] untuk ditampilkan di kasir: harga umum
  /// dan harga level [levelId] (level lain tidak), urut jumlah minimum.
  List<PriceTier> tiersFor(String? unitName, {int? levelId}) {
    final option = optionFor(unitName);
    final rows = [
      for (final tier in tiers)
        if (_tierUnit(tier, option.name)) tier,
      if (levelId != null)
        for (final tier in levelTiers)
          if (tier.levelId == levelId && _tierUnit(tier, option.name)) tier,
    ];
    rows.sort((a, b) {
      final byMin = _compare6(a.minQuantity, b.minQuantity);
      return byMin != 0 ? byMin : (a.levelId == null ? 0 : 1) - (b.levelId == null ? 0 : 1);
    });
    return rows;
  }

  /// Tingkat dengan batas minimum tertinggi yang terpenuhi untuk satu satuan
  /// (sama dengan `ProductService::bestTier()`).
  PriceTier? _bestTier(Iterable<PriceTier> candidates, String unitName, String quantity) {
    PriceTier? best;
    for (final tier in candidates) {
      if (!_tierUnit(tier, unitName) || _compare6(quantity, tier.minQuantity) < 0) {
        continue;
      }
      if (best == null || _compare6(tier.minQuantity, best.minQuantity) > 0) {
        best = tier;
      }
    }
    return best;
  }

  /// Satuan tingkat harga cocok dengan [unitName]; kosong = satuan dasar.
  bool _tierUnit(PriceTier tier, String unitName) => _sameUnit(tier.unit.trim().isEmpty ? unitOptions().first.name : tier.unit, unitName);

  static bool _sameUnit(String a, String b) => a.trim().toLowerCase() == b.trim().toLowerCase();

  bool isLowStock() {
    if (!trackInventory || stockQuantity == null || minimumStock == null) {
      return false;
    }
    return _compare6(stockQuantity!, minimumStock!) <= 0;
  }

  static int _compare6(String a, String b) => bccomp(Money.normalize(a, 6), Money.normalize(b, 6), 6);
}

/// Kategori barang dari Katalog web (chip Kategori di kasir).
/// Pesan saat kode scan/ketik hanya cocok dengan barang yang sudah dinonaktifkan.
const String inactiveCodeMessage = 'Barang ini sudah dinonaktifkan.';

/// Hasil mencocokkan kode scan/ketik: [product] = barang aktif yang dijual,
/// atau null. [inactive] = barang nonaktif yang cocok (tidak dijual; kasir
/// melihat [inactiveCodeMessage]). Sama dengan `lookupCode` kasir web.
class CodeLookup {
  const CodeLookup({this.product, this.inactive});

  static const CodeLookup none = CodeLookup();

  final Product? product;
  final Product? inactive;

  bool get isInactive => product == null && inactive != null;
}

class ProductCategory {
  const ProductCategory({required this.id, required this.name, this.sort = 0});

  factory ProductCategory.fromJson(Map<String, dynamic> json) => ProductCategory(id: _i(json['id'])!, name: _s(json['name']), sort: _i(json['sort']) ?? 0);

  final int id;
  final String name;
  final int sort;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'sort': sort};
}

class Customer {
  const Customer({
    this.id,
    this.clientUuid,
    required this.name,
    this.phone,
    this.email,
    this.address,
    this.isWalkIn = false,
    this.pending = false,
    this.levelId,
    this.level,
  });

  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
        id: _i(json['id']),
        clientUuid: json['client_uuid']?.toString(),
        name: _s(json['name']),
        phone: json['phone']?.toString(),
        email: json['email']?.toString(),
        address: json['address']?.toString(),
        isWalkIn: _b(json['is_walk_in']),
        pending: _b(json['pending']),
        levelId: _i(json['level_id']),
        level: _blank(json['level']),
      );

  final int? id;
  final String? clientUuid;
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final bool isWalkIn;

  /// Pelanggan baru yang dibuat di HP dan belum terkirim.
  final bool pending;

  /// Level pelanggan dari web (mis. Reseller) untuk harga khusus level;
  /// null = tanpa level (termasuk pelanggan yang dibuat di HP).
  final int? levelId;
  final String? level;

  String get key => id != null ? 'id:$id' : 'uuid:$clientUuid';

  /// Nama untuk panel pesanan: "Bu Ani · Reseller" bila punya level.
  String get nameWithLevel => level == null ? name : '$name · $level';

  Map<String, dynamic> toJson() => {
        'id': id,
        'client_uuid': clientUuid,
        'name': name,
        'phone': phone,
        'email': email,
        'address': address,
        'is_walk_in': isWalkIn,
        'pending': pending,
        'level_id': levelId,
        'level': level,
      };
}

class CashAccount {
  const CashAccount({required this.id, required this.name, this.code, this.kind = 'cash'});

  factory CashAccount.fromJson(Map<String, dynamic> json) =>
      CashAccount(id: _i(json['id'])!, name: _s(json['name']), code: json['code']?.toString(), kind: _s(json['kind'], 'cash'));

  final int id;
  final String name;
  final String? code;
  final String kind;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'code': code, 'kind': kind};
}

class TenantSettings {
  const TenantSettings({
    required this.id,
    required this.name,
    this.pricesIncludeTax = false,
    this.salesTaxName = 'PPN',
    this.salesTaxRate = '0.00',
    this.autoStockAdjustment = false,
    this.paymentTermsDays = 14,
    this.posDining = true,
  });

  factory TenantSettings.fromJson(Map<String, dynamic> json) => TenantSettings(
        id: _i(json['id'])!,
        name: _s(json['name']),
        pricesIncludeTax: _b(json['prices_include_tax']),
        salesTaxName: _s(json['sales_tax_name'], 'PPN'),
        salesTaxRate: Money.normalize(json['sales_tax_rate']),
        autoStockAdjustment: _b(json['auto_stock_adjustment']),
        paymentTermsDays: _i(json['payment_terms_days']) ?? 14,
        // Server lama tanpa `pos_dining`: fitur rumah makan tetap tampil.
        posDining: json['pos_dining'] == null || _b(json['pos_dining']),
      );

  final int id;
  final String name;
  final bool pricesIncludeTax;
  final String salesTaxName;
  final String salesTaxRate;
  final bool autoStockAdjustment;
  final int paymentTermsDays;

  /// Fitur rumah makan / kafe di kasir (Pengaturan Kasir di web): jenis
  /// pesanan dan meja/antrian. Mati = toko eceran ("Cetak list" tetap ada).
  final bool posDining;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'prices_include_tax': pricesIncludeTax,
        'sales_tax_name': salesTaxName,
        'sales_tax_rate': salesTaxRate,
        'auto_stock_adjustment': autoStockAdjustment,
        'payment_terms_days': paymentTermsDays,
        'pos_dining': posDining,
      };
}

/// Pengaturan nota termal dari web (Dokumen & Nota › Nota Termal) + identitas usaha.
class ReceiptConfig {
  const ReceiptConfig({
    this.width = 58,
    this.fontSize = 'normal',
    this.showLogo = true,
    this.showAddress = true,
    this.showPhone = true,
    this.showCashier = true,
    this.showCustomer = true,
    this.showTax = true,
    this.showPayment = true,
    this.showQr = false,
    this.headerText,
    this.footerText = 'Terima kasih atas kunjungan Anda',
    this.companyName = '',
    this.address,
    this.phone,
    this.website,
    this.logoUrl,
    this.logoVersion,
    this.verifyBaseUrl,
  });

  factory ReceiptConfig.fromJson(Map<String, dynamic> json) {
    final company = Map<String, dynamic>.from((json['company'] as Map?) ?? const {});
    return ReceiptConfig(
      width: _i(json['width']) == 80 ? 80 : 58,
      fontSize: _s(json['font_size'], 'normal'),
      showLogo: json['show_logo'] == null || _b(json['show_logo']),
      showAddress: json['show_address'] == null || _b(json['show_address']),
      showPhone: json['show_phone'] == null || _b(json['show_phone']),
      showCashier: json['show_cashier'] == null || _b(json['show_cashier']),
      showCustomer: json['show_customer'] == null || _b(json['show_customer']),
      showTax: json['show_tax'] == null || _b(json['show_tax']),
      showPayment: json['show_payment'] == null || _b(json['show_payment']),
      showQr: _b(json['show_qr']),
      headerText: json['header_text']?.toString(),
      footerText: _s(json['footer_text'], 'Terima kasih atas kunjungan Anda'),
      companyName: _s(company['name']),
      address: company['address']?.toString(),
      phone: company['phone']?.toString(),
      website: company['website']?.toString(),
      logoUrl: json['logo_url']?.toString(),
      logoVersion: json['logo_version']?.toString(),
      verifyBaseUrl: json['verify_base_url']?.toString(),
    );
  }

  final int width;
  final String fontSize;
  final bool showLogo;
  final bool showAddress;
  final bool showPhone;
  final bool showCashier;
  final bool showCustomer;
  final bool showTax;
  final bool showPayment;
  final bool showQr;
  final String? headerText;
  final String footerText;
  final String companyName;
  final String? address;
  final String? phone;
  final String? website;
  final String? logoUrl;
  final String? logoVersion;
  final String? verifyBaseUrl;

  Map<String, dynamic> toJson() => {
        'width': width,
        'font_size': fontSize,
        'show_logo': showLogo,
        'show_address': showAddress,
        'show_phone': showPhone,
        'show_cashier': showCashier,
        'show_customer': showCustomer,
        'show_tax': showTax,
        'show_payment': showPayment,
        'show_qr': showQr,
        'header_text': headerText,
        'footer_text': footerText,
        'company': {'name': companyName, 'address': address, 'phone': phone, 'website': website},
        'logo_url': logoUrl,
        'logo_version': logoVersion,
        'verify_base_url': verifyBaseUrl,
      };
}

class NumberBlock {
  const NumberBlock({required this.id, required this.format, required this.start, required this.end, this.lastUsed});

  factory NumberBlock.fromJson(Map<String, dynamic> json) => NumberBlock(
        id: _i(json['id'])!,
        format: _s(json['format']),
        start: _i(json['start'])!,
        end: _i(json['end'])!,
        lastUsed: _i(json['last_used']),
      );

  final int id;
  final String format;
  final int start;
  final int end;
  final int? lastUsed;

  Map<String, dynamic> toJson() => {'id': id, 'format': format, 'start': start, 'end': end, 'last_used': lastUsed};
}

/// Menu aplikasi yang boleh tampil (dari permission role di web).
class Menus {
  const Menus({
    this.pos = false,
    this.voidSale = false,
    this.shift = false,
    this.reports = false,
    this.ai = false,
    this.records = false,
    this.stock = false,
    this.cashJournal = false,
    this.addCustomer = false,
    this.printer = false,
    this.operations = false,
    this.posSettings = false,
  });

  factory Menus.fromJson(Map<String, dynamic>? json) {
    final data = json ?? const {};
    return Menus(
      pos: _b(data['pos']),
      voidSale: _b(data['void_sale']),
      shift: _b(data['shift']),
      reports: _b(data['reports']),
      ai: _b(data['ai']),
      records: _b(data['records']),
      stock: _b(data['stock']),
      cashJournal: _b(data['cash_journal']),
      addCustomer: _b(data['add_customer']),
      printer: _b(data['printer']),
      operations: _b(data['operations']),
      posSettings: _b(data['pos_settings']),
    );
  }

  final bool pos;
  final bool voidSale;
  final bool shift;
  final bool reports;
  final bool ai;
  final bool records;
  final bool stock;
  final bool cashJournal;
  final bool addCustomer;
  final bool printer;

  /// Operasional harian: catat biaya, tagihan pemasok, Kas & Bank, pembayaran.
  final bool operations;

  /// Boleh mengubah pengaturan kasir untuk semua kasir usaha ini (mis.
  /// fitur rumah makan / kafe) lewat `PUT /pos/settings`.
  final bool posSettings;

  Map<String, dynamic> toJson() => {
        'pos': pos,
        'void_sale': voidSale,
        'shift': shift,
        'reports': reports,
        'ai': ai,
        'records': records,
        'stock': stock,
        'cash_journal': cashJournal,
        'add_customer': addCustomer,
        'printer': printer,
        'operations': operations,
        'pos_settings': posSettings,
      };
}

class TenantSummary {
  const TenantSummary({required this.id, required this.name, this.slug, this.role, this.roleLabel, this.active = true, this.menus = const Menus(), this.permissions, this.hasPin = false});

  factory TenantSummary.fromJson(Map<String, dynamic> json) => TenantSummary(
        id: _i(json['id'])!,
        slug: json['slug']?.toString(),
        name: _s(json['name']),
        role: json['role']?.toString(),
        roleLabel: json['role_label']?.toString(),
        active: json['active'] == null || _b(json['active']),
        menus: Menus.fromJson(json['menus'] == null ? null : Map<String, dynamic>.from(json['menus'] as Map)),
        permissions: json['permissions'] is List ? [for (final item in json['permissions'] as List) item.toString()] : null,
        hasPin: _b(json['has_pin']),
      );

  final int id;
  final String? slug;
  final String name;
  final String? role;
  final String? roleLabel;
  final bool active;
  final Menus menus;

  /// User sudah punya PIN aplikasi di perusahaan ini (tablet kasir bersama).
  final bool hasPin;

  TenantSummary copyWith({Menus? menus, bool? hasPin}) =>
      TenantSummary(id: id, slug: slug, name: name, role: role, roleLabel: roleLabel, active: active, menus: menus ?? this.menus, permissions: permissions, hasPin: hasPin ?? this.hasPin);

  /// Daftar permission web (`ViewAny:Invoice`, `view-reports`, …) dari
  /// login / `GET /me`; null bila sesi lama belum menyimpannya.
  final List<String>? permissions;

  /// Punya permission web tertentu. Bila daftar belum tersimpan, pakai
  /// [fallback] (menu yang sudah dipetakan server).
  bool can(String permission, {bool fallback = false}) => permissions == null ? fallback : permissions!.contains(permission);

  Map<String, dynamic> toJson() => {'id': id, 'slug': slug, 'name': name, 'role': role, 'role_label': roleLabel, 'active': active, 'menus': menus.toJson(), 'permissions': permissions, 'has_pin': hasPin};
}

class SessionUser {
  const SessionUser({required this.id, required this.name, required this.email, this.avatarUrl});

  factory SessionUser.fromJson(Map<String, dynamic> json) =>
      SessionUser(id: _i(json['id'])!, name: _s(json['name']), email: _s(json['email']), avatarUrl: json['avatar_url']?.toString());

  final int id;
  final String name;
  final String email;
  final String? avatarUrl;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'email': email, 'avatar_url': avatarUrl};
}

/// Anggota yang bisa membuka tablet kasir bersama dengan PIN.
class PinUser {
  const PinUser({required this.id, required this.name, this.roleLabel, this.avatarUrl, this.isHost = false});

  factory PinUser.fromJson(Map<String, dynamic> json, {bool isHost = false}) =>
      PinUser(id: _i(json['id'])!, name: _s(json['name']), roleLabel: json['role_label']?.toString(), avatarUrl: json['avatar_url']?.toString(), isHost: isHost);

  final int id;
  final String name;
  final String? roleLabel;
  final String? avatarUrl;

  /// Pemilik login tablet ini.
  final bool isHost;

  /// Inisial untuk avatar ("Sri Wahyuni" → "SW").
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) {
      return '?';
    }
    return (parts.length == 1 ? parts.first.substring(0, 1) : '${parts.first[0]}${parts.last[0]}').toUpperCase();
  }
}
