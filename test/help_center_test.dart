import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:infois/app.dart';
import 'package:infois/core/store_policy.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/router.dart';
import 'package:infois/ui/screens/akun_screen.dart';
import 'package:infois/ui/screens/help_screens.dart';
import 'package:infois/ui/widgets/ai_markdown.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';
import 'support/play_policy.dart';

/// Pusat Bantuan di aplikasi: dibuka dari Akun, kategori & artikel pilihan,
/// cari, daftar per kategori, pembaca artikel (daftar isi, gambar dengan
/// token, video, tautan, "membantu"), galat offline/tidak ditemukan, layar
/// sempit & mode gelap, dan tautan bantuan dari Tim AI.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  late FakeFilePlatform files;
  setUp(() {
    mockClipboard();
    files = FakeFilePlatform();
  });

  Future<void> pumpApp(WidgetTester tester, {required FakeServer server, Size size = const Size(1080, 2340), double pixelRatio = 3, Brightness brightness = Brightness.light}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = pixelRatio;
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Pemilik', menus: Menus(pos: true, ai: true)).toJson()],
      }),
      'tenant_id': 1,
      if (brightness == Brightness.dark) 'theme_mode': 'dark',
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db);
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
  }

  Future<void> openHelpFromAccount(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(NavigationDestination, 'Akun'));
    await settle(tester);
    await tester.dragUntilVisible(find.byKey(const Key('akun-help')), find.descendant(of: find.byType(AkunScreen), matching: find.byType(Scrollable)).first, const Offset(0, -200));
    await settle(tester);
    await tester.tap(find.byKey(const Key('akun-help')));
    await settle(tester);
  }

  Future<void> openArticle(WidgetTester tester, String slug) async {
    final container = ProviderScope.containerOf(tester.element(find.byType(InfoisApp)));
    unawaited(container.read(routerProvider).push('/bantuan/artikel/$slug'));
    await settle(tester);
  }

  testWidgets('Akun › Pusat Bantuan: kategori dengan ikon, artikel pilihan & populer, cari, lalu daftar kategori', (tester) async {
    final server = FakeServer(helpHandler());
    await pumpApp(tester, server: server);
    await openHelpFromAccount(tester);

    expect(find.text('Ada yang bisa kami bantu?'), findsOneWidget);
    expect(find.byKey(const Key('help-category-penjualan')), findsOneWidget);
    expect(find.text('Penjualan'), findsWidgets);
    expect(find.text('Invoice & kasir · 2 artikel'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('help-category-penjualan')), matching: find.byIcon(Icons.shopping_cart_outlined)), findsOneWidget, reason: 'heroicon-o-shopping-cart → ikon keranjang.');
    expect(find.text('Artikel pilihan'), findsOneWidget);
    expect(find.text('Cara membuat invoice'), findsOneWidget);
    expect(find.text('Paling sering dibaca'), findsOneWidget);
    expect(find.text('Mencatat pembayaran'), findsOneWidget);
    final home = server.requests.firstWhere((request) => request.path == 'help');
    expect(home.headers['Authorization'], 'Bearer token');
    expect(purchaseTextOnScreen(tester), isEmpty);

    // Cari (setelah jeda mengetik), tanpa hasil → saran + Tanya Tim AI.
    await tester.enterText(find.byKey(const Key('help-search')), 'stok');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    final search = server.requests.lastWhere((request) => request.path == 'help/search');
    expect(search.queryParameters['q'], 'stok');
    expect(find.text('Hasil untuk "stok"'), findsOneWidget);
    expect(find.text('Stok opname bulanan'), findsOneWidget);
    expect(find.text('Cara membuat invoice'), findsNothing);

    await tester.enterText(find.byKey(const Key('help-search')), 'zzzz');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.byKey(const Key('help-no-results')), findsOneWidget);
    expect(find.byKey(const Key('help-ask-ai')), findsOneWidget);

    await tester.tap(find.byKey(const Key('help-search-clear')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('help-category-penjualan')));
    await settle(tester);
    expect(find.byKey(const Key('help-category')), findsOneWidget);
    expect(find.text('Invoice & kasir'), findsOneWidget);
    expect(find.byKey(const Key('help-article-cara-membuat-invoice')), findsOneWidget);
    expect(find.byKey(const Key('help-article-mencatat-pembayaran')), findsOneWidget);

    await tester.tap(find.byKey(const Key('help-article-cara-membuat-invoice')));
    await settle(tester);
    expect(find.byKey(const Key('help-article-title')), findsOneWidget);
    expect(find.text('Cara membuat invoice'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('artikel: isi, daftar isi melompat ke bagian, gambar dengan token, kotak tips, tautan, dan Apakah membantu', (tester) async {
    final server = FakeServer(helpHandler());
    await pumpApp(tester, server: server);
    await openArticle(tester, 'cara-membuat-invoice');

    expect(find.byKey(const Key('help-html')), findsOneWidget);
    expect(find.text('Langkah 1: Buka menu'), findsOneWidget);
    expect(find.textContaining('Klik Penjualan'), findsOneWidget);
    expect(find.text('Pilih pelanggan'), findsOneWidget, reason: 'Butir daftar.');
    expect(find.byKey(const Key('help-callout-warning')), findsOneWidget);
    expect(find.text('Jangan lupa simpan'), findsOneWidget);
    expect(find.text('Demo invoice'), findsOneWidget, reason: 'Keterangan video.');
    expect(find.textContaining('Dompet Koin'), findsNothing, reason: 'Kalimat ajakan membeli koin tidak ditampilkan (Google Play).');
    expect(purchaseTextOnScreen(tester), isEmpty);
    expect(find.text('2 menit baca · Diperbarui 12 Okt 2026'), findsOneWidget);

    // Gambar & sampul diunduh lewat API dengan token.
    final images = server.requests.where((request) => request.path.startsWith('help/media/images/') || request.path.startsWith('help/media/covers/')).toList();
    expect(images.map((request) => request.path), containsAll(['help/media/covers/sampul.png', 'help/media/images/menu.png']));
    expect(images.every((request) => request.headers['Authorization'] == 'Bearer token'), isTrue);

    // Daftar isi: lompat ke "Kirim" (bagian paling bawah).
    final scrollable = find.descendant(of: find.byKey(const Key('help-article')), matching: find.byType(Scrollable)).first;
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    await tester.tap(find.byKey(const Key('help-toc')));
    await settle(tester);
    expect(find.byKey(const Key('help-toc-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('help-toc-bagian-kirim')));
    await settle(tester);
    await settle(tester);
    expect(tester.state<ScrollableState>(scrollable).position.pixels, greaterThan(before + 200));
    expect(find.text('Kirim'), findsOneWidget);

    // Tautan panel dashboard ditolak, tautan bantuan dibuka di aplikasi.
    await tester.ensureVisible(find.byKey(const Key('help-feedback')));
    await settle(tester);
    expect(files.urls, isEmpty);

    // Apakah artikel ini membantu? Ya → terkirim, terima kasih tampil.
    await tester.tap(find.byKey(const Key('help-vote-yes')));
    await settle(tester);
    final vote = server.requests.lastWhere((request) => request.path == 'help/articles/cara-membuat-invoice/feedback');
    expect(vote.method, 'POST');
    expect(vote.data, {'helpful': true});
    expect(find.text('Terima kasih! Senang bisa membantu.'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(find.byKey(const Key('help-vote-yes'))), isA<FilledButton>());

    // Artikel terkait.
    await tester.ensureVisible(find.byKey(const Key('help-article-mencatat-pembayaran')));
    await tester.tap(find.byKey(const Key('help-article-mencatat-pembayaran')));
    await settle(tester);
    expect(find.text('Isi artikel pembayaran.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('artikel: tautan bantuan dibuka di aplikasi, panel dashboard tidak; video YouTube dikonfirmasi, video unggahan diputar di HP', (tester) async {
    final server = FakeServer(helpHandler());
    await pumpApp(tester, server: server);
    await openArticle(tester, 'cara-membuat-invoice');

    Future<void> tapLink(String text) async {
      final finder = find.byWidgetPredicate((widget) => widget is RichText && widget.text.toPlainText().contains(text));
      await tester.ensureVisible(finder.first);
      await settle(tester);
      await tester.tapOnText(find.textRange.ofSubstring(text));
      await settle(tester);
    }

    await tapLink('daftar invoice');
    expect(files.urls, isEmpty, reason: 'Panel dashboard (/app/...) tidak dibuka dari aplikasi.');
    expect(find.text(blockedLinkMessage), findsOneWidget);

    // YouTube: konfirmasi dulu, lalu dibuka di luar aplikasi.
    await tester.ensureVisible(find.byKey(const Key('help-video-1')));
    await tester.tap(find.byKey(const Key('help-video-1')));
    await settle(tester);
    expect(find.byKey(const Key('link-confirm')), findsOneWidget);
    expect(find.text('Tonton di YouTube?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-confirm-open')));
    await settle(tester);
    expect(files.urls.single.toString(), 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');

    // Video unggahan: diunduh dengan token lalu dibuka pemutar video HP.
    await tester.ensureVisible(find.byKey(const Key('help-video-0')));
    await tester.tap(find.byKey(const Key('help-video-0')));
    await ioSettle(tester);
    final video = server.requests.lastWhere((request) => request.path == 'help/media/videos/demo.mp4');
    expect(video.headers['Authorization'], 'Bearer token');
    expect(files.opened, hasLength(1));
    expect(files.opened.single.$2, 'video/mp4');
    expect(files.downloads, isEmpty, reason: 'Video bantuan tidak menumpuk di folder Download.');

    // Tautan ke artikel bantuan lain: layar artikel aplikasi.
    await tapLink('stok opname');
    expect(find.text('Isi artikel stok opname.'), findsOneWidget);
    expect(files.urls, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('galat: offline → pesan + Coba lagi; artikel tidak ada → Tidak ditemukan; pemeliharaan → pesan server', (tester) async {
    var online = false;
    final server = FakeServer((options, body) {
      if (!online && options.path.startsWith('help')) {
        return null;
      }
      return helpHandler()(options, body);
    });
    await pumpApp(tester, server: server);
    await openHelpFromAccount(tester);

    expect(find.byKey(const Key('help-error')), findsOneWidget);
    expect(find.text('Tidak ada koneksi internet'), findsOneWidget);
    online = true;
    await tester.tap(find.byKey(const Key('help-retry')));
    await settle(tester);
    expect(find.byKey(const Key('help-error')), findsNothing);
    expect(find.byKey(const Key('help-category-penjualan')), findsOneWidget);

    await openArticle(tester, 'tidak-ada');
    expect(find.text('Tidak ditemukan'), findsOneWidget);
    expect(find.textContaining('Artikel ini tidak ditemukan'), findsOneWidget);

    await openArticle(tester, 'sedang-pemeliharaan');
    expect(find.text('Sedang pemeliharaan'), findsOneWidget);
    expect(find.textContaining('Aplikasi HP Infois sedang dalam pemeliharaan'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('layar 320dp, huruf besar, mode gelap: beranda & artikel tanpa luapan', (tester) async {
    final server = FakeServer(helpHandler());
    await pumpApp(tester, server: server, size: const Size(640, 1200), pixelRatio: 2, brightness: Brightness.dark);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    await openHelpFromAccount(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('help-category-penjualan')), findsOneWidget);
    expect(Theme.of(tester.element(find.byKey(const Key('help-home')))).brightness, Brightness.dark);

    await openArticle(tester, 'cara-membuat-invoice');
    expect(tester.takeException(), isNull);
    await tester.drag(find.byKey(const Key('help-article')), const Offset(0, -3000));
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  group('tautan Pusat Bantuan dari Tim AI', () {
    test('slug artikel dikenali dari /bantuan/{slug} dan /app/{perusahaan}/pusat-bantuan/artikel/{slug}', () {
      expect(helpArticleSlugFromUrl('https://dashboard.infois.ai/bantuan/cara-cetak-struk'), 'cara-cetak-struk');
      expect(helpArticleSlugFromUrl('https://dashboard.infois.ai/app/kopi-senja/pusat-bantuan/artikel/stok-opname'), 'stok-opname');
      expect(helpArticleSlugFromUrl('/bantuan/stok-opname'), 'stok-opname');
      expect(helpArticleSlugFromUrl('https://dashboard.infois.ai/bantuan/media/images/a.png'), isNull);
      expect(helpArticleSlugFromUrl('https://dashboard.infois.ai/bantuan'), isNull);
      expect(helpArticleSlugFromUrl('https://evil.example/bantuan/stok-opname'), isNull);
      expect(helpArticleSlugFromUrl('https://dashboard.infois.ai/app/kopi-senja/langganan'), isNull);
      expect(aiLinkAction('https://dashboard.infois.ai/bantuan/cara-cetak-struk'), AiLinkAction.helpArticle);
      expect(aiLinkAction('https://dashboard.infois.ai/app/kopi/pusat-bantuan/artikel/stok-opname'), AiLinkAction.helpArticle);
      expect(aiLinkAction('https://dashboard.infois.ai/app/kopi/pusat-bantuan'), AiLinkAction.block, reason: 'Halaman panel lain tetap tidak dibuka.');
    });

    testWidgets('mengetuk tautan artikel di jawaban Tim AI membuka layar artikel aplikasi', (tester) async {
      final opened = <String>[];
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, __) => const Scaffold(body: AiMarkdown('Lihat [panduan cetak struk](https://dashboard.infois.ai/bantuan/cara-cetak-struk) atau [stok](https://dashboard.infois.ai/app/kopi/pusat-bantuan/artikel/stok-opname).'))),
        GoRoute(
          path: '/bantuan/artikel/:slug',
          builder: (_, state) {
            opened.add(state.pathParameters['slug']!);
            return Scaffold(body: Text('artikel ${state.pathParameters['slug']}'));
          },
        ),
      ]);
      await tester.pumpWidget(ProviderScope(overrides: [filePlatformProvider.overrideWithValue(files)], child: MaterialApp.router(routerConfig: router)));
      await tester.pumpAndSettle();

      await tester.tapOnText(find.textRange.ofSubstring('panduan cetak struk'));
      await tester.pumpAndSettle();
      expect(find.text('artikel cara-cetak-struk'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      await tester.tapOnText(find.textRange.ofSubstring('stok'));
      await tester.pumpAndSettle();
      expect(find.text('artikel stok-opname'), findsOneWidget);
      expect(opened, ['cara-cetak-struk', 'stok-opname']);
      expect(files.urls, isEmpty, reason: 'Tidak dibuka di browser.');
    });
  });

  test('ikon kategori: nama Heroicon → ikon Material, cadangan buku', () {
    expect(helpCategoryIcon('heroicon-o-chart-bar'), Icons.bar_chart_rounded);
    expect(helpCategoryIcon('heroicon-o-sparkles'), Icons.auto_awesome_outlined);
    expect(helpCategoryIcon('heroicon-o-tidak-dikenal'), Icons.menu_book_outlined);
  });
}

const articleHtml = '<h2 id="bagian-langkah-1">Langkah 1: Buka menu</h2><p>Klik <strong>Penjualan</strong>, lalu buka menu <em>Invoice</em>.</p>'
    '<p><img loading="lazy" src="https://dashboard.infois.ai/api/v1/help/media/images/menu.png" alt="Menu invoice"></p>'
    '<h2 id="bagian-langkah-2">Langkah 2: Isi data</h2><ul><li><p>Pilih pelanggan</p></li><li><p>Isi barang &amp; jumlahnya</p></li></ul>'
    '<figure class="help-media help-media-video"><a class="help-video" data-video="upload" href="https://dashboard.infois.ai/api/v1/help/media/videos/demo.mp4">Putar video</a><figcaption>Demo invoice</figcaption></figure>'
    '<figure class="help-media help-media-embed"><a class="help-video" data-video="youtube" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">Tonton di YouTube</a></figure>'
    '<aside class="help-callout help-callout-warning"><p class="help-callout-title">Penting</p><p>Jangan lupa simpan</p></aside>'
    '<p>Baca juga <a href="https://dashboard.infois.ai/bantuan/stok-opname" data-help-article="stok-opname">stok opname</a> untuk menghitung barang.</p>'
    '<p>Lihat juga <a href="https://dashboard.infois.ai/app/kopi/invoices">daftar invoice</a> di komputer.</p>'
    '<p>Isi ulang koin lewat menu Dompet Koin bila jatah habis.</p>'
    '<p>Paragraf panjang pertama untuk mengisi halaman supaya daftar isi benar-benar menggulir. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p>'
    '<p>Paragraf panjang kedua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit.</p>'
    '<p>Paragraf panjang ketiga. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Sed ut perspiciatis unde omnis.</p>'
    '<table><tr><th>Kolom</th><th>Isi</th></tr><tr><td>Tanggal</td><td>Hari ini</td></tr></table>'
    '<h3 id="bagian-kirim">Kirim</h3><p>Selesai. Invoice terkirim ke pelanggan.</p>';

Map<String, dynamic> summaryJson(String slug, String title, {String summary = 'Ringkasan singkat.', bool featured = false, String? cover}) => {
      'id': slug.hashCode,
      'slug': slug,
      'title': title,
      'summary': summary,
      'category': {'id': 1, 'name': 'Penjualan', 'slug': 'penjualan', 'icon': 'heroicon-o-shopping-cart'},
      'reading_minutes': 2,
      'is_featured': featured,
      'cover_url': cover,
      'updated_at': '2026-10-12T09:00:00+07:00',
    };

Map<String, dynamic> articleJson(String slug, String title, String html, {List<Map<String, dynamic>> headings = const [], List<Map<String, dynamic>> related = const [], String? cover}) => {
      'article': {
        ...summaryJson(slug, title, cover: cover),
        'published_at': '2026-10-01T09:00:00+07:00',
        'view_count': 12,
        'my_vote': null,
        'html': html,
        'headings': headings,
        'videos': [],
      },
      'related': related,
    };

/// Server palsu: sinkron minimal + semua endpoint Pusat Bantuan (API.md).
Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) helpHandler() {
  return (options, body) {
    final path = options.path;
    switch (path) {
      case 'ping':
        return {'ok': true, 'min_app_version': '1.0.0'};
      case 'sync/push':
        return {'results': []};
      case 'sync/pull':
        return {
          'cursor': 'c1',
          'full': true,
          'tenant': {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'},
          'receipt': {'width': 58, 'company': {'name': 'Warung Tes'}},
          'device': {'id': 3, 'code': 'K1', 'name': 'HP Tes'},
          'menus': {'pos': true, 'ai': true, 'printer': true},
          'products': {'items': [], 'ids': [1, 2]},
          'customers': {'items': [], 'ids': [7]},
          'accounts': {'items': [], 'ids': [], 'default_cash_id': null, 'default_transfer_id': null},
          'warehouses': {'items': [], 'ids': []},
          'number_blocks': [],
          'open_shift': null,
        };
      case 'help':
        return {
          'categories': [
            {'id': 1, 'name': 'Penjualan', 'slug': 'penjualan', 'description': 'Invoice & kasir', 'icon': 'heroicon-o-shopping-cart', 'article_count': 2},
            {'id': 2, 'name': 'Laporan', 'slug': 'laporan', 'description': null, 'icon': 'heroicon-o-chart-bar', 'article_count': 1},
          ],
          'featured': [summaryJson('cara-membuat-invoice', 'Cara membuat invoice', featured: true)],
          'popular': [summaryJson('mencatat-pembayaran', 'Mencatat pembayaran')],
          'min_search_length': 2,
        };
      case 'help/search':
        final q = options.queryParameters['q']?.toString() ?? '';
        return {
          'query': q,
          'too_short': q.length < 2,
          'results': [if (q == 'stok') summaryJson('stok-opname', 'Stok opname bulanan')],
        };
      case 'help/categories/penjualan':
        return {
          'category': {'id': 1, 'name': 'Penjualan', 'slug': 'penjualan', 'description': 'Invoice & kasir', 'icon': 'heroicon-o-shopping-cart', 'article_count': 2},
          'articles': [summaryJson('cara-membuat-invoice', 'Cara membuat invoice'), summaryJson('mencatat-pembayaran', 'Mencatat pembayaran')],
        };
      case 'help/articles/cara-membuat-invoice':
        return articleJson(
          'cara-membuat-invoice',
          'Cara membuat invoice',
          articleHtml,
          cover: 'https://dashboard.infois.ai/api/v1/help/media/covers/sampul.png',
          headings: [
            {'id': 'bagian-langkah-1', 'text': 'Langkah 1: Buka menu', 'level': 2},
            {'id': 'bagian-langkah-2', 'text': 'Langkah 2: Isi data', 'level': 2},
            {'id': 'bagian-kirim', 'text': 'Kirim', 'level': 3},
          ],
          related: [summaryJson('mencatat-pembayaran', 'Mencatat pembayaran')],
        );
      case 'help/articles/mencatat-pembayaran':
        return articleJson('mencatat-pembayaran', 'Mencatat pembayaran', '<p>Isi artikel pembayaran.</p>');
      case 'help/articles/stok-opname':
        return articleJson('stok-opname', 'Stok opname bulanan', '<p>Isi artikel stok opname.</p>');
      case 'help/articles/sedang-pemeliharaan':
        return {
          '_status': 503,
          'code': 'kanal_pemeliharaan',
          'message': 'Aplikasi HP Infois sedang dalam pemeliharaan. Penjualan yang tersimpan di HP tetap aman dan terkirim otomatis setelah selesai.',
        };
      case 'help/articles/cara-membuat-invoice/feedback':
        return {'my_vote': body?['helpful'] == true, 'message': body?['helpful'] == true ? 'Terima kasih! Senang bisa membantu.' : 'Terima kasih atas masukannya, kami akan memperbaiki artikel ini.'};
    }
    if (path.startsWith('help/media/')) {
      return {'isi': 'media'};
    }
    return {'_status': 404, 'message': 'Tidak ditemukan.', 'code': 'tidak_ditemukan'};
  };
}

/// Seperti [settle], tetapi memberi waktu I/O sungguhan (menulis file video).
Future<void> ioSettle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
