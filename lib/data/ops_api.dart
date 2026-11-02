import 'api_client.dart';

/// Satu pilihan di form (jenis biaya, akun, pemasok).
class OpsChoice {
  const OpsChoice({required this.id, required this.name, this.group});

  factory OpsChoice.fromJson(Map<String, dynamic> json) => OpsChoice(id: (json['id'] as num).toInt(), name: json['name']?.toString() ?? '-', group: json['group']?.toString());

  final int id;
  final String name;
  final String? group;
}

/// Pilihan form + hak Operasional (`GET /ops/options`).
class OpsOptions {
  const OpsOptions({
    this.expenseCategories = const [],
    this.cashAccounts = const [],
    this.incomeAccounts = const [],
    this.spendingAccounts = const [],
    this.suppliers = const [],
    this.taxName = 'PPN',
    this.taxRate = '0',
    this.can = const {},
  });

  factory OpsOptions.fromJson(Map<String, dynamic> json) {
    List<OpsChoice> list(String key) => [for (final item in json[key] as List? ?? const []) if (item is Map) OpsChoice.fromJson(Map<String, dynamic>.from(item))];
    final tax = json['tax'] is Map ? Map<String, dynamic>.from(json['tax'] as Map) : const <String, dynamic>{};
    return OpsOptions(
      expenseCategories: list('expense_categories'),
      cashAccounts: [
        for (final item in json['cash_accounts'] as List? ?? const [])
          if (item is Map) OpsChoice(id: (item['id'] as num).toInt(), name: item['name']?.toString() ?? '-', group: item['code']?.toString()),
      ],
      incomeAccounts: list('income_accounts'),
      spendingAccounts: list('spending_accounts'),
      suppliers: list('suppliers'),
      taxName: tax['name']?.toString() ?? 'PPN',
      taxRate: tax['rate']?.toString() ?? '0',
      can: {for (final entry in (json['can'] as Map? ?? const {}).entries) entry.key.toString(): entry.value == true},
    );
  }

  final List<OpsChoice> expenseCategories;
  final List<OpsChoice> cashAccounts;
  final List<OpsChoice> incomeAccounts;
  final List<OpsChoice> spendingAccounts;
  final List<OpsChoice> suppliers;
  final String taxName;
  final String taxRate;
  final Map<String, bool> can;

  bool allows(String ability) => can[ability] ?? false;
}

/// Hasil simpan dokumen (biaya / tagihan / Kas & Bank).
class OpsResult {
  const OpsResult({required this.type, required this.id, this.number, this.status, this.total, this.balanceDue, this.message, this.paymentId});

  factory OpsResult.fromJson(Map<String, dynamic> json) => OpsResult(
        type: json['type']?.toString() ?? '',
        id: (json['id'] as num).toInt(),
        number: json['number']?.toString(),
        status: json['status']?.toString(),
        total: json['total']?.toString(),
        balanceDue: json['balance_due']?.toString(),
        message: json['message']?.toString(),
        paymentId: (json['payment_id'] as num?)?.toInt(),
      );

  final String type;
  final int id;
  final String? number;
  final String? status;
  final String? total;
  final String? balanceDue;
  final String? message;
  final int? paymentId;
}

/// Dokumen yang dibuka untuk diubah: isian form + tombol yang berlaku.
class OpsDocument {
  const OpsDocument({required this.id, required this.form, this.number, this.status, this.total, this.balanceDue, this.canEdit = false, this.canDelete = false, this.canPay = false, this.lockedReason, this.raw = const {}});

  factory OpsDocument.fromJson(Map<String, dynamic> json) {
    final actions = json['actions'] is Map ? Map<String, dynamic>.from(json['actions'] as Map) : const <String, dynamic>{};
    return OpsDocument(
      id: (json['id'] as num).toInt(),
      number: json['number']?.toString(),
      status: json['status']?.toString(),
      total: json['total']?.toString(),
      balanceDue: json['balance_due']?.toString(),
      form: json['form'] is Map ? Map<String, dynamic>.from(json['form'] as Map) : const {},
      canEdit: actions['edit'] == true,
      canDelete: actions['delete'] == true,
      canPay: actions['pay'] == true,
      lockedReason: json['locked_reason']?.toString(),
      raw: json,
    );
  }

