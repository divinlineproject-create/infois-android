import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';

/// Masuk dengan verifikasi dua langkah (API.md › Login): 401
/// `butuh_kode_2fa` → langkah kode (6 angka / kode pemulihan / kode email),
/// kode salah, terlalu sering, dan kirim ulang kode email.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  setUp(mockClipboard);

  final success = {
    'token': 'token-baru',
    'token_type': 'Bearer',
    'user': {'id': 1, 'name': 'Rani', 'email': 'rani@kopisenja.example'},
    'tenants': [
      {'id': 1, 'name': 'PT Kopi Senja', 'mobile_eligible': true, 'menus': {'pos': true}},
    ],
  };

  /// Server: [methods] = `metode_2fa` akun ini; kode benar 123456 atau
  /// kode pemulihan ABCDEFGHIJ-klmnopqrst; [throttleAfter] kode salah → 429.
  ({FakeServer server, List<Map<String, dynamic>?> logins}) twoFactorServer(List<String> methods, {int throttleAfter = 99}) {
    final logins = <Map<String, dynamic>?>[];
    var wrong = 0;
    final server = FakeServer((RequestOptions options, Map<String, dynamic>? body) {
      if (options.path != 'auth/login') {
        return null;
      }
      logins.add(body);
      final code = body?['code']?.toString();
      if (code == null) {
        return {
          '_status': 401,
          'code': 'butuh_kode_2fa',
          'metode_2fa': methods,
          'message': methods.contains('email') ? 'Akun ini memakai verifikasi dua langkah. Kami sudah mengirim kode ke email Anda.' : 'Akun ini memakai verifikasi dua langkah. Masukkan kode 6 angka.',
        };
      }
      if (code == '123456' || code == 'ABCDEFGHIJ-klmnopqrst') {
        return Map<String, dynamic>.from(success);
      }
      wrong++;
      if (wrong > throttleAfter) {
        return {'_status': 429, 'code': 'kode_2fa_terlalu_sering', 'metode_2fa': methods, 'message': 'Terlalu banyak percobaan kode. Silakan coba lagi dalam 120 detik.'};
      }
      return {'_status': 401, 'code': 'kode_2fa_salah', 'metode_2fa': methods, 'message': 'Kode verifikasi salah atau sudah kedaluwarsa. Periksa lagi kodenya.'};
    });
    return (server: server, logins: logins);
  }

  Future<ProviderContainer> pumpLogin(WidgetTester tester, FakeServer server) async {
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
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('login-email')), 'rani@kopisenja.example');
    await tester.enterText(find.byKey(const Key('login-password')), 'KopiSenja#2026');
    await tester.tap(find.byKey(const Key('login-submit')));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(InfoisApp)));
  }

  testWidgets('aplikasi autentikator: langkah kode 6 angka, kode salah, lalu masuk', (tester) async {
    final (:server, :logins) = twoFactorServer(['aplikasi']);
    final container = await pumpLogin(tester, server);

    expect(find.byKey(const Key('login-2fa-title')), findsOneWidget);
    expect(find.textContaining('aplikasi autentikator'), findsOneWidget);
    expect(find.byKey(const Key('login-2fa-resend')), findsNothing, reason: 'Tanpa kode email.');
    expect(find.byKey(const Key('login-2fa-recovery')), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const Key('login-2fa-code')));
    expect(field.keyboardType, TextInputType.number);
    expect(field.maxLength, 6);
    expect(logins.single!.containsKey('code'), isFalse);

    // Huruf dibuang, kurang dari 6 angka → pesan, tanpa request.
    await tester.enterText(find.byKey(const Key('login-2fa-code')), '12ab3');
    await tester.tap(find.byKey(const Key('login-2fa-submit')));
    await settle(tester);
    expect(find.text('Kode terdiri dari 6 angka.'), findsOneWidget);
    expect(logins, hasLength(1));

    // Kode salah (6 angka langsung dikirim).
    await tester.enterText(find.byKey(const Key('login-2fa-code')), '111111');
    await settle(tester);
    expect(logins.last!['code'], '111111');
    expect(find.text('Kode verifikasi salah atau sudah kedaluwarsa. Periksa lagi kodenya.'), findsOneWidget);
    expect(container.read(sessionProvider).value!.loggedIn, isFalse);
    expect(tester.widget<TextField>(find.byKey(const Key('login-2fa-code'))).controller!.text, isEmpty);

    await tester.enterText(find.byKey(const Key('login-2fa-code')), '123456');
    await settle(tester);
    expect(logins.last!['code'], '123456');
    expect(logins.last!['email'], 'rani@kopisenja.example');
    expect(container.read(sessionProvider).value!.loggedIn, isTrue);
    expect(find.byKey(const Key('login-2fa-title')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kode pemulihan: format 10-10 huruf/angka, papan ketik huruf', (tester) async {
    final (:server, :logins) = twoFactorServer(['aplikasi']);
    final container = await pumpLogin(tester, server);

    await tester.tap(find.byKey(const Key('login-2fa-recovery')));
    await settle(tester);
    expect(find.text('Pakai kode 6 angka'), findsOneWidget);
    expect(find.textContaining('kode pemulihan yang Anda simpan'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('login-2fa-code'))).keyboardType, TextInputType.visiblePassword);

    await tester.enterText(find.byKey(const Key('login-2fa-code')), 'ABCDE-12345');
    await tester.tap(find.byKey(const Key('login-2fa-submit')));
    await settle(tester);
    expect(find.textContaining('Kode pemulihan berbentuk 10 huruf/angka'), findsOneWidget);
    expect(logins, hasLength(1));

    await tester.enterText(find.byKey(const Key('login-2fa-code')), 'ABCDEFGHIJ-klmnopqrst');
    await tester.tap(find.byKey(const Key('login-2fa-submit')));
    await settle(tester);
    expect(logins.last!['code'], 'ABCDEFGHIJ-klmnopqrst');
    expect(container.read(sessionProvider).value!.loggedIn, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kode email: petunjuk email, kirim ulang = login tanpa kode, terlalu sering, Kembali', (tester) async {
    final (:server, :logins) = twoFactorServer(['email'], throttleAfter: 1);
    final container = await pumpLogin(tester, server);

    expect(find.textContaining('Kami mengirim kode 6 angka ke rani@kopisenja.example'), findsOneWidget);
    expect(find.byKey(const Key('login-2fa-recovery')), findsNothing, reason: 'Kode pemulihan hanya untuk aplikasi autentikator.');
    expect(find.text('Kirim ulang kode ke email (30)'), findsOneWidget, reason: 'Jeda sebelum kirim ulang.');
    expect(tester.widget<TextButton>(find.byKey(const Key('login-2fa-resend'))).onPressed, isNull);

    for (var i = 0; i < 31; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Kirim ulang kode ke email'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('login-2fa-resend')));
    await tester.tap(find.byKey(const Key('login-2fa-resend')));
    await settle(tester);
    expect(logins, hasLength(2));
    expect(logins.last!.containsKey('code'), isFalse, reason: 'Kirim ulang = login lagi tanpa kode.');
    expect(find.text('Kode baru sudah dikirim ke email Anda.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('login-2fa-code')), '000000');
    await settle(tester);
    expect(find.text('Kode verifikasi salah atau sudah kedaluwarsa. Periksa lagi kodenya.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('login-2fa-code')), '000001');
    await settle(tester);
    expect(find.text('Terlalu banyak percobaan kode. Silakan coba lagi dalam 120 detik.'), findsOneWidget);
    expect(container.read(sessionProvider).value!.loggedIn, isFalse);

    await tester.ensureVisible(find.byKey(const Key('login-2fa-back')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('login-2fa-back')));
    await settle(tester);
    expect(find.byKey(const Key('login-email')), findsOneWidget);
    expect(find.byKey(const Key('login-2fa-code')), findsNothing);
    for (var i = 0; i < 31; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpWidget(const SizedBox());
  });
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
