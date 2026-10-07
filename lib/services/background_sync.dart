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

/// Sinkron latar tiap ±15 menit (Android WorkManager): kirim outbox dan
/// tarik data master untuk perusahaan yang sedang aktif.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final storage = await AppStorage.load();
      final token = await storage.token();
      final session = storage.session();
      final tenantId = storage.tenantId;
      if (token == null || session == null || tenantId == null) {
        return true;
      }
      final local = await LocalDb.open(p.join(await getDatabasesPath(), LocalDb.fileName(session.user.id, tenantId)));
      try {
        final outbox = OutboxStore(local);
        final pending = await outbox.pendingCount();
        final api = ApiClient(baseUrl: storage.serverUrl, token: token, tenantId: tenantId, outboxCount: () => pending);
        final engine = SyncEngine(api: api, local: local, outbox: outbox);
        if ((await engine.ping()).ok) {
          await engine.run();
        }
      } finally {
        await local.close();
      }
      return true;
    } on Exception {
      return false;
    }
  });
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
