import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Layar Tim AI: ringkasan tim & jatah, kirim pesan + polling proses,
/// Setujui usulan, offline, dan hak akses.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  Future<void> pumpApp(WidgetTester tester, {required FakeServer server, Map<String, dynamic>? menus, List<TenantSummary>? tenants}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
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
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
  }

  Future<void> openAiTab(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(NavigationDestination, 'Tim AI'));
    await settle(tester);
  }

  testWidgets('ringkasan: tim tampil dengan gembok paket, jatah bulan ini, contoh perintah, dan riwayat', (tester) async {
    final server = FakeServer(aiHandler());
    await pumpApp(tester, server: server);
    await openAiTab(tester);

    expect(find.text('Tim yang bekerja untuk Anda'), findsOneWidget);
    expect(find.text('Penjualan'), findsOneWidget);
    expect(find.text('Analis'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget, reason: 'Tim Analis terkunci (paket Growth).');
    expect(find.text('Jatah Tim AI bulan ini'), findsOneWidget);
    expect(find.text('9% terpakai'), findsOneWidget);
    expect(find.text('45,74'), findsOneWidget, reason: 'Sisa koin tampil dengan ikon koin, tanpa kata token.');
    expect(find.textContaining('token'), findsNothing);
    expect(find.byKey(const Key('coin-usage-bar')), findsOneWidget);
    expect(find.text('Kopi susu 3, roti bakar 2, bayar tunai'), findsOneWidget);
    expect(find.text('jual 2 kopi susu ke pak budi'), findsOneWidget);
    expect(find.text('1 usulan'), findsOneWidget);
    expect(find.text('Percakapan baru'), findsOneWidget);
    expect(server.requests.where((request) => request.path == 'ai/overview'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kirim teks: pesan tampil, proses dipantau tiap 2 detik, jawaban Tim Penjualan + usulan muncul', (tester) async {
    var runPolls = 0;
    final server = FakeServer(aiHandler(onRun: () => ++runPolls));
    await pumpApp(tester, server: server);
    await openAiTab(tester);

    await tester.tap(find.byKey(const Key('new-conversation')));
    await settle(tester);
    expect(find.text('Apa yang perlu dicatat?'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('ai-text')), 'kopi susu 2 tunai');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await settle(tester);

    final sent = server.requests.where((request) => request.path == 'ai/messages').toList();
    expect(sent, hasLength(1));
    expect((sent.single.data as FormData).fields.where((field) => field.key == 'text').map((field) => field.value), ['kopi susu 2 tunai']);
    expect(find.descendant(of: find.byType(ListView), matching: find.text('kopi susu 2 tunai')), findsOneWidget, reason: 'Bubble pengguna langsung tampil.');
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('kopi susu 2 tunai')), findsOneWidget, reason: 'Judul percakapan dari pesan pertama.');
    expect(find.byKey(const Key('ai-working')), findsOneWidget);
    expect(find.textContaining('sedang mengerjakan'), findsWidgets);
    expect(runPolls, 1, reason: 'Status proses dicek segera setelah terkirim (masih berjalan).');

    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(runPolls, 2);
    expect(find.byKey(const Key('ai-working')), findsNothing);
    expect(find.text('Tim Penjualan'), findsWidgets);
    expect(find.textContaining('Saya siapkan penjualan'), findsOneWidget);
    expect(find.byKey(const Key('proposal-3')), findsOneWidget);
    expect(find.text('Menunggu persetujuan'), findsOneWidget);
    expect(find.text('Setujui'), findsOneWidget);
    expect(find.byKey(const Key('ai-text')), findsOneWidget, reason: 'Kotak tulis aktif lagi setelah selesai.');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('setujui usulan: API dipanggil dan kartu berubah menjadi Tercatat', (tester) async {
    final server = FakeServer(aiHandler());
    await pumpApp(tester, server: server);
    await openAiTab(tester);

    await tester.tap(find.byKey(const Key('conversation-12')));
    await settle(tester);
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
Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) aiHandler({int Function()? onRun, Map<String, dynamic>? menus, Map<String, dynamic>? overview}) {
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
            assistantJson(),
          ],
        };
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

Map<String, dynamic> assistantJson() => {
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
      'attachments': [],
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

/// Pump beberapa frame (tanpa pumpAndSettle karena animasi titik berkedip).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
