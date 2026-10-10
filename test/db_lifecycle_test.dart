import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/background_sync.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

/// Bug "database_closed 1" saat menekan Sinkron sekarang.
///
/// Akar masalah: sqflite memakai satu koneksi bersama ("single instance") per
/// file. Sinkron latar WorkManager berjalan di engine Flutter lain tetapi di
/// proses yang sama, membuka file database yang sama (mendapat koneksi
/// aplikasi, id 1), lalu menutupnya: semua query aplikasi setelah itu gagal
/// `database_closed 1`. Selain itu workspace lama menutup database seketika
/// saat ganti perusahaan / keluar walau siklus sinkron masih memakainya.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory directory;
  setUp(() async => directory = await Directory.systemTemp.createTemp('infois_db'));
  tearDown(() async {
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  /// Tunggu sampai [condition] benar (tahan beban mesin saat semua tes jalan).
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

  Map<String, dynamic> pullJson() => {
        'cursor': 'c1',
        'tenant': {'id': 1, 'name': 'Warung A'},
        'receipt': {'company': {'name': 'Warung A'}},
        'device': {'id': 3, 'code': 'K1'},
        'menus': {'pos': true},
        'user': {'id': 1, 'name': 'Sari'},
        'products': {'items': [], 'ids': [1, 2]},
        'customers': {'items': [], 'ids': [7]},
        'accounts': {'items': [], 'ids': []},
        'warehouses': {'items': [], 'ids': []},
        'number_blocks': [],
        'open_shift': null,
      };

  Map<String, dynamic>? okHandler(RequestOptions options, Map<String, dynamic>? body) => switch (options.path) {
        'ping' => {'ok': true, 'min_app_version': '1.0.0'},
        'sync/pull' => pullJson(),
        'sync/push' => {
            'results': [
              for (final item in body?['items'] as List? ?? const []) {'client_uuid': (item as Map)['client_uuid'], 'type': item['type'], 'status': 'ok'},
            ],
          },
        'pos/number-blocks' => {
            '_status': 201,
            'block': {'id': 9, 'format': 'POS-K1/{SEQ:6}', 'start': 1, 'end': 500},
          },
        _ => {},
      };

  Future<AppStorage> storageWith({int tenantId = 1, Map<String, Object> extra = const {}}) async {
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [
          const TenantSummary(id: 1, name: 'Warung A', menus: Menus(pos: true)).toJson(),
          const TenantSummary(id: 2, name: 'Warung B', menus: Menus(pos: true)).toJson(),
        ],
      }),
      'tenant_id': tenantId,
      ...extra,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes'});
    return AppStorage.load();
  }

  test('pembuka kedua file yang sama (sinkron latar) menutup koneksinya sendiri, bukan koneksi aplikasi', () async {
    final app = await openFile(LocalDb.fileName(1, 1));
    await seedMaster(app);
    final background = await openFile(LocalDb.fileName(1, 1));
    await background.close();

    // Dulu: DatabaseException(database_closed) — di HP "database_closed 1".
    expect(await app.productCount(), 2);
    await OutboxStore(app).enqueue('customer', 'c-1', {'name': 'A'});
    expect(await OutboxStore(app).pendingCount(), 1);
    await app.close();
  });

  test('sinkron latar: dilewati saat aplikasi tampil; bila berjalan, database aplikasi tetap terbuka', () async {
    final app = await openFile(LocalDb.fileName(1, 1));
    await seedMaster(app);
    final server = FakeServer(okHandler);

    final storage = await storageWith();
    await storage.markForeground(true);
    final skipped = await runBackgroundSync(storage: storage, openDb: openFile, apiFactory: (_, __, ___, ____) => fakeApi(server));
    expect(skipped, BackgroundSyncResult.skippedForeground);
    expect(server.requests, isEmpty);

    await storage.markForeground(false);
    final result = await runBackgroundSync(storage: storage, openDb: openFile, apiFactory: (_, __, ___, ____) => fakeApi(server));
    expect(result, BackgroundSyncResult.synced);
    expect(server.requests.map((request) => request.path), containsAll(['ping', 'sync/pull']));

    // Aplikasi masih bisa membaca dan menulis setelah tugas latar menutup koneksinya.
    expect(await app.getMeta(MetaKeys.cursor), 'c1');
    await app.setMeta('cek', 'ok');
    expect(await app.getMeta('cek'), 'ok');
    await app.close();
  });

  test('tanda "aplikasi tampil" kedaluwarsa: sinkron latar jalan lagi', () async {
    final stale = DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    final storage = await storageWith(extra: {'foreground_at': stale});
    expect(await storage.foregroundActive(), isFalse);
    await storage.markForeground(true);
    expect(await storage.foregroundActive(), isTrue);
  });

  test('tutup database ditunda sampai pemakaian (siklus sinkron) selesai', () async {
    final local = await openFile(LocalDb.fileName(1, 1));
    final gate = Completer<void>();
    final work = local.hold(() async {
      await gate.future;
      return local.getMeta('x');
    });
    var closed = false;
    final closing = local.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse);
    expect(local.isOpen, isFalse, reason: 'Pekerjaan baru tidak boleh memakai database yang diminta tutup.');
    gate.complete();
    expect(await work, isNull);
    await closing;
    expect(closed, isTrue);
    expect(local.db.isOpen, isFalse);
    await local.close(); // Aman dipanggil lagi.
  });

  group('workspace + sinkron', () {
    late List<LocalDb> opened;

    ProviderContainer containerFor(AppStorage storage, FakeServer server) {
      opened = [];
      final container = ProviderContainer(overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((name) async {
          final local = await openFile(name);
          opened.add(local);
          return local;
        }),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    test('ganti perusahaan saat sinkron berjalan: database lama ditutup setelah siklus selesai, tanpa database_closed', () async {
      final storage = await storageWith();
      final gate = Completer<void>();
      final server = GatedServer(okHandler)..hold((options) => options.path == 'sync/pull' && options.headers['X-Tenant'] == '1', gate);
      final container = containerFor(storage, server);
      final keep = container.listen(syncProvider, (_, __) {});
      addTearDown(keep.close);

      await container.read(sessionProvider.future);
      final first = await container.read(workspaceProvider.future);
      // Sinkron otomatis saat workspace siap: tertahan di sync/pull.
      await waitFor(() => container.read(syncProvider).syncing, reason: 'sinkron tertahan di sync/pull');
      expect(container.read(syncProvider).syncing, isTrue);

      await container.read(sessionProvider.notifier).selectTenant(2);
      final second = await container.read(workspaceProvider.future);
      expect(second!.tenant.id, 2);
      expect(first!.disposed, isTrue);
      expect(first.local.db.isOpen, isTrue, reason: 'Siklus sinkron perusahaan lama masih memakai database-nya.');

      gate.complete();
      await waitFor(() => !first.local.db.isOpen, reason: 'Ditutup setelah siklus selesai.');
      expect(container.read(syncProvider).message ?? '', isNot(contains('database_closed')));
      expect(second.local.isOpen, isTrue);
    });

    test('Sinkron sekarang setelah database tertutup dari luar: dibuka ulang otomatis, sinkron berhasil', () async {
      final storage = await storageWith();
      final server = FakeServer(okHandler);
      final container = containerFor(storage, server);
      final keep = container.listen(syncProvider, (_, __) {});
      addTearDown(keep.close);

      await container.read(sessionProvider.future);
      final first = await container.read(workspaceProvider.future);
      await waitFor(() => container.read(syncProvider).lastSyncAt != null, reason: 'sinkron awal selesai');
      // Meniru tugas latar versi lama yang menutup koneksi aplikasi.
      await first!.local.db.close();

      await container.read(syncProvider.notifier).syncNow();
      await waitFor(() => opened.length == 2, reason: 'workspace dibuka ulang');
      final reopened = await container.read(workspaceProvider.future);
      expect(reopened, isNot(same(first)), reason: 'Workspace dibuat ulang dengan koneksi baru.');
      expect(reopened!.local.isOpen, isTrue);
      expect(opened, hasLength(2));

      await container.read(syncProvider.notifier).syncNow();
      final state = container.read(syncProvider);
      expect(state.message, isNull);
      expect(state.lastSyncAt, isNotNull);
      expect(await reopened.local.getMeta(MetaKeys.cursor), 'c1');
    });

    test('bayar / simpan pesanan saat perusahaan diganti: penjualan tersimpan, tanpa database_closed', () async {
      final storage = await storageWith();
      final container = containerFor(storage, offlineServer());
      final keep = container.listen(syncProvider, (_, __) {});
      addTearDown(keep.close);

      await container.read(sessionProvider.future);
      final first = (await container.read(workspaceProvider.future))!;
      // Sinkron awal (offline) selesai: tidak ada lagi yang menahan database.
      await waitFor(() => container.read(syncProvider).connection == ConnectionStatus.offline, reason: 'sinkron awal selesai');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await seedMaster(first.local);
      container.read(dataVersionProvider.notifier).state++;
      final service = (await container.read(posServiceProvider.future))!;
      final held = HeldOrderStore(first.local);
      final cart = const Cart().copyWith(lines: [CartLine.fromProduct('l-1', kopi)]);

      // Bayar dimulai, lalu perusahaan diganti (403 / pilih perusahaan lain)
      // sebelum penyimpanan selesai.
      final sale = service.checkout(clientUuid: 'sale-1', cart: cart, payment: const PaymentInput(mode: PayMode.cash));
      final order = held.save(cart, name: 'Meja 3', total: '18000');
      // Workspace diganti seketika (seperti 403 dropTenant / buka ulang):
      // onDispose langsung meminta database lama ditutup.
      container.invalidate(workspaceProvider);
      container.read(workspaceProvider);
      expect(first.disposed, isTrue);
      await container.read(sessionProvider.notifier).selectTenant(2);
      final second = await container.read(workspaceProvider.future);
      expect(second!.tenant.id, 2);

      expect((await sale)['number'], 'POS-K1/000001');
      expect(await order, isNotEmpty);
      await waitFor(() => !first.local.db.isOpen, reason: 'database lama ditutup setelah penjualan tersimpan');

      // Layar lama yang masih memegang database lama: pesan biasa, bukan database_closed.
      await expectLater(
        service.checkout(clientUuid: 'sale-2', cart: cart, payment: const PaymentInput(mode: PayMode.cash)),
        throwsA(isA<LocalDbClosedException>().having((error) => error.toString(), 'pesan', allOf(contains('dimuat ulang'), isNot(contains('database'))))),
      );
      await expectLater(held.save(cart, name: 'Meja 4', total: '18000'), throwsA(isA<LocalDbClosedException>()));
      await expectLater(held.delete('x'), throwsA(isA<LocalDbClosedException>()));

      // Penjualan & pesanan tetap ada di file perusahaan lama (terkirim nanti).
      final reopened = await openFile(LocalDb.fileName(1, 1));
      addTearDown(reopened.close);
      expect(await OutboxStore(reopened).pendingCount(), 1);
      expect(await HeldOrderStore(reopened).count(), 1);
    });

    test('aplikasi di belakang layar: pemicu otomatis berhenti (sinkron latar yang bekerja, tidak ada dua penulis database)', () async {
      expect(SyncController.autoSyncAllowed(null), isTrue);
      expect(SyncController.autoSyncAllowed(AppLifecycleState.resumed), isTrue);
      expect(SyncController.autoSyncAllowed(AppLifecycleState.paused), isFalse);
      expect(SyncController.autoSyncAllowed(AppLifecycleState.hidden), isFalse);
      expect(SyncController.autoSyncAllowed(AppLifecycleState.detached), isFalse);

      final storage = await storageWith();
      final server = FakeServer(okHandler);
      final network = StreamController<List<ConnectivityResult>>.broadcast();
      addTearDown(network.close);
      final binding = TestWidgetsFlutterBinding.instance;
      addTearDown(() => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final container = ProviderContainer(overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue(openFile),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(network.stream),
      ]);
      addTearDown(container.dispose);
      final keep = container.listen(syncProvider, (_, __) {});
      addTearDown(keep.close);
      await container.read(sessionProvider.future);
      final workspace = await container.read(workspaceProvider.future);
      addTearDown(() => workspace!.local.close());
      await waitFor(() => container.read(syncProvider).lastSyncAt != null, reason: 'sinkron awal selesai');

      await waitFor(() => !container.read(syncProvider).syncing, reason: 'siklus awal selesai');
      // Setiap siklus sinkron dimulai dengan ping.
      int pings() => server.requests.where((request) => request.path == 'ping').length;

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final before = pings();
      network.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(pings(), before, reason: 'Di belakang layar tidak ada sinkron otomatis dari aplikasi.');

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      network.add([ConnectivityResult.wifi]);
      await waitFor(() => pings() > before, reason: 'tampil lagi: sinkron otomatis jalan');
    });

    test('keluar saat sinkron berjalan: layar Masuk, database ditutup setelah siklus', () async {
      final storage = await storageWith();
      final gate = Completer<void>();
      final server = GatedServer(okHandler)..hold((options) => options.path == 'sync/pull', gate);
      final deleted = <int>[];
      final original = SessionController.deleteLocalData;
      SessionController.deleteLocalData = (userId) async => deleted.add(userId);
      addTearDown(() => SessionController.deleteLocalData = original);
      final container = containerFor(storage, server);
      final keep = container.listen(syncProvider, (_, __) {});
      addTearDown(keep.close);

      await container.read(sessionProvider.future);
      final workspace = await container.read(workspaceProvider.future);
      await waitFor(() => container.read(syncProvider).syncing, reason: 'sinkron tertahan di sync/pull');

      await container.read(sessionProvider.notifier).logout();
      expect(container.read(sessionProvider).value!.loggedIn, isFalse);
      expect(await container.read(workspaceProvider.future), isNull);
      expect(deleted, [1]);
      expect(workspace!.local.db.isOpen, isTrue);

      gate.complete();
      await waitFor(() => !workspace.local.db.isOpen, reason: 'database ditutup setelah siklus');
      expect(container.read(syncProvider).message ?? '', isNot(contains('database_closed')));
    });
  });
}
