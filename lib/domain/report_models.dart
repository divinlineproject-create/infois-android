// Model Laporan dari server (lihat API.md › 7. Laporan). Uang string 2
// desimal, qty 6 desimal, persen string 1 desimal dengan titik ("42.5").

import '../core/format.dart';
import '../core/money.dart';

String _s(Object? value, [String fallback = '']) => value == null ? fallback : value.toString();

int _i(Object? value, [int fallback = 0]) => value == null ? fallback : (value is int ? value : int.tryParse(value.toString()) ?? fallback);

int? _in(Object? value) => value == null ? null : (value is int ? value : int.tryParse(value.toString()));

String _m(Object? value) => Money.normalize(value);

Map<String, dynamic> _map(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

/// Daftar objek; bentuk lain dari server (mis. `{}`) dianggap kosong.
List<Map<String, dynamic>> _maps(Object? value) => [if (value is List) for (final item in value) _map(item)];

DateTime? _date(Object? value) => value == null ? null : DateTime.tryParse(value.toString());

/// Persen dari server ("42.5", "0") menjadi teks "42,5%".
String percentText(Object? value) {
  final raw = _s(value, '0').trim();
  final text = raw.isEmpty ? '0' : raw;
  return '${text.replaceAll('.', ',')}%';
}

/// Pilihan periode di HP; diubah menjadi query `period`/`from`/`to`.
class ReportPeriodChoice {
  const ReportPeriodChoice(this.preset, {this.from, this.to});

  final String preset;
  final DateTime? from;
  final DateTime? to;

  static const presets = <String, String>{
    'hari_ini': 'Hari ini',
    'kemarin': 'Kemarin',
    'minggu_ini': 'Minggu ini',
    'bulan_ini': 'Bulan ini',
    'bulan_lalu': 'Bulan lalu',
    '30_hari': '30 hari',
  };

  static const bulanIni = ReportPeriodChoice('bulan_ini');

  bool get isCustom => preset == 'custom';

  String get label => isCustom && from != null && to != null ? '${dateLabel(from!)} – ${dateLabel(to!)}' : (presets[preset] ?? preset);

  Map<String, dynamic> toQuery() => isCustom && from != null && to != null ? {'period': 'custom', 'from': isoDate(from!), 'to': isoDate(to!)} : {'period': preset};

  @override
  bool operator ==(Object other) => other is ReportPeriodChoice && other.preset == preset && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(preset, from, to);
}

/// Periode seperti dijawab server.
class ReportPeriod {
  const ReportPeriod({required this.preset, required this.from, required this.to, this.days = 1, required this.label});

  factory ReportPeriod.fromJson(Map<String, dynamic> json) => ReportPeriod(
        preset: _s(json['preset'], 'custom'),
        from: _s(json['from']),
        to: _s(json['to']),
        days: _i(json['days'], 1),
        label: _s(json['label']),
      );

  final String preset;
  final String from;
  final String to;
  final int days;
  final String label;
}

/// Angka penjualan satu hari / satu bulan di ubin beranda.
class SalesSnapshot {
  const SalesSnapshot({
    this.date,
    this.from,
    this.to,
    this.label,
    this.count = 0,
    this.total = '0.00',
    this.net = '0.00',
    this.average = '0.00',
    this.grossProfit = '0.00',
    this.margin = '0',
    this.paid = '0.00',
    this.outstanding = '0.00',
  });

  factory SalesSnapshot.fromJson(Map<String, dynamic> json) => SalesSnapshot(
        date: json['date']?.toString(),
        from: json['from']?.toString(),
        to: json['to']?.toString(),
        label: json['label']?.toString(),
        count: _i(json['count']),
        total: _m(json['total']),
        net: _m(json['net']),
        average: _m(json['average']),
        grossProfit: _m(json['gross_profit']),
        margin: _s(json['margin'], '0'),
        paid: _m(json['paid']),
        outstanding: _m(json['outstanding']),
      );

  final String? date;
  final String? from;
  final String? to;
  final String? label;
  final int count;
  final String total;
  final String net;
  final String average;
  final String grossProfit;
  final String margin;
  final String paid;
  final String outstanding;
}

class AgingSummary {
  const AgingSummary({this.outstandingTotal = '0.00', this.outstandingCount = 0, this.overdueTotal = '0.00', this.overdueCount = 0});

  factory AgingSummary.fromJson(Map<String, dynamic> json) => AgingSummary(
        outstandingTotal: _m(json['outstanding_total']),
        outstandingCount: _i(json['outstanding_count']),
        overdueTotal: _m(json['overdue_total']),
        overdueCount: _i(json['overdue_count']),
      );

  final String outstandingTotal;
  final int outstandingCount;
  final String overdueTotal;
  final int overdueCount;
}

class SparkPoint {
  const SparkPoint({required this.date, this.total = '0.00', this.count = 0});

  factory SparkPoint.fromJson(Map<String, dynamic> json) => SparkPoint(date: _s(json['date']), total: _m(json['total']), count: _i(json['count']));

  final String date;
  final String total;
  final int count;

  double get value => double.tryParse(total) ?? 0;
}

/// `GET /reports/overview`.
class ReportOverview {
  const ReportOverview({
    required this.today,
    required this.yesterday,
    required this.month,
    this.cashBalance = '0.00',
    required this.receivables,
    required this.payables,
    this.lowStock = 0,
    this.emptyStock = 0,
    this.sparkline = const [],
    this.generatedAt,
  });

  factory ReportOverview.fromJson(Map<String, dynamic> json) {
    final stock = _map(json['stock']);
    return ReportOverview(
      today: SalesSnapshot.fromJson(_map(json['today'])),
      yesterday: SalesSnapshot.fromJson(_map(json['yesterday'])),
      month: SalesSnapshot.fromJson(_map(json['month'])),
      cashBalance: _m(json['cash_balance']),
      receivables: AgingSummary.fromJson(_map(json['receivables'])),
      payables: AgingSummary.fromJson(_map(json['payables'])),
      lowStock: _i(stock['low_count']),
      emptyStock: _i(stock['empty_count']),
      sparkline: [for (final point in _maps(json['sparkline'])) SparkPoint.fromJson(point)],
      generatedAt: _date(json['generated_at']),
    );
  }

  final SalesSnapshot today;
  final SalesSnapshot yesterday;
  final SalesSnapshot month;
  final String cashBalance;
  final AgingSummary receivables;
  final AgingSummary payables;
  final int lowStock;
  final int emptyStock;
  final List<SparkPoint> sparkline;
  final DateTime? generatedAt;
}

/// Total penjualan satu periode (`SalesReportService::summary`). Kunci yang
/// tidak dikirim server bernilai nol.
class SalesTotals {
  const SalesTotals({
    this.count = 0,
    this.gross = '0.00',
    this.discount = '0.00',
    this.net = '0.00',
    this.tax = '0.00',
    this.total = '0.00',
    this.paid = '0.00',
    this.outstanding = '0.00',
    this.cogs = '0.00',
    this.grossProfit = '0.00',
    this.margin = '0',
    this.average = '0.00',
    this.customers = 0,
    this.returns = '0.00',
    this.unpaidCount = 0,
  });

  factory SalesTotals.fromJson(Map<String, dynamic> json) => SalesTotals(
        count: _i(json['count']),
        gross: _m(json['gross']),
        discount: _m(json['discount']),
        net: _m(json['net']),
        tax: _m(json['tax']),
        total: _m(json['total']),
        paid: _m(json['paid']),
        outstanding: _m(json['outstanding']),
        cogs: _m(json['cogs']),
        grossProfit: _m(json['gross_profit']),
        margin: _s(json['margin'], '0'),
        average: _m(json['average']),
        customers: _i(json['customers']),
        returns: _m(json['returns']),
        unpaidCount: _i(json['unpaid_count']),
      );

  final int count;
  final String gross;
  final String discount;
  final String net;
  final String tax;
  final String total;
  final String paid;
  final String outstanding;
  final String cogs;
  final String grossProfit;
  final String margin;
  final String average;
  final int customers;
  final String returns;
  final int unpaidCount;
}

class SeriesPoint {
  const SeriesPoint({required this.key, required this.label, this.count = 0, this.net = '0.00', this.total = '0.00'});

  factory SeriesPoint.fromJson(Map<String, dynamic> json) =>
      SeriesPoint(key: _s(json['key']), label: _s(json['label']), count: _i(json['count']), net: _m(json['net']), total: _m(json['total']));

  final String key;
  final String label;
  final int count;
  final String net;
  final String total;

  double get value => double.tryParse(total) ?? 0;
}

class PaymentMethodTotal {
  const PaymentMethodTotal({required this.method, required this.label, this.count = 0, this.total = '0.00'});

  factory PaymentMethodTotal.fromJson(Map<String, dynamic> json) =>
      PaymentMethodTotal(method: _s(json['method']), label: _s(json['label'], 'Lainnya'), count: _i(json['count']), total: _m(json['total']));

  final String method;
  final String label;
  final int count;
  final String total;
}

/// `GET /reports/sales/summary`.
class SalesSummary {
  const SalesSummary({required this.period, required this.totals, this.seriesUnit = 'day', this.points = const [], this.payments = const []});

  factory SalesSummary.fromJson(Map<String, dynamic> json) {
    final series = _map(json['series']);
    return SalesSummary(
      period: ReportPeriod.fromJson(_map(json['period'])),
      totals: SalesTotals.fromJson(_map(json['totals'])),
      seriesUnit: _s(series['unit'], 'day'),
      points: [for (final point in _maps(series['points'])) SeriesPoint.fromJson(point)],
      payments: [for (final payment in _maps(json['payments'])) PaymentMethodTotal.fromJson(payment)],
    );
  }

  final ReportPeriod period;
  final SalesTotals totals;

  /// `hour` (24 titik) atau `day`.
  final String seriesUnit;
  final List<SeriesPoint> points;
  final List<PaymentMethodTotal> payments;
}

/// Satu baris peringkat (per barang / pelanggan / kasir / HP / jam).
class RankRow {
  const RankRow({
    this.id,
    required this.name,
    this.code,
    this.sku,
    this.type,
    this.unit,
    this.hour,
    this.label,
    this.quantity,
    this.lines = 0,
    this.count = 0,
    this.gross = '0.00',
    this.discount = '0.00',
    this.net = '0.00',
    this.tax = '0.00',
    this.total = '0.00',
    this.paid = '0.00',
    this.outstanding = '0.00',
    this.cogs = '0.00',
    this.grossProfit = '0.00',
    this.averagePrice,
    this.margin = '0',
    this.share = '0',
  });

  factory RankRow.fromJson(Map<String, dynamic> json) => RankRow(
        id: _in(json['id']),
        name: _s(json['name'], json['label']?.toString() ?? '-'),
        code: json['code']?.toString(),
        sku: json['sku']?.toString(),
        type: json['type']?.toString(),
        unit: json['unit']?.toString(),
        hour: _in(json['hour']),
        label: json['label']?.toString(),
        quantity: json['quantity'] == null ? null : Money.normalize(json['quantity'], 6),
        lines: _i(json['lines']),
        count: _i(json['count']),
        gross: _m(json['gross']),
        discount: _m(json['discount']),
        net: _m(json['net']),
        tax: _m(json['tax']),
        total: _m(json['total']),
        paid: _m(json['paid']),
        outstanding: _m(json['outstanding']),
        cogs: _m(json['cogs']),
        grossProfit: _m(json['gross_profit']),
        averagePrice: json['average_price'] == null ? null : _m(json['average_price']),
        margin: _s(json['margin'], '0'),
        share: _s(json['share'], '0'),
      );

  final int? id;
  final String name;
  final String? code;
  final String? sku;
  final String? type;
  final String? unit;
  final int? hour;
  final String? label;
  final String? quantity;
  final int lines;
  final int count;
  final String gross;
  final String discount;
  final String net;
  final String tax;
  final String total;
  final String paid;
  final String outstanding;
  final String cogs;
  final String grossProfit;
  final String? averagePrice;
  final String margin;
  final String share;

  double get shareValue => (double.tryParse(share) ?? 0).clamp(0, 100);
}

/// `GET /reports/sales/by-*` dan `/by-hour`.
class RankedReport {
  const RankedReport({required this.period, required this.totals, this.totalRows = 0, this.rows = const [], this.nextCursor, this.peakHour});

  factory RankedReport.fromJson(Map<String, dynamic> json) => RankedReport(
        period: ReportPeriod.fromJson(_map(json['period'])),
        totals: SalesTotals.fromJson(_map(json['totals'])),
        totalRows: _i(json['total_rows'], (json['data'] is List ? (json['data'] as List).length : 0)),
        rows: [for (final row in _maps(json['data'])) RankRow.fromJson(row)],
        nextCursor: json['next_cursor']?.toString(),
        peakHour: _in(json['peak_hour']),
      );

  final ReportPeriod period;
  final SalesTotals totals;
  final int totalRows;
  final List<RankRow> rows;
  final String? nextCursor;
  final int? peakHour;
}

class AgingBucket {
  const AgingBucket({required this.key, required this.label, this.total = '0.00'});

  factory AgingBucket.fromJson(Map<String, dynamic> json) => AgingBucket(key: _s(json['key']), label: _s(json['label']), total: _m(json['total']));

  final String key;
  final String label;
  final String total;
}

class AgingRow {
  const AgingRow({
    this.partyId,
    required this.party,
    this.documentCount = 0,
    this.current = '0.00',
    this.d1to30 = '0.00',
    this.d31to60 = '0.00',
    this.d61to90 = '0.00',
    this.over90 = '0.00',
    this.total = '0.00',
    this.overdue = '0.00',
  });

  factory AgingRow.fromJson(Map<String, dynamic> json) => AgingRow(
        partyId: _in(json['party_id']),
        party: _s(json['party'], '-'),
        documentCount: _i(json['document_count']),
        current: _m(json['current']),
        d1to30: _m(json['d1_30']),
        d31to60: _m(json['d31_60']),
        d61to90: _m(json['d61_90']),
        over90: _m(json['over_90']),
        total: _m(json['total']),
        overdue: _m(json['overdue']),
      );

  final int? partyId;
  final String party;
  final int documentCount;
  final String current;
  final String d1to30;
  final String d31to60;
  final String d61to90;
  final String over90;
  final String total;
  final String overdue;
}

/// `GET /reports/receivables` / `/payables`.
class AgingReport {
  const AgingReport({required this.asOf, this.buckets = const [], this.total = '0.00', this.overdue = '0.00', this.parties = 0, this.rows = const [], this.nextCursor});

  factory AgingReport.fromJson(Map<String, dynamic> json) {
    final totals = _map(json['totals']);
    return AgingReport(
      asOf: _s(json['as_of']),
      buckets: [for (final bucket in _maps(json['buckets'])) AgingBucket.fromJson(bucket)],
      total: _m(totals['total']),
      overdue: _m(totals['overdue']),
      parties: _i(totals['parties']),
      rows: [for (final row in _maps(json['data'])) AgingRow.fromJson(row)],
      nextCursor: json['next_cursor']?.toString(),
    );
  }

  final String asOf;
  final List<AgingBucket> buckets;
  final String total;
  final String overdue;
  final int parties;
  final List<AgingRow> rows;
  final String? nextCursor;
}

class ReportLine {
  const ReportLine({required this.code, required this.name, this.amount = '0.00'});

  factory ReportLine.fromJson(Map<String, dynamic> json) => ReportLine(code: _s(json['code']), name: _s(json['name']), amount: _m(json['amount']));

  final String code;
  final String name;
  final String amount;
}

class ReportSection {
  const ReportSection({required this.key, required this.label, this.total = '0.00', this.rows = const []});

  factory ReportSection.fromJson(Map<String, dynamic> json) => ReportSection(
        key: _s(json['key']),
        label: _s(json['label']),
        total: _m(json['total']),
        rows: [for (final row in _maps(json['rows'])) ReportLine.fromJson(row)],
      );

  final String key;
  final String label;
  final String total;
  final List<ReportLine> rows;
}

/// `GET /reports/profit-loss`.
class ProfitLossReport {
  const ProfitLossReport({
    required this.period,
    this.revenue = '0.00',
    this.cogs = '0.00',
    this.grossProfit = '0.00',
    this.grossMargin = '0',
    this.operatingExpense = '0.00',
    this.operatingIncome = '0.00',
    this.otherRevenue = '0.00',
    this.otherExpense = '0.00',
    this.totalRevenue = '0.00',
    this.totalExpense = '0.00',
    this.netIncome = '0.00',
    this.netMargin = '0',
    this.sections = const [],
  });

  factory ProfitLossReport.fromJson(Map<String, dynamic> json) => ProfitLossReport(
        period: ReportPeriod.fromJson(_map(json['period'])),
        revenue: _m(json['revenue']),
        cogs: _m(json['cogs']),
        grossProfit: _m(json['gross_profit']),
        grossMargin: _s(json['gross_margin'], '0'),
        operatingExpense: _m(json['operating_expense']),
        operatingIncome: _m(json['operating_income']),
        otherRevenue: _m(json['other_revenue']),
        otherExpense: _m(json['other_expense']),
        totalRevenue: _m(json['total_revenue']),
        totalExpense: _m(json['total_expense']),
        netIncome: _m(json['net_income']),
        netMargin: _s(json['net_margin'], '0'),
        sections: [for (final section in _maps(json['sections'])) ReportSection.fromJson(section)],
      );

  final ReportPeriod period;
  final String revenue;
  final String cogs;
  final String grossProfit;
  final String grossMargin;
  final String operatingExpense;
  final String operatingIncome;
  final String otherRevenue;
  final String otherExpense;
  final String totalRevenue;
  final String totalExpense;
  final String netIncome;
  final String netMargin;
  final List<ReportSection> sections;
}

/// `GET /reports/cash-flow`.
class CashFlowReport {
  const CashFlowReport({required this.period, this.opening = '0.00', this.netChange = '0.00', this.closing = '0.00', this.categories = const []});

  factory CashFlowReport.fromJson(Map<String, dynamic> json) => CashFlowReport(
        period: ReportPeriod.fromJson(_map(json['period'])),
        opening: _m(json['opening']),
        netChange: _m(json['net_change']),
        closing: _m(json['closing']),
        categories: [for (final category in _maps(json['categories'])) ReportSection.fromJson(category)],
      );

  final ReportPeriod period;
  final String opening;
  final String netChange;
  final String closing;
  final List<ReportSection> categories;
}

class ShiftSummary {
  const ShiftSummary({
    this.salesCount = 0,
    this.salesTotal = '0.00',
    this.cashTotal = '0.00',
    this.transferTotal = '0.00',
    this.unpaidTotal = '0.00',
    this.openingCash = '0.00',
    this.expectedCash = '0.00',
  });

  factory ShiftSummary.fromJson(Map<String, dynamic> json) => ShiftSummary(
        salesCount: _i(json['sales_count']),
        salesTotal: _m(json['sales_total']),
        cashTotal: _m(json['cash_total']),
        transferTotal: _m(json['transfer_total']),
        unpaidTotal: _m(json['unpaid_total']),
        openingCash: _m(json['opening_cash']),
        expectedCash: _m(json['expected_cash']),
      );

  final int salesCount;
  final String salesTotal;
  final String cashTotal;
  final String transferTotal;
  final String unpaidTotal;
  final String openingCash;
  final String expectedCash;
}

class NamedRef {
  const NamedRef({this.id, required this.name, this.code});

  factory NamedRef.fromJson(Map<String, dynamic> json) => NamedRef(id: _in(json['id']), name: _s(json['name']), code: json['code']?.toString());

  final int? id;
  final String name;
  final String? code;

  String get display => code == null || code!.isEmpty ? name : '$code · $name';
}

/// Satu shift kasir (`GET /reports/shifts`).
class ShiftReport {
  const ShiftReport({
    required this.id,
    this.clientUuid,
    this.openedAt,
    this.closedAt,
    this.status = 'closed',
    this.openingCash = '0.00',
    this.closingCash,
    this.expectedCash,
    this.difference,
    required this.summary,
    this.device,
    this.cashier,
    this.durationMinutes,
    this.notes,
  });

  factory ShiftReport.fromJson(Map<String, dynamic> json) => ShiftReport(
        id: _i(json['id']),
        clientUuid: json['client_uuid']?.toString(),
        openedAt: _date(json['opened_at']),
        closedAt: _date(json['closed_at']),
        status: _s(json['status'], 'closed'),
        openingCash: _m(json['opening_cash']),
        closingCash: json['closing_cash'] == null ? null : _m(json['closing_cash']),
        expectedCash: json['expected_cash'] == null ? null : _m(json['expected_cash']),
        difference: json['difference'] == null ? null : _m(json['difference']),
        summary: ShiftSummary.fromJson(_map(json['summary'])),
        device: json['device'] is Map ? NamedRef.fromJson(_map(json['device'])) : null,
        cashier: json['cashier'] is Map ? NamedRef.fromJson(_map(json['cashier'])) : null,
        durationMinutes: _in(json['duration_minutes']),
        notes: json['notes']?.toString(),
      );

  final int id;
  final String? clientUuid;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final String status;
  final String openingCash;
  final String? closingCash;
  final String? expectedCash;
  final String? difference;

  /// Ringkasan yang tersimpan saat shift ditutup.
  final ShiftSummary summary;
  final NamedRef? device;
  final NamedRef? cashier;
  final int? durationMinutes;
  final String? notes;

  bool get open => status == 'open';

  /// Peta untuk `ReceiptBuilder.shiftReport` (cetak ulang Z-report).
  Map<String, dynamic> toPrintMap(ShiftSummary live) => {
        'cashier': cashier?.name,
        'opened_at': openedAt?.toIso8601String(),
        'closed_at': closedAt?.toIso8601String(),
        'sales_count': live.salesCount,
        'sales_total': live.salesTotal,
        'cash_total': live.cashTotal,
        'transfer_total': live.transferTotal,
        'unpaid_total': live.unpaidTotal,
        'opening_cash': live.openingCash,
        'expected_cash': live.expectedCash,
        'closing_cash': closingCash ?? '0.00',
        'difference': difference ?? '0.00',
      };
}

class ShiftSale {
  const ShiftSale({
    required this.id,
    required this.number,
    this.time,
    this.customer,
    this.total = '0.00',
    this.paid = '0.00',
    this.balance = '0.00',
    this.status = 'issued',
    this.statusLabel = '',
    this.methods = const [],
  });

  factory ShiftSale.fromJson(Map<String, dynamic> json) => ShiftSale(
        id: _i(json['id']),
        number: _s(json['number'], '-'),
        time: _date(json['time']),
        customer: json['customer']?.toString(),
        total: _m(json['total']),
        paid: _m(json['paid']),
        balance: _m(json['balance']),
        status: _s(json['status'], 'issued'),
        statusLabel: _s(json['status_label']),
        methods: [if (json['methods'] is List) for (final method in json['methods'] as List) method.toString()],
      );

  final int id;
  final String number;
  final DateTime? time;
  final String? customer;
  final String total;
  final String paid;
  final String balance;
  final String status;
  final String statusLabel;
  final List<String> methods;
}

/// `GET /reports/shifts/{id}`: shift + ringkasan yang dihitung ulang + nota.
class ShiftDetail {
  const ShiftDetail({required this.shift, required this.summary, this.sales = const []});

  factory ShiftDetail.fromJson(Map<String, dynamic> json) => ShiftDetail(
        shift: ShiftReport.fromJson(_map(json['shift'])),
        summary: ShiftSummary.fromJson(_map(json['summary'])),
        sales: [for (final sale in _maps(json['sales'])) ShiftSale.fromJson(sale)],
      );

  final ShiftReport shift;
  final ShiftSummary summary;
  final List<ShiftSale> sales;
}

/// Halaman daftar shift.
class ShiftPage {
  const ShiftPage({this.period, this.items = const [], this.nextCursor});

  factory ShiftPage.fromJson(Map<String, dynamic> json) => ShiftPage(
        period: json['period'] is Map ? ReportPeriod.fromJson(_map(json['period'])) : null,
        items: [for (final item in _maps(json['data'])) ShiftReport.fromJson(item)],
        nextCursor: json['next_cursor']?.toString(),
      );

  final ReportPeriod? period;
  final List<ShiftReport> items;
  final String? nextCursor;
}
