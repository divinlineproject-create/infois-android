import '../domain/record_models.dart';
import 'ai_api.dart';
import 'api_client.dart';

/// Semua panggilan Catatan ke `/api/v1/records/*` (API.md › 8). Daftar
/// memakai kursor buram dari server (`next_cursor`).
class RecordsApi {
  const RecordsApi(this.client);

  final ApiClient client;

  Map<String, dynamic> _query(Map<String, dynamic>? params, {String? cursor, int? limit}) => {
        for (final entry in (params ?? const <String, dynamic>{}).entries)
          if (entry.value != null && entry.value.toString().isNotEmpty) entry.key: entry.value,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };

  Future<RecordPage<T>> _page<T>(String path, T Function(Map<String, dynamic>) parse, {Map<String, dynamic>? params, String? cursor, int? limit}) async {
    final response = await client.get(path, query: _query(params, cursor: cursor, limit: limit));
    return RecordPage(
      items: [if (response['data'] is List) for (final item in response['data'] as List) if (item is Map) parse(Map<String, dynamic>.from(item))],
      nextCursor: response['next_cursor']?.toString(),
      extra: {for (final entry in response.entries) if (entry.key != 'data' && entry.key != 'next_cursor') entry.key: entry.value},
    );
  }

  // Penjualan ----------------------------------------------------------------

  /// Filter: status, source, customer_id, shift_id, mine, q, from, to.
  Future<RecordPage<SaleRecord>> sales({Map<String, dynamic>? params, String? cursor, int? limit}) =>
      _page('records/sales', SaleRecord.fromJson, params: params, cursor: cursor, limit: limit);

  Future<SaleDetail> sale(int id) async => SaleDetail.fromJson(Map<String, dynamic>.from((await client.get('records/sales/$id'))['sale'] as Map));

  /// Batalkan penjualan. Melempar [ApiException] `tidak_bisa_dibatalkan`,
  /// `sudah_dibayar`, `ditolak`, atau `tidak_berhak`.
  Future<({SaleDetail sale, String message})> voidSale(int id, String reason) async {
    final response = await client.post('records/sales/$id/void', data: {'reason': reason});
    return (sale: SaleDetail.fromJson(Map<String, dynamic>.from(response['sale'] as Map)), message: response['message']?.toString() ?? 'Penjualan dibatalkan');
  }

  /// Data struk untuk cetak ulang; bentuknya sama dengan penjualan lokal
  /// HP sehingga langsung bisa dipakai `ReceiptBuilder.sale`.
  Future<Map<String, dynamic>> receipt(int id) async => Map<String, dynamic>.from((await client.get('records/sales/$id/receipt'))['sale'] as Map);

  Future<List<int>> salePdf(int id) => client.bytes('records/sales/$id/pdf');

  // Pembayaran ---------------------------------------------------------------

  /// Filter: kind, method, account_id, document_id, q, from, to.
  Future<RecordPage<PaymentRecord>> payments({Map<String, dynamic>? params, String? cursor, int? limit}) =>
      _page('records/payments', PaymentRecord.fromJson, params: params, cursor: cursor, limit: limit);

  Future<PaymentRecord> payment(String kind, int id) async =>
      PaymentRecord.fromJson(Map<String, dynamic>.from((await client.get('records/payments/$kind/$id'))['payment'] as Map));

  // Pembelian ----------------------------------------------------------------

  Future<RecordPage<PurchaseRecord>> purchases({Map<String, dynamic>? params, String? cursor, int? limit}) =>
      _page('records/purchases', PurchaseRecord.fromJson, params: params, cursor: cursor, limit: limit);

  Future<PurchaseDetail> purchase(int id) async => PurchaseDetail.fromJson(Map<String, dynamic>.from((await client.get('records/purchases/$id'))['purchase'] as Map));

  // Kas & bank ---------------------------------------------------------------

  /// Filter: from, to, account_id, direction, q. `extra` berisi
  /// `period`, `accounts`, `totals` (lihat [CashBookHeader]).
  Future<RecordPage<CashEntry>> cash({Map<String, dynamic>? params, String? cursor, int? limit}) =>
      _page('records/cash', CashEntry.fromJson, params: params, cursor: cursor, limit: limit);

  Future<({List<CashAccountBalance> accounts, String total, String asOf})> cashAccounts() async {
    final response = await client.get('records/cash/accounts');
    return (
      accounts: [if (response['accounts'] is List) for (final account in response['accounts'] as List) if (account is Map) CashAccountBalance.fromJson(Map<String, dynamic>.from(account))],
      total: response['total']?.toString() ?? '0.00',
      asOf: response['as_of']?.toString() ?? '',
    );
  }

  // Stok ---------------------------------------------------------------------

  /// Filter: product_id, warehouse_id, type, q, from, to.
  Future<RecordPage<StockMovement>> stockMovements({Map<String, dynamic>? params, String? cursor, int? limit}) =>
      _page('records/stock-movements', StockMovement.fromJson, params: params, cursor: cursor, limit: limit);

  /// Filter: q, low, warehouse_id, sort, include_inactive. `extra.low_count`.
  Future<RecordPage<StockLevel>> stock({Map<String, dynamic>? params, String? cursor, int? limit}) =>
      _page('records/stock', StockLevel.fromJson, params: params, cursor: cursor, limit: limit);

  // Pelanggan & pemasok ------------------------------------------------------

  /// Filter: q, has_receivable, overdue, to_collect.
  Future<RecordPage<CustomerRecord>> customers({Map<String, dynamic>? params, String? cursor, int? limit}) =>
      _page('records/customers', CustomerRecord.fromJson, params: params, cursor: cursor, limit: limit);

  Future<CustomerRecord> customer(int id) async => CustomerRecord.fromJson(Map<String, dynamic>.from((await client.get('records/customers/$id'))['customer'] as Map));

  /// Filter: q, has_payable, overdue.
  Future<RecordPage<SupplierRecord>> suppliers({Map<String, dynamic>? params, String? cursor, int? limit}) =>
      _page('records/suppliers', SupplierRecord.fromJson, params: params, cursor: cursor, limit: limit);

  Future<SupplierRecord> supplier(int id) async => SupplierRecord.fromJson(Map<String, dynamic>.from((await client.get('records/suppliers/$id'))['supplier'] as Map));

  // Lampiran -----------------------------------------------------------------

  /// Isi lampiran dengan token + X-Tenant; URL server dipakai relatif
  /// terhadap `/api/v1/` (lihat [AiApi.relativeApiPath]).
  Future<List<int>> attachmentBytes(String url) => client.bytes(AiApi.relativeApiPath(url));
}
