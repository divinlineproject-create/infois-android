import '../core/bcmath.dart';
import '../core/money.dart';

/// Data master dari server (lihat API.md › sync/pull). Semua angka uang/qty
/// disimpan sebagai string desimal.

String _s(Object? value, [String fallback = '']) => value == null ? fallback : value.toString();

bool _b(Object? value) => value == true || value == 1 || value == '1' || value == 'true';

int? _i(Object? value) => value == null ? null : (value is int ? value : int.tryParse(value.toString()));

class UnitOption {
  const UnitOption({required this.name, required this.factor, required this.price});

  factory UnitOption.fromJson(Map<String, dynamic> json) =>
      UnitOption(name: _s(json['name']), factor: Money.normalize(json['factor'], 6), price: Money.normalize(json['price']));

  final String name;
  final String factor;
  final String price;

  Map<String, dynamic> toJson() => {'name': name, 'factor': factor, 'price': price};
}

class PriceTier {
  const PriceTier({required this.unit, required this.minQuantity, required this.price});

  factory PriceTier.fromJson(Map<String, dynamic> json) =>
      PriceTier(unit: _s(json['unit']), minQuantity: Money.normalize(json['min_quantity'], 6), price: Money.normalize(json['price']));

  final String unit;
  final String minQuantity;
  final String price;

  Map<String, dynamic> toJson() => {'unit': unit, 'min_quantity': minQuantity, 'price': price};
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
    this.kind,
    this.kindLabel,
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
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
        kind: (json['kind']?.toString() ?? '').isEmpty ? null : json['kind'].toString(),
        kindLabel: (json['kind_label']?.toString() ?? '').trim().isEmpty ? null : json['kind_label'].toString(),
      );

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
  final List<PriceTier> tiers;

  /// Jenis asli di Katalog web: `product` | `service` | `raw_material`
  /// (bahan baku dikirim sebagai [type] `product`); null dari server lama.
  final String? kind;

  /// Label jenis dari server, mis. "Bahan baku".
  final String? kindLabel;

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
        'kind': kind,
        'kind_label': kindLabel,
      };

  /// Satuan dasar (isi 1) + satuan lain, sama dengan `ProductService::unitOptions()`.
  List<UnitOption> unitOptions() => [UnitOption(name: unit.isEmpty ? 'unit' : unit, factor: '1.000000', price: price), ...units];

  UnitOption optionFor(String? unitName) {
    final options = unitOptions();
    if (unitName != null && unitName.trim().isNotEmpty) {
      final wanted = unitName.trim().toLowerCase();
      for (final option in options) {
        if (option.name.toLowerCase() == wanted) {
          return option;
        }
      }
    }
    return options.first;
  }

  /// Harga jual per satuan untuk jumlah tertentu: harga satuan itu, lalu
  /// harga grosir dengan batas minimum tertinggi yang terpenuhi. Port dari
  /// `ProductService::priceFor()`.
  String priceFor(String? unitName, String quantity) {
    final option = optionFor(unitName);
    final normalizedQuantity = Money.normalize(quantity.isEmpty ? '0' : quantity, 6);
    PriceTier? best;
    for (final tier in tiers) {
      final tierUnit = tier.unit.isEmpty ? unit : tier.unit;
      if (tierUnit.toLowerCase() != option.name.toLowerCase()) {
        continue;
      }
      if (_compare6(normalizedQuantity, tier.minQuantity) < 0) {
        continue;
      }
      if (best == null || _compare6(tier.minQuantity, best.minQuantity) > 0) {
        best = tier;
      }
    }
    return Money.normalize(best?.price ?? option.price);
  }

  bool isLowStock() {
    if (!trackInventory || stockQuantity == null || minimumStock == null) {
      return false;
    }
    return _compare6(stockQuantity!, minimumStock!) <= 0;
  }

  static int _compare6(String a, String b) => bccomp(Money.normalize(a, 6), Money.normalize(b, 6), 6);
}

class Customer {
  const Customer({this.id, this.clientUuid, required this.name, this.phone, this.email, this.address, this.isWalkIn = false, this.pending = false});

  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
        id: _i(json['id']),
        clientUuid: json['client_uuid']?.toString(),
        name: _s(json['name']),
        phone: json['phone']?.toString(),
        email: json['email']?.toString(),
        address: json['address']?.toString(),
        isWalkIn: _b(json['is_walk_in']),
        pending: _b(json['pending']),
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

  String get key => id != null ? 'id:$id' : 'uuid:$clientUuid';

  Map<String, dynamic> toJson() => {
        'id': id,
        'client_uuid': clientUuid,
        'name': name,
        'phone': phone,
        'email': email,
        'address': address,
        'is_walk_in': isWalkIn,
        'pending': pending,
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
  });

  factory TenantSettings.fromJson(Map<String, dynamic> json) => TenantSettings(
        id: _i(json['id'])!,
        name: _s(json['name']),
        pricesIncludeTax: _b(json['prices_include_tax']),
        salesTaxName: _s(json['sales_tax_name'], 'PPN'),
        salesTaxRate: Money.normalize(json['sales_tax_rate']),
        autoStockAdjustment: _b(json['auto_stock_adjustment']),
        paymentTermsDays: _i(json['payment_terms_days']) ?? 14,
      );

  final int id;
  final String name;
  final bool pricesIncludeTax;
  final String salesTaxName;
  final String salesTaxRate;
  final bool autoStockAdjustment;
  final int paymentTermsDays;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'prices_include_tax': pricesIncludeTax,
        'sales_tax_name': salesTaxName,
        'sales_tax_rate': salesTaxRate,
        'auto_stock_adjustment': autoStockAdjustment,
        'payment_terms_days': paymentTermsDays,
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
      };
}

class TenantSummary {
  const TenantSummary({required this.id, required this.name, this.slug, this.role, this.roleLabel, this.active = true, this.menus = const Menus(), this.permissions});

  factory TenantSummary.fromJson(Map<String, dynamic> json) => TenantSummary(
        id: _i(json['id'])!,
        slug: json['slug']?.toString(),
        name: _s(json['name']),
        role: json['role']?.toString(),
        roleLabel: json['role_label']?.toString(),
        active: json['active'] == null || _b(json['active']),
        menus: Menus.fromJson(json['menus'] == null ? null : Map<String, dynamic>.from(json['menus'] as Map)),
        permissions: json['permissions'] is List ? [for (final item in json['permissions'] as List) item.toString()] : null,
      );

  final int id;
  final String? slug;
  final String name;
  final String? role;
  final String? roleLabel;
  final bool active;
  final Menus menus;

  /// Daftar permission web (`ViewAny:Invoice`, `view-reports`, …) dari
  /// login / `GET /me`; null bila sesi lama belum menyimpannya.
  final List<String>? permissions;

  /// Punya permission web tertentu. Bila daftar belum tersimpan, pakai
  /// [fallback] (menu yang sudah dipetakan server).
  bool can(String permission, {bool fallback = false}) => permissions == null ? fallback : permissions!.contains(permission);

  Map<String, dynamic> toJson() => {'id': id, 'slug': slug, 'name': name, 'role': role, 'role_label': roleLabel, 'active': active, 'menus': menus.toJson(), 'permissions': permissions};
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
