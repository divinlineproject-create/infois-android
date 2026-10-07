import 'models.dart';

/// Data master yang sering dipakai layar kasir.
class MasterData {
  const MasterData({
    required this.tenant,
    required this.receipt,
    required this.accounts,
    required this.menus,
    this.defaultCashId,
    this.defaultTransferId,
    this.deviceCode,
    this.deviceName,
    this.lastSyncAt,
    this.logoBytes,
    this.productCount = 0,
  });

  final TenantSettings tenant;
  final ReceiptConfig receipt;
  final List<CashAccount> accounts;
  final Menus menus;
  final int? defaultCashId;
  final int? defaultTransferId;
  final String? deviceCode;
  final String? deviceName;
  final DateTime? lastSyncAt;
  final List<int>? logoBytes;
  final int productCount;

  bool get hasData => productCount > 0 || lastSyncAt != null;

  List<CashAccount> get cashAccounts => accounts.where((account) => account.kind == 'cash').toList();

  List<CashAccount> get transferAccounts {
    final banks = accounts.where((account) => account.kind != 'cash').toList();
    return banks.isEmpty ? accounts : banks;
  }
}
