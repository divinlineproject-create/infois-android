import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
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
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';

/// Perusahaan ditutup pemiliknya (403 `perusahaan_ditutup`) atau user bukan
/// anggotanya lagi (403 `bukan_anggota` lalu hilang dari `GET /me`): pesan
/// dengan jumlah transaksi belum terkirim, data HP perusahaan itu dihapus
/// setelah pengguna menekan "Mengerti", dan tidak ada coba-ulang tanpa akhir.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  late Directory directory;
  late List<(int, int)> wiped;
  late Future<void> Function(int userId, int tenantId) originalWipe;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('infois_closed');
    wiped = [];
    originalWipe = SessionController.deleteCompanyData;
    SessionController.deleteCompanyData = (userId, tenantId) async => wiped.add((userId, tenantId));
  });
  tearDown(() async {
    SessionController.deleteCompanyData = originalWipe;
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> waitFor(bool Function() condition, {String? reason}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Menunggu terlalu lama: ${reason ?? 'kondisi'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<LocalDb> openFile(String fileName) => LocalDb.open(p.join(directory.path, fileName), factory: databaseFactoryFfiNoIsolate);

  /// Isi file database perusahaan [tenantId]: [unsent] transaksi belum
  /// terkirim dan [held] pesanan tersimpan.
  Future<void> seedFile(int tenantId, {int unsent = 0, int held = 0}) async {
    final local = await openFile(LocalDb.fileName(1, tenantId));
    for (var i = 0; i < unsent; i++) {
      await OutboxStore(local).enqueue('customer', 'c-$tenantId-$i', {'name': 'Pelanggan $i'});
    }
    for (var i = 0; i < held; i++) {
      final now = DateTime(2026, 10, 11).toIso8601String();
      await local.db.insert('held_orders', {'id': 'h-$i', 'name': 'Meja $i', 'total': '18000', 'item_count': 1, 'created_at': now, 'updated_at': now, 'data': '{}'});
    }
    await local.close();
  }

  Map<String, dynamic> meJson(List<int> tenantIds) => {
    'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
    'tenants': [
      for (final id in tenantIds)
        {
          'id': id,
          'name': id == 1 ? 'Warung A' : 'Warung B',
          'mobile_eligible': true,
          'menus': {'pos': true},
          'permissions': [],
        },
    ],
  };

  Map<String, dynamic> pullJson() => {
    'cursor': 'c1',
    'tenant': {'id': 1, 'name': 'Warung A'},
    'receipt': {
      'company': {'name': 'Warung A'},
    },
    'device': {'id': 3, 'code': 'K1'},
    'menus': {'pos': true},
    'user': {'id': 1, 'name': 'Sari'},
    'products': {'items': [], 'ids': []},
    'customers': {'items': [], 'ids': []},
    'accounts': {'items': [], 'ids': []},
    'warehouses': {'items': [], 'ids': []},
    'number_blocks': [],
    'open_shift': null,
  };

  Map<String, dynamic> closed() => {'_status': 403, 'code': 'perusahaan_ditutup', 'message': 'Warung A sudah ditutup oleh pemiliknya.'};
  Map<String, dynamic> notMember() => {'_status': 403, 'code': 'bukan_anggota', 'message': 'Anda bukan anggota perusahaan ini.'};

  Future<AppStorage> storageWith({int? tenantId = 1, List<int> tenants = const [1, 2], Map<String, Object> extra = const {}}) async {
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [
          for (final id in tenants)
            TenantSummary(id: id, slug: id == 1 ? 'warung-a' : 'warung-b', name: id == 1 ? 'Warung A' : 'Warung B', menus: const Menus(pos: true), permissions: const []).toJson(),
        ],
      }),
      if (tenantId != null) 'tenant_id': tenantId,
      ...extra,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    return AppStorage.load();
  }

  ProviderContainer containerFor(AppStorage storage, FakeServer server) {
    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue(openFile),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);
    final keep = container.listen(syncProvider, (_, __) {});
    addTearDown(keep.close);
    return container;
  }

  int count(FakeServer server, String path) => server.requests.where((request) => request.path == path).length;

  group('sinkron', () {
    test('403 perusahaan_ditutup saat kirim outbox: pesan + jumlah belum terkirim, perusahaan dilepas, tanpa coba ulang', () async {
      await seedFile(1, unsent: 2, held: 1);
      final storage = await storageWith();
      final server = FakeServer(
        (options, _) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          'sync/push' || 'sync/pull' => closed(),
          'me' => meJson([2]),
          _ => {},
        },
      );
      final container = containerFor(storage, server);
      await container.read(sessionProvider.future);
      final workspace = await container.read(workspaceProvider.future);
      expect(workspace!.tenant.id, 1);

      await waitFor(() => container.read(sessionProvider).value!.gone.isNotEmpty, reason: 'perusahaan dicatat ditutup');
      final session = container.read(sessionProvider).value!;
      final gone = session.gone.single;
      expect(gone.tenantId, 1);
      expect(gone.userId, 1);
      expect(gone.name, 'Warung A');
      expect(gone.reason, GoneReason.closed);
      expect(gone.unsent, 2);
      expect(gone.held, 1);
      expect(gone.title, 'Warung A sudah ditutup');
      expect(gone.lossWarning, contains('2 transaksi'));
      expect(gone.lossWarning, contains('1 pesanan tersimpan'));
      expect(session.goneNotices, hasLength(1));
      expect(session.tenantId, isNull, reason: 'Kembali ke Pilih perusahaan.');
      expect(session.tenants.map((tenant) => tenant.id), [2]);
      expect(session.loggedIn, isTrue, reason: 'Perusahaan lain masih bisa dipakai.');

      // Tersimpan di HP: tetap tampil setelah aplikasi ditutup-buka.
      expect(storage.tenantId, isNull);
      expect(storage.session()!.tenants.map((tenant) => tenant.id), [2]);
      expect(SessionController.goneIn(storage).single.unsent, 2);

      // Tidak ada coba ulang: workspace dilepas dan sinkron berhenti.
      expect(await container.read(workspaceProvider.future), isNull);
      await waitFor(() => !workspace.local.db.isOpen, reason: 'database perusahaan ditutup');
      final pushes = count(server, 'sync/push');
      expect(pushes, 1);
      await container.read(syncProvider.notifier).syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(count(server, 'sync/push'), pushes);
      expect(wiped, isEmpty, reason: 'Data baru dihapus setelah pengguna menekan Mengerti.');

      // Outbox tidak dianggap gagal per item (bukan galat transaksi).
      final reopened = await openFile(LocalDb.fileName(1, 1));
      final items = await OutboxStore(reopened).pending();
      expect(items.map((item) => item.attempts), everyElement(0));
      await reopened.close();

      // Mengerti → data HP perusahaan itu dihapus, pesan hilang.
      await container.read(sessionProvider.notifier).acknowledgeGone(gone);
      expect(wiped, [(1, 1)]);
      expect(container.read(sessionProvider).value!.gone, isEmpty);
      expect(SessionController.goneIn(storage), isEmpty);
    });

    test('403 bukan_anggota lalu perusahaan hilang dari GET /me: dianggap dikeluarkan (pesan + hapus setelah Mengerti)', () async {
      await seedFile(1, unsent: 3);
      final storage = await storageWith();
      final server = FakeServer(
        (options, _) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          'sync/push' || 'sync/pull' => notMember(),
          'me' => meJson([2]),
          _ => {},
        },
      );
      final container = containerFor(storage, server);
      await container.read(sessionProvider.future);
      await container.read(workspaceProvider.future);

      await waitFor(() => container.read(sessionProvider).value!.gone.isNotEmpty, reason: 'perusahaan dicatat hilang');
      final gone = container.read(sessionProvider).value!.gone.single;
      expect(gone.reason, GoneReason.removed);
      expect(gone.unsent, 3);
      expect(gone.title, 'Anda tidak lagi menjadi anggota Warung A');
      expect(container.read(sessionProvider).value!.tenantId, isNull);
      expect(count(server, 'me'), 1);
      expect(await container.read(workspaceProvider.future), isNull);
    });

    test('403 bukan_anggota tetapi GET /me masih memuat perusahaan itu: data tidak dihapus, tidak ada pengulangan cepat', () async {
      await seedFile(1, unsent: 1);
      final storage = await storageWith();
      final server = FakeServer(
        (options, _) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          'sync/push' || 'sync/pull' => notMember(),
          'me' => meJson([1, 2]),
          _ => {},
        },
      );
      final container = containerFor(storage, server);
      await container.read(sessionProvider.future);
      await container.read(workspaceProvider.future);

      await waitFor(() => count(server, 'me') == 1, reason: 'GET /me dipanggil');
      await waitFor(() => !container.read(syncProvider).syncing, reason: 'siklus selesai');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final session = container.read(sessionProvider).value!;
      expect(session.gone, isEmpty);
      expect(session.tenantId, 1, reason: 'Tanpa bukti, perusahaan tetap dipakai.');
      expect(count(server, 'sync/push'), 1, reason: 'Tidak ada timer coba ulang untuk galat keanggotaan.');
      expect(wiped, isEmpty);
    });

    test('GET /me gagal (offline) setelah bukan_anggota: tidak ada yang dihapus', () async {
      final storage = await storageWith();
      final server = FakeServer(
        (options, _) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          'sync/push' || 'sync/pull' => notMember(),
          _ => null,
        },
      );
      final container = containerFor(storage, server);
      await container.read(sessionProvider.future);
      await container.read(workspaceProvider.future);
      await waitFor(() => server.requests.any((request) => request.path == 'me'), reason: 'GET /me dicoba');
      await waitFor(() => !container.read(syncProvider).syncing, reason: 'siklus selesai');
      expect(container.read(sessionProvider).value!.gone, isEmpty);
      expect(container.read(sessionProvider).value!.tenantId, 1);
    });

    test('403 perusahaan_ditutup dari layar lain (mis. Laporan) juga melepas perusahaan', () async {
      await seedFile(1, unsent: 1);
      final storage = await storageWith();
      var closedNow = false;
      final server = FakeServer(
        (options, _) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          'sync/pull' => closedNow ? closed() : pullJson(),
          'sync/push' => closedNow ? closed() : {'results': []},
          'reports/overview' => closed(),
          'pos/number-blocks' => {
            '_status': 201,
            'block': {'id': 9, 'format': 'POS-K1/{SEQ:6}', 'start': 1, 'end': 500},
          },
          _ => {},
        },
      );
      final container = containerFor(storage, server);
      await container.read(sessionProvider.future);
      final workspace = (await container.read(workspaceProvider.future))!;
      await waitFor(() => container.read(syncProvider).lastSyncAt != null || container.read(syncProvider).message != null, reason: 'sinkron awal selesai');
      await waitFor(() => !container.read(syncProvider).syncing, reason: 'siklus selesai');
      closedNow = true;

      await expectLater(workspace.api.get('reports/overview'), throwsA(isA<ApiException>().having((error) => error.companyClosed, 'companyClosed', isTrue)));
      await waitFor(() => container.read(sessionProvider).value!.gone.isNotEmpty, reason: 'perusahaan dicatat ditutup');
      final gone = container.read(sessionProvider).value!.gone.single;
      expect(gone.reason, GoneReason.closed);
      expect(gone.unsent, 1);
      expect(container.read(sessionProvider).value!.tenantId, isNull);
    });
  });

  group('sesi', () {
    ProviderContainer sessionOnly(AppStorage storage, FakeServer server) {
      final container = ProviderContainer(overrides: [storageProvider.overrideWithValue(storage), apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server))]);
      addTearDown(container.dispose);
      return container;
    }

    test('catatan tersimpan dimuat lagi saat aplikasi dibuka; perusahaan yang muncul lagi di GET /me membatalkan pesan tanpa menghapus', () async {
      const saved = GoneCompany(userId: 1, tenantId: 1, name: 'Warung A', reason: GoneReason.removed, unsent: 4);
      final storage = await storageWith(
        tenantId: null,
        tenants: const [2],
        extra: {
          SessionController.goneKey: jsonEncode([saved.toJson()]),
        },
      );
      final container = sessionOnly(storage, FakeServer((options, _) => options.path == 'me' ? meJson([1, 2]) : null));
      final session = await container.read(sessionProvider.future);
      expect(session.gone.single.unsent, 4);
      expect(session.goneNotices.single.title, 'Anda tidak lagi menjadi anggota Warung A');

      await container.read(sessionProvider.notifier).refreshMe();
      expect(container.read(sessionProvider).value!.gone, isEmpty);
      expect(SessionController.goneIn(storage), isEmpty);
      expect(wiped, isEmpty, reason: 'Masih anggota: transaksinya bisa terkirim lagi.');
    });

    test('GET /me 403 akses_hp_tidak_tersedia: perusahaan yang ada di daftar ditolak = masalah paket, bukan dikeluarkan', () async {
      final storage = await storageWith(tenants: const [1]);
      final server = FakeServer(
        (options, _) => switch (options.path) {
          'me' => {
            '_status': 403,
            'code': 'akses_hp_tidak_tersedia',
            'message': 'Warung A masih masa trial.',
            'tenants': [
              {'id': 1, 'name': 'Warung A', 'reason': 'trial'},
            ],
          },
          _ => {},
        },
      );
      final container = sessionOnly(storage, server);
      await container.read(sessionProvider.future);
      await container.read(sessionProvider.notifier).refreshMe(notMemberOf: 1);
      final session = container.read(sessionProvider).value!;
      expect(session.loggedIn, isFalse);
      expect(session.notice, isNotNull);
      expect(session.gone, isEmpty);
    });

    test('GET /me 403 akses_hp_tidak_tersedia tanpa perusahaan itu: dicatat dikeluarkan, tetap tampil di layar Masuk', () async {
      final storage = await storageWith(tenants: const [1, 2]);
      final server = FakeServer(
        (options, _) => switch (options.path) {
          'me' => {
            '_status': 403,
            'code': 'akses_hp_tidak_tersedia',
            'message': 'Warung B masih masa trial.',
            'tenants': [
              {'id': 2, 'name': 'Warung B', 'reason': 'trial'},
            ],
          },
          _ => {},
        },
      );
      final container = sessionOnly(storage, server);
      await container.read(sessionProvider.future);
      await container.read(sessionProvider.notifier).refreshMe(notMemberOf: 1);
      final session = container.read(sessionProvider).value!;
      expect(session.loggedIn, isFalse);
      expect(session.gone.single.tenantId, 1);
      expect(session.goneNotices, hasLength(1), reason: 'Di layar Masuk pesan tetap tampil sampai Mengerti.');
      expect(SessionController.goneIn(storage), hasLength(1));
    });

    test('Keluar menghapus semua data HP user ini, termasuk catatan perusahaan yang ditutup', () async {
      const saved = GoneCompany(userId: 1, tenantId: 1, name: 'Warung A', reason: GoneReason.closed);
      final storage = await storageWith(
        tenantId: null,
        tenants: const [2],
        extra: {
          SessionController.goneKey: jsonEncode([saved.toJson()]),
        },
      );
      final deleted = <int>[];
      final original = SessionController.deleteLocalData;
      SessionController.deleteLocalData = (userId) async => deleted.add(userId);
      addTearDown(() => SessionController.deleteLocalData = original);
      final container = sessionOnly(storage, FakeServer((_, __) => {}));
      await container.read(sessionProvider.future);
      await container.read(sessionProvider.notifier).logout();
      expect(deleted, [1]);
      expect(container.read(sessionProvider).value!.gone, isEmpty);
      expect(SessionController.goneIn(storage), isEmpty);
    });

    test('pesan dua kali untuk perusahaan yang sama dicatat sekali', () async {
      final storage = await storageWith();
      final container = sessionOnly(storage, FakeServer((_, __) => {}));
      await container.read(sessionProvider.future);
      final controller = container.read(sessionProvider.notifier);
      await Future.wait([controller.companyGone(1, reason: GoneReason.closed), controller.companyGone(1, reason: GoneReason.closed)]);
      await controller.companyGone(1, reason: GoneReason.closed);
      expect(container.read(sessionProvider).value!.gone, hasLength(1));
      expect(SessionController.goneIn(storage), hasLength(1));
    });

    test('teks pesan: bahasa sehari-hari, jumlah tidak diketahui tidak ditulis 0', () {
      const unknown = GoneCompany(userId: 1, tenantId: 1, name: 'Warung A', reason: GoneReason.closed);
      expect(unknown.lossWarning, contains('bila ada'));
      const none = GoneCompany(userId: 1, tenantId: 1, name: 'Warung A', reason: GoneReason.closed, unsent: 0, held: 0);
      expect(none.lossWarning, isNull);
      const some = GoneCompany(userId: 1, tenantId: 1, name: 'Warung A', reason: GoneReason.removed, unsent: 5, held: 0);
      expect(some.lossWarning, '5 transaksi di HP ini belum terkirim dan tidak bisa dikirim lagi. Semuanya ikut terhapus.');
      final roundTrip = GoneCompany.fromJson(jsonDecode(jsonEncode(some.toJson())) as Map<String, dynamic>);
      expect((roundTrip.tenantId, roundTrip.reason, roundTrip.unsent, roundTrip.held), (1, GoneReason.removed, 5, 0));
    });

    test('hapus data satu perusahaan: hanya file perusahaan itu (bukan t11, bukan user lain)', () async {
      for (final name in ['infois_u1_t1.db', 'infois_u1_t1.db-wal', 'infois_u1_t1.db-shm', 'infois_u1_t11.db', 'infois_u2_t1.db', 'infois_u1_t2.db']) {
        File(p.join(directory.path, name)).writeAsStringSync('x');
      }
      await SessionController.deleteCompanyDataIn(directory, 1, 1);
      final left = [for (final file in directory.listSync()) p.basename(file.path)]..sort();
      expect(left, ['infois_u1_t11.db', 'infois_u1_t2.db', 'infois_u2_t1.db']);
    });
  });

  group('sinkron latar', () {
    test('403 perusahaan_ditutup: dicatat untuk pesan, perusahaan dilepas, tugas berikutnya dilewati', () async {
      await seedFile(1, unsent: 2);
      final storage = await storageWith();
      final server = FakeServer(
        (options, _) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          _ => closed(),
        },
      );
      final first = await runBackgroundSync(storage: storage, openDb: openFile, apiFactory: (_, __, ___, ____) => fakeApi(server));
      expect(first, BackgroundSyncResult.companyGone);
      expect(storage.tenantId, isNull);
      expect(storage.session()!.tenants.map((tenant) => tenant.id), [2]);
      final gone = SessionController.goneIn(storage).single;
      expect((gone.tenantId, gone.reason, gone.unsent), (1, GoneReason.closed, 2));

      final requests = server.requests.length;
      final second = await runBackgroundSync(storage: storage, openDb: openFile, apiFactory: (_, __, ___, ____) => fakeApi(server));
      expect(second, BackgroundSyncResult.skippedNoSession);
      expect(server.requests.length, requests);
      expect(wiped, isEmpty, reason: 'Dihapus setelah pengguna melihat pesannya di aplikasi.');
    });

    test('403 bukan_anggota: tidak dilempar sebagai galat (WorkManager tidak mengulang), aplikasi yang memastikan', () async {
      await seedFile(1, unsent: 1);
      final storage = await storageWith();
      final server = FakeServer((options, _) => options.path == 'ping' ? {'ok': true, 'min_app_version': '1.0.0'} : notMember());
      final result = await runBackgroundSync(storage: storage, openDb: openFile, apiFactory: (_, __, ___, ____) => fakeApi(server));
      expect(result, BackgroundSyncResult.notMember);
      expect(storage.tenantId, 1);
      expect(SessionController.goneIn(storage), isEmpty);
    });
  });

  group('layar', () {
    Future<AppStorage> pumpApp(WidgetTester tester, {required AppStorage storage, required FakeServer server}) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      mockClipboard();
      final local = await tester.runAsync(() async {
        final db = await memoryDb();
        await seedMaster(db, menus: {'pos': true});
        return db;
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageProvider.overrideWithValue(storage),
            localDbOpenerProvider.overrideWithValue((_) async => local!),
            apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
            connectivityStreamProvider.overrideWithValue(const Stream.empty()),
            printerTransportProvider.overrideWithValue(FakePrinter()),
            filePlatformProvider.overrideWithValue(FakeFilePlatform()),
          ],
          child: const InfoisApp(),
        ),
      );
      await settle(tester);
      return storage;
    }

    testWidgets('Pilih perusahaan: pesan perusahaan ditutup + jumlah belum terkirim; Mengerti menghapus data HP-nya', (tester) async {
      const saved = GoneCompany(userId: 1, tenantId: 1, name: 'Warung A', reason: GoneReason.closed, unsent: 2, held: 1, message: 'Warung A sudah ditutup oleh pemiliknya.');
      final storage =
          (await tester.runAsync(
            () => storageWith(
              tenantId: null,
              tenants: const [2],
              extra: {
                SessionController.goneKey: jsonEncode([saved.toJson()]),
              },
            ),
          ))!;
      await pumpApp(tester, storage: storage, server: FakeServer((options, _) => options.path == 'me' ? meJson([2]) : {}));

      expect(find.text('Pilih perusahaan'), findsOneWidget);
      expect(find.byKey(const Key('gone-notice-1')), findsOneWidget);
      expect(find.text('Warung A sudah ditutup'), findsOneWidget);
      expect(find.textContaining('2 transaksi'), findsOneWidget);
      expect(find.textContaining('1 pesanan tersimpan'), findsOneWidget);
      expect(find.text('Warung B'), findsOneWidget);

      await tester.tap(find.byKey(const Key('gone-ack-1')));
      await settle(tester);
      expect(wiped, [(1, 1)]);
      expect(find.byKey(const Key('gone-notice-1')), findsNothing);
      expect(find.text('Warung B'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('layar Masuk: pesan tetap tampil setelah login dilupakan', (tester) async {
      const saved = GoneCompany(userId: 1, tenantId: 1, name: 'Warung A', reason: GoneReason.removed, unsent: 0, held: 0);
      SharedPreferences.setMockInitialValues({
        SessionController.goneKey: jsonEncode([saved.toJson()]),
      });
      FlutterSecureStorage.setMockInitialValues({'device_uid': 'hp-tes'});
      final storage = (await tester.runAsync(AppStorage.load))!;
      await pumpApp(tester, storage: storage, server: FakeServer((_, __) => {}));

      expect(find.text('Masuk ke Infois'), findsOneWidget);
      expect(find.byKey(const Key('gone-notice-1')), findsOneWidget);
      expect(find.text('Anda tidak lagi menjadi anggota Warung A'), findsOneWidget);
      await tester.tap(find.byKey(const Key('gone-ack-1')));
      await settle(tester);
      expect(wiped, [(1, 1)]);
      expect(find.byKey(const Key('gone-notice-1')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
