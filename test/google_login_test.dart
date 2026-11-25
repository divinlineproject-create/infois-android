import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/services/google_auth.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/theme.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';

/// Lembar pilih akun Google palsu: [token] = ID token yang diberikan (null =
/// pengguna menutup lembarnya), [failure] = gagal dengan pesan itu.
class FakeGoogleAuth implements GoogleAuth {
  FakeGoogleAuth({this.token = 'id-token-google', this.failure});

  final String? token;
  final String? failure;
  final List<String> clientIds = [];

  @override
  Future<String?> idToken({required String serverClientId}) async {
    clientIds.add(serverClientId);
    if (failure != null) {
      throw GoogleAuthFailure(failure!);
    }
    return token;
  }
}

/// Masuk dengan Google (API.md › Masuk dengan Google): Client ID dari
/// `GET auth/google`, ID token dikirim ke `POST auth/google`, langkah kode
/// aplikasi autentikator memakai token yang sama, dan layar pembuka/masuk
/// berlatar hijau dengan logo web.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  setUp(mockClipboard);

  final success = {
    'token': 'token-google',
    'token_type': 'Bearer',
    'user': {'id': 1, 'name': 'Rani', 'email': 'rani@gmail.com'},
    'tenants': [
      {'id': 1, 'name': 'PT Kopi Senja', 'mobile_eligible': true, 'menus': {'pos': true}},
    ],
  };

  /// Server: [enabled] = login Google aktif; [handler] = jawaban `POST
  /// auth/google` (bawaan: berhasil). Semua body POST dicatat.
  ({FakeServer server, List<Map<String, dynamic>?> posts, List<String> paths}) googleServer({bool enabled = true, Map<String, dynamic> Function(Map<String, dynamic>? body)? handler}) {
    final posts = <Map<String, dynamic>?>[];
    final paths = <String>[];
    final server = FakeServer((RequestOptions options, Map<String, dynamic>? body) {
      paths.add('${options.method} ${options.path}');
      if (options.path == 'auth/google' && options.method == 'GET') {
        return {'enabled': enabled, 'client_id': enabled ? 'web-client.apps.googleusercontent.com' : null};
      }
      if (options.path == 'auth/google') {
        posts.add(body);
        return handler?.call(body) ?? Map<String, dynamic>.from(success);
      }
      if (options.path == 'auth/login') {
        posts.add(body);
        return {'_status': 422, 'code': 'login_gagal', 'message': 'Email atau kata sandi salah.'};
      }
      return null;
    });
    return (server: server, posts: posts, paths: paths);
  }

  Future<ProviderContainer> pumpLogin(WidgetTester tester, FakeServer server, GoogleAuth google) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'device_uid': 'hp-tes'});
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
        filePlatformProvider.overrideWithValue(FakeFilePlatform()),
        googleAuthProvider.overrideWithValue(google),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(InfoisApp)));
  }

  Future<void> tapGoogle(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('login-google')));
    await tester.tap(find.byKey(const Key('login-google')));
    await settle(tester);
  }

  testWidgets('layar masuk: panel hijau dengan logo web, tombol Masuk dengan Google', (tester) async {
    final (:server, posts: _, paths: _) = googleServer();
    await pumpLogin(tester, server, FakeGoogleAuth());

    final panel = tester.widget<Container>(find.byKey(const Key('auth-brand-panel')));
    expect(panel.color, Brand.green);
    final logo = tester.widget<Image>(find.byKey(const Key('auth-brand-logo')));
    expect((logo.image as AssetImage).assetName, 'assets/images/infois-logo-web-on-green.png');
    expect(find.text('Masuk dengan Google'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('akun Google terdaftar: Client ID dari server, ID token dikirim, langsung masuk', (tester) async {
    final (:server, :posts, :paths) = googleServer();
    final google = FakeGoogleAuth();
    final container = await pumpLogin(tester, server, google);

    await tapGoogle(tester);

    expect(google.clientIds, ['web-client.apps.googleusercontent.com']);
    expect(paths.where((path) => path.endsWith('auth/google')), ['GET auth/google', 'POST auth/google']);
    expect(posts.single!['id_token'], 'id-token-google');
    expect(posts.single!['device_uid'], 'hp-tes');
    expect(posts.single!.containsKey('password'), isFalse);
    expect(container.read(sessionProvider).value!.loggedIn, isTrue);
    expect(container.read(sessionProvider).value!.token, 'token-google');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lembar Google ditutup: tetap di Masuk tanpa pesan dan tanpa request login', (tester) async {
    final (:server, :posts, paths: _) = googleServer();
    final container = await pumpLogin(tester, server, FakeGoogleAuth(token: null));

    await tapGoogle(tester);

    expect(posts, isEmpty);
    expect(container.read(sessionProvider).value!.loggedIn, isFalse);
    expect(find.byKey(const Key('login-google')), findsOneWidget);
    expect(find.textContaining('Belum bisa'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('login Google dimatikan admin: pesan, lembar Google tidak dibuka', (tester) async {
    final (:server, :posts, paths: _) = googleServer(enabled: false);
    final google = FakeGoogleAuth();
    await pumpLogin(tester, server, google);

    await tapGoogle(tester);

    expect(google.clientIds, isEmpty);
    expect(posts, isEmpty);
    expect(find.text('Masuk dengan Google belum tersedia. Silakan masuk dengan email dan kata sandi.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('aplikasi autentikator: langkah kode memakai ID token yang sama', (tester) async {
    final (:server, :posts, paths: _) = googleServer(handler: (body) {
      if (body?['code'] == '123456') {
        return Map<String, dynamic>.from(success);
      }
      return {'_status': 401, 'code': 'butuh_kode_2fa', 'metode_2fa': ['aplikasi'], 'message': 'Akun ini memakai verifikasi dua langkah. Masukkan kode 6 angka dari aplikasi autentikator.'};
    });
    final container = await pumpLogin(tester, server, FakeGoogleAuth());

    await tapGoogle(tester);
    expect(find.byKey(const Key('login-2fa-title')), findsOneWidget);
    expect(find.byKey(const Key('login-2fa-resend')), findsNothing, reason: 'Login Google tanpa kode email.');

    await tester.enterText(find.byKey(const Key('login-2fa-code')), '123456');
    await settle(tester);

    expect(posts, hasLength(2));
    expect(posts.last!['id_token'], 'id-token-google');
    expect(posts.last!['code'], '123456');
    expect(container.read(sessionProvider).value!.loggedIn, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('akun Google belum terdaftar: pesan server, tombol Masuk kembali memakai email & kata sandi', (tester) async {
    final (:server, :posts, :paths) = googleServer(handler: (_) => {
          '_status': 422,
          'code': 'google_belum_terdaftar',
          'message': 'Akun Google orang@gmail.com belum terdaftar di Infois. Masuk dengan akun yang dibuat pemilik usaha Anda, atau daftar dulu lewat website.',
        });
    await pumpLogin(tester, server, FakeGoogleAuth());

    await tapGoogle(tester);
    expect(find.textContaining('belum terdaftar di Infois'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('login-email')), 'rani@kopisenja.example');
    await tester.enterText(find.byKey(const Key('login-password')), 'KopiSenja#2026');
    await tester.tap(find.byKey(const Key('login-submit')));
    await settle(tester);

    expect(paths.last, 'POST auth/login');
    expect(posts.last!['email'], 'rani@kopisenja.example');
    expect(posts.last!.containsKey('id_token'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gagal di HP (mis. belum diatur di Google): pesannya tampil', (tester) async {
    final (:server, :posts, paths: _) = googleServer();
    await pumpLogin(tester, server, FakeGoogleAuth(failure: 'Masuk dengan Google belum bisa dipakai di aplikasi ini. Silakan masuk dengan email dan kata sandi.'));

    await tapGoogle(tester);

    expect(posts, isEmpty);
    expect(find.text('Masuk dengan Google belum bisa dipakai di aplikasi ini. Silakan masuk dengan email dan kata sandi.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
