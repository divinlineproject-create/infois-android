import 'dart:async';
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
export 'session.dart' show apiFactoryProvider;

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

  /// Sudah diganti (ganti perusahaan, keluar): database-nya sedang/sudah
  /// ditutup dan tidak boleh dipakai pekerjaan baru.
  bool disposed = false;

  /// Bisa dipakai untuk pekerjaan baru.
  bool get usable => !disposed && local.isOpen;
}

/// Pesan pemeliharaan dari server (503 `kanal_pemeliharaan`: aplikasi HP
/// dimatikan sementara oleh admin Infois), atau null. Diisi dari galat rute
/// mana pun, dikosongkan setelah sinkron berhasil. Tidak mengeluarkan
/// pengguna; transaksi offline tetap di antrean HP.
final maintenanceProvider = StateProvider<String?>((ref) => null);

/// Workspace aktif yang siap dipakai, atau null. Saat workspace sedang dibuat
/// ulang (ganti perusahaan, keluar) nilainya null, bukan workspace lama yang
/// database-nya sedang ditutup.
Workspace? readyWorkspace(Ref ref) {
  final value = ref.read(workspaceProvider);
  final workspace = value is AsyncData<Workspace?> ? value.value : null;
  return workspace != null && workspace.usable ? workspace : null;
}

/// Cara membuka database lokal (diganti di tes dengan database di memori).
final localDbOpenerProvider = Provider<Future<LocalDb> Function(String fileName)>((ref) {
  return (fileName) async => LocalDb.open(p.join(await getDatabasesPath(), fileName));
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

  // Satu pemilik koneksi database per perusahaan: workspace ini. Saat diganti,
  // database ditutup setelah pemakaian yang sedang berjalan (mis. siklus
  // sinkron) selesai, bukan di tengahnya.
  final opener = ref.read(localDbOpenerProvider);
  final apiFactory = ref.read(apiFactoryProvider);
  final storage = ref.read(storageProvider);
  final controller = ref.read(sessionProvider.notifier);
  Workspace? created;
  var replaced = false;
  ref.onDispose(() {
    replaced = true;
    final workspace = created;
    if (workspace != null) {
      workspace.disposed = true;
      workspace.api.onError = null;
      unawaited(workspace.local.close());
    }
  });

  // Data server lama yang belum terpindah tidak boleh terbuka atas nama login
  // ini (nomor user/perusahaan bisa sama di server lain).
  await storage.ensureServerMigrated();
  final local = await opener(LocalDb.fileName(user.id, tenant.id));
  if (replaced) {
    // Sesi berubah lagi selama database dibuka: workspace ini tidak dipakai.
    unawaited(local.close());
    return null;
  }
  late final Workspace workspace;
  final api = apiFactory(session.serverUrl, session.token, tenant.id, () => workspace.pendingCache);
  workspace = created = Workspace(storage: storage, user: user, tenant: tenant, local: local, outbox: OutboxStore(local), api: api);
  // Paket tidak termasuk aplikasi HP / langganan berhenti (403 dari rute
  // mana pun ber-X-Tenant): lepas perusahaan ini dan kembali ke Pilih
  // perusahaan / Masuk dengan pesannya.
  api.onError = (error) {
    if (error.mobileAccessDenied && !workspace.disposed) {
      unawaited(controller.dropTenant(tenant.id, error));
    } else if (error.maintenance && !workspace.disposed) {
      ref.read(maintenanceProvider.notifier).state = error.message;
    } else if (error.companyClosed && !workspace.disposed) {
      // Perusahaan ditutup (dari rute mana pun): pesan + lepas perusahaan.
      unawaited(controller.companyGone(tenant.id, reason: GoneReason.closed, message: error.message, local: local));
    }
  };
  try {
    workspace.pendingCache = await workspace.outbox.pendingCount();
  } on DatabaseException {
    // Jumlah tertunda diperbarui lagi oleh sinkron.
  }
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
