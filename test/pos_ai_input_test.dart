import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/core/store_policy.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/ai_models.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/domain/pos_ai.dart';
import 'package:infois/services/ai_media.dart';
import 'package:infois/services/permission_gate.dart';
import 'package:infois/state/pos_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/pos_ai_sheet.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/play_policy.dart';

/// Input AI di kasir HP: tombol hanya saat online, pesanan diketik /
/// diucapkan / difoto langsung masuk keranjang lewat aturan tambah barang
/// yang sama dengan ketuk manual, yang tidak cocok jadi "tidak ditemukan"
/// dengan saran, dan koin habis memakai kalimat netral (Google Play).
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  setUp(mockClipboard);

  const gula = Product(id: 6, name: 'Gula pasir', unit: 'kg', price: '16000.00', units: [UnitOption(name: 'karung', factor: '50.000000', price: '750000.00')]);
  const kopiLama = Product(id: 9, name: 'Kopi lama', unit: 'gelas', price: '9000.00', isActive: false);

  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('pos-ai-'));
  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, dynamic> pull() => {
        'cursor': 'c1',
        'full': true,
        'tenant': {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'},
        'receipt': {'width': 58, 'company': {'name': 'Warung Tes'}},
        'device': {'id': 3, 'code': 'K1', 'name': 'HP Tes'},
        'menus': {'pos': true},
        'products': {'items': [kopi.toJson(), roti.toJson(), gula.toJson(), kopiLama.toJson()], 'ids': [1, 2, 6, 9]},
        'customers': {'items': [], 'ids': [7]},
        'accounts': {'items': [], 'ids': [], 'default_cash_id': 11, 'default_transfer_id': 12},
        'warehouses': {'items': [], 'ids': []},
        'number_blocks': [],
        'open_shift': null,
      };

  Future<ProviderContainer> pumpKasir(WidgetTester tester, FakeServer server, {_Recorder? recorder, _Picker? picker}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true)).toJson()],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = (await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: {'pos': true});
      await db.upsertProducts([gula, kopiLama]);
      return db;
    }))!;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(FakePrinter()),
        permissionGateProvider.overrideWithValue(_NoRationale()),
        if (recorder != null) voiceRecorderProvider.overrideWithValue(recorder),
        if (picker != null) aiMediaPickerProvider.overrideWithValue(picker),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(InfoisApp)));
  }

  Map<String, String> fields(RequestOptions options) => {for (final field in (options.data as FormData).fields) field.key: field.value};

  Map<String, dynamic> aiAnswer() => {
        'status': 'ok',
        'items': [
          {'product_id': 1, 'name': 'Kopi susu', 'quantity': '2.000000', 'unit': 'gelas', 'note': 'tanpa gula', 'said': 'kopsus 2 tanpa gula'},
          {'product_id': 6, 'name': 'Gula pasir', 'quantity': '1.000000', 'unit': 'karung', 'note': null, 'said': 'gula sekarung'},
          {'product_id': 9, 'name': 'Kopi lama', 'quantity': '1.000000', 'unit': 'gelas', 'note': null, 'said': 'kopi lama'},
        ],
        'unmatched': [
          {'said': 'roti 3', 'quantity': '3.000000', 'unit': null, 'note': null, 'suggestions': [{'id': 2, 'name': 'Roti bakar'}, {'id': 9, 'name': 'Kopi lama'}]},
        ],
        'heard': null,
        'message': null,
        'coins_used': '0.320',
        'coins_used_label': '0,3',
        'coins_left': '49,7',
      };

  testWidgets('tombol Input AI hanya saat online; offline disembunyikan', (tester) async {
    var online = true;
    final server = FakeServer((options, body) => switch (options.path) {
          'ping' => online ? {'ok': true, 'min_app_version': '1.0.0'} : null,
          'sync/push' => {'results': []},
          'sync/pull' => pull(),
          _ => null,
        });
    final container = await pumpKasir(tester, server);
    expect(container.read(syncProvider).connection, ConnectionStatus.online);
    expect(find.byKey(const Key('ai-input-button')), findsOneWidget);

    online = false;
    unawaited(container.read(syncProvider.notifier).syncNow());
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }
    expect(container.read(syncProvider).connection, ConnectionStatus.offline);
    expect(find.byKey(const Key('ai-input-button')), findsNothing);
    expect(find.byKey(const Key('scan-button')), findsOneWidget, reason: 'Scan tetap jalan offline.');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ketik pesanan: barang masuk keranjang seperti ketuk manual, nonaktif & tak dikenal jadi saran', (tester) async {
    final requests = <Map<String, String>>[];
    final server = FakeServer((options, body) {
      switch (options.path) {
        case 'ping':
          return {'ok': true, 'min_app_version': '1.0.0'};
        case 'sync/push':
          return {'results': []};
        case 'sync/pull':
          return pull();
        case 'pos/ai-input':
          requests.add(fields(options));
          return aiAnswer();
      }
      return null;
    });
    final container = await pumpKasir(tester, server);

    await tester.tap(find.byKey(const Key('ai-input-button')));
    await settle(tester);
    expect(find.byType(PosAiSheet), findsOneWidget);
    expect(find.textContaining('koin'), findsNothing, reason: 'Perkiraan & pemakaian koin tidak ditampilkan.');

    await tester.enterText(find.byKey(const Key('pos-ai-text')), 'kopsus 2 tanpa gula, gula sekarung, kopi lama, roti 3');
    await tester.tap(find.byKey(const Key('pos-ai-send')));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }

    expect(requests, [
      {'mode': 'text', 'text': 'kopsus 2 tanpa gula, gula sekarung, kopi lama, roti 3'},
    ]);
    final cart = container.read(cartProvider);
    expect([for (final line in cart.lines) (line.product?.id, line.quantity, line.unit, line.unitPrice, line.note)], [
      (1, '2.000000', 'gelas', '18000.00', 'tanpa gula'),
      (6, '1.000000', 'karung', '750000.00', null),
    ]);
    expect(find.text('2 barang masuk keranjang'), findsOneWidget);
    expect(find.text('“kopi lama”'), findsOneWidget, reason: 'Barang nonaktif tidak dimasukkan.');
    expect(find.text('“roti 3”'), findsOneWidget);
    expect(find.byKey(const Key('pos-ai-suggestion-9')), findsNothing, reason: 'Barang nonaktif tidak disarankan.');
    expect(find.textContaining('koin'), findsNothing);
    expect(find.textContaining('token'), findsNothing);

    await tester.tap(find.byKey(const Key('pos-ai-suggestion-2')));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }
    final after = container.read(cartProvider);
    expect(after.lines.last.product?.id, 2);
    expect(after.lines.last.quantity, '3.000000');
    expect(find.text('“roti 3”'), findsNothing);
    expect(find.text('3 barang masuk keranjang'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('koin habis: kalimat netral tanpa ajakan membeli, keranjang tidak berubah', (tester) async {
    final server = FakeServer((options, body) => switch (options.path) {
          'ping' => {'ok': true, 'min_app_version': '1.0.0'},
          'sync/push' => {'results': []},
          'sync/pull' => pull(),
          'pos/ai-input' => {'_status': 422, 'code': 'koin_habis', 'message': 'Koin tidak cukup (tersisa 0 koin). Isi ulang koin di menu Services › Dompet Koin.'},
          _ => null,
        });
    final container = await pumpKasir(tester, server);
    await tester.tap(find.byKey(const Key('ai-input-button')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('pos-ai-text')), 'kopsus 2');
    await tester.tap(find.byKey(const Key('pos-ai-send')));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }
    expect(find.text(posAiCoinsShortMessage), findsOneWidget);
    expect(purchaseTextOnScreen(tester, prices: false), isEmpty, reason: 'Harga barang di grid boleh; tanpa ajakan membeli koin.');
    expect(container.read(cartProvider).lines, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('suara: tahan untuk bicara, lepas = kirim rekaman + durasi; foto dari kamera', (tester) async {
    final requests = <(Map<String, String>, List<String>)>[];
    final server = FakeServer((options, body) {
      switch (options.path) {
        case 'ping':
          return {'ok': true, 'min_app_version': '1.0.0'};
        case 'sync/push':
          return {'results': []};
        case 'sync/pull':
          return pull();
        case 'pos/ai-input':
          requests.add((fields(options), [for (final file in (options.data as FormData).files) '${file.key}:${file.value.filename}']));
          return {
            'status': 'ok',
            'items': [
              {'product_id': 1, 'name': 'Kopi susu', 'quantity': '2.000000', 'unit': 'gelas', 'note': null, 'said': 'dua kopi susu'},
            ],
            'unmatched': [],
            'heard': 'dua kopi susu',
            'coins_used_label': '0,2',
            'coins_left': '49,8',
          };
      }
      return null;
    });
    final voice = File('${temp.path}/voice.m4a')..writeAsBytesSync(List.filled(4096, 1));
    final photo = File('${temp.path}/pesanan.jpg')..writeAsBytesSync(List.filled(2048, 2));
    final recorder = _Recorder(AiDraftAttachment(path: voice.path, name: 'voice.m4a', size: 4096, kind: 'audio', seconds: 3));
    final picker = _Picker(AiDraftAttachment(path: photo.path, name: 'pesanan.jpg', size: 2048, kind: 'image'));
    final container = await pumpKasir(tester, server, recorder: recorder, picker: picker);

    await tester.tap(find.byKey(const Key('ai-input-button')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('pos-ai-mode-voice')));
    await settle(tester);
    expect(find.text('Ketuk untuk mulai bicara'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pos-ai-mic')));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }
    expect(recorder.started, 1);
    expect(find.textContaining('Merekam'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pos-ai-mic')));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }
    expect(requests.single.$1, {'mode': 'voice', 'seconds': '3'});
    expect(requests.single.$2, ['file:voice.m4a']);
    expect(find.text('Terbaca: “dua kopi susu”'), findsOneWidget);
    expect(container.read(cartProvider).lines.single.quantity, '2.000000');

    await tester.tap(find.byKey(const Key('pos-ai-mode-photo')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('pos-ai-camera')));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }
    expect(picker.camera, [true]);
    expect(requests.last.$1, {'mode': 'photo'});
    expect(requests.last.$2, ['file:pesanan.jpg']);
    expect(container.read(cartProvider).lines.single.quantity, '4.000000', reason: 'Kopi susu yang sama digabung seperti ketuk manual.');
    await tester.pumpWidget(const SizedBox());
  });

  test('applyAi memakai add(): sama persis dengan menambah barang manual', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final cart = container.read(cartProvider.notifier);
    final applied = cart.applyAi(
      const PosAiResult(items: [
        PosAiItem(productId: 6, name: 'Gula pasir', quantity: '2.000000', unit: 'KARUNG'),
        PosAiItem(productId: 1, name: 'Kopi susu', quantity: '1.000000', unit: null),
        PosAiItem(productId: 1, name: 'Kopi susu', quantity: '1.000000', unit: 'gelas'),
        PosAiItem(productId: 77, name: 'Hilang', quantity: '1.000000', unit: null, said: 'barang hilang'),
      ]),
      {1: kopi, 6: gula, 9: kopiLama},
    );
    final viaAi = [for (final line in container.read(cartProvider).lines) (line.product?.id, line.quantity, line.unit, line.unitPrice)];

    cart.clear();
    cart.add(gula, unit: 'KARUNG', quantity: '2.000000');
    cart.add(kopi, quantity: '1.000000');
    cart.add(kopi, unit: 'gelas', quantity: '1.000000');
    final manual = [for (final line in container.read(cartProvider).lines) (line.product?.id, line.quantity, line.unit, line.unitPrice)];

    expect(viaAi, manual);
    expect(viaAi, [(6, '2.000000', 'karung', '750000.00'), (1, '2.000000', 'gelas', '18000.00')]);
    expect([for (final row in applied.added) row.unit], ['karung', 'gelas', 'gelas']);
    expect([for (final row in applied.unmatched) row.said], ['barang hilang']);
  });
}

class _NoRationale implements PermissionGate {
  @override
  Future<bool> needsRationale(AppPermission permission) async => false;

  @override
  Future<void> markExplained(AppPermission permission) async {}
}

class _Recorder implements VoiceRecorder {
  _Recorder(this.file);

  final AiDraftAttachment file;
  int started = 0;

  @override
  Future<bool> start() async {
    started++;
    return true;
  }

  @override
  Future<AiDraftAttachment?> stop() async => file;

  @override
  Future<void> cancel() async {}
}

class _Picker implements AiMediaPicker {
  _Picker(this.file);

  final AiDraftAttachment file;
  final List<bool> camera = [];

  @override
  Future<AiDraftAttachment?> pickImage({required bool camera}) async {
    this.camera.add(camera);
    return file;
  }

  @override
  Future<List<AiDraftAttachment>> pickFiles() async => const [];
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
