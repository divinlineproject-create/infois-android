import 'dart:convert';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';

/// Kontrak "Tolak total": aplikasi HP hanya untuk perusahaan dengan paket
/// berbayar aktif yang termasuk aplikasi HP.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  const deniedMessage = 'Aplikasi HP Infois hanya untuk perusahaan dengan paket berbayar yang aktif dan termasuk aplikasi HP. '
      'PT Kopi Senja masih masa trial. Kelola paket lewat website: dashboard.infois.ai › Langganan.';

  Map<String, dynamic> deniedLogin() => {
        '_status': 403,
        'code': 'akses_hp_tidak_tersedia',
        'message': deniedMessage,
        'tenants': [
          {'id': 1, 'slug': 'kopi-senja', 'name': 'PT Kopi Senja', 'reason': 'trial', 'unlock_plan': 'Starter'},
          {'id': 2, 'name': 'CV Roti Pagi', 'reason': 'paket_tanpa_hp', 'unlock_plan': 'Starter'},
        ],
      };

  late FakeFilePlatform files;
  setUp(() {
    mockClipboard();
    files = FakeFilePlatform();
  });

  Future<AppStorage> pumpApp(WidgetTester tester, {required FakeServer server, List<TenantSummary>? tenants, bool loggedIn = true}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final list = tenants ?? const [TenantSummary(id: 1, name: 'PT Kopi Senja', menus: Menus(pos: true), permissions: [])];
    SharedPreferences.setMockInitialValues({
      if (loggedIn)
        'session': jsonEncode({
          'user': {'id': 1, 'name': 'Rani', 'email': 'rani@kopisenja.example'},
          'tenants': [for (final tenant in list) tenant.toJson()],
        }),
      if (loggedIn) 'tenant_id': list.first.id,
    });
    FlutterSecureStorage.setMockInitialValues({if (loggedIn) 'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: {'pos': true});
      return db;
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local!),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(FakePrinter()),
        filePlatformProvider.overrideWithValue(files),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    return storage;
  }

  Future<void> submitLogin(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('login-email')), 'rani@kopisenja.example');
    await tester.enterText(find.byKey(const Key('login-password')), 'KopiSenja#2026');
    await tester.tap(find.byKey(const Key('login-submit')));
    await settle(tester);
  }

  testWidgets('masuk ditolak (403 akses_hp_tidak_tersedia): pesan + alasan per perusahaan + Lihat paket, tanpa token', (tester) async {
    final server = FakeServer((options, _) => options.path == 'auth/login' ? deniedLogin() : null);
    final storage = await pumpApp(tester, server: server, loggedIn: false);
    await submitLogin(tester);

    expect(find.text('Masuk ke Infois'), findsOneWidget);
    expect(find.byKey(const Key('access-notice')), findsOneWidget);
    expect(find.textContaining('masih masa trial'), findsWidgets);
    expect(find.text('• PT Kopi Senja: masih masa trial.'), findsOneWidget);
    expect(find.text('• CV Roti Pagi: paketnya belum termasuk aplikasi HP (mulai paket Starter).'), findsOneWidget);
    expect(await storage.token(), isNull);
    expect(storage.session(), isNull);

    await tester.tap(find.byKey(const Key('access-notice-plans')));
    await settle(tester);
    final base = storage.serverUrl.replaceAll(RegExp(r'/+$'), '');
    // Halaman Langganan selalu per perusahaan (/app/langganan = 404 di web).
    expect(files.urls.single.toString(), '$base/app/kopi-senja/langganan');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('masuk: perusahaan dengan mobile_eligible false tidak ditawarkan', (tester) async {
    final server = FakeServer((options, _) => switch (options.path) {
          'auth/login' => {
              'token': 'token-baru',
              'user': {'id': 1, 'name': 'Rani', 'email': 'rani@kopisenja.example'},
              'tenants': [
                {'id': 1, 'name': 'PT Kopi Senja', 'mobile_eligible': true, 'menus': {'pos': true}},
                {'id': 2, 'name': 'CV Roti Pagi', 'mobile_eligible': false, 'menus': {'pos': true}},
              ],
            },
          _ => null,
        });
    await pumpApp(tester, server: server, loggedIn: false);
    await submitLogin(tester);

    final container = ProviderScope.containerOf(tester.element(find.byType(InfoisApp)));
    final session = container.read(sessionProvider).value!;
    expect(session.tenants.map((tenant) => tenant.name), ['PT Kopi Senja']);
    expect(session.tenantId, 1, reason: 'Satu perusahaan yang boleh: langsung dipilih.');
    expect(find.text('Pilih perusahaan'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saat dipakai: 403 akses_hp_tidak_tersedia → perusahaan dilepas, ke Pilih perusahaan dengan pesan', (tester) async {
    Map<String, dynamic>? handler(RequestOptions options, Map<String, dynamic>? body) {
      if (options.path == 'ping') {
        return {'ok': true, 'min_app_version': '1.0.0'};
      }
      if (options.path == 'me') {
        // GET /me ikut menyaring perusahaan yang tidak boleh memakai aplikasi HP.
        return {
          'user': {'id': 1, 'name': 'Rani', 'email': 'rani@kopisenja.example'},
          'tenants': [
            {'id': 2, 'name': 'CV Roti Pagi', 'mobile_eligible': true, 'menus': {'pos': true}, 'permissions': []},
          ],
        };
      }
      if (options.path.startsWith('sync/')) {
        return {'_status': 403, 'code': 'akses_hp_tidak_tersedia', 'message': 'Paket PT Kopi Senja belum termasuk aplikasi HP. Kelola paket lewat website: dashboard.infois.ai › Langganan.'};
      }
      return null;
    }

    final storage = await pumpApp(
      tester,
      server: FakeServer(handler),
      tenants: const [
        TenantSummary(id: 1, slug: 'kopi-senja', name: 'PT Kopi Senja', menus: Menus(pos: true), permissions: []),
        TenantSummary(id: 2, slug: 'roti-pagi', name: 'CV Roti Pagi', menus: Menus(pos: true), permissions: []),
      ],
    );

    expect(find.text('Pilih perusahaan'), findsOneWidget);
    expect(find.byKey(const Key('access-notice')), findsOneWidget);
    expect(find.textContaining('belum termasuk aplikasi HP'), findsWidgets);
    expect(find.text('CV Roti Pagi'), findsOneWidget);
    expect(find.text('PT Kopi Senja'), findsNothing, reason: 'Perusahaan yang ditolak hilang dari daftar.');
    expect(storage.session()!.tenants.map((tenant) => tenant.id), [2]);
    expect(storage.tenantId, isNull);
    expect(await storage.token(), 'token-tes', reason: 'Masih bisa memakai perusahaan lain.');

    await tester.tap(find.byKey(const Key('access-notice-plans')));
    await settle(tester);
    expect(files.urls.single.path, '/app/kopi-senja/langganan', reason: 'Langganan perusahaan yang ditolak (slug dari daftar perusahaan di HP).');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saat dipakai, satu-satunya perusahaan ditolak → layar Masuk dengan pesan', (tester) async {
    final server = FakeServer((options, _) => options.path == 'ping'
        ? {'ok': true, 'min_app_version': '1.0.0'}
        : {'_status': 403, 'code': 'akses_hp_tidak_tersedia', 'message': 'PT Kopi Senja masih masa trial. Kelola paket lewat website: dashboard.infois.ai › Langganan.'});
    final storage = await pumpApp(tester, server: server);

    expect(find.text('Masuk ke Infois'), findsOneWidget);
    expect(find.byKey(const Key('access-notice')), findsOneWidget);
    expect(find.textContaining('masih masa trial'), findsOneWidget);
    expect(await storage.token(), isNull);
    expect(server.requests.where((request) => request.path == 'auth/logout'), hasLength(1), reason: 'Token HP dicabut di server.');

    // Pesan bisa ditutup.
    await tester.tap(find.byTooltip('Tutup'));
    await settle(tester);
    expect(find.byKey(const Key('access-notice')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('GET /me 403 akses_hp_tidak_tersedia: login dilupakan DAN token HP dicabut di server', () async {
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Rani', 'email': 'rani@kopisenja.example'},
        'tenants': [const TenantSummary(id: 1, name: 'PT Kopi Senja', menus: Menus(pos: true)).toJson()],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final server = FakeServer((options, _) => switch (options.path) {
          'me' => {'_status': 403, 'code': 'akses_hp_tidak_tersedia', 'message': deniedMessage, 'tenants': []},
          'auth/logout' => {'message': 'ok'},
          _ => null,
        });
    final tokens = <String?>[];
    final container = ProviderContainer(overrides: [
      storageProvider.overrideWithValue(storage),
      apiFactoryProvider.overrideWithValue((_, token, __, ___) {
        tokens.add(token);
        return fakeApi(server);
      }),
    ]);
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);

    await container.read(sessionProvider.notifier).refreshMe();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(sessionProvider).value!.loggedIn, isFalse);
    expect(container.read(sessionProvider).value!.notice?.message, deniedMessage);
    expect(await storage.token(), isNull);
    expect(server.requests.map((request) => request.path), containsAllInOrder(['me', 'auth/logout']));
    expect(tokens.last, 'token-tes', reason: 'Token lama dicabut supaya HP tidak tetap terdaftar aktif di Tim & Akses.');
  });

  test('alamat web per perusahaan: /app/{slug}/langganan, cadangan /app', () {
    expect(billingPath('kopi-senja'), '/app/kopi-senja/langganan');
    expect(billingPath(null), '/app');
    expect(tenantWebPath('kopi-senja'), '/app/kopi-senja');
    expect(tenantWebPath(''), '/app');
    final notice = AccessNotice.fromError(
      const ApiException('x', code: 'akses_hp_tidak_tersedia', status: 403, data: {
        'tenants': [
          {'id': 1, 'name': 'A', 'reason': 'trial'},
          {'id': 2, 'slug': 'warung-b', 'name': 'B', 'reason': 'trial'},
        ],
      }),
    );
    expect(notice.billingSlug, 'warung-b');
  });

  test('AccessNotice: alasan dalam bahasa sehari-hari, cadangan untuk langganan_tidak_aktif', () {
    const error = ApiException('Langganan sudah berakhir.', code: 'langganan_tidak_aktif', status: 403);
    expect(error.mobileAccessDenied, isTrue);
    final notice = AccessNotice.fromError(error, fallbackTenant: 'PT Kopi Senja');
    expect(notice.message, 'Langganan sudah berakhir.');
    expect(notice.tenants.single.reasonLabel, 'langganannya sudah berakhir atau dihentikan');
    expect(const DeniedTenant(name: 'X', reason: 'tanpa_paket').reasonLabel, 'belum memilih paket berbayar');
    expect(const ApiException('x', code: 'akses_hp_tidak_tersedia', status: 422).mobileAccessDenied, isFalse);
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
