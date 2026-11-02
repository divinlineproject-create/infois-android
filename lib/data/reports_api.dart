import '../domain/report_models.dart';
import 'api_client.dart';

/// Semua panggilan Laporan ke `/api/v1/reports/*` (API.md › 7). Angka
/// dihitung server dari service laporan web; HP hanya menampilkan.
class ReportsApi {
  const ReportsApi(this.client);

  final ApiClient client;

  /// Jenis laporan peringkat yang memakai bentuk jawaban sama.
  static const rankedKinds = {'by-product', 'by-customer', 'by-cashier', 'by-device'};

  /// Alamat PDF laporan (relatif ke `/api/v1/`, `?format=pdf`): angka &
  /// periode sama dengan layar, semua baris tanpa halaman (API.md › 7).
  static String pdfPath(String endpoint, [Map<String, dynamic> query = const {}]) =>
      Uri(path: 'reports/$endpoint', queryParameters: {for (final entry in query.entries) entry.key: '${entry.value}', 'format': 'pdf'}).toString();

  Future<ReportOverview> overview() async => ReportOverview.fromJson(await client.get('reports/overview'));

  Future<SalesSummary> salesSummary(ReportPeriodChoice period, {Map<String, dynamic>? filters}) async =>
      SalesSummary.fromJson(await client.get('reports/sales/summary', query: {...period.toQuery(), ...?filters}));

  /// `by-product` | `by-customer` | `by-cashier` | `by-device` | `by-hour`.
  Future<RankedReport> ranked(String kind, ReportPeriodChoice period, {Map<String, dynamic>? filters, int? limit, String? cursor}) async =>
      RankedReport.fromJson(await client.get('reports/sales/$kind', query: {
        ...period.toQuery(),
        ...?filters,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      }));

  /// `receivables` (piutang) | `payables` (hutang).
  Future<AgingReport> aging(String kind, {String? asOf, int? limit, String? cursor}) async => AgingReport.fromJson(await client.get('reports/$kind', query: {
        if (asOf != null) 'as_of': asOf,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      }));

  Future<ProfitLossReport> profitLoss(ReportPeriodChoice period) async => ProfitLossReport.fromJson(await client.get('reports/profit-loss', query: period.toQuery()));

  Future<CashFlowReport> cashFlow(ReportPeriodChoice period) async => CashFlowReport.fromJson(await client.get('reports/cash-flow', query: period.toQuery()));

  /// Shift yang sudah ditutup, terbaru dulu. Tanpa [period] = semua.
  Future<ShiftPage> shifts({ReportPeriodChoice? period, int? deviceId, int? userId, int? limit, String? cursor}) async =>
      ShiftPage.fromJson(await client.get('reports/shifts', query: {
        ...?period?.toQuery(),
        if (deviceId != null) 'device_id': deviceId,
        if (userId != null) 'user_id': userId,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      }));

  Future<ShiftDetail> shift(int id) async => ShiftDetail.fromJson(await client.get('reports/shifts/$id'));
}
