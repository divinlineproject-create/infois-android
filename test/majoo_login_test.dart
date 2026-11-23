import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/device_info.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/kasir_screen.dart';
import 'package:infois/ui/screens/lock_screen.dart' show pinMissingNote;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Login perangkat seperti Majoo: login penuh hanya akun pemilik, lalu layar
/// PIN "Pilih Karyawan" selalu tampil (pemilik juga); model perangkat
/// dikirim otomatis (tanpa isian "Nama HP ini").
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });
  setUp(() => ApiClient.deviceModel = 'Samsung SM-A155F');
  tearDown(() => ApiClient.deviceModel = null);

  test('model perangkat: pabrikan + model dengan huruf besar wajar', () {
    expect(formatDeviceModel('samsung', 'SM-A155F'), 'Samsung SM-A155F');
    expect(formatDeviceModel('SUNMI', 'V2'), 'SUNMI V2');
    expect(formatDeviceModel('Google', 'Pixel 7'), 'Google Pixel 7');
    expect(formatDeviceModel('Xiaomi', 'Xiaomi 13T'), 'Xiaomi 13T', reason: 'Nama pabrikan tidak diulang.');
    expect(formatDeviceModel('xiaomi', '2201117TG'), 'Xiaomi 2201117TG');
    expect(formatDeviceModel('', 'V2s'), 'V2s');
    expect(formatDeviceModel(null, null), isNull);
  });

  test('header X-Device-Model di setiap request; tanpa model = tanpa header', () async {
    final server = FakeServer((_, __) => {'ok': true});
    await fakeApi(server).get('ping');
    expect(server.requests.single.headers['X-Device-Model'], 'Samsung SM-A155F');
    ApiClient.deviceModel = null;
    await fakeApi(server).get('ping');
    expect(server.requests.last.headers.containsKey('X-Device-Model'), isFalse);
  });

  test('daftar PIN: has_pin dibaca; server lama tanpa has_pin = punya PIN; role selain owner tidak boleh login perangkat', () {
    expect(PinUser.fromJson({'id': 3, 'name': 'Budi', 'has_pin': false}).hasPin, isFalse);
    expect(PinUser.fromJson({'id': 2, 'name': 'Rina'}).hasPin, isTrue);
    expect(TenantSummary.fromJson({'id': 1, 'name': 'A', 'role': 'owner'}).deviceLoginBlocked, isFalse);
    expect(TenantSummary.fromJson({'id': 1, 'name': 'A', 'role': 'cashier'}).deviceLoginBlocked, isTrue);
    expect(TenantSummary.fromJson({'id': 1, 'name': 'A'}).deviceLoginBlocked, isFalse, reason: 'Server lama tanpa role: tidak dibatasi.');
  });

  group('aplikasi', () {
    late List<RequestOptions> requests;
    late Map<String, dynamic>? loginBody;

    Map<String, dynamic> tenant(int id, String name, {String? role = 'owner', bool hasPin = true}) => {
          'id': id,
          'slug': 'usaha-$id',
          'name': name,
          if (role != null) 'role': role,
          'role_label': role == 'owner' ? 'Pemilik' : 'Kasir',
          'has_pin': hasPin,
          'menus': {'pos': true},
          'permissions': [],
        };

    Future<ProviderContainer> pumpApp(
      WidgetTester tester, {
      required Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) handler,
      bool loggedIn = false,
    }) async {
      requests = [];
      loginBody = null;
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        if (loggedIn)
          'session': jsonEncode({
            'user': {'id': 1, 'name': 'Sari Pemilik', 'email': 'sari@tes.id'},
            'tenants': [const TenantSummary(id: 1, name: 'Kafe Sift', roleLabel: 'Kasir', menus: Menus(pos: true)).toJson()],
          }),
        if (loggedIn) 'tenant_id': 1,
      });
      FlutterSecureStorage.setMockInitialValues({'device_uid': 'hp-tes', if (loggedIn) 'auth_token': 'token-lama'});
      final storage = await AppStorage.load();
      final local = (await tester.runAsync(() async {
        final db = await memoryDb();
        await seedMaster(db, menus: {'pos': true});
        return db;
      }))!;
      final server = FakeServer((options, body) {
        requests.add(options);
        if (options.path == 'auth/login') {
          loginBody = body;
        }
        return handler(options, body);
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          localDbOpenerProvider.overrideWithValue((_) async => local),
          apiFactoryProvider.overrideWithValue((_, token, tenantId, ____) {
            final dio = Dio(BaseOptions(baseUrl: 'http://tes/api/v1/'));
            dio.httpClientAdapter = server;
            return ApiClient(baseUrl: 'http://tes', token: token, tenantId: tenantId, dio: dio);
          }),
          connectivityStreamProvider.overrideWithValue(const Stream.empty()),
          printerTransportProvider.overrideWithValue(FakePrinter()),
        ],
        child: const InfoisApp(),
      ));
      await flush(tester);
      return ProviderScope.containerOf(tester.element(find.byType(InfoisApp)));
    }

    Future<void> submitLogin(WidgetTester tester) async {
      await tester.enterText(find.byKey(const Key('login-email')), 'sari@tes.id');
      await tester.enterText(find.byKey(const Key('login-password')), 'rahasia');
      await tester.tap(find.byKey(const Key('login-submit')));
      await flush(tester);
    }

    Future<void> typePin(WidgetTester tester, String pin) async {
      for (final digit in pin.split('')) {
        await tester.ensureVisible(find.byKey(Key('pin-key-$digit')));
        await tester.pump();
        await tester.tap(find.byKey(Key('pin-key-$digit')));
        await tester.pump();
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await flush(tester);
    }

    Map<String, dynamic>? owner(RequestOptions options, Map<String, dynamic>? body, {required bool hasPin, List<Map<String, dynamic>>? tenants}) => switch (options.path) {
          'auth/login' => {
              'token': 'token-pemilik',
              'user': {'id': 1, 'name': 'Sari Pemilik', 'email': 'sari@tes.id'},
              'tenants': tenants ?? [tenant(1, 'Kafe Sift', hasPin: hasPin)],
            },
          'pin/users' => {
              'users': [
                {'id': 1, 'name': 'Sari Pemilik', 'role': 'owner', 'role_label': 'Pemilik', 'has_pin': hasPin},
                {'id': 2, 'name': 'Rina Kasir', 'role': 'cashier', 'role_label': 'Kasir', 'has_pin': true},
                {'id': 3, 'name': 'Budi Baru', 'role': 'cashier', 'role_label': 'Kasir', 'has_pin': false},
              ],
              'has_pin': hasPin,
              'pin_length': 6,
            },
          'pin/unlock' => body?['pin'] == '271828' ? {'token': null, 'pin_session': true} : {'_status': 422, 'code': 'pin_salah', 'message': 'PIN salah.'},
          'auth/logout' => {},
          _ => null,
        };

    testWidgets('pemilik masuk → layar PIN wajib "Pilih Karyawan"; anggota tanpa PIN redup; pemilik buka dengan PIN', (tester) async {
      final container = await pumpApp(tester, handler: (options, body) => owner(options, body, hasPin: true));
      expect(find.byKey(const Key('login-device-name')), findsNothing);
      expect(find.text('Nama HP ini'), findsNothing);
      await submitLogin(tester);

      expect(loginBody?['device_name'], 'Samsung SM-A155F', reason: 'Model perangkat untuk server lama.');
      expect(requests.firstWhere((options) => options.path == 'auth/login').headers['X-Device-Model'], 'Samsung SM-A155F');
      expect(find.text('Pilih Karyawan'), findsOneWidget);
      expect(container.read(sessionProvider).value!.locked, isTrue);
      expect(requests.firstWhere((options) => options.path == 'pin/users').queryParameters['include_without_pin'], '1');
      expect(find.text('Rina Kasir'), findsOneWidget);
      expect(find.text('Budi Baru'), findsOneWidget);
      expect(find.byKey(const Key('lock-user-nopin-3')), findsOneWidget);
      expect(find.text(pinMissingNote), findsOneWidget);
      expect(pinMissingNote, 'PIN belum dibuat. Pemilik bisa membuatnya di web (Tim & Akses).');

      // Belum punya PIN: tidak bisa dipilih.
      await tester.tap(find.byKey(const Key('lock-user-3')));
      await flush(tester);
      expect(find.byKey(const Key('lock-selected-name')), findsNothing);

      await tester.tap(find.byKey(const Key('lock-user-1')));
      await flush(tester);
      expect(find.byKey(const Key('lock-selected-name')), findsOneWidget);
      await typePin(tester, '271828');
      final session = container.read(sessionProvider).value!;
      expect((session.locked, session.user!.id, session.isOperator), (false, 1, false));
      expect(find.byType(KasirScreen), findsOneWidget);

      // Kunci PIN otomatis (bukan pilihan) dan "Ganti pengguna" tetap ada.
      final storage = container.read(storageProvider);
      expect((storage.pinRequired, storage.pinLockActive, storage.pinLock), (true, true, false));
      expect(find.byKey(const Key('shell-lock')), findsOneWidget);
      container.read(sessionProvider.notifier).lock();
      await flush(tester);
      expect(find.text('Pilih Karyawan'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pemilik belum punya PIN: "Buat PIN 6 angka untuk Anda" (PUT /pin) lalu layar PIN', (tester) async {
      var created = false;
      Map<String, dynamic>? putBody;
      await pumpApp(tester, handler: (options, body) {
        if (options.path == 'pin' && options.method == 'PUT') {
          putBody = body;
          created = true;
          return {'ok': true};
        }
        return owner(options, body, hasPin: created);
      });
      await submitLogin(tester);
      expect(find.text('Buat PIN 6 angka untuk Anda'), findsOneWidget);
      expect(find.text('Pilih Karyawan'), findsNothing);

      await typePin(tester, '271828');
      expect(find.text('Ketik sekali lagi PIN baru'), findsOneWidget);
      await typePin(tester, '271828');
      expect(putBody, {'pin': '271828'});
      expect(find.text('Pilih Karyawan'), findsOneWidget);
      expect(find.byKey(const Key('lock-user-nopin-1')), findsNothing, reason: 'PIN pemilik sudah dibuat.');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('akun bukan pemilik: login perangkat ditolak di aplikasi dengan pesan, token dicabut', (tester) async {
      final container = await pumpApp(tester, handler: (options, body) => owner(options, body, hasPin: true, tenants: [tenant(1, 'Kafe Sift', role: 'cashier')]));
      await submitLogin(tester);
      expect(find.text(ownerOnlyDeviceMessage), findsOneWidget);
      expect(ownerOnlyDeviceMessage, 'Perangkat kasir hanya bisa diaktifkan dengan akun pemilik (super admin). Minta pemilik masuk di perangkat ini, lalu masuk dengan PIN Anda.');
      expect(container.read(sessionProvider).value!.loggedIn, isFalse);
      expect(requests.where((options) => options.path == 'auth/logout'), hasLength(1));
      expect(await container.read(storageProvider).token(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pemilik di satu usaha, kasir di usaha lain: usaha sebagai kasir ditolak, usaha sebagai pemilik → layar PIN', (tester) async {
      final container = await pumpApp(tester, handler: (options, body) => owner(options, body, hasPin: true, tenants: [tenant(1, 'Kafe Sift'), tenant(2, 'Toko Lain', role: 'cashier')]));
      await submitLogin(tester);
      expect(find.text('Pilih perusahaan'), findsOneWidget);
      await tester.tap(find.text('Toko Lain'));
      await flush(tester);
      expect(find.text(ownerOnlyDeviceMessage), findsOneWidget);
      expect(container.read(sessionProvider).value!.tenantId, isNull);

      await tester.tap(find.text('Kafe Sift'));
      await flush(tester);
      expect(container.read(sessionProvider).value!.tenantId, 1);
      expect(find.text('Pilih Karyawan'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('server menolak perangkat (403 perangkat_khusus_pemilik) → kembali ke Masuk dengan pesannya', (tester) async {
      const message = 'Perangkat kasir baru hanya bisa didaftarkan oleh pemilik usaha.';
      final container = await pumpApp(
        tester,
        loggedIn: true,
        handler: (options, body) => options.path == 'ping' ? {'_status': 403, 'code': 'perangkat_khusus_pemilik', 'message': message} : null,
      );
      await container.read(syncProvider.notifier).syncNow();
      await flush(tester);
      expect(container.read(sessionProvider).value!.loggedIn, isFalse);
      expect(find.byKey(const Key('login-submit')), findsOneWidget);
      expect(find.text(message), findsOneWidget);
      expect(find.text('Perangkat kasir khusus pemilik'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('server lama tanpa role: langsung ke kasir seperti dulu (tanpa layar PIN wajib)', (tester) async {
      final container = await pumpApp(tester, handler: (options, body) => owner(options, body, hasPin: true, tenants: [tenant(1, 'Kafe Sift', role: null)]));
      await submitLogin(tester);
      expect(container.read(sessionProvider).value!.locked, isFalse);
      expect(find.byType(KasirScreen), findsOneWidget);
      expect(container.read(storageProvider).pinRequired, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Pump beberapa frame dan beri waktu nyata untuk request & database.
Future<void> flush(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    for (var j = 0; j < 6; j++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}
