import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/ai_models.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/ai_media.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_flow_test.dart' show aiHandler, settle;
import 'support/fakes.dart';
import 'support/file_fakes.dart';

/// Pemilih file palsu: memberi [count] PDF sekaligus.
class _Picker implements AiMediaPicker {
  _Picker(this.count);

  final int count;

  @override
  Future<AiDraftAttachment?> pickImage({required bool camera}) async => null;

  @override
  Future<List<AiDraftAttachment>> pickFiles() async => [
        for (var i = 0; i < count; i++) AiDraftAttachment(path: '/tmp/nota-$i.pdf', name: 'Faktur pemasok Oktober 2026 nomor $i.pdf', size: 245760, kind: 'file'),
      ];
}

/// Tata letak Tim AI di HP kecil: satu bilah atas, keyboard terbuka, saran
/// yang hilang saat mengetik, dan area ketuk tombol di jawaban.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  Future<void> pumpApp(WidgetTester tester, {double textScale = 1, Size size = const Size(360, 640), int files = 5}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    const tenant = TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Pemilik', menus: Menus(pos: true, shift: true, ai: true, reports: true, records: true));
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [tenant.toJson()],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db);
      return db;
    });
    final server = FakeServer(aiHandler());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local!),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(FakePrinter()),
        filePlatformProvider.overrideWithValue(FakeFilePlatform()),
        aiMediaPickerProvider.overrideWithValue(_Picker(files)),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    await tester.tap(find.widgetWithText(NavigationDestination, 'Tim AI'));
    await settle(tester);
  }

  Future<void> openConversation(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('ai-history')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('conversation-12')));
    await settle(tester);
  }

  testWidgets('tab Tim AI hanya punya satu bilah atas; laci Riwayat menutupi seluruh layar termasuk navigasi bawah', (tester) async {
    await pumpApp(tester, size: const Size(360, 780));
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byKey(const Key('ai-topbar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-history')));
    await settle(tester);
    final drawer = tester.getRect(find.byKey(const Key('ai-history-drawer')));
    expect(drawer.top, 0);
    expect(drawer.bottom, 780, reason: 'Laci setinggi layar, di atas navigasi bawah.');
    // Ketukan di luar laci menutupnya (bukan berpindah tab).
    await tester.tapAt(const Offset(350, 760));
    await settle(tester);
    expect(find.byKey(const Key('ai-history-drawer')), findsNothing);
    expect(find.byKey(const Key('ai-topbar')), findsOneWidget, reason: 'Masih di tab Tim AI.');

    // Tab lain tetap memakai bilah aplikasi biasa.
    await tester.tap(find.widgetWithText(NavigationDestination, 'Laporan'));
    await settle(tester);
    expect(find.byKey(const Key('ai-topbar')), findsNothing);
    expect(find.byType(AppBar), findsWidgets);
  });

  testWidgets('layar awal: saran disembunyikan selama kotak tulis berisi, muncul lagi saat dikosongkan', (tester) async {
    await pumpApp(tester, size: const Size(360, 780));
    expect(find.byKey(const Key('ai-suggestions')), findsOneWidget);
    expect(find.text('AI dapat membuat kesalahan, periksa sebelum melakukan keputusan!'), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('ai-disclaimer'))).top, greaterThanOrEqualTo(tester.getRect(find.byKey(const Key('ai-composer'))).bottom), reason: 'Catatan di bawah kotak tulis.');
    final composerBefore = tester.getRect(find.byKey(const Key('ai-composer')));

    await tester.enterText(find.byKey(const Key('ai-text')), 'Catat faktur ini');
    await settle(tester);
    expect(find.byKey(const Key('ai-suggestions')), findsNothing);

    await tester.enterText(find.byKey(const Key('ai-text')), '');
    await settle(tester);
    expect(find.byKey(const Key('ai-suggestions')), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('ai-composer'))).bottom, composerBefore.bottom, reason: 'Kotak tulis menempel di bawah (tidak melompat).');
    expect(tester.takeException(), isNull);
  });

  testWidgets('kirim pertama: kotak tulis tetap di posisi yang sama (tidak melompat dari tengah)', (tester) async {
    await pumpApp(tester, size: const Size(412, 915));
    final before = tester.getRect(find.byKey(const Key('ai-composer')));
    expect(before.bottom, greaterThan(915 - 80 - 120), reason: 'Kotak tulis menempel di bawah sejak layar awal.');
    await tester.enterText(find.byKey(const Key('ai-text')), 'kopi susu 2 tunai');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await settle(tester);
    expect(find.byKey(const Key('ai-messages')), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('ai-composer'))).bottom, moreOrLessEquals(before.bottom, epsilon: 1));
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (scale, attach) in const [(1.0, true), (1.3, true), (1.3, false), (1.0, false)]) {
    testWidgets('keyboard terbuka di 360×640, huruf $scale×${attach ? ', 5 lampiran' : ''}: Kirim tetap terlihat, tidak meluap', (tester) async {
      await pumpApp(tester, textScale: scale);
      await openConversation(tester);
      if (attach) {
        await tester.tap(find.byKey(const Key('ai-attach')));
        await settle(tester);
        await tester.tap(find.byKey(const Key('ai-pick-file')));
        await settle(tester);
        expect(find.byKey(const Key('ai-remove-0')), findsOneWidget);
        expect(find.textContaining('Maksimal'), findsNothing, reason: 'Kelima lampiran diterima.');
      }
      await tester.enterText(find.byKey(const Key('ai-text')), 'Baris satu\nbaris dua\nbaris tiga\nbaris empat\nbaris lima\nbaris enam\nbaris tujuh');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await settle(tester);
      expect(tester.takeException(), isNull);
      final send = tester.getRect(find.byKey(const Key('ai-send')));
      expect(send.bottom, lessThanOrEqualTo(640 - 280), reason: 'Tombol Kirim di atas keyboard.');
      expect(tester.getRect(find.byKey(const Key('ai-attach'))).bottom, lessThanOrEqualTo(640 - 280));
      expect(tester.getSize(find.byKey(const Key('ai-messages'))).height, greaterThan(0), reason: 'Percakapan masih terlihat sedikit.');
      tester.view.resetViewInsets();
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('tombol Salin di jawaban punya area ketuk 48×48', (tester) async {
    await pumpApp(tester, size: const Size(360, 780));
    await openConversation(tester);
    final copy = tester.getSize(find.byKey(const Key('copy-m41')));
    expect(copy.width, greaterThanOrEqualTo(48));
    expect(copy.height, greaterThanOrEqualTo(48));
  });
}
