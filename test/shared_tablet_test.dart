import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/core/pin.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
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

/// Tablet kasir bersama: dibuka dengan pilih nama + PIN (online dicek server,
/// offline dengan pencocok di HP), satu database untuk semua kasir, dan menu
/// Operasional (catat biaya) dari tab Catatan.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  test('PIN: aturan sama dengan server, pencocok tidak menyimpan PIN', () {
    expect(PinCode.invalidReason('12345'), isNotNull);
    expect(PinCode.invalidReason('111111'), contains('mudah ditebak'));
    expect(PinCode.invalidReason('123456'), contains('mudah ditebak'));
    expect(PinCode.invalidReason('654321'), contains('mudah ditebak'));
    expect(PinCode.invalidReason('271828'), isNull);
    final verifier = PinCode.verifier('271828');
    expect(verifier.contains('271828'), isFalse);
    expect(PinCode.matches('271828', verifier), isTrue);
    expect(PinCode.matches('271829', verifier), isFalse);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<(AppStorage, LocalDb, ProviderContainer, List<String>)> pumpApp(
    WidgetTester tester, {
    required FakeServer server,
    bool pinLock = true,
    Map<String, dynamic>? menus,
    Map<String, Object> prefs = const {},
    Map<String, String> secure = const {},
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari Pemilik', 'email': 'sari@tes.id'},
        'tenants': [
          TenantSummary(id: 1, slug: 'kafe', name: 'Kafe Sift', roleLabel: 'Owner', menus: Menus.fromJson(menus ?? {'pos': true, 'shift': true}), permissions: const [], hasPin: true).toJson(),
        ],
      }),
      'tenant_id': 1,
      'pin_lock': pinLock,
      ...prefs,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-pemilik', 'device_uid': 'tablet-1', ...secure});
    final storage = await AppStorage.load();
    final opened = <String>[];
    final local = (await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: menus ?? {'pos': true, 'shift': true});
      return db;
    }))!;
    final tokens = <String>[];
    final overrides = [
      storageProvider.overrideWithValue(storage),
      localDbOpenerProvider.overrideWithValue((name) async {
        opened.add(name);
        // Satu database tablet; pergantian pengguna membuka koneksi baru (di tes: pembungkus baru).
        return _SharedLocal(local.db);
      }),
      apiFactoryProvider.overrideWithValue((_, token, tenantId, ____) {
        final dio = Dio(BaseOptions(baseUrl: 'http://tes/api/v1/'));
        dio.httpClientAdapter = server;
        dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          tokens.add('${options.path}:$token');
          handler.next(options);
        }));
        return ApiClient(baseUrl: 'http://tes', token: token, tenantId: tenantId, dio: dio);
      }),
      connectivityStreamProvider.overrideWithValue(const Stream.empty()),
      printerTransportProvider.overrideWithValue(FakePrinter()),
      filePlatformProvider.overrideWithValue(FakeFilePlatform()),
    ];
    await tester.pumpWidget(ProviderScope(overrides: overrides, child: const InfoisApp()));
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(InfoisApp)));
    return (storage, local, container, tokens..addAll(opened.map((name) => 'db:$name')));
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.byKey(Key('pin-key-$digit')));
      await tester.pump();
    }
    // Hash pencocok PIN + jawaban server palsu.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await settle(tester);
  }

  Map<String, dynamic>? baseServer(RequestOptions options, Map<String, dynamic>? body) => switch (options.path) {
        'ping' => {'ok': true, 'min_app_version': '1.0.0'},
        'sync/push' => {'results': []},
        'pin/users' => {
            'users': [
              {'id': 1, 'name': 'Sari Pemilik', 'role_label': 'Owner'},
              {'id': 2, 'name': 'Budi Kasir', 'role_label': 'Kasir'},
            ],
          },
        _ => {},
      };

  testWidgets('tablet terkunci: pilih nama + PIN → masuk sebagai kasir itu, database tablet tetap satu', (tester) async {
    final unlocks = <Map<String, dynamic>?>[];
    var online = true;
    final server = FakeServer((options, body) {
      if (!online) {
        return null;
      }
      if (options.path == 'pin/unlock') {
        unlocks.add(body);
        if (body?['pin'] != '271828') {
          return {'_status': 422, 'message': 'PIN salah. Sisa 4 kali percobaan sebelum dikunci 15 menit.', 'code': 'pin_salah'};
        }
        return {
          'token': 'token-budi',
          'user': {'id': 2, 'name': 'Budi Kasir', 'email': 'budi@tes.id'},
          'tenants': [
            {'id': 1, 'slug': 'kafe', 'name': 'Kafe Sift', 'role_label': 'Kasir', 'menus': {'pos': true, 'shift': true}, 'permissions': [], 'has_pin': true},
          ],
          'pin_session': true,
        };
      }
      return baseServer(options, body);
    });
    final (storage, _, container, tokens) = await pumpApp(tester, server: server);

    expect(find.byKey(const Key('lock-title')), findsOneWidget);
    expect(find.byKey(const Key('auth-brand-panel')), findsOneWidget);
    expect(find.text('Budi Kasir'), findsOneWidget);

    await tester.tap(find.byKey(const Key('lock-user-2')));
    await settle(tester);
    await typePin(tester, '111112');
    expect(find.textContaining('PIN salah'), findsOneWidget);

    await typePin(tester, '271828');
    final session = container.read(sessionProvider).value!;
    expect(session.locked, isFalse);
    expect(session.user!.id, 2);
    expect(session.isOperator, isTrue);
    expect(session.token, 'token-budi');
    expect(session.ownerId, 1, reason: 'database tetap milik pemilik login tablet');
    expect(await storage.operatorToken(2), 'token-budi');
    expect(await storage.pinVerifier(2), isNotNull);
    expect(unlocks.last, {'user_id': 2, 'pin': '271828'});
    expect(tokens.where((entry) => entry.startsWith('pin/unlock:')).every((entry) => entry.endsWith('token-pemilik')), isTrue, reason: 'PIN dibuka lewat token tablet');
    expect(container.read(workspaceProvider).value!.user.id, 2);
    expect(container.read(workspaceProvider).value!.ownerId, 1);
    expect(find.byKey(const Key('lock-title')), findsNothing);

    // Kunci lagi lalu buka offline dengan pencocok di HP.
    container.read(sessionProvider.notifier).lock();
    await settle(tester);
    expect(find.byKey(const Key('lock-title')), findsOneWidget);
    online = false;
    await tester.tap(find.byKey(const Key('lock-user-2')));
    await settle(tester);
    await typePin(tester, '271829');
    expect(find.textContaining('PIN salah'), findsOneWidget);
    expect(storage.pinFailures(2), 1);
    await typePin(tester, '271828');
    expect(container.read(sessionProvider).value!.locked, isFalse);
    expect(container.read(sessionProvider).value!.user!.id, 2);
    expect(storage.pinFailures(2), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sesi PIN ditolak server (PIN diganti) → kembali ke pemilik tablet tanpa keluar', (tester) async {
    final server = FakeServer(baseServer);
    final (storage, _, container, _) = await pumpApp(
      tester,
      server: server,
      pinLock: false,
      prefs: {
        'pin_active_user': 2,
        'pin_operators': jsonEncode([
          {
            'user': {'id': 2, 'name': 'Budi Kasir', 'email': 'budi@tes.id'},
            'tenants': [const TenantSummary(id: 1, name: 'Kafe Sift', menus: Menus(pos: true)).toJson()],
          },
        ]),
      },
      secure: {'pin_operator_tokens': jsonEncode({'2': 'token-budi'})},
    );
    var session = container.read(sessionProvider).value!;
    expect(session.user!.id, 2, reason: 'tanpa kunci PIN: pengguna terakhir dilanjutkan');
    expect(session.token, 'token-budi');

    await tester.runAsync(() => container.read(sessionProvider.notifier).expire());
    await settle(tester);
    session = container.read(sessionProvider).value!;
    expect(session.loggedIn, isTrue, reason: 'pemilik login tablet tidak ikut keluar');
    expect(session.user!.id, 1);
    expect(session.token, 'token-pemilik');
    expect(await storage.operatorToken(2), isNull);
    expect(storage.operators(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Catat biaya dari tab Catatan: payload sama dengan form biaya web', (tester) async {
    final saved = <Map<String, dynamic>?>[];
    final server = FakeServer((options, body) {
      switch (options.path) {
        case 'ops/options':
          return {
            'expense_categories': [
              {'id': 61, 'name': 'Biaya Listrik', 'group': 'Biaya usaha'},
              {'id': 62, 'name': 'Biaya Sewa', 'group': 'Biaya usaha'},
            ],
            'cash_accounts': [
              {'id': 11, 'code': '1-1100', 'name': 'Kas'},
            ],
            'income_accounts': [],
            'spending_accounts': [],
            'suppliers': [],
            'tax': {'name': 'PPN', 'rate': '11.00'},
            'can': {'expense_paid': true, 'expense_unpaid': true, 'bill': true, 'cash': true, 'pay_bill': true},
          };
        case 'ops/expenses':
          saved.add(body);
          return {
            '_status': 201,
            'result': {'type': 'cash', 'id': 5, 'number': 'KK/2026/11/0001', 'status': 'posted', 'total': '60000.00', 'message': 'Tercatat · KK/2026/11/0001.'},
          };
      }
      return baseServer(options, body);
    });
    await pumpApp(tester, server: server, pinLock: false, menus: {'pos': true, 'records': true, 'operations': true});

    await tester.tap(find.text('Catatan'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('catatan-ops')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ops-expense')));
    await settle(tester);

    await tester.tap(find.byKey(const Key('ops-category-0')));
    await settle(tester);
    await tester.tap(find.text('Biaya Listrik'));
    await settle(tester);
    await tester.enterText(find.byType(TextFormField).at(1), '3');
    await tester.enterText(find.descendant(of: find.byKey(const Key('ops-price-0')), matching: find.byType(EditableText)), '20000');
    await settle(tester);
    expect(find.text('Rp 60.000'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('ops-paid-from')));
    await tester.tap(find.byKey(const Key('ops-paid-from')));
    await settle(tester);
    await tester.tap(find.text('Kas').last);
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('ops-save')));
    await tester.tap(find.byKey(const Key('ops-save')));
    await settle(tester);

    expect(saved, hasLength(1));
    expect(saved.single!['mode'], 'paid');
    expect(saved.single!['account_id'], 11);
    expect((saved.single!['lines'] as List).single, {'account_id': 61, 'quantity': '3.000000', 'unit_price': '20000', 'amount': '60000.00'});
    expect(find.textContaining('KK/2026/11/0001'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Database tablet yang sama untuk setiap pembuka (tes): menutup satu
/// pembungkus tidak menutup database aslinya.
class _SharedLocal extends LocalDb {
  _SharedLocal(super.db);

  @override
  Future<void> close() async {}
}
