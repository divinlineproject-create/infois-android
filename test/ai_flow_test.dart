import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/ai_models.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/state/ai_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/ai_chat_screen.dart';
import 'package:infois/ui/screens/ai_home_screen.dart';
import 'package:infois/ui/theme.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';

/// Layar Tim AI: ringkasan tim & jatah, kirim pesan + polling proses,
/// Setujui usulan, offline, dan hak akses.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    required FakeServer server,
    Map<String, dynamic>? menus,
    List<TenantSummary>? tenants,
    Size size = const Size(1080, 2340),
    double pixelRatio = 3,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    FakeFilePlatform? files,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = pixelRatio;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final allTenants = tenants ?? const [TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Pemilik', menus: Menus(pos: true, shift: true, ai: true, reports: true, records: true))];
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [for (final tenant in allTenants) tenant.toJson()],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: menus);
      return db;
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local!),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(FakePrinter()),
        filePlatformProvider.overrideWithValue(files ?? FakeFilePlatform()),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
  }

  Future<void> openAiTab(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(NavigationDestination, 'Tim AI'));
    await settle(tester);
  }

  Future<void> openHistory(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('ai-history')));
    await settle(tester);
  }

  testWidgets('layar awal: sapaan, tim, saran mengisi kotak tulis; riwayat & jatah di laci', (tester) async {
    final server = FakeServer(aiHandler());
    await pumpApp(tester, server: server);
    await openAiTab(tester);

    final greeting = tester.widget<Text>(find.byKey(const Key('ai-greeting'))).data!;
    expect(greeting, startsWith('Selamat '));
    expect(greeting, endsWith(', Sari'));
    expect(find.text('Apa yang bisa Tim AI kerjakan hari ini?'), findsOneWidget);
    expect(find.byKey(const Key('ai-composer')), findsOneWidget, reason: 'Kotak tulis langsung di layar awal.');
    expect(find.byKey(const Key('ai-messages')), findsNothing);
    expect(find.text('1 tim siap bekerja'), findsOneWidget);
    expect(find.byKey(const Key('ai-send')), findsNothing, reason: 'Belum ada isi: tombol mikrofon, bukan Kirim.');

    // Saran (dari server + contoh tim yang terbuka, tanpa duplikat) mengisi kotak tulis.
    expect(find.byKey(const Key('ai-suggestion-0')), findsOneWidget);
    expect(find.byKey(const Key('ai-suggestion-1')), findsNothing, reason: 'Contoh Tim Penjualan sama dengan saran; Tim Analis terkunci.');
    await tester.tap(find.byKey(const Key('ai-suggestion-0')));
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const Key('ai-text'))).controller!.text, 'Kopi susu 3, roti bakar 2, bayar tunai');
    expect(find.byKey(const Key('ai-send')), findsOneWidget);
    expect(server.requests.where((request) => request.path == 'ai/messages'), isEmpty, reason: 'Saran hanya mengisi, tidak langsung mengirim.');

    // Tim (gembok untuk paket lebih tinggi).
    await tester.tap(find.byKey(const Key('ai-teams-row')));
    await settle(tester);
    expect(find.text('Tim yang bekerja untuk Anda'), findsOneWidget);
    expect(find.text('Tim Penjualan'), findsOneWidget);
    expect(find.text('Tim Analis'), findsOneWidget);
    expect(find.text('Tersedia di paket Growth'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsWidgets);
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);

    // Riwayat + jatah bulan ini di laci (tanpa kata token).
    await openHistory(tester);
    expect(find.byKey(const Key('ai-history-drawer')), findsOneWidget);
    expect(find.byKey(const Key('conversation-12')), findsOneWidget);
    expect(find.text('1 usulan'), findsOneWidget);
    expect(find.byKey(const Key('drawer-new-conversation')), findsOneWidget);
    expect(find.text('Jatah Tim AI bulan ini'), findsOneWidget);
    expect(find.text('9% terpakai'), findsOneWidget);
    expect(find.text('45,74'), findsOneWidget, reason: 'Sisa koin tampil dengan ikon koin, tanpa kata token.');
    expect(find.byKey(const Key('coin-usage-bar')), findsOneWidget);
    expect(find.textContaining('token'), findsNothing);
    expect(server.requests.where((request) => request.path == 'ai/overview'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kirim teks: kotak tulis pindah ke bawah, proses dipantau tiap 2 detik, jawaban Tim Penjualan + usulan; Percakapan baru mulai bersih', (tester) async {
    var runPolls = 0;
    final server = FakeServer(aiHandler(onRun: () => ++runPolls));
    await pumpApp(tester, server: server);
    await openAiTab(tester);

    await tester.tap(find.byKey(const Key('new-conversation')));
    await settle(tester);
    expect(find.byKey(const Key('ai-greeting')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('ai-text')), 'kopi susu 2 tunai');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await settle(tester);

    final sent = server.requests.where((request) => request.path == 'ai/messages').toList();
    expect(sent, hasLength(1));
    expect((sent.single.data as FormData).fields.where((field) => field.key == 'text').map((field) => field.value), ['kopi susu 2 tunai']);
    expect(find.byKey(const Key('ai-greeting')), findsNothing, reason: 'Layar awal diganti percakapan.');
    expect(find.descendant(of: find.byKey(const Key('ai-messages')), matching: find.text('kopi susu 2 tunai')), findsOneWidget, reason: 'Bubble pengguna langsung tampil.');
    expect(find.descendant(of: find.byKey(const Key('ai-topbar')), matching: find.text('kopi susu 2 tunai')), findsOneWidget, reason: 'Judul percakapan dari pesan pertama.');
    expect(find.byKey(const Key('ai-working')), findsOneWidget);
    expect(find.textContaining('sedang mengerjakan'), findsWidgets);
    expect(find.byKey(const Key('ai-stop')), findsOneWidget, reason: 'Selama bekerja, tombol Kirim menjadi tanda sedang bekerja.');
    expect(runPolls, 1, reason: 'Status proses dicek segera setelah terkirim (masih berjalan).');

    // Kotak tulis menempel di bawah layar.
    final composerTop = tester.getTopLeft(find.byKey(const Key('ai-composer'))).dy;
    final messagesBottom = tester.getBottomLeft(find.byKey(const Key('ai-messages'))).dy;
    expect(composerTop, greaterThanOrEqualTo(messagesBottom));

    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(runPolls, 2);
    expect(find.byKey(const Key('ai-working')), findsNothing);
    expect(find.byKey(const Key('ai-stop')), findsNothing);
    expect(find.text('Tim Penjualan'), findsWidgets);
    expect(find.textContaining('Saya siapkan penjualan'), findsOneWidget);
    expect(find.byKey(const Key('proposal-3')), findsOneWidget);
    expect(find.text('Menunggu persetujuan'), findsOneWidget);
    expect(find.text('Setujui'), findsOneWidget);
    expect(find.byKey(const Key('copy-m41')), findsOneWidget, reason: 'Tombol Salin di bawah jawaban.');
    expect(find.byKey(const Key('regenerate-m41')), findsNothing, reason: 'Jawaban berisi usulan tidak ditawarkan Coba lagi (hindari transaksi ganda).');
    expect(find.byKey(const Key('ai-text')), findsOneWidget, reason: 'Kotak tulis aktif lagi setelah selesai.');

    // Salin: teks polos tanpa tanda Markdown.
    // Jawaban panjang dibaca dari awalnya: nama tim di dalam layar (bukan
    // digulir sampai ujung jawaban).
    final list = tester.getRect(find.byKey(const Key('ai-messages')));
    final header = tester.getRect(find.descendant(of: find.byKey(const Key('msg-m41')), matching: find.text('Tim Penjualan')).first);
    expect(header.top, greaterThanOrEqualTo(list.top));
    expect(header.bottom, lessThanOrEqualTo(list.bottom));

    final copied = mockClipboard();
    await tester.ensureVisible(find.byKey(const Key('copy-m41')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('copy-m41')));
    await settle(tester);
    expect(copied, ['Saya siapkan penjualan 2 kopi susu ke Pak Budi. Cek lalu Setujui.']);
    expect(tester.getRect(find.descendant(of: find.byKey(const Key('ai-toast')), matching: find.byType(Material)).first).bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const Key('ai-composer'))).top), reason: '"Teks disalin" tidak menutupi kotak tulis.');

    // Percakapan baru: kembali ke layar awal, dan kirim lagi tetap berjalan.
    await tester.tap(find.byKey(const Key('new-conversation')));
    await settle(tester);
    expect(find.byKey(const Key('ai-greeting')), findsOneWidget);
    expect(find.byKey(const Key('ai-messages')), findsNothing);
    await tester.enterText(find.byKey(const Key('ai-text')), 'roti bakar 1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await settle(tester);
    expect(server.requests.where((request) => request.path == 'ai/messages'), hasLength(2));
    final second = server.requests.where((request) => request.path == 'ai/messages').last;
    expect((second.data as FormData).fields.where((field) => field.key == 'conversation_id'), isEmpty, reason: 'Percakapan baru, bukan lanjutan percakapan sebelumnya.');
    expect(find.descendant(of: find.byKey(const Key('ai-topbar')), matching: find.text('roti bakar 1')), findsOneWidget);
    await tester.drag(find.byKey(const Key('ai-messages')), const Offset(0, 2000));
    await settle(tester);
    expect(find.descendant(of: find.byKey(const Key('ai-messages')), matching: find.text('roti bakar 1')), findsOneWidget);
    expect(find.text('kopi susu 2 tunai'), findsNothing, reason: 'Pesan percakapan sebelumnya tidak terbawa.');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('setujui usulan dari riwayat: API dipanggil dan kartu berubah menjadi Tercatat', (tester) async {
    final server = FakeServer(aiHandler());
    await pumpApp(tester, server: server);
    await openAiTab(tester);

    await openHistory(tester);
    await tester.tap(find.byKey(const Key('conversation-12')));
    await settle(tester);
    expect(find.byKey(const Key('ai-history-drawer')), findsNothing, reason: 'Laci tertutup setelah memilih percakapan.');
    expect(find.text('Menunggu persetujuan'), findsOneWidget);
    expect(find.text('Pak Budi'), findsOneWidget);
    expect(find.text('Rp 30.000'), findsWidgets);

    await tester.ensureVisible(find.byKey(const Key('approve-3')));
    await tester.tap(find.byKey(const Key('approve-3')));
    await settle(tester);

    expect(server.requests.where((request) => request.path == 'ai/proposals/3/approve' && request.method == 'POST'), hasLength(1));
    expect(find.text('Tercatat'), findsOneWidget);
    expect(find.text('INV-0001 · Rp 30.000, lunas'), findsOneWidget);
    expect(find.byKey(const Key('approve-3')), findsNothing);
    expect(find.textContaining('Tercatat: INV-0001'), findsOneWidget, reason: 'Snackbar hasil.');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('file dari Tim AI: kartu file dengan Buka dan Bagikan (diunduh sekali)', (tester) async {
    final files = FakeFilePlatform();
    final server = FakeServer(aiHandler(withReport: true));
    await pumpApp(tester, server: server, files: files);
    await openAiTab(tester);
    await openHistory(tester);
    await tester.tap(find.byKey(const Key('conversation-12')));
    await settle(tester);

    expect(find.byKey(const Key('ai-file-0')), findsOneWidget);
    expect(find.text('Laba rugi Oktober.pdf'), findsOneWidget);
    expect(find.textContaining('Laporan dari Tim AI'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('file-open-0')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('file-open-0')));
    await ioSettle(tester);
    expect(files.opened, hasLength(1));
    expect(files.opened.single.$2, 'application/pdf');
    expect(find.text('Tersimpan di Download'), findsOneWidget);

    await tester.tap(find.byKey(const Key('file-share-0')));
    await ioSettle(tester);
    expect(files.sharedFiles, hasLength(1));
    expect(server.requests.where((request) => request.path == 'ai/attachments/41/0'), hasLength(1), reason: 'File yang sudah diunduh tidak diunduh ulang.');
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    testWidgets('360×640, huruf 1,3×, ${brightness == Brightness.dark ? 'gelap' : 'terang'}: layar awal, percakapan, laci, dan menu + tidak meluap', (tester) async {
      final server = FakeServer(aiHandler(withReport: true));
      await pumpApp(tester, server: server, size: const Size(360, 640), pixelRatio: 1, textScale: 1.3, brightness: brightness);
      await openAiTab(tester);
      expect(find.byKey(const Key('ai-greeting')), findsOneWidget);
      expect(Theme.of(tester.element(find.byKey(const Key('ai-composer')))).brightness, brightness);

      await tester.tap(find.byKey(const Key('ai-attach')));
      await settle(tester);
      expect(find.byKey(const Key('ai-pick-file')), findsOneWidget);
      await tester.tapAt(const Offset(180, 40));
      await settle(tester);

      await openHistory(tester);
      expect(find.byKey(const Key('ai-history-drawer')), findsOneWidget);
      await tester.tap(find.byKey(const Key('conversation-12')));
      await settle(tester);
      expect(find.byKey(const Key('proposal-3')), findsOneWidget);
      await tester.drag(find.byKey(const Key('ai-messages')), const Offset(0, 300));
      await settle(tester);
      await tester.drag(find.byKey(const Key('ai-messages')), const Offset(0, 600));
      await settle(tester);
      expect(find.byKey(const Key('ai-jump-bottom')), findsOneWidget, reason: 'Digulir ke atas: tombol ke pesan terbaru muncul.');
      await tester.tap(find.byKey(const Key('ai-jump-bottom')));
      await settle(tester);
      expect(find.byKey(const Key('ai-jump-bottom')), findsNothing);

      await tester.enterText(find.byKey(const Key('ai-text')), 'Baris satu\nbaris dua\nbaris tiga\nbaris empat\nbaris lima\nbaris enam\nbaris tujuh');
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('riwayat dikelompokkan: Hari ini, Kemarin, 7 hari terakhir, Lebih lama', () {
    final now = DateTime(2026, 10, 10, 9);
    AiConversation item(int id, DateTime? at) => AiConversation(id: id, title: 'c$id', lastMessageAt: at);
    final groups = groupConversations([
      item(1, DateTime(2026, 10, 10, 8)),
      item(2, DateTime(2026, 10, 9, 23, 59)),
      item(3, DateTime(2026, 10, 3)),
      item(4, DateTime(2026, 9, 1)),
      item(5, null),
      item(6, DateTime(2026, 10, 10, 0, 5)),
    ], now);
    expect(groups.map((group) => group.label), ['Hari ini', 'Kemarin', '7 hari terakhir', 'Lebih lama']);
    expect(groups[0].items.map((item) => item.id), [1, 6]);
    expect(groups[1].items.map((item) => item.id), [2]);
    expect(groups[2].items.map((item) => item.id), [3]);
    expect(groups[3].items.map((item) => item.id), [4, 5]);
    expect(groupConversations([item(7, DateTime(2026, 10, 1))], now).single.label, 'Lebih lama');
  });

  test('sapaan menurut jam dan saran tanpa duplikat', () {
    expect(aiGreeting(DateTime(2026, 10, 10, 7), 'Rani Putri'), 'Selamat pagi, Rani');
    expect(aiGreeting(DateTime(2026, 10, 10, 12), 'Rani'), 'Selamat siang, Rani');
    expect(aiGreeting(DateTime(2026, 10, 10, 16), 'Rani'), 'Selamat sore, Rani');
    expect(aiGreeting(DateTime(2026, 10, 10, 21), null), 'Selamat malam');
    expect(aiGreeting(DateTime(2026, 10, 10, 2), ''), 'Selamat malam');
    final overview = AiOverview.fromJson({
      'suggestions': ['Kopi susu 3', 'kopi susu 3', 'Beli gula'],
      'teams': [
        {'key': 'stock', 'name': 'Tim Gudang', 'example': 'Stok gula tinggal berapa?'},
        {'key': 'analyst', 'name': 'Tim Analis', 'example': 'Untung bulan ini?', 'locked': true},
        {'key': 'finance', 'name': 'Tim Keuangan', 'example': 'Bayar listrik 500rb'},
        {'key': 'tax', 'name': 'Tim Pajak', 'example': 'PPN bulan ini?'},
      ],
    });
    expect(aiSuggestions(overview), ['Kopi susu 3', 'Beli gula', 'Stok gula tinggal berapa?', 'Bayar listrik 500rb']);
    expect(aiSuggestions(null), isEmpty);
  });

  testWidgets('laci riwayat: kelompok berurutan, bisa dicari, percakapan aktif ditandai', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final items = [
      AiConversation(id: 1, title: 'Jual kopi susu', preview: 'Saya siapkan **penjualan**', lastMessageAt: now),
      AiConversation(id: 2, title: 'Beli gula', pendingProposals: 2, lastMessageAt: now.subtract(const Duration(days: 1))),
      AiConversation(id: 3, title: 'Laporan minggu ini', working: true, lastMessageAt: now.subtract(const Duration(days: 3))),
      AiConversation(id: 4, title: 'Stok opname', lastMessageAt: now.subtract(const Duration(days: 30))),
    ];
    final opened = <int>[];
    var newChats = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: AiHistoryDrawer(
          conversations: AsyncData(AiConversationsState(items: items)),
          currentId: 2,
          coins: const AiCoins(used: '1.000', available: '9.000', percent: 10),
          onNew: () => newChats++,
          onOpen: opened.add,
          onDelete: (_) {},
          onRefresh: () async {},
          onLoadMore: () {},
        ),
      ),
    ));
    await tester.pump();

    final headers = ['Hari ini', 'Kemarin', '7 hari terakhir', 'Lebih lama'];
    final tops = [for (final label in headers) tester.getTopLeft(find.byKey(Key('history-group-$label'))).dy];
    expect(tops, orderedEquals([...tops]..sort()), reason: 'Kelompok tampil dari yang terbaru.');
    expect(find.text('Saya siapkan penjualan'), findsOneWidget, reason: 'Cuplikan tanpa tanda Markdown.');
    expect(find.text('2 usulan'), findsOneWidget);
    expect(find.text('Sedang dikerjakan'), findsOneWidget);
    expect(find.text('10% terpakai'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('history-search')), 'GULA');
    await tester.pump();
    expect(find.byKey(const Key('conversation-2')), findsOneWidget);
    expect(find.byKey(const Key('conversation-1')), findsNothing);
    expect(find.byKey(const Key('history-group-Kemarin')), findsOneWidget);
    expect(find.byKey(const Key('history-group-Hari ini')), findsNothing);

    await tester.tap(find.byKey(const Key('conversation-2')));
    expect(opened, [2]);

    await tester.enterText(find.byKey(const Key('history-search')), 'tidak ada');
    await tester.pump();
    expect(find.text('Tidak ada yang cocok'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drawer-new-conversation')));
    expect(newChats, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('trial / paket tanpa HP: tab Tim AI menjelaskan paket yang membukanya, tanpa chat', (tester) async {
    final server = FakeServer(aiHandler(
      overview: {
        'enabled': false,
        'reason': 'kanal_tidak_termasuk_paket',
        'channels': {'web': true, 'telegram': false, 'mobile': false, 'unlock_plan': 'Starter', 'message': 'Tim AI lewat aplikasi HP belum termasuk paket trial. Tersedia di paket berbayar mulai paket Starter. Sementara ini, Tim AI tetap bisa dipakai lewat web.'},
      },
    ));
    await pumpApp(tester, server: server);
    await openAiTab(tester);

    expect(find.byKey(const Key('ai-channel-locked')), findsOneWidget);
    expect(find.text('Tim AI lewat HP belum termasuk paket'), findsOneWidget);
    expect(find.textContaining('mulai paket Starter'), findsWidgets);
    expect(find.byKey(const Key('new-conversation')), findsNothing, reason: 'Tidak ada tombol percakapan baru.');
    expect(find.text('Tim yang bekerja untuk Anda'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offline: tab Tim AI menjelaskan butuh internet', (tester) async {
    await pumpApp(tester, server: offlineServer());
    await openAiTab(tester);
    expect(find.text('Tim AI butuh internet'), findsOneWidget);
    expect(find.byKey(const Key('new-conversation')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tanpa hak akses Tim AI: tab tidak tampil dan /ai tidak dipanggil', (tester) async {
    final server = FakeServer(aiHandler(menus: {'pos': true, 'shift': true}));
    await pumpApp(
      tester,
      server: server,
      tenants: const [TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, shift: true))],
      menus: {'pos': true, 'shift': true},
    );
    expect(find.widgetWithText(NavigationDestination, 'Kasir'), findsOneWidget);
    expect(find.widgetWithText(NavigationDestination, 'Tim AI'), findsNothing);
    expect(server.requests.where((request) => request.path.startsWith('ai/')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Server palsu: ping + sinkron minimal, dan semua endpoint Tim AI
/// (API.md › 6). [onRun] dipanggil setiap GET /ai/runs/7; polling pertama
/// masih berjalan, berikutnya selesai.
Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) aiHandler({int Function()? onRun, Map<String, dynamic>? menus, Map<String, dynamic>? overview, bool withReport = false}) {
  var polls = 0;
  return (options, body) {
    final path = options.path;
    switch (path) {
      case 'ping':
        return {'ok': true, 'min_app_version': '1.0.0'};
      case 'sync/pull':
        return {
          'cursor': 'c1',
          'full': true,
          'tenant': {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'},
          'receipt': {'width': 58, 'company': {'name': 'Warung Tes'}},
          'device': {'id': 3, 'code': 'K1', 'name': 'HP Tes'},
          'menus': menus ?? {'pos': true, 'shift': true, 'ai': true, 'reports': true, 'records': true, 'printer': true},
          'products': {'items': [], 'ids': [1, 2]},
          'customers': {'items': [], 'ids': [7]},
          'accounts': {
            'items': [
              {'id': 11, 'code': '1-1100', 'name': 'Kas', 'kind': 'cash'},
            ],
            'ids': [11],
            'default_cash_id': 11,
            'default_transfer_id': null,
          },
          'warehouses': {'items': [], 'ids': []},
          'number_blocks': [],
          'open_shift': null,
        };
      case 'sync/push':
        return {'results': []};
      case 'ai/overview':
        return {
          'enabled': true,
          'reason': null,
          'channels': {'web': true, 'telegram': true, 'mobile': true, 'unlock_plan': null, 'message': null},
          ...?overview,
          'fast_mode': false,
          'teams': [
            {'key': 'sales', 'name': 'Tim Penjualan', 'role': 'Kasir, pesanan, pengiriman, dan data pelanggan', 'tone': 'sky', 'icon': 'shopping-bag', 'example': 'Kopi susu 3, roti bakar 2, bayar tunai', 'locked': false, 'unlock_plan': null},
            {'key': 'analyst', 'name': 'Tim Analis', 'role': 'Laporan', 'tone': 'violet', 'icon': 'chart-bar', 'example': 'Berapa untung bulan ini?', 'locked': true, 'unlock_plan': 'Growth'},
          ],
          'coins': {'used': '4.260', 'available': '45.740', 'percent': 9, 'resets_at': '2026-11-01T00:00:00+07:00'},
          'suggestions': ['Kopi susu 3, roti bakar 2, bayar tunai'],
          'pending_proposals': 1,
          'limits': {'max_attachments': 5, 'max_upload_kb': 10240, 'max_text': 4000},
        };
      case 'ai/conversations':
        if (options.method == 'POST') {
          return {'_status': 201, 'conversation': conversationJson()};
        }
        return {'data': [conversationJson()], 'next_cursor': null};
      case 'ai/conversations/12':
        return {
          'conversation': conversationJson(),
          'working': false,
          'active_run_id': null,
          'messages': [
            {'id': 40, 'conversation_id': 12, 'run_id': 7, 'role': 'user', 'content': 'jual 2 kopi susu ke pak budi', 'failed': false, 'coins': null, 'teams': [], 'run_status': 'completed', 'created_at': '2026-10-09T09:00:00+07:00', 'attachments': [], 'proposals': []},
            assistantJson(withReport: withReport),
          ],
        };
      case 'ai/attachments/41/0':
        return {'isi': 'laporan laba rugi'};
      case 'ai/settings':
        return {'fast_mode': body?['fast_mode'] == true};
      case 'ai/messages':
        return {'_status': 201, 'conversation_id': 12, 'message_id': 40, 'run_id': 7, 'status': 'queued'};
      case 'ai/runs/7':
        polls++;
        onRun?.call();
        if (polls == 1) {
          return {'id': 7, 'conversation_id': 12, 'status': 'running', 'done': false, 'error': null, 'coins_charged': null, 'assistant_message': null, 'proposals': []};
        }
        return {'id': 7, 'conversation_id': 12, 'status': 'completed', 'done': true, 'error': null, 'coins_charged': '4.260', 'assistant_message': assistantJson(), 'proposals': [proposalJson()]};
      case 'ai/proposals/3/approve':
        return {
          'proposal': proposalJson(status: 'executed', statusLabel: 'Tercatat', resultLabel: 'INV-0001 · Rp 30.000, lunas'),
          'message': 'Tercatat: INV-0001 · Rp 30.000, lunas',
        };
      case 'ai/proposals/3/reject':
        return {'proposal': proposalJson(status: 'rejected', statusLabel: 'Ditolak'), 'message': 'Usulan ditolak'};
    }
    return {'_status': 404, 'message': 'Tidak ditemukan: $path', 'code': 'tidak_ditemukan'};
  };
}

Map<String, dynamic> conversationJson() => {
      'id': 12,
      'title': 'jual 2 kopi susu ke pak budi',
      'channel': 'mobile',
      'preview': 'Saya siapkan penjualan 2 kopi susu ke Pak Budi.',
      'pending_proposals': 1,
      'working': false,
      'last_message_at': '2026-10-09T09:00:05+07:00',
      'created_at': '2026-10-09T09:00:00+07:00',
      'updated_at': '2026-10-09T09:00:05+07:00',
    };

Map<String, dynamic> assistantJson({bool withReport = false}) => {
      'id': 41,
      'conversation_id': 12,
      'run_id': 7,
      'role': 'assistant',
      'content': 'Saya siapkan penjualan **2 kopi susu** ke Pak Budi. Cek lalu **Setujui**.',
      'failed': false,
      'coins': '4.260',
      'teams': [
        {'key': 'sales', 'name': 'Tim Penjualan', 'tone': 'sky'},
      ],
      'run_status': 'completed',
      'created_at': '2026-10-09T09:00:05+07:00',
      'attachments': [
        if (withReport) {'index': 0, 'name': 'Laba rugi Oktober.pdf', 'mime': 'application/pdf', 'size': 24576, 'kind': 'report', 'seconds': null, 'transcript': null, 'url': 'https://dashboard.infois.ai/api/v1/ai/attachments/41/0'},
      ],
      'proposals': [proposalJson()],
    };

Map<String, dynamic> proposalJson({String status = 'pending', String statusLabel = 'Menunggu persetujuan', String? resultLabel}) => {
      'id': 3,
      'conversation_id': 12,
      'run_id': 7,
      'type': 'sale',
      'title': 'Penjualan ke Pak Budi · Rp 30.000',
      'status': status,
      'status_label': statusLabel,
      'editable': status == 'pending',
      'editable_fields': ['contact', 'date', 'items', 'paid', 'payment_method', 'cash_account_id'],
      'payload': {
        'customer_id': 5,
        'customer_name': null,
        'date': '2026-10-09',
        'paid': false,
        'payment_method': null,
        'cash_account_id': null,
        'due_days': 14,
        'items': [
          {'product_id': 1, 'description': 'Kopi susu', 'quantity': '2.000000', 'unit': 'gelas', 'unit_factor': '1.000000', 'unit_price': '15000.00', 'discount_percent': '0.00', 'tax_rate': '0.00', 'total': '30000.00'},
        ],
      },
      'preview': {
        'contact': 'Pak Budi',
        'new_contact': false,
        'lines': [
          {'product_id': 1, 'description': 'Kopi susu', 'quantity': '2.000000', 'unit': 'gelas', 'unit_price': '15000.00', 'total': '30000.00'},
        ],
        'totals': {'subtotal': '30000.00', 'tax_total': '0.00', 'total': '30000.00'},
        'payment': 'Belum dibayar, ditagih ke pelanggan nanti',
        'warnings': [],
      },
      'error': null,
      'result_label': resultLabel,
      'result_url': null,
      'print_links': [],
      'decided_at': status == 'pending' ? null : '2026-10-09T09:01:00+07:00',
      'created_at': '2026-10-09T09:00:05+07:00',
    };

/// Seperti [settle], tetapi memberi waktu I/O sungguhan (menulis file unduhan).
Future<void> ioSettle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Pump beberapa frame (tanpa pumpAndSettle karena animasi titik berkedip).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
