import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import '../data/api_client.dart';
import '../data/app_storage.dart';
import '../data/local_db.dart';
import '../data/outbox_store.dart';
import 'sync_engine.dart';

const backgroundSyncTask = 'infois-sync';

/// Hasil satu kali sinkron latar.
enum BackgroundSyncResult { skippedNoSession, skippedForeground, offline, synced }

/// Sinkron latar tiap ±15 menit (Android WorkManager): kirim outbox dan
/// tarik data master untuk perusahaan yang sedang aktif.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await runBackgroundSync(storage: await AppStorage.load());
      return true;
    } catch (_) {
      return false;
    }
  });
}

/// Satu kali sinkron latar.
///
/// WorkManager menjalankan tugas ini di engine Flutter terpisah tetapi di
/// PROSES yang sama dengan aplikasi bila aplikasi sedang terbuka. Karena itu:
/// - dilewati selama aplikasi tampil di layar (aplikasi sinkron sendiri),
/// - database dibuka dengan koneksi sendiri ([LocalDb.open] tidak memakai
///   koneksi bersama), sehingga menutupnya tidak menutup database aplikasi
///   (dulu: `database_closed 1` saat menekan Sinkron sekarang).
Future<BackgroundSyncResult> runBackgroundSync({
  required AppStorage storage,
  Future<LocalDb> Function(String fileName)? openDb,
  ApiClient Function(String baseUrl, String token, int tenantId, int pending)? apiFactory,
}) async {
  final token = await storage.token();
  final session = storage.session();
  final tenantId = storage.tenantId;
  // Data server lama belum terpindah: jangan buka / kirim apa pun.
  if (token == null || session == null || tenantId == null || storage.serverMigrationPending) {
    return BackgroundSyncResult.skippedNoSession;
  }
  if (await storage.foregroundActive()) {
    return BackgroundSyncResult.skippedForeground;
  }
  final open = openDb ?? (fileName) async => LocalDb.open(p.join(await getDatabasesPath(), fileName));
  final local = await open(LocalDb.fileName(session.user.id, tenantId));
  try {
    final outbox = OutboxStore(local);
    final pending = await outbox.pendingCount();
    final api = apiFactory?.call(storage.serverUrl, token, tenantId, pending) ?? ApiClient(baseUrl: storage.serverUrl, token: token, tenantId: tenantId, outboxCount: () => pending);
    final engine = SyncEngine(api: api, local: local, outbox: outbox);
    if (!(await engine.ping()).ok) {
      return BackgroundSyncResult.offline;
    }
    await engine.run();
    return BackgroundSyncResult.synced;
  } finally {
    await local.close();
  }
}

Future<void> registerBackgroundSync() async {
  await Workmanager().initialize(backgroundDispatcher);
  await Workmanager().registerPeriodicTask(
    backgroundSyncTask,
    backgroundSyncTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );
}
