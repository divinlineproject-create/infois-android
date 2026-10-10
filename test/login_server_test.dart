import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/core/config.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/background_sync.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';

/// Server permanen: alamat server tetap sejak build, tidak ada pilihan server
/// di layar Masuk, dan login/data milik server lain tidak terbawa.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  final originalQuarantine = AppStorage.quarantineLocalData;
  late List<String> quarantined;
  setUp(() {
    mockClipboard();
    quarantined = [];
    AppStorage.quarantineLocalData = (oldServer) async {
      quarantined.add(oldServer);
      return const ['infois_u1_t1.db'];
    };
  });
  tearDown(() => AppStorage.quarantineLocalData = originalQuarantine);

  Map<String, Object> loggedInPrefs({Map<String, Object> extra = const {}}) => {
        'session': jsonEncode({
          'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
          'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', menus: Menus(pos: true)).toJson()],
        }),
        'tenant_id': 1,
        'printer_mac': '00:11:22:33:44:55',
        'theme_mode': 'dark',
        ...extra,
      };

  Future<AppStorage> loadWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-lama', 'device_uid': 'hp-tes'});
    return AppStorage.load();
  }

  test('server bawaan = INFOIS_SERVER saat build (default produksi), sama di semua mode', () {
    const defined = String.fromEnvironment('INFOIS_SERVER');
    expect(AppConfig.serverUrl, defined.isEmpty ? 'https://dashboard.infois.ai' : defined);
    expect(AppConfig.productionServerUrl, 'https://dashboard.infois.ai');
  });

  group('perpindahan saat dibuka', () {
    test('alamat ketikan versi lama (10.0.2.2) diabaikan + dihapus; login & data server lama dilepas', () async {
      final storage = await loadWith(loggedInPrefs(extra: {AppStorage.legacyServerKey: 'http://10.0.2.2:8000'}));

      expect(storage.prefs.containsKey(AppStorage.legacyServerKey), isFalse);
      expect(storage.prefs.getString(AppStorage.dataServerKey), AppConfig.serverUrl);
      expect(storage.serverUrl, AppConfig.serverUrl);
      expect(await storage.token(), isNull, reason: 'token milik server lain');
      expect(storage.session(), isNull);
      expect(storage.tenantId, isNull);
      expect(quarantined, ['http://10.0.2.2:8000'], reason: 'database lokal server lama tidak boleh disinkron ke server ini');
      // Pengaturan HP tetap.
      expect(await storage.deviceUid(), 'hp-tes');
      expect(storage.printer?.mac, '00:11:22:33:44:55');
      expect(storage.themeMode, 'dark');

      // Dibuka lagi: tidak ada yang dilepas dua kali.
      expect(await storage.migrateServer(), isNull);
      expect(quarantined, hasLength(1));
    });

    test('penanda dari build lain (mis. server uji) → login dilepas, database dikarantina', () async {
      final storage = await loadWith(loggedInPrefs(extra: {AppStorage.dataServerKey: 'http://192.168.1.10:8000'}));

      expect(await storage.token(), isNull);
      expect(storage.session(), isNull);
      expect(quarantined, ['http://192.168.1.10:8000']);
      expect(storage.prefs.getString(AppStorage.dataServerKey), AppConfig.serverUrl);
    });

    test('alamat ketikan sama dengan server bawaan (beda / di akhir & huruf besar) → login tetap', () async {
      final typed = '${AppConfig.serverUrl.toUpperCase()}/';
      final storage = await loadWith(loggedInPrefs(extra: {AppStorage.legacyServerKey: typed}));

      expect(storage.prefs.containsKey(AppStorage.legacyServerKey), isFalse);
      expect(await storage.token(), 'token-lama');
      expect(storage.session()?.user.name, 'Sari');
      expect(storage.tenantId, 1);
      expect(quarantined, isEmpty);
    });

    test('pemasangan lama tanpa ketikan server → dianggap server bawaan, cukup diberi penanda', () async {
      final storage = await loadWith(loggedInPrefs());

      expect(await storage.token(), 'token-lama');
      expect(storage.session(), isNotNull);
      expect(quarantined, isEmpty);
      expect(storage.prefs.getString(AppStorage.dataServerKey), AppConfig.serverUrl);
    });

    test('server bawaan build berganti (rilis baru) → login dilepas', () async {
      final storage = await loadWith(loggedInPrefs());
      expect(await storage.migrateServer(builtInServer: 'https://baru.infois.ai'), AppConfig.serverUrl);
      expect(await storage.token(), isNull);
      expect(quarantined, [AppConfig.serverUrl]);
      expect(storage.prefs.getString(AppStorage.dataServerKey), 'https://baru.infois.ai');
    });

    test('karantina: file database dipindah utuh, tidak terbaca lagi sebagai database perusahaan', () async {
      final directory = await Directory.systemTemp.createTemp('infois_karantina');
      addTearDown(() => directory.delete(recursive: true));
      File(p.join(directory.path, LocalDb.fileName(1, 1))).writeAsStringSync('isi-1');
      File(p.join(directory.path, '${LocalDb.fileName(1, 1)}-wal')).writeAsStringSync('wal');
      File(p.join(directory.path, LocalDb.fileName(1, 2))).writeAsStringSync('isi-2');
      File(p.join(directory.path, 'lain.db')).writeAsStringSync('lain');

      final moved = await AppStorage.quarantineLocalDataIn(directory, 'http://10.0.2.2:8000');

      expect(moved..sort(), [LocalDb.fileName(1, 1), '${LocalDb.fileName(1, 1)}-wal', LocalDb.fileName(1, 2)]..sort());
      final top = directory.listSync().whereType<File>().map((file) => p.basename(file.path)).toList();
      expect(top, ['lain.db'], reason: 'aplikasi hanya membuka infois_u* langsung di folder database');
      final kept = Directory(p.join(directory.path, 'server_lama')).listSync().single as Directory;
      expect(p.basename(kept.path), startsWith('10.0.2.2_8000-'));
      expect(File(p.join(kept.path, LocalDb.fileName(1, 1))).readAsStringSync(), 'isi-1');
      expect(File(p.join(kept.path, LocalDb.fileName(1, 2))).readAsStringSync(), 'isi-2');

      expect(await AppStorage.quarantineLocalDataIn(directory, 'http://10.0.2.2:8000'), isEmpty);
    });

    test('pemindahan gagal: penanda tidak ditulis, diulang saat dibuka lagi; database tidak dibuka selama tertunda', () async {
      var fail = true;
      var calls = 0;
      AppStorage.quarantineLocalData = (oldServer) async {
        calls++;
        if (fail) {
          throw const FileSystemException('disk penuh');
        }
        return const ['infois_u1_t1.db'];
      };
      final storage = await loadWith(loggedInPrefs(extra: {AppStorage.legacyServerKey: 'http://10.0.2.2:8000'}));

      expect(calls, 1);
      expect(await storage.token(), isNull, reason: 'login server lama tetap dilepas');
      expect(storage.prefs.getString(AppStorage.legacyServerKey), 'http://10.0.2.2:8000', reason: 'belum tuntas: diulang nanti');
      expect(storage.prefs.getString(AppStorage.dataServerKey), isNull);
      expect(storage.serverMigrationPending, isTrue);

      // Pengguna masuk lagi ke server ini dengan nomor user/perusahaan yang sama.
      await storage.setToken('token-baru');
      await storage.setSession(const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'), [const TenantSummary(id: 1, name: 'Warung Tes', menus: Menus(pos: true))]);
      await storage.setTenantId(1);
      final opened = <String>[];
      final container = ProviderContainer(overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((name) async {
          opened.add(name);
          return memoryDb();
        }),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(offlineServer())),
      ]);
      addTearDown(container.dispose);
      final keepAlive = container.listen(workspaceProvider, (_, __) {});
      addTearDown(keepAlive.close);
      await expectLater(container.read(workspaceProvider.future), throwsA(isA<ServerMigrationPending>()));
      expect(opened, isEmpty, reason: 'file infois_u1_t1.db server lama tidak boleh terbuka atas nama login baru');
      expect(calls, 2, reason: 'dicoba lagi sebelum membuka database');
      expect(await storage.token(), 'token-baru', reason: 'login baru ke server ini tidak ikut dilepas saat mengulang');

      final background = await runBackgroundSync(storage: storage, openDb: (name) async {
        opened.add(name);
        return memoryDb();
      });
      expect(background, BackgroundSyncResult.skippedNoSession);
      expect(opened, isEmpty, reason: 'sinkron latar juga tidak membuka / mengirim data server lama');

      // Dibuka lagi dan pemindahan berhasil: penanda ditulis, tidak tertunda lagi.
      fail = false;
      expect(await storage.migrateServer(), 'http://10.0.2.2:8000');
      expect(calls, 3);
      expect(storage.serverMigrationPending, isFalse);
      expect(storage.prefs.containsKey(AppStorage.legacyServerKey), isFalse);
      expect(storage.prefs.getString(AppStorage.dataServerKey), AppConfig.serverUrl);
      expect(await storage.migrateServer(), isNull);
      expect(calls, 3);
    });

    test('karantina: kunci proses lain dihormati, kunci basi diambil alih, sisa file = gagal', () async {
      final directory = await Directory.systemTemp.createTemp('infois_karantina_kunci');
      addTearDown(() => directory.delete(recursive: true));
      final db = File(p.join(directory.path, LocalDb.fileName(1, 1)))..writeAsStringSync('isi');
      final lock = File(p.join(directory.path, AppStorage.quarantineLockName))..writeAsStringSync('');

      // Proses lain (aplikasi / sinkron latar) sedang memindah: jangan ikut memindah.
      await expectLater(AppStorage.quarantineLocalDataIn(directory, 'http://10.0.2.2:8000'), throwsA(isA<FileSystemException>()));
      expect(db.existsSync(), isTrue);

      // Kunci sisa proses yang terhenti (lebih dari 2 menit): diambil alih.
      lock.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
      expect(await AppStorage.quarantineLocalDataIn(directory, 'http://10.0.2.2:8000'), [LocalDb.fileName(1, 1)]);
      expect(db.existsSync(), isFalse);
      expect(lock.existsSync(), isFalse, reason: 'kunci dilepas setelah selesai');

      // Tujuan tidak bisa dibuat: file tetap di tempat dan pemanggil diberi tahu.
      final other = File(p.join(directory.path, LocalDb.fileName(2, 1)))..writeAsStringSync('isi-2');
      Directory(p.join(directory.path, 'server_lama')).deleteSync(recursive: true);
      File(p.join(directory.path, 'server_lama')).writeAsStringSync('bukan folder');
      await expectLater(AppStorage.quarantineLocalDataIn(directory, 'http://10.0.2.2:8000'), throwsA(isA<FileSystemException>()));
      expect(other.existsSync(), isTrue);
      expect(lock.existsSync(), isFalse);
    });
  });

  group('alamat API', () {
    test('klien API bawaan memakai server build-time', () async {
      final storage = await loadWith(loggedInPrefs());
      final container = ProviderContainer(overrides: [storageProvider.overrideWithValue(storage)]);
      addTearDown(container.dispose);
      final session = await container.read(sessionProvider.future);

      expect(session.serverUrl, AppConfig.serverUrl);
      final api = container.read(apiFactoryProvider)(session.serverUrl, session.token, 1, () => null);
      expect(api.dio.options.baseUrl, '${AppConfig.serverUrl.replaceAll(RegExp(r'/+$'), '')}/api/v1/');
      expect(session.webUrl('/app'), '${AppConfig.serverUrl.replaceAll(RegExp(r'/+$'), '')}/app');
    });

    test('workspace dan sinkron latar memakai server build-time', () async {
      final storage = await loadWith(loggedInPrefs());
      final bases = <String>[];
      final container = ProviderContainer(overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) => memoryDb()),
        apiFactoryProvider.overrideWithValue((baseUrl, _, __, ___) {
          bases.add(baseUrl);
          return fakeApi(offlineServer());
        }),
      ]);
      addTearDown(container.dispose);
      final keepAlive = container.listen(workspaceProvider, (_, __) {});
      addTearDown(keepAlive.close);
      await container.read(workspaceProvider.future);

      await runBackgroundSync(storage: storage, openDb: (_) => memoryDb(), apiFactory: (baseUrl, _, __, ___) {
        bases.add(baseUrl);
        return fakeApi(offlineServer());
      });

      expect(bases, isNotEmpty);
      expect(bases.toSet(), {AppConfig.serverUrl});
    });
  });

  group('layar Masuk', () {
    Future<List<String>> pumpLogin(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({AppStorage.legacyServerKey: 'http://10.0.2.2:8000'});
      FlutterSecureStorage.setMockInitialValues({'device_uid': 'hp-tes'});
      final storage = await AppStorage.load();
      final bases = <String>[];
      final server = FakeServer((options, _) => switch (options.path) {
            'auth/login' => {
                'token': 'token-baru',
                'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
                'tenants': [
                  {'id': 1, 'name': 'Warung Tes', 'menus': {'pos': true}},
                ],
              },
            _ => null,
          });
      final local = await tester.runAsync(() async {
        final db = await memoryDb();
        await seedMaster(db, menus: {'pos': true});
        return db;
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          localDbOpenerProvider.overrideWithValue((_) async => local!),
          apiFactoryProvider.overrideWithValue((baseUrl, _, __, ___) {
            bases.add(baseUrl);
            return fakeApi(server);
          }),
          connectivityStreamProvider.overrideWithValue(const Stream.empty()),
          printerTransportProvider.overrideWithValue(FakePrinter()),
          filePlatformProvider.overrideWithValue(FakeFilePlatform()),
        ],
        child: const InfoisApp(),
      ));
      await settle(tester);
      return bases;
    }

    testWidgets('tidak ada tombol / dialog server; masuk langsung ke server build-time', (tester) async {
      final bases = await pumpLogin(tester);

      expect(find.text('Masuk ke Infois'), findsOneWidget);
      expect(find.textContaining('Server'), findsNothing);
      expect(find.textContaining('10.0.2.2'), findsNothing);
      expect(find.textContaining(AppConfig.serverUrl), findsNothing);
      expect(find.byIcon(Icons.dns_outlined), findsNothing);

      await tester.enterText(find.byKey(const Key('login-email')), 'sari@tes.id');
      await tester.enterText(find.byKey(const Key('login-password')), 'rahasia');
      await tester.tap(find.byKey(const Key('login-submit')));
      await settle(tester);

      expect(find.text('Masuk ke Infois'), findsNothing);
      expect(bases, isNotEmpty);
      expect(bases.toSet(), {AppConfig.serverUrl});
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('ApiClient memakai alamat yang diberikan apa adanya (+ /api/v1/)', () {
    expect(ApiClient(baseUrl: 'https://dashboard.infois.ai/').dio.options.baseUrl, 'https://dashboard.infois.ai/api/v1/');
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
