import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../data/api_client.dart';
import '../data/app_storage.dart';
import '../data/local_db.dart';
import '../data/outbox_store.dart';
import '../domain/master_data.dart';
import '../domain/models.dart';
import '../services/sync_engine.dart';
import 'session.dart';

export '../domain/master_data.dart';

/// Semua yang dibutuhkan untuk bekerja di satu perusahaan: database lokal,
/// outbox, klien API, dan mesin sinkron.
class Workspace {
  Workspace({required this.storage, required this.user, required this.tenant, required this.local, required this.outbox, required this.api})
      : engine = SyncEngine(api: api, local: local, outbox: outbox);

  final AppStorage storage;
  final SessionUser user;
  final TenantSummary tenant;
  final LocalDb local;
  final OutboxStore outbox;
  final ApiClient api;
  final SyncEngine engine;

  /// Jumlah outbox terakhir (untuk header X-Outbox-Count).
  int pendingCache = 0;
}

/// Cara membuka database lokal (diganti di tes dengan database di memori).
final localDbOpenerProvider = Provider<Future<LocalDb> Function(String fileName)>((ref) {
  return (fileName) async => LocalDb.open(p.join(await getDatabasesPath(), fileName));
});

/// Cara membuat klien API (diganti di tes).
final apiFactoryProvider = Provider<ApiClient Function(String baseUrl, String? token, int? tenantId, int? Function() outboxCount)>((ref) {
  return (baseUrl, token, tenantId, outboxCount) => ApiClient(baseUrl: baseUrl, token: token, tenantId: tenantId, outboxCount: outboxCount);
});

final workspaceProvider = FutureProvider<Workspace?>((ref) async {
  // Hanya buka ulang database bila server, token, user, atau perusahaan berubah
  // (bukan saat menu/hak akses diperbarui oleh sinkron).
  ref.watch(sessionProvider.select((value) {
    final current = value.valueOrNull;
    return (current?.serverUrl, current?.token, current?.user?.id, current?.tenantId);
  }));
  final session = ref.read(sessionProvider).valueOrNull;
  final user = session?.user;
  final tenant = session?.tenant;
  if (session == null || !session.loggedIn || user == null || tenant == null) {
    return null;
  }

  final local = await ref.read(localDbOpenerProvider)(LocalDb.fileName(user.id, tenant.id));
  late final Workspace workspace;
  final api = ref.read(apiFactoryProvider)(session.serverUrl, session.token, tenant.id, () => workspace.pendingCache);
  workspace = Workspace(storage: ref.read(storageProvider), user: user, tenant: tenant, local: local, outbox: OutboxStore(local), api: api);
  workspace.pendingCache = await workspace.outbox.pendingCount();
  ref.onDispose(local.close);
  return workspace;
});

/// Naik setiap kali data lokal berubah (sinkron, penjualan baru, shift),
/// supaya layar memuat ulang dari database.
final dataVersionProvider = StateProvider<int>((ref) => 0);

final masterDataProvider = FutureProvider<MasterData?>((ref) async {
  ref.watch(dataVersionProvider);
  final workspace = await ref.watch(workspaceProvider.future);
  if (workspace == null) {
    return null;
  }
  final local = workspace.local;
  final tenantJson = await local.getJson(MetaKeys.tenant);
  final receiptJson = await local.getJson(MetaKeys.receipt);
  final accountsJson = await local.getJson(MetaKeys.accounts);
  final deviceJson = await local.getJson(MetaKeys.device);
  final menusJson = await local.getJson(MetaKeys.menus);
  final logo = await local.getMeta(MetaKeys.logoBytes);

  return MasterData(
    tenant: tenantJson == null ? TenantSettings(id: workspace.tenant.id, name: workspace.tenant.name) : TenantSettings.fromJson(tenantJson),
    receipt: receiptJson == null ? ReceiptConfig(companyName: workspace.tenant.name) : ReceiptConfig.fromJson(receiptJson),
    accounts: [for (final account in (accountsJson?['items'] as List? ?? const [])) CashAccount.fromJson(Map<String, dynamic>.from(account as Map))],
    defaultCashId: accountsJson?['default_cash_id'] as int?,
    defaultTransferId: accountsJson?['default_transfer_id'] as int?,
    menus: menusJson == null ? workspace.tenant.menus : Menus.fromJson(menusJson),
    deviceCode: deviceJson?['code']?.toString(),
    deviceName: deviceJson?['name']?.toString(),
    lastSyncAt: DateTime.tryParse(await local.getMeta(MetaKeys.lastSyncAt) ?? ''),
    logoBytes: logo == null ? null : base64Decode(logo),
    productCount: await local.productCount(),
  );
});

final productSearchProvider = FutureProvider.family<List<Product>, String>((ref, query) async {
  ref.watch(dataVersionProvider);
  final workspace = await ref.watch(workspaceProvider.future);
  return workspace == null ? const [] : workspace.local.products(query: query);
});

final customerSearchProvider = FutureProvider.family<List<Customer>, String>((ref, query) async {
  ref.watch(dataVersionProvider);
  final workspace = await ref.watch(workspaceProvider.future);
  return workspace == null ? const [] : workspace.local.customers(query: query);
});

final openShiftProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  ref.watch(dataVersionProvider);
  final workspace = await ref.watch(workspaceProvider.future);
  return workspace?.local.openShift();
});

final recentSalesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(dataVersionProvider);
  final workspace = await ref.watch(workspaceProvider.future);
  return workspace == null ? const [] : workspace.local.recentSales();
});

final outboxProblemsProvider = FutureProvider<List<OutboxItem>>((ref) async {
  ref.watch(dataVersionProvider);
  final workspace = await ref.watch(workspaceProvider.future);
  return workspace == null ? const [] : workspace.outbox.problems();
});
