// Model Catatan dari server (lihat API.md › 8. Catatan). Uang string 2
// desimal, qty 6 desimal, tanggal YYYY-MM-DD, waktu ISO 8601.

import '../core/money.dart';

String _s(Object? value, [String fallback = '']) => value == null ? fallback : value.toString();

bool _b(Object? value) => value == true || value == 1 || value == '1' || value == 'true';

int _i(Object? value, [int fallback = 0]) => value == null ? fallback : (value is int ? value : int.tryParse(value.toString()) ?? fallback);

int? _in(Object? value) => value == null ? null : (value is int ? value : int.tryParse(value.toString()));

String _m(Object? value) => Money.normalize(value);

String _q(Object? value) => Money.normalize(value, 6);

Map<String, dynamic> _map(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

Map<String, dynamic>? _mapOrNull(Object? value) => value is Map ? Map<String, dynamic>.from(value) : null;

/// Daftar objek; bentuk lain dari server (mis. `{}`) dianggap kosong.
List<Map<String, dynamic>> _maps(Object? value) => [if (value is List) for (final item in value) _map(item)];

DateTime? _date(Object? value) => value == null ? null : DateTime.tryParse(value.toString());

/// Satu halaman daftar; [extra] menyimpan kunci tambahan di luar `data`
/// (mis. `accounts`/`totals` buku kas, `low_count` stok).
class RecordPage<T> {
  const RecordPage({required this.items, this.nextCursor, this.extra = const {}});

  final List<T> items;
  final String? nextCursor;
  final Map<String, dynamic> extra;
}

/// Rujukan ringkas ke pihak/akun/HP/gudang: `{id, name, code?, phone?}`.
class RecordRef {
  const RecordRef({this.id, required this.name, this.code, this.phone, this.type});

  factory RecordRef.fromJson(Map<String, dynamic> json) => RecordRef(
        id: _in(json['id']),
        name: _s(json['name'], json['number']?.toString() ?? '-'),
        code: json['code']?.toString(),
        phone: json['phone']?.toString(),
        type: json['type']?.toString(),
      );

  static RecordRef? maybe(Object? value) => value is Map ? RecordRef.fromJson(_map(value)) : null;

  final int? id;
  final String name;
  final String? code;
  final String? phone;
  final String? type;

  String get display => code == null || code!.isEmpty ? name : '$code · $name';
}

/// Dokumen induk pembayaran: `{type: sale|purchase, id, number, status}`.
class DocumentRef {
  const DocumentRef({required this.type, required this.id, required this.number, this.status});

  factory DocumentRef.fromJson(Map<String, dynamic> json) =>
      DocumentRef(type: _s(json['type'], 'sale'), id: _i(json['id']), number: _s(json['number'], '-'), status: json['status']?.toString());

  static DocumentRef? maybe(Object? value) => value is Map ? DocumentRef.fromJson(_map(value)) : null;

  final String type;
  final int id;
  final String number;
  final String? status;
}

/// Lampiran dokumen: `{index, name, kind: image|pdf|file, url}`.
class RecordAttachment {
  const RecordAttachment({required this.index, required this.name, this.kind = 'file', this.url});

  factory RecordAttachment.fromJson(Map<String, dynamic> json) =>
      RecordAttachment(index: _i(json['index']), name: _s(json['name'], 'lampiran'), kind: _s(json['kind'], 'file'), url: json['url']?.toString());

  static List<RecordAttachment> list(Object? value) => [for (final item in _maps(value)) RecordAttachment.fromJson(item)];

  final int index;
  final String name;
  final String kind;
  final String? url;

  bool get isImage => kind == 'image';
}

/// Label status penjualan (sama dengan web).
String saleStatusLabel(String status) => switch (status) {
      'draft' => 'Draft',
      'issued' => 'Terbit',
      'partially_paid' => 'Dibayar Sebagian',
      'paid' => 'Lunas',
      'void' => 'Dibatalkan',
      'open' => 'Belum Dibayar',
      _ => status,
    };

/// Ringkasan penjualan (`GET /records/sales`).
class SaleRecord {
  const SaleRecord({
    required this.id,
    required this.number,
    this.clientUuid,
    this.date = '',
    this.dueDate,
    this.status = 'issued',
    this.statusLabel = '',
    this.source = 'web',
    this.customer,
    this.currency = 'IDR',
    this.total = '0.00',
    this.amountPaid = '0.00',
    this.balanceDue = '0.00',
    this.itemsCount = 0,
    this.cashier,
    this.device,
    this.posShiftId,
    this.hasAttachments = false,
    this.issuedAt,
    this.createdAt,
  });

  factory SaleRecord.fromJson(Map<String, dynamic> json) => SaleRecord(
        id: _i(json['id']),
        number: _s(json['number'], 'DRAFT-${json['id']}'),
        clientUuid: json['client_uuid']?.toString(),
        date: _s(json['date']),
        dueDate: json['due_date']?.toString(),
        status: _s(json['status'], 'issued'),
        statusLabel: _s(json['status_label'], saleStatusLabel(_s(json['status'], 'issued'))),
        source: _s(json['source'], 'web'),
        customer: RecordRef.maybe(json['customer']),
        currency: _s(json['currency'], 'IDR'),
        total: _m(json['total']),
        amountPaid: _m(json['amount_paid']),
        balanceDue: _m(json['balance_due']),
        itemsCount: _i(json['items_count']),
        cashier: json['cashier']?.toString(),
        device: RecordRef.maybe(json['device']),
        posShiftId: _in(json['pos_shift_id']),
        hasAttachments: _b(json['has_attachments']),
        issuedAt: _date(json['issued_at']),
        createdAt: _date(json['created_at']),
      );

  final int id;
  final String number;
  final String? clientUuid;
  final String date;
  final String? dueDate;
  final String status;
  final String statusLabel;
  final String source;
  final RecordRef? customer;
  final String currency;
  final String total;
  final String amountPaid;
  final String balanceDue;
  final int itemsCount;
  final String? cashier;
  final RecordRef? device;
  final int? posShiftId;
  final bool hasAttachments;
  final DateTime? issuedAt;
  final DateTime? createdAt;

  bool get outstanding => status == 'issued' || status == 'partially_paid';
}

class SaleLine {
  const SaleLine({
    this.id,
    this.productId,
    this.sku,
    required this.description,
    this.quantity = '1.000000',
    this.unit,
    this.unitPrice = '0.00',
    this.discountPercent = '0.00',
    this.taxRate = '0.00',
    this.discountAmount = '0.00',
    this.netAmount = '0.00',
    this.taxAmount = '0.00',
    this.lineTotal = '0.00',
    this.account,
  });

  factory SaleLine.fromJson(Map<String, dynamic> json) => SaleLine(
        id: _in(json['id']),
        productId: _in(json['product_id']),
        sku: json['sku']?.toString(),
        description: _s(json['description'], '-'),
        quantity: _q(json['quantity']),
        unit: json['unit']?.toString(),
        unitPrice: _m(json['unit_price']),
        discountPercent: _m(json['discount_percent']),
        taxRate: _m(json['tax_rate']),
        discountAmount: _m(json['discount_amount']),
        netAmount: _m(json['net_amount']),
        taxAmount: _m(json['tax_amount']),
        lineTotal: _m(json['line_total']),
        account: RecordRef.maybe(json['account']),
      );

  final int? id;
  final int? productId;
  final String? sku;
  final String description;
  final String quantity;
  final String? unit;
  final String unitPrice;
  final String discountPercent;
  final String taxRate;
  final String discountAmount;
  final String netAmount;
  final String taxAmount;
  final String lineTotal;

  /// Akun biaya (hanya baris pembelian).
  final RecordRef? account;
}

/// Pembayaran masuk/keluar (`GET /records/payments`).
class PaymentRecord {
  const PaymentRecord({
    required this.id,
    this.kind = 'in',
    this.date = '',
    this.amount = '0.00',
    this.baseAmount = '0.00',
    this.currency = 'IDR',
    this.method = 'cash',
    this.methodLabel = 'Tunai',
    this.via = 'payment',
    this.reference,
    this.account,
    this.document,
    this.party,
    this.withholdingAmount = '0.00',
    this.hasAttachments = false,
    this.createdAt,
    this.exchangeRate,
    this.withholdingType,
    this.journal,
    this.deposit,
    this.clientUuid,
    this.attachments = const [],
  });

  factory PaymentRecord.fromJson(Map<String, dynamic> json) => PaymentRecord(
        id: _i(json['id']),
        kind: _s(json['kind'], 'in'),
        date: _s(json['date']),
        amount: _m(json['amount']),
        baseAmount: _m(json['base_amount']),
        currency: _s(json['currency'], 'IDR'),
        method: _s(json['method'], 'cash'),
        methodLabel: _s(json['method_label'], 'Tunai'),
        via: _s(json['via'], 'payment'),
        reference: json['reference']?.toString(),
        account: RecordRef.maybe(json['account']),
        document: DocumentRef.maybe(json['document']),
        party: RecordRef.maybe(json['party']),
        withholdingAmount: _m(json['withholding_amount']),
        hasAttachments: _b(json['has_attachments']),
        createdAt: _date(json['created_at']),
        exchangeRate: json['exchange_rate']?.toString(),
        withholdingType: json['withholding_type']?.toString(),
        journal: RecordRef.maybe(json['journal']),
        deposit: RecordRef.maybe(json['deposit']),
        clientUuid: json['client_uuid']?.toString(),
        attachments: RecordAttachment.list(json['attachments']),
      );

  final int id;

  /// `in` = uang masuk, `out` = uang keluar.
  final String kind;
  final String date;
  final String amount;
  final String baseAmount;
  final String currency;
  final String method;
  final String methodLabel;
  final String via;
  final String? reference;
  final RecordRef? account;
  final DocumentRef? document;
  final RecordRef? party;
  final String withholdingAmount;
  final bool hasAttachments;
  final DateTime? createdAt;
  final String? exchangeRate;
  final String? withholdingType;
  final RecordRef? journal;
  final RecordRef? deposit;
  final String? clientUuid;
  final List<RecordAttachment> attachments;

  bool get incoming => kind == 'in';
}

class CreditNoteRef {
  const CreditNoteRef({required this.id, required this.number, this.date = '', this.reason, this.restock = false, this.total = '0.00'});

  factory CreditNoteRef.fromJson(Map<String, dynamic> json) => CreditNoteRef(
        id: _i(json['id']),
        number: _s(json['number'], '-'),
        date: _s(json['date']),
        reason: json['reason']?.toString(),
        restock: _b(json['restock']),
        total: _m(json['total']),
      );

  final int id;
  final String number;
  final String date;
  final String? reason;
  final bool restock;
  final String total;
}

/// Rincian penjualan (`GET /records/sales/{id}`).
class SaleDetail {
  const SaleDetail({
    required this.summary,
    this.isOpening = false,
    this.pricesIncludeTax = false,
    this.taxName = 'PPN',
    this.subtotal = '0.00',
    this.discountTotal = '0.00',
    this.taxTotal = '0.00',
    this.notes,
    this.terms,
    this.warehouse,
    this.items = const [],
    this.payments = const [],
    this.creditNotes = const [],
    this.verificationUrl,
    this.verificationStatus,
    this.voidReason,
    this.voidedAt,
    this.attachments = const [],
    this.receiptLink,
    this.pdfLink,
    this.canVoid = false,
    this.canReturn = false,
  });

  factory SaleDetail.fromJson(Map<String, dynamic> json) {
    final verification = _mapOrNull(json['verification']);
    final links = _map(json['links']);
    final can = _map(json['can']);
    return SaleDetail(
      summary: SaleRecord.fromJson(json),
      isOpening: _b(json['is_opening']),
      pricesIncludeTax: _b(json['prices_include_tax']),
      taxName: _s(json['tax_name'], 'PPN'),
      subtotal: _m(json['subtotal']),
      discountTotal: _m(json['discount_total']),
      taxTotal: _m(json['tax_total']),
      notes: json['notes']?.toString(),
      terms: json['terms']?.toString(),
      warehouse: RecordRef.maybe(json['warehouse']),
      items: [for (final item in _maps(json['items'])) SaleLine.fromJson(item)],
      payments: [for (final payment in _maps(json['payments'])) PaymentRecord.fromJson(payment)],
      creditNotes: [for (final note in _maps(json['credit_notes'])) CreditNoteRef.fromJson(note)],
      verificationUrl: verification?['url']?.toString(),
      verificationStatus: verification?['status']?.toString(),
      voidReason: json['void_reason']?.toString(),
      voidedAt: _date(json['voided_at']),
      attachments: RecordAttachment.list(json['attachments']),
      receiptLink: links['receipt']?.toString(),
      pdfLink: links['pdf']?.toString(),
      canVoid: _b(can['void']),
      canReturn: _b(can['return']),
    );
  }

  final SaleRecord summary;
  final bool isOpening;
  final bool pricesIncludeTax;
  final String taxName;
  final String subtotal;
  final String discountTotal;
  final String taxTotal;
  final String? notes;
  final String? terms;
  final RecordRef? warehouse;
  final List<SaleLine> items;
  final List<PaymentRecord> payments;
  final List<CreditNoteRef> creditNotes;

  /// Tautan publik cek keaslian (untuk Bagikan / WhatsApp); null untuk draft.
  final String? verificationUrl;
  final String? verificationStatus;
  final String? voidReason;
  final DateTime? voidedAt;
  final List<RecordAttachment> attachments;
  final String? receiptLink;
  final String? pdfLink;
  final bool canVoid;
  final bool canReturn;
}

/// Ringkasan pembelian / tagihan pemasok (`GET /records/purchases`).
class PurchaseRecord {
  const PurchaseRecord({
    required this.id,
    required this.number,
    this.supplierReference,
    this.date = '',
    this.dueDate,
    this.status = 'open',
    this.statusLabel = '',
    this.supplier,
    this.currency = 'IDR',
    this.total = '0.00',
    this.amountPaid = '0.00',
    this.balanceDue = '0.00',
    this.overdueDays = 0,
    this.itemsCount = 0,
    this.hasAttachments = false,
    this.postedAt,
    this.createdAt,
  });

  factory PurchaseRecord.fromJson(Map<String, dynamic> json) => PurchaseRecord(
        id: _i(json['id']),
        number: _s(json['number'], 'DRAFT-${json['id']}'),
        supplierReference: json['supplier_reference']?.toString(),
        date: _s(json['date']),
        dueDate: json['due_date']?.toString(),
        status: _s(json['status'], 'open'),
        statusLabel: _s(json['status_label'], saleStatusLabel(_s(json['status'], 'open'))),
        supplier: RecordRef.maybe(json['supplier']),
        currency: _s(json['currency'], 'IDR'),
        total: _m(json['total']),
        amountPaid: _m(json['amount_paid']),
        balanceDue: _m(json['balance_due']),
        overdueDays: _i(json['overdue_days']),
        itemsCount: _i(json['items_count']),
        hasAttachments: _b(json['has_attachments']),
        postedAt: _date(json['posted_at']),
        createdAt: _date(json['created_at']),
      );

  final int id;
  final String number;
  final String? supplierReference;
  final String date;
  final String? dueDate;
  final String status;
  final String statusLabel;
  final RecordRef? supplier;
  final String currency;
  final String total;
  final String amountPaid;
  final String balanceDue;
  final int overdueDays;
  final int itemsCount;
  final bool hasAttachments;
  final DateTime? postedAt;
  final DateTime? createdAt;
}

/// Rincian pembelian (`GET /records/purchases/{id}`), baca saja.
class PurchaseDetail {
  const PurchaseDetail({
    required this.summary,
    this.isOpening = false,
    this.subtotal = '0.00',
    this.taxTotal = '0.00',
    this.notes,
    this.warehouse,
    this.items = const [],
    this.payments = const [],
    this.debitNotes = const [],
    this.voidReason,
    this.voidedAt,
    this.attachments = const [],
  });

  factory PurchaseDetail.fromJson(Map<String, dynamic> json) => PurchaseDetail(
        summary: PurchaseRecord.fromJson(json),
        isOpening: _b(json['is_opening']),
        subtotal: _m(json['subtotal']),
        taxTotal: _m(json['tax_total']),
        notes: json['notes']?.toString(),
        warehouse: RecordRef.maybe(json['warehouse']),
        items: [for (final item in _maps(json['items'])) SaleLine.fromJson(item)],
        payments: [for (final payment in _maps(json['payments'])) PaymentRecord.fromJson(payment)],
        debitNotes: [for (final note in _maps(json['debit_notes'])) CreditNoteRef.fromJson(note)],
        voidReason: json['void_reason']?.toString(),
        voidedAt: _date(json['voided_at']),
        attachments: RecordAttachment.list(json['attachments']),
      );

  final PurchaseRecord summary;
  final bool isOpening;
  final String subtotal;
  final String taxTotal;
  final String? notes;
  final RecordRef? warehouse;
  final List<SaleLine> items;
  final List<PaymentRecord> payments;
  final List<CreditNoteRef> debitNotes;
  final String? voidReason;
  final DateTime? voidedAt;
  final List<RecordAttachment> attachments;
}

/// Baris buku kas & bank (`GET /records/cash`).
class CashEntry {
  const CashEntry({
    required this.id,
    this.entryId,
    this.date = '',
    this.number,
    this.reference,
    this.description,
    this.direction = 'in',
    this.amount = '0.00',
    this.account,
    this.counterpart,
    this.sourceType = 'other',
    this.sourceLabel = '',
    this.sourceId,
    this.balance = '0.00',
  });

  factory CashEntry.fromJson(Map<String, dynamic> json) {
    final source = _map(json['source']);
    return CashEntry(
      id: _i(json['id']),
      entryId: _in(json['entry_id']),
      date: _s(json['date']),
      number: json['number']?.toString(),
      reference: json['reference']?.toString(),
      description: json['description']?.toString(),
      direction: _s(json['direction'], 'in'),
      amount: _m(json['amount']),
      account: RecordRef.maybe(json['account']),
      counterpart: json['counterpart']?.toString(),
      sourceType: _s(source['type'], 'other'),
      sourceLabel: _s(source['label']),
      sourceId: _in(source['id']),
      balance: _m(json['balance']),
    );
  }

  final int id;
  final int? entryId;
  final String date;
  final String? number;
  final String? reference;
  final String? description;
  final String direction;
  final String amount;
  final RecordRef? account;
  final String? counterpart;
  final String sourceType;
  final String sourceLabel;
  final int? sourceId;

  /// Saldo akun ini setelah baris ini.
  final String balance;

  bool get incoming => direction == 'in';
}

/// Saldo akun kas/bank (buku kas: `opening`/`closing`; saldo hari ini: `balance`).
class CashAccountBalance {
  const CashAccountBalance({required this.id, this.code, required this.name, this.kind = 'cash', this.opening = '0.00', this.closing = '0.00', this.balance = '0.00'});

  factory CashAccountBalance.fromJson(Map<String, dynamic> json) => CashAccountBalance(
        id: _i(json['id']),
        code: json['code']?.toString(),
        name: _s(json['name']),
        kind: _s(json['kind'], 'cash'),
        opening: _m(json['opening']),
        closing: _m(json['closing'] ?? json['balance']),
        balance: _m(json['balance'] ?? json['closing']),
      );

  final int id;
  final String? code;
  final String name;
  final String kind;
  final String opening;
  final String closing;
  final String balance;
}

/// Kepala buku kas: periode, saldo per akun, total masuk/keluar.
class CashBookHeader {
  const CashBookHeader({this.from = '', this.to = '', this.accounts = const [], this.totalIn = '0.00', this.totalOut = '0.00', this.opening = '0.00', this.closing = '0.00'});

  factory CashBookHeader.fromJson(Map<String, dynamic> json) {
    final period = _map(json['period']);
    final totals = _map(json['totals']);
    return CashBookHeader(
      from: _s(period['from']),
      to: _s(period['to']),
      accounts: [for (final account in _maps(json['accounts'])) CashAccountBalance.fromJson(account)],
      totalIn: _m(totals['in']),
      totalOut: _m(totals['out']),
      opening: _m(totals['opening']),
      closing: _m(totals['closing']),
    );
  }

  final String from;
  final String to;
  final List<CashAccountBalance> accounts;
  final String totalIn;
  final String totalOut;
  final String opening;
  final String closing;
}

/// Mutasi stok (`GET /records/stock-movements`).
class StockMovement {
  const StockMovement({
    required this.id,
    this.date = '',
    this.type = 'adjustment',
    this.typeLabel = '',
    this.direction = 'in',
    this.quantity = '0.000000',
    this.unit,
    this.product,
    this.warehouse,
    this.unitCost = '0.00',
    this.totalCost = '0.00',
    this.balanceQuantity = '0.000000',
    this.warehouseBalanceQuantity,
    this.averageCost = '0.00',
    this.reference,
    this.description,
    this.createdAt,
  });

  factory StockMovement.fromJson(Map<String, dynamic> json) => StockMovement(
        id: _i(json['id']),
        date: _s(json['date']),
        type: _s(json['type'], 'adjustment'),
        typeLabel: _s(json['type_label'], _s(json['type'])),
        direction: _s(json['direction'], 'in'),
        quantity: _q(json['quantity']),
        unit: json['unit']?.toString(),
        product: RecordRef.maybe(json['product']),
        warehouse: RecordRef.maybe(json['warehouse']),
        unitCost: _m(json['unit_cost']),
        totalCost: _m(json['total_cost']),
        balanceQuantity: _q(json['balance_quantity']),
        warehouseBalanceQuantity: json['warehouse_balance_quantity'] == null ? null : _q(json['warehouse_balance_quantity']),
        averageCost: _m(json['average_cost']),
        reference: DocumentRef.maybe(json['reference']),
        description: json['description']?.toString(),
        createdAt: _date(json['created_at']),
      );

  final int id;
  final String date;
  final String type;
  final String typeLabel;
  final String direction;

  /// Bertanda: + masuk, − keluar.
  final String quantity;
  final String? unit;
  final RecordRef? product;
  final RecordRef? warehouse;
  final String unitCost;
  final String totalCost;
  final String balanceQuantity;
  final String? warehouseBalanceQuantity;
  final String averageCost;
  final DocumentRef? reference;
  final String? description;
  final DateTime? createdAt;

  bool get incoming => direction == 'in';
}

class WarehouseStock {
  const WarehouseStock({required this.id, this.code, required this.name, this.quantity = '0.000000'});

  factory WarehouseStock.fromJson(Map<String, dynamic> json) =>
      WarehouseStock(id: _i(json['id']), code: json['code']?.toString(), name: _s(json['name']), quantity: _q(json['quantity']));

  final int id;
  final String? code;
  final String name;
  final String quantity;
}

/// Stok barang saat ini (`GET /records/stock`).
class StockLevel {
  const StockLevel({
    required this.id,
    this.sku,
    required this.name,
    this.unit = 'unit',
    this.quantity = '0.000000',
    this.minimumStock,
    this.low = false,
    this.empty = false,
    this.averageCost = '0.00',
    this.stockValue = '0.00',
    this.price = '0.00',
    this.warehouses = const [],
    this.updatedAt,
  });

  factory StockLevel.fromJson(Map<String, dynamic> json) => StockLevel(
        id: _i(json['id']),
        sku: json['sku']?.toString(),
        name: _s(json['name']),
        unit: _s(json['unit'], 'unit'),
        quantity: _q(json['quantity']),
        minimumStock: json['minimum_stock'] == null ? null : _q(json['minimum_stock']),
        low: _b(json['low']),
        empty: _b(json['empty']),
        averageCost: _m(json['average_cost']),
        stockValue: _m(json['stock_value']),
        price: _m(json['price']),
        warehouses: [for (final warehouse in _maps(json['warehouses'])) WarehouseStock.fromJson(warehouse)],
        updatedAt: _date(json['updated_at']),
      );

  final int id;
  final String? sku;
  final String name;
  final String unit;
  final String quantity;
  final String? minimumStock;
  final bool low;
  final bool empty;
  final String averageCost;
  final String stockValue;
  final String price;
  final List<WarehouseStock> warehouses;
  final DateTime? updatedAt;
}

/// Pelanggan (`GET /records/customers`).
class CustomerRecord {
  const CustomerRecord({
    required this.id,
    this.clientUuid,
    required this.name,
    this.contactPerson,
    this.phone,
    this.email,
    this.address,
    this.npwp,
    this.currency = 'IDR',
    this.invoicesCount = 0,
    this.outstandingCount = 0,
    this.overdueCount = 0,
    this.receivable = '0.00',
    this.needsCollection = false,
    this.notes,
    this.outstandingInvoices = const [],
    this.lastPayment,
    this.depositsAvailable = '0.00',
  });

  factory CustomerRecord.fromJson(Map<String, dynamic> json) => CustomerRecord(
        id: _i(json['id']),
        clientUuid: json['client_uuid']?.toString(),
        name: _s(json['name'], '-'),
        contactPerson: json['contact_person']?.toString(),
        phone: json['phone']?.toString(),
        email: json['email']?.toString(),
        address: json['address']?.toString(),
        npwp: json['npwp']?.toString(),
        currency: _s(json['currency'], 'IDR'),
        invoicesCount: _i(json['invoices_count']),
        outstandingCount: _i(json['outstanding_count']),
        overdueCount: _i(json['overdue_count']),
        receivable: _m(json['receivable']),
        needsCollection: _b(json['needs_collection']),
        notes: json['notes']?.toString(),
        outstandingInvoices: [for (final sale in _maps(json['outstanding_invoices'])) SaleRecord.fromJson(sale)],
        lastPayment: json['last_payment'] is Map ? PaymentRecord.fromJson(_map(json['last_payment'])) : null,
        depositsAvailable: _m(json['deposits_available']),
      );

  final int id;
  final String? clientUuid;
  final String name;
  final String? contactPerson;
  final String? phone;
  final String? email;
  final String? address;
  final String? npwp;
  final String currency;
  final int invoicesCount;
  final int outstandingCount;
  final int overdueCount;
  final String receivable;
  final bool needsCollection;
  final String? notes;
  final List<SaleRecord> outstandingInvoices;
  final PaymentRecord? lastPayment;
  final String depositsAvailable;
}

/// Pemasok (`GET /records/suppliers`).
class SupplierRecord {
  const SupplierRecord({
    required this.id,
    required this.name,
    this.contactPerson,
    this.phone,
    this.email,
    this.address,
    this.npwp,
    this.bankInfo,
    this.currency = 'IDR',
    this.billsCount = 0,
    this.outstandingCount = 0,
    this.overdueCount = 0,
    this.payable = '0.00',
    this.notes,
    this.outstandingBills = const [],
    this.lastPayment,
    this.depositsAvailable = '0.00',
  });

  factory SupplierRecord.fromJson(Map<String, dynamic> json) => SupplierRecord(
        id: _i(json['id']),
        name: _s(json['name'], '-'),
        contactPerson: json['contact_person']?.toString(),
        phone: json['phone']?.toString(),
        email: json['email']?.toString(),
        address: json['address']?.toString(),
        npwp: json['npwp']?.toString(),
        bankInfo: json['bank_info']?.toString(),
        currency: _s(json['currency'], 'IDR'),
        billsCount: _i(json['bills_count']),
        outstandingCount: _i(json['outstanding_count']),
        overdueCount: _i(json['overdue_count']),
        payable: _m(json['payable']),
        notes: json['notes']?.toString(),
        outstandingBills: [for (final bill in _maps(json['outstanding_bills'])) PurchaseRecord.fromJson(bill)],
        lastPayment: json['last_payment'] is Map ? PaymentRecord.fromJson(_map(json['last_payment'])) : null,
        depositsAvailable: _m(json['deposits_available']),
      );

  final int id;
  final String name;
  final String? contactPerson;
  final String? phone;
  final String? email;
  final String? address;
  final String? npwp;
  final String? bankInfo;
  final String currency;
  final int billsCount;
  final int outstandingCount;
  final int overdueCount;
  final String payable;
  final String? notes;
  final List<PurchaseRecord> outstandingBills;
  final PaymentRecord? lastPayment;
  final String depositsAvailable;
}
