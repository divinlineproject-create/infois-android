import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/core/store_policy.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/akun_screen.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';
import 'support/play_policy.dart';

/// Akun: tombol Keluar (online, offline, 401, database tertutup, transaksi
/// belum terkirim), Tampilan terang/gelap, dan Buka Infois di web.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  late List<int> deleted;
  late FakeFilePlatform files;
  final originalDelete = SessionController.deleteLocalData;
  final originalUnsent = SessionController.unsentElsewhere;
  final originalHeld = SessionController.heldElsewhere;

  setUp(() {
    mockClipboard();
    deleted = [];
    files = FakeFilePlatform();
    SessionController.deleteLocalData = (userId) async => deleted.add(userId);
    SessionController.unsentElsewhere = (userId, {exceptTenantId}) async => 0;
    SessionController.heldElsewhere = (userId, {exceptTenantId}) async => 0;
  });
  tearDown(() {
    SessionController.deleteLocalData = originalDelete;
    SessionController.unsentElsewhere = originalUnsent;
    SessionController.heldElsewhere = originalHeld;
  });

  Future<(AppStorage, LocalDb)> pumpApp(WidgetTester tester, {required FakeServer server, Map<String, Object> prefs = const {}, Future<void> Function(LocalDb local)? prepare}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [const TenantSummary(id: 1, slug: 'warung-tes', name: 'Warung Tes', roleLabel: 'Pemilik', menus: Menus(pos: true, shift: true), permissions: []).toJson()],
      }),
      'tenant_id': 1,
      ...prefs,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = (await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: {'pos': true, 'shift': true});
      await prepare?.call(db);
      return db;
    }))!;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(FakePrinter()),
        filePlatformProvider.overrideWithValue(files),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    return (storage, local);
  }

  Future<void> openAkun(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(NavigationDestination, 'Akun'));
    await settle(tester);
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.descendant(of: find.byType(AkunScreen), matching: find.byType(Scrollable)).first);
    await tester.pump();
  }

  Future<void> tapLogout(WidgetTester tester) async {
    await reveal(tester, find.byKey(const Key('akun-logout')));
    await tester.tap(find.byKey(const Key('akun-logout')));
    await settle(tester);
  }

  bool onLogin() => find.text('Masuk ke Infois').evaluate().isNotEmpty;

  group('Keluar', () {
    testWidgets('online: token dicabut, data HP dihapus, kembali ke layar Masuk', (tester) async {
      final server = FakeServer((options, _) => options.path == 'auth/logout' ? {'message': 'ok'} : null);
      final (storage, _) = await pumpApp(tester, server: server);
      await openAkun(tester);
      await tapLogout(tester);

      expect(find.byKey(const Key('logout-dialog')), findsOneWidget);
      expect(find.text('Keluar dari aplikasi?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('logout-confirm')));
      await settle(tester);

      expect(onLogin(), isTrue);
      expect(server.requests.where((request) => request.path == 'auth/logout'), hasLength(1));
      expect(deleted, [1]);
      expect(await storage.token(), isNull);
      expect(storage.session(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('offline: tetap keluar ke layar Masuk', (tester) async {
      final server = offlineServer();
      final (storage, _) = await pumpApp(tester, server: server);
      await openAkun(tester);
      await tapLogout(tester);
      await tester.tap(find.byKey(const Key('logout-confirm')));
      await settle(tester);

      expect(onLogin(), isTrue);
      expect(deleted, [1]);
      expect(await storage.token(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('server menjawab 401 (token sudah dicabut): tetap keluar ke layar Masuk', (tester) async {
      final server = FakeServer((options, _) => options.path == 'auth/logout' ? {'_status': 401, 'message': 'Unauthenticated.'} : null);
      await pumpApp(tester, server: server);
      await openAkun(tester);
      await tapLogout(tester);
      await tester.tap(find.byKey(const Key('logout-confirm')));
      await settle(tester);

      expect(onLogin(), isTrue);
      expect(deleted, [1]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('database HP sudah tertutup (bug database_closed): tombol Keluar tetap bekerja', (tester) async {
      final (_, local) = await pumpApp(tester, server: offlineServer());
      await openAkun(tester);
      // Meniru koneksi yang ditutup tugas latar: dulu pendingCount() melempar
      // DatabaseException dan dialog Keluar tidak pernah muncul.
      await tester.runAsync(() => local.db.close());
      await tapLogout(tester);

      expect(find.byKey(const Key('logout-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('logout-confirm')));
      await settle(tester);
      expect(onLogin(), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('ada transaksi belum terkirim: peringatan, Sinkron dulu (offline → tetap masuk), lalu Tetap keluar', (tester) async {
      await pumpApp(
        tester,
        server: offlineServer(),
        prepare: (local) => OutboxStore(local).enqueue('sale', 'jual-1', {'client_uuid': 'jual-1', 'number': 'POS-K1/000001'}),
      );
      await openAkun(tester);
      await tapLogout(tester);

      expect(find.text('Transaksi belum terkirim'), findsOneWidget);
      expect(find.textContaining('Ada 1 transaksi belum terkirim'), findsOneWidget);
      await tester.tap(find.byKey(const Key('logout-sync-first')));
      await settle(tester);
      expect(onLogin(), isFalse, reason: 'Sinkron dulu tidak mengeluarkan pengguna.');
      expect(find.textContaining('1 transaksi belum terkirim'), findsOneWidget);
      // Tunggu pesan hilang (pesan mengambang menutupi tombol Keluar).
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);

      await tapLogout(tester);
      await tester.tap(find.byKey(const Key('logout-anyway')));
      await settle(tester);
      expect(onLogin(), isTrue);
      expect(deleted, [1]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('ada transaksi belum terkirim: Sinkron dulu berhasil → konfirmasi Keluar biasa', (tester) async {
      Map<String, dynamic>? handler(RequestOptions options, Map<String, dynamic>? body) => switch (options.path) {
            'ping' => {'ok': true, 'min_app_version': '1.0.0'},
            'sync/push' => {
                'results': [
                  for (final item in body?['items'] as List? ?? const []) {'client_uuid': (item as Map)['client_uuid'], 'type': item['type'], 'status': 'ok', 'number': 'POS-K1/000001'},
                ],
              },
            'auth/logout' => {'message': 'ok'},
            _ => null,
          };
      // Sinkron otomatis saat aplikasi dibuka gagal tarik data (offline untuk
      // sync/pull): outbox tetap terkirim lebih dulu.
      await pumpApp(
        tester,
        server: FakeServer(handler),
        prepare: (local) => OutboxStore(local).enqueue('customer', 'pel-1', {'client_uuid': 'pel-1', 'name': 'Bu Ani'}),
      );
      // Isi ulang outbox setelah sinkron awal supaya peringatan muncul.
      final container = ProviderScope.containerOf(tester.element(find.byType(InfoisApp)));
      final workspace = container.read(workspaceProvider).value!;
      await tester.runAsync(() => workspace.outbox.enqueue('customer', 'pel-2', {'client_uuid': 'pel-2', 'name': 'Pak Budi'}));
      await openAkun(tester);
      await tapLogout(tester);
      expect(find.textContaining('Ada 1 transaksi belum terkirim'), findsOneWidget);

      await tester.tap(find.byKey(const Key('logout-sync-first')));
      await settle(tester);
      await settle(tester);
      expect(find.text('Keluar dari aplikasi?'), findsOneWidget, reason: 'Semua terkirim: tinggal konfirmasi keluar.');
      await tester.tap(find.byKey(const Key('logout-confirm')));
      await settle(tester);
      expect(onLogin(), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('ada pesanan tersimpan (belum dibayar): peringatan pesanan hilang, bukan "semua sudah di server"', (tester) async {
      await pumpApp(
        tester,
        server: offlineServer(),
        prepare: (local) => HeldOrderStore(local).save(const Cart().copyWith(lines: [CartLine.fromProduct('l-1', kopi)]), name: 'Meja 3', total: '18000'),
      );
      await openAkun(tester);
      await tapLogout(tester);

      expect(find.text('Pesanan tersimpan belum dibayar'), findsOneWidget);
      expect(find.textContaining('Ada 1 pesanan tersimpan yang belum dibayar'), findsOneWidget);
      expect(find.textContaining('Semua transaksi sudah tersimpan di server'), findsNothing);
      expect(find.byKey(const Key('logout-sync-first')), findsNothing, reason: 'Pesanan tersimpan tidak terkirim lewat sinkron.');
      await tester.tap(find.text('Batal'));
      await settle(tester);
      expect(onLogin(), isFalse);

      await tapLogout(tester);
      await tester.tap(find.byKey(const Key('logout-anyway')));
      await settle(tester);
      expect(onLogin(), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pesanan tersimpan di perusahaan lain ikut diperingatkan (Akun dan Pilih perusahaan)', (tester) async {
      SessionController.heldElsewhere = (userId, {exceptTenantId}) async => 2;
      await pumpApp(tester, server: offlineServer(), prefs: {'tenant_id': 0});
      expect(find.text('Pilih perusahaan'), findsOneWidget);
      await tester.tap(find.byKey(const Key('picker-logout')));
      await settle(tester);
      expect(find.text('Pesanan tersimpan belum dibayar'), findsOneWidget);
      expect(find.textContaining('Ada 2 pesanan tersimpan'), findsOneWidget);
      await tester.tap(find.byKey(const Key('logout-anyway')));
      await settle(tester);
      expect(onLogin(), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Keluar diketuk dua kali dengan cepat: hanya satu dialog', (tester) async {
      final gate = Completer<int>();
      SessionController.unsentElsewhere = (userId, {exceptTenantId}) => gate.future;
      await pumpApp(tester, server: offlineServer());
      await openAkun(tester);
      await reveal(tester, find.byKey(const Key('akun-logout')));
      await tester.tap(find.byKey(const Key('akun-logout')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('akun-logout')));
      await tester.pump();
      gate.complete(0);
      await settle(tester);
      expect(find.byKey(const Key('logout-dialog')), findsOneWidget);
      await tester.tap(find.text('Batal'));
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Keluar dari Pilih perusahaan diketuk dua kali: hanya satu dialog', (tester) async {
      final gate = Completer<int>();
      SessionController.unsentElsewhere = (userId, {exceptTenantId}) => gate.future;
      await pumpApp(tester, server: offlineServer(), prefs: {'tenant_id': 0});
      await tester.tap(find.byKey(const Key('picker-logout')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('picker-logout')));
      await tester.pump();
      gate.complete(0);
      await settle(tester);
      expect(find.byKey(const Key('logout-dialog')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Keluar dari Pilih perusahaan memperingatkan transaksi yang tertinggal di perusahaan lain', (tester) async {
      SessionController.unsentElsewhere = (userId, {exceptTenantId}) async => 3;
      final server = offlineServer();
      await pumpApp(tester, server: server, prefs: {'tenant_id': 0});
      expect(find.text('Pilih perusahaan'), findsOneWidget);
      await tester.tap(find.byKey(const Key('picker-logout')));
      await settle(tester);
      expect(find.textContaining('Ada 3 transaksi belum terkirim'), findsOneWidget);
      await tester.tap(find.byKey(const Key('logout-anyway')));
      await settle(tester);
      expect(onLogin(), isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('Tampilan: pilihan Gelap langsung berlaku dan tersimpan di HP', (tester) async {
    final (storage, _) = await pumpApp(tester, server: offlineServer());
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().themeMode, ThemeMode.system);

    await openAkun(tester);
    expect(find.text('Ikuti sistem'), findsOneWidget);
    await tester.tap(find.byKey(const Key('akun-theme')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('theme-dark')));
    await settle(tester);

    expect(app().themeMode, ThemeMode.dark);
    expect(Theme.of(tester.element(find.byKey(const Key('akun-theme')))).brightness, Brightness.dark);
    expect(storage.prefs.getString('theme_mode'), 'dark');
    expect(find.text('Gelap'), findsOneWidget);

    // Dibuka lagi: tetap gelap.
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, server: offlineServer(), prefs: {'theme_mode': 'dark'});
    expect(app().themeMode, ThemeMode.dark);

    await openAkun(tester);
    await tester.tap(find.byKey(const Key('akun-theme')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('theme-light')));
    await settle(tester);
    expect(app().themeMode, ThemeMode.light);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Akun (kebijakan Google Play): tanpa tautan paket/langganan/web dasbor; kebijakan privasi bisa dibuka', (tester) async {
    await pumpApp(tester, server: offlineServer());
    await openAkun(tester);
    await reveal(tester, find.byKey(const Key('akun-logout')));
    expect(find.byKey(const Key('akun-open-plan')), findsNothing);
    expect(find.byKey(const Key('akun-open-web')), findsNothing, reason: 'Dasbor web memuat menu Langganan: tidak ditautkan dari aplikasi.');
    expect(purchaseTextOnScreen(tester), isEmpty);
    expect(find.byKey(const Key('akun-web-info')), findsOneWidget);

    await tester.tap(find.byKey(const Key('akun-web-info')));
    await settle(tester);
    expect(files.urls, isEmpty, reason: 'Info web hanya teks, bukan tautan.');

    await tester.tap(find.byKey(const Key('akun-privacy')));
    await settle(tester);
    expect(files.urls.map((uri) => uri.toString()), [privacyPolicyUrl]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Hapus akun: menjelaskan yang dihapus lalu membuka halaman hapus akun di web', (tester) async {
    final (storage, _) = await pumpApp(tester, server: offlineServer());
    await openAkun(tester);
    await reveal(tester, find.byKey(const Key('akun-delete-account')));
    await tester.tap(find.byKey(const Key('akun-delete-account')));
    await settle(tester);

    expect(find.byKey(const Key('delete-account-sheet')), findsOneWidget);
    expect(find.text('Yang dihapus'), findsOneWidget);
    expect(find.text('Yang tetap disimpan'), findsOneWidget);
    expect(find.textContaining('tidak bisa dibatalkan'), findsOneWidget);
    expect(files.urls, isEmpty, reason: 'Belum dibuka sebelum pengguna menekan tombolnya.');

    // Batal: tidak membuka apa-apa.
    await tester.tap(find.text('Batal'));
    await settle(tester);
    expect(files.urls, isEmpty);

    await tester.tap(find.byKey(const Key('akun-delete-account')));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('delete-account-open')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('delete-account-open')));
    await settle(tester);
    final base = storage.serverUrl.replaceAll(RegExp(r'/+$'), '');
    expect(files.urls.map((uri) => uri.toString()), ['$base/app/hapus-akun']);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