  final int id;
  final String? number;
  final String? status;
  final String? total;
  final String? balanceDue;
  final Map<String, dynamic> form;
  final bool canEdit;
  final bool canDelete;
  final bool canPay;
  final String? lockedReason;
  final Map<String, dynamic> raw;
}

/// Panggilan Operasional harian ke `/api/v1/ops/*` (API.md › Operasional).
class OpsApi {
  const OpsApi(this.client);

  final ApiClient client;

  Future<OpsOptions> options() async => OpsOptions.fromJson(await client.get('ops/options'));

  Future<({List<Map<String, dynamic>> items, String? next})> expenses({String? q, String? from, String? to, String? cursor}) async {
    final response = await client.get('ops/expenses', query: {if (q != null && q.isNotEmpty) 'q': q, if (from != null) 'from': from, if (to != null) 'to': to, if (cursor != null) 'cursor': cursor});
    return (items: [for (final item in response['data'] as List? ?? const []) Map<String, dynamic>.from(item as Map)], next: response['next_cursor']?.toString());
  }

  /// Biaya untuk diubah; null + [redirectBillId] bila harus diubah lewat Tagihan Pemasok.
  Future<({OpsDocument? expense, int? redirectBillId})> expense(String source, int id) async {
    final response = await client.get('ops/expenses/$source/$id');
    final redirect = response['redirect'];
    return (
      expense: response['expense'] is Map ? OpsDocument.fromJson(Map<String, dynamic>.from(response['expense'] as Map)) : null,
      redirectBillId: redirect is Map ? (redirect['id'] as num?)?.toInt() : null,
    );
  }

  Future<OpsResult> saveExpense(Map<String, dynamic> data, {String? source, int? id}) async {
    final response = id == null ? await client.post('ops/expenses', data: data) : await client.put('ops/expenses/$source/$id', data: data);
    return OpsResult.fromJson(Map<String, dynamic>.from(response['result'] as Map));
  }

  Future<void> deleteExpense(String source, int id) => client.delete('ops/expenses/$source/$id');

  Future<OpsDocument> bill(int id) async => OpsDocument.fromJson(Map<String, dynamic>.from((await client.get('ops/bills/$id'))['bill'] as Map));

  Future<OpsResult> saveBill(Map<String, dynamic> data, {int? id}) async {
    final response = id == null ? await client.post('ops/bills', data: data) : await client.put('ops/bills/$id', data: data);
    return OpsResult.fromJson(Map<String, dynamic>.from(response['result'] as Map));
  }

  Future<void> deleteBill(int id) => client.delete('ops/bills/$id');

  Future<OpsResult> payBill(int id, Map<String, dynamic> data) async => OpsResult.fromJson(Map<String, dynamic>.from((await client.post('ops/bills/$id/payments', data: data))['result'] as Map));

  Future<void> cancelBillPayment(int billId, int paymentId) => client.delete('ops/bills/$billId/payments/$paymentId');

  Future<({List<Map<String, dynamic>> items, String? next})> cashTransactions({String? type, String? q, String? cursor}) async {
    final response = await client.get('ops/cash', query: {if (type != null) 'type': type, if (q != null && q.isNotEmpty) 'q': q, if (cursor != null) 'cursor': cursor});
    return (items: [for (final item in response['data'] as List? ?? const []) Map<String, dynamic>.from(item as Map)], next: response['next_cursor']?.toString());
  }

  Future<OpsDocument> cashTransaction(int id) async {
    final json = Map<String, dynamic>.from((await client.get('ops/cash/$id'))['transaction'] as Map);
    return OpsDocument.fromJson({...json, 'form': json});
  }

  Future<OpsResult> saveCash(Map<String, dynamic> data, {int? id}) async {
    final response = id == null ? await client.post('ops/cash', data: data) : await client.put('ops/cash/$id', data: data);
    return OpsResult.fromJson(Map<String, dynamic>.from(response['result'] as Map));
  }

  Future<void> deleteCash(int id) => client.delete('ops/cash/$id');

  Future<OpsResult> receivePayment(int invoiceId, Map<String, dynamic> data) async =>
      OpsResult.fromJson(Map<String, dynamic>.from((await client.post('ops/invoices/$invoiceId/payments', data: data))['result'] as Map));

  Future<void> cancelInvoicePayment(int invoiceId, int paymentId) => client.delete('ops/invoices/$invoiceId/payments/$paymentId');
}
