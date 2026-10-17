import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:infois/app.dart';
import 'package:infois/core/config.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/code_scanner.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/services/permission_gate.dart';
import 'package:infois/services/product_photos.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/photo_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/focus.dart';
import 'package:infois/ui/screens/kasir_screen.dart';
import 'package:infois/ui/screens/pos_item_sheet.dart';
import 'package:infois/ui/screens/scan_screen.dart';
import 'package:infois/ui/widgets/pos_categories.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

/// Katalog kasir 1.0: foto barang (cache HP, token + X-Tenant), chip
/// kategori, scan barcode kamera (pemindai palsu), scanner keyboard tanpa
/// fokus, dan keyboard yang tidak muncul sendiri.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  const kopiKategori = ProductCategory(id: 10, name: 'Minuman', sort: 1);
  const makanan = ProductCategory(id: 20, name: 'Makanan', sort: 2);
  const kosong = ProductCategory(id: 30, name: 'Kategori kosong', sort: 0);
  const kopiFoto = Product(
    id: 1,
    name: 'Kopi susu',
    unit: 'gelas',
    price: '18000.00',
    barcode: '8990001',
    sku: 'KS-1',
    categoryId: 10,
    categoryName: 'Minuman',
    hasPhoto: true,
    photoVersion: 'abc123',
  );
  const rotiKat = Product(id: 2, name: 'Roti bakar', unit: 'pcs', price: '15000.00', sku: 'RT-1', categoryId: 20, categoryName: 'Makanan');
  const gula = Product(id: 3, name: 'Gula aren', unit: 'kg', price: '30000.00', sku: '8990001X');

  Future<Directory> tempDir(WidgetTester? tester) async {
    final dir = tester == null ? await Directory.systemTemp.createTemp('infois_foto') : (await tester.runAsync(() => Directory.systemTemp.createTemp('infois_foto')))!;
    addTearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
    return dir;
  }

  List<int> pngBytes() => img.encodePng(img.Image(width: 2, height: 2));

  group('data katalog', () {
    test('Product: barcode, kategori, foto bolak-balik JSON; server lama tanpa has_photo', () {
      final json = {
        'id': 5,
        'name': 'Es teh',
        'unit': 'gelas',
        'price': '5000',
        'barcode': ' 123 ',
        'category_id': 10,
        'category': {'id': 10, 'name': 'Minuman'},
        'has_photo': true,
        'photo_version': 'v1',
        'photo_url': 'https://server/api/v1/products/5/photo',
        'photo_thumb_url': 'https://server/api/v1/products/5/photo?size=thumb',
      };
      final product = Product.fromJson(json);
      expect(product.barcode, '123');
      expect(product.categoryId, 10);
      expect(product.categoryName, 'Minuman');
      expect(product.hasPhoto, isTrue);
      final copy = Product.fromJson(product.toJson());
      expect(copy.toJson(), product.toJson());

      final legacy = Product.fromJson({'id': 6, 'name': 'Lama', 'unit': 'pcs', 'price': '1', 'photo_url': 'x', 'category': {'id': 3, 'name': 'A'}});
      expect(legacy.hasPhoto, isTrue);
      expect(legacy.categoryId, 3);
      expect(Product.fromJson({'id': 7, 'name': 'Polos', 'unit': 'pcs', 'price': '1'}).hasPhoto, isFalse);
    });

    test('kode scan: barcode dulu, lalu SKU (huruf besar/kecil sama); cari ikut barcode', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      await local.upsertProducts([kopiFoto, rotiKat, gula]);
      expect((await local.productByCode('8990001'))!.id, 1);
      expect((await local.productByCode('rt-1'))!.id, 2);
      expect((await local.productByCode('8990001x'))!.id, 3, reason: 'SKU barang lain yang mirip barcode tetap cocok lewat SKU.');
      expect(await local.productByCode('TIDAK-ADA'), isNull);
      expect((await local.products(query: '8990001')).map((product) => product.id), containsAll([1, 3]));
    });

    test('database versi 2 dinaikkan ke 3: kolom barcode/kategori + tarikan berikutnya penuh', () async {
      sqfliteFfiInit();
      final dir = await tempDir(null);
      final path = '${dir.path}/v2.db';
      final old = await databaseFactoryFfiNoIsolate.openDatabase(path, options: OpenDatabaseOptions(version: 2, onCreate: (db, _) async {
        await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
        await db.execute('CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT NOT NULL, sku TEXT, search TEXT NOT NULL, is_active INTEGER NOT NULL, data TEXT NOT NULL)');
        await db.insert('products', {'id': 1, 'name': 'Kopi', 'sku': 'K1', 'search': 'kopi k1', 'is_active': 1, 'data': jsonEncode(const Product(id: 1, name: 'Kopi', unit: 'gelas', price: '1', sku: 'K1').toJson())});
        await db.insert('meta', {'key': MetaKeys.cursor, 'value': '2026-10-01T00:00:00Z'});
        await db.insert('meta', {'key': MetaKeys.lastFullPull, 'value': '2026-10-01T00:00:00Z'});
      }));
      await old.close();

      final local = await LocalDb.open(path, factory: databaseFactoryFfiNoIsolate);
      addTearDown(local.close);
      expect((await local.productByCode('k1'))!.name, 'Kopi');
      expect(await local.getMeta(MetaKeys.cursor), isNull, reason: 'Sinkron berikutnya penuh supaya barcode & kategori terisi.');
      await local.upsertProducts([kopiFoto]);
      expect((await local.productByCode('8990001'))!.id, 1);
    });

    test('sync/pull menyimpan kategori dan field katalog baru', () async {
      final local = await memoryDb();
      addTearDown(local.close);
      final server = FakeServer((options, _) {
        if (options.path == 'sync/pull') {
          return {
            'cursor': 'c1',
            'products': {
              'items': [
                {...kopiFoto.toJson(), 'category': {'id': 10, 'name': 'Minuman'}, 'photo_url': 'http://tes/api/v1/products/1/photo'},
                rotiKat.toJson(),
              ],
              'ids': [1, 2],
            },
            'categories': {
              'items': [makanan.toJson(), kopiKategori.toJson()],
              'ids': [20, 10],
            },
            'customers': {'items': [], 'ids': []},
            'tenant': {'id': 1, 'name': 'Warung'},
            'receipt': {'width': 58, 'company': {'name': 'Warung'}},
            'device': {'id': 1, 'code': 'K1'},
            'menus': {'pos': true},
            'accounts': {'items': [], 'ids': []},
            'warehouses': {'items': [], 'ids': []},
            'user': {'id': 1, 'name': 'Sari'},
            'number_blocks': [],
          };
        }
        return {};
      });
      final engine = SyncEngine(api: fakeApi(server), local: local, outbox: OutboxStore(local));
      await engine.pull(forceFull: true);
      expect((await local.categories()).map((category) => category.name), ['Minuman', 'Makanan'], reason: 'Urut sort lalu nama.');
      final kopi = (await local.productByCode('8990001'))!;
      expect(kopi.hasPhoto, isTrue);
      expect(kopi.photoVersion, 'abc123');
      expect(kopi.categoryName, 'Minuman');
    });

    test('chip kategori: Semua + kategori berisi barang (urut) + Lainnya; kategori kosong disembunyikan', () {
      final chips = posCategories([kopiFoto, rotiKat, gula], [kosong, makanan, kopiKategori]..sort((a, b) => a.sort.compareTo(b.sort)));
      expect(chips.map((chip) => chip.label), ['Semua', 'Minuman', 'Makanan', 'Lainnya']);
      expect(chips.map((chip) => chip.count), [3, 1, 1, 1]);
      expect(chips[1].matches(kopiFoto), isTrue);
      expect(chips[1].matches(rotiKat), isFalse);
      expect(chips.last.matches(gula), isTrue);
      // Kategori yang hanya dikenal dari barang (daftar belum tersimpan).
      expect(posCategories([kopiFoto, rotiKat]).map((chip) => chip.label), ['Semua', 'Makanan', 'Minuman']);
    });
  });

  group('foto barang', () {
    test('unduh sekali dengan token + X-Tenant, lalu dari HP (offline); versi baru diunduh ulang & versi lama dihapus', () async {
      final dir = await tempDir(null);
      var online = true;
      final server = FakeServer((options, _) => online ? {'foto': 'isi'} : null);
      final api = fakeApi(server, tenantId: 7);
      final store = ProductPhotoStore(directory: dir, download: api.bytes);

      final first = await store.load(kopiFoto, PhotoSize.thumb);
      expect(first, isNotNull);
      expect(server.requests.single.uri.toString(), 'http://tes/api/v1/products/1/photo?size=thumb&v=abc123');
      expect(server.requests.single.headers['Authorization'], 'Bearer token');
      expect(server.requests.single.headers['X-Tenant'], '7');

      online = false;
      final again = ProductPhotoStore(directory: dir, download: api.bytes);
      expect((await again.load(kopiFoto, PhotoSize.thumb))!.path, first!.path, reason: 'Offline setelah pertama dimuat: dari file HP.');
      expect(server.requests, hasLength(1));

      online = true;
      const replaced = Product(id: 1, name: 'Kopi susu', unit: 'gelas', price: '18000.00', hasPhoto: true, photoVersion: 'def456');
      final fresh = await again.load(replaced, PhotoSize.thumb);
      expect(fresh!.path, isNot(first.path));
      expect(await File(first.path).exists(), isFalse, reason: 'Versi lama dibuang.');

      await again.keepOnly({2});
      expect(await File(fresh.path).exists(), isFalse, reason: 'Barang yang sudah tidak ada: fotonya dibuang.');
    });

    test('tanpa foto / gagal: tidak mengunduh lagi sebelum jeda coba ulang', () async {
      final dir = await tempDir(null);
      final server = offlineServer();
      final store = ProductPhotoStore(directory: dir, download: fakeApi(server).bytes);
      expect(await store.load(rotiKat, PhotoSize.thumb), isNull);
      expect(server.requests, isEmpty, reason: 'has_photo false: tidak ada request.');
      expect(await store.load(kopiFoto, PhotoSize.full), isNull);
      expect(await store.load(kopiFoto, PhotoSize.full), isNull);
      expect(server.requests, hasLength(1));
      expect(server.requests.single.uri.toString(), 'http://tes/api/v1/products/1/photo?v=abc123');
    });
  });

  group('kasir', () {
    late List<String> haptics;

    Future<(LocalDb, FakeCodeScanner, _Gate)> pumpKasir(WidgetTester tester, {bool rationale = true, Directory? photos, Map<String, dynamic>? menus}) async {
      SharedPreferences.setMockInitialValues({
        'session': jsonEncode({
          'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
          'tenants': [const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, ai: true, reports: true, records: true)).toJson()],
        }),
        'tenant_id': 1,
      });
      FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
      final storage = await AppStorage.load();
      final local = await tester.runAsync(() async {
        final db = await memoryDb();
        await seedMaster(db, menus: menus ?? {'pos': true, 'ai': true, 'reports': true, 'records': true});
        await db.upsertProducts([kopiFoto, rotiKat, gula]);
        await db.saveCategories([kopiKategori, makanan, kosong]);
        return db;
      });
      haptics = [];
      ScanScreen.continuousPreference = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments.toString());
        }
        return null;
      });
      final scanner = FakeCodeScanner();
      final gate = _Gate(needs: rationale);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          localDbOpenerProvider.overrideWithValue((_) async => local!),
          apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(offlineServer())),
          connectivityStreamProvider.overrideWithValue(const Stream.empty()),
          printerTransportProvider.overrideWithValue(FakePrinter()),
          permissionGateProvider.overrideWithValue(gate),
          codeScannerFactoryProvider.overrideWithValue(() => scanner),
          photoRootProvider.overrideWithValue(() async => photos),
        ],
        child: const InfoisApp(),
      ));
      await settle(tester);
      return (local!, scanner, gate);
    }

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await settle(tester);
    }

    bool anyFieldFocused() => textFieldFocused();

    testWidgets('chip kategori menyaring grid; cari selalu di semua kategori', (tester) async {
      phone(tester);
      await pumpKasir(tester);
      expect(find.byKey(const Key('category-all')), findsOneWidget);
      expect(find.byKey(const Key('category-cat:10')), findsOneWidget);
      expect(find.byKey(const Key('category-cat:20')), findsOneWidget);
      expect(find.byKey(const Key('category-${PosCategory.noneKey}'), skipOffstage: false), findsOneWidget);
      expect(find.byKey(const Key('category-cat:30'), skipOffstage: false), findsNothing, reason: 'Kategori tanpa barang tidak tampil.');
      expect(find.byKey(const Key('category-unit:pcs')), findsNothing);
      expect(find.text('Minuman'), findsWidgets, reason: 'Nama kategori juga tampil di kartu barang.');

      await tap(tester, find.byKey(const Key('category-cat:20')));
      expect(find.byKey(const Key('product-1')), findsNothing);
      expect(find.byKey(const Key('product-2')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('kasir-search')), 'gula');
      await settle(tester);
      expect(find.byKey(const Key('product-3')), findsOneWidget, reason: 'Cari pindah ke Semua kategori.');
      expect((tester.widget(find.byKey(const Key('category-all'), skipOffstage: false)) as ChoiceChip).selected, isTrue);

      await tester.enterText(find.byKey(const Key('kasir-search')), '8990001');
      await settle(tester);
      expect(find.byKey(const Key('product-1')), findsOneWidget, reason: 'Cari dengan barcode.');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('foto barang dari cache HP di grid & lembar barang; tanpa foto = inisial', (tester) async {
      phone(tester);
      final root = await tempDir(tester);
      final folder = Directory('${root.path}/${ProductPhotoStore.folderName(1, 1)}');
      await tester.runAsync(() async {
        await folder.create(recursive: true);
        await File('${folder.path}/1_abc123_t').writeAsBytes(pngBytes());
        await File('${folder.path}/1_abc123_f').writeAsBytes(pngBytes());
      });
      await pumpKasir(tester, photos: root);
      // Cek file di HP (I/O sungguhan) berjalan di luar fake-async.
      await flushIo(tester);
      expect(find.byKey(const Key('product-photo-1')), findsOneWidget);
      expect(find.byKey(const Key('product-photo-2')), findsNothing, reason: 'Roti tanpa foto: inisial.');
      expect(find.text('RB'), findsOneWidget);

      await tester.longPress(find.byKey(const Key('product-1')));
      await flushIo(tester);
      expect(find.descendant(of: find.byKey(const Key('item-photo')), matching: find.byKey(const Key('product-photo-1'))), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('scan kamera: izin dijelaskan dulu, barang masuk pesanan + getar, scan terus dengan penghitung, kode asing, senter', (tester) async {
      phone(tester);
      final (_, scanner, gate) = await pumpKasir(tester);

      // "Nanti": kamera tidak dibuka.
      await tap(tester, find.byKey(const Key('scan-button')));
      expect(find.byKey(const Key('permission-rationale-camera')), findsOneWidget);
      expect(find.textContaining('tidak disimpan dan tidak dikirim'), findsOneWidget);
      await tap(tester, find.text('Nanti'));
      expect(find.byType(ScanScreen), findsNothing);

      // Lanjutkan → layar scan; satu kode = satu barang lalu kembali.
      await tap(tester, find.byKey(const Key('scan-button')));
      await tap(tester, find.byKey(const Key('permission-rationale-continue')));
      expect(gate.explained, [AppPermission.camera]);
      expect(find.byKey(const Key('fake-camera')), findsOneWidget);
      scanner.emit('8990001');
      await settle(tester);
      expect(find.byType(ScanScreen), findsNothing, reason: 'Mode satu barang: kembali ke kasir.');
      expect(find.text('Kopi susu masuk pesanan.'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('product-badge-1')), matching: find.text('1')), findsOneWidget);
      expect(haptics, isNotEmpty);
      expect(scanner.disposed, isTrue);

      // Scan terus: beberapa barang, kode yang masih terlihat tidak dobel.
      await tap(tester, find.byKey(const Key('scan-button')));
      expect(find.byKey(const Key('permission-rationale-camera')), findsNothing, reason: 'Penjelasan cukup sekali.');
      await tap(tester, find.byKey(const Key('scan-continuous')));
      scanner.emit('rt-1');
      await settle(tester);
      scanner.emit('rt-1');
      await settle(tester);
      expect((tester.widget(find.byKey(const Key('scan-count'))) as Text).data, '1');
      expect(find.text('Roti bakar'), findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(ScanScreen.repeatGap + const Duration(milliseconds: 50)));
      scanner.emit('rt-1');
      await settle(tester);
      expect((tester.widget(find.byKey(const Key('scan-count'))) as Text).data, '2', reason: 'Barang yang sama di-scan lagi setelah hilang dari kamera.');

      scanner.emit('0000-ASING');
      await settle(tester);
      expect(find.byKey(const Key('scan-not-found')), findsOneWidget);
      expect(find.textContaining('0000-ASING', findRichText: true), findsOneWidget);

      await tap(tester, find.byKey(const Key('scan-torch')));
      expect(scanner.torchToggles, 1);

      await tap(tester, find.byKey(const Key('scan-done')));
      expect(find.text('2 barang masuk pesanan.'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('product-badge-2')), matching: find.text('2')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('kamera ditolak: pesan jelas + ketik kode tetap bisa', (tester) async {
      phone(tester);
      final (_, scanner, _) = await pumpKasir(tester, rationale: false);
      scanner.problem = ScannerProblem.permissionDenied;
      await tap(tester, find.byKey(const Key('scan-button')));
      expect(find.byKey(const Key('scan-problem-permissionDenied')), findsOneWidget);
      expect(find.byKey(const Key('scan-open-settings')), findsOneWidget);
      await tap(tester, find.byKey(const Key('scan-type')));
      await tester.enterText(find.byKey(const Key('scan-code')), 'KS-1');
      await tap(tester, find.byKey(const Key('scan-add')));
      expect(find.byType(ScanScreen), findsNothing);
      expect(find.text('Kopi susu masuk pesanan.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('scanner keyboard (Bluetooth/USB) tanpa fokus isian: barang masuk, keyboard layar tidak muncul', (tester) async {
      phone(tester);
      await pumpKasir(tester);
      expect(anyFieldFocused(), isFalse);
      for (final key in [LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9, LogicalKeyboardKey.digit9, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit1]) {
        await tester.sendKeyEvent(key);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.text('Kopi susu masuk pesanan.'), findsOneWidget);
      expect(anyFieldFocused(), isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.descendant(of: find.byKey(const Key('product-badge-1')), matching: find.text('1')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    test('pengumpul scanner: ketikan cepat + Enter = kode; jeda lama memulai ulang', () {
      final buffer = ScannerKeyBuffer();
      KeyDownEvent down(LogicalKeyboardKey key, String? character, int ms) =>
          KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: key, character: character, timeStamp: Duration(milliseconds: ms));
      expect(buffer.feed(down(LogicalKeyboardKey.keyA, 'a', 0)), isNull);
      expect(buffer.feed(down(LogicalKeyboardKey.keyB, 'b', 500)), isNull, reason: 'Jeda lama: "a" dibuang.');
      expect(buffer.feed(down(LogicalKeyboardKey.digit1, '1', 510)), isNull);
      expect(buffer.feed(down(LogicalKeyboardKey.digit2, '2', 520)), isNull);
      expect(buffer.feed(down(LogicalKeyboardKey.enter, '\n', 530)), 'b12');
      expect(buffer.feed(down(LogicalKeyboardKey.digit1, '1', 540)), isNull);
      expect(buffer.feed(down(LogicalKeyboardKey.enter, null, 545)), isNull, reason: 'Terlalu pendek untuk kode.');
    });

    testWidgets('keyboard tidak muncul sendiri: tab utama, ganti tab, tutup lembar barang & Bayar, buka lagi aplikasi', (tester) async {
      phone(tester);
      await pumpKasir(tester);
      final search = find.byKey(const Key('kasir-search'));
      expect(anyFieldFocused(), isFalse, reason: 'Kasir dibuka: tidak ada isian fokus.');

      // Ketuk barang saat kotak cari fokus: keyboard ditutup.
      await tester.showKeyboard(search);
      await tap(tester, find.byKey(const Key('product-1')));
      expect(anyFieldFocused(), isFalse);

      // Lembar barang dibuka & ditutup (tanpa ketuk di luar kotak cari):
      // kotak cari tidak difokuskan ulang saat lembar tertutup.
      await tester.showKeyboard(search);
      expect(anyFieldFocused(), isTrue);
      final kasir = tester.element(find.byType(KasirScreen));
      unawaited(showPosItemSheet(kasir, rotiKat));
      await settle(tester);
      expect(find.byKey(const Key('item-add')), findsOneWidget);
      Navigator.of(kasir).pop();
      await settle(tester);
      expect(anyFieldFocused(), isFalse, reason: 'Tutup lembar barang: fokus tidak dipulihkan ke kotak cari.');
      expect(tester.testTextInput.isVisible, isFalse);

      // Bayar lalu kembali (tombol kembali HP).
      await tester.showKeyboard(search);
      GoRouter.of(kasir).push('/bayar');
      await settle(tester);
      expect(find.byKey(const Key('pay-total')), findsOneWidget);
      expect(anyFieldFocused(), isFalse);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byKey(const Key('pay-total')), findsNothing);
      expect(anyFieldFocused(), isFalse, reason: 'Kembali dari Bayar: kotak cari tidak difokuskan ulang.');

      // Tab utama satu per satu tanpa isian fokus.
      for (final label in ['Tim AI', 'Laporan', 'Catatan', 'Akun', 'Kasir']) {
        await tap(tester, find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
        expect(anyFieldFocused(), isFalse, reason: 'Tab $label dibuka tanpa isian fokus.');
        expect(tester.testTextInput.isVisible, isFalse, reason: 'Tab $label: keyboard tidak tampil.');
      }

      // Isian di tab lain (Catatan) yang fokus tidak terbawa ke Kasir.
      await tap(tester, find.descendant(of: find.byType(NavigationBar), matching: find.text('Catatan')));
      final catatanSearch = find.byWidgetPredicate((widget) => widget is TextField && widget.key is ValueKey<String> && (widget.key! as ValueKey<String>).value.startsWith('search-'));
      expect(catatanSearch, findsWidgets);
      await tester.showKeyboard(catatanSearch.first);
      expect(anyFieldFocused(), isTrue);
      await tap(tester, find.descendant(of: find.byType(NavigationBar), matching: find.text('Kasir')));
      expect(anyFieldFocused(), isFalse, reason: 'Isian di tab tersembunyi tidak memegang fokus.');

      // Aplikasi ke latar lalu dibuka lagi: isian tidak difokuskan ulang.
      await tester.showKeyboard(search);
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await settle(tester);
      expect(anyFieldFocused(), isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    test('nama aplikasi & versi', () {
      expect(AppConfig.name, 'Infois POS');
      expect(AppConfig.version, '1.0.0');
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('version: 1.0.0+1'));
      expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync(), contains('android:label="Infois POS"'));
    });
  });
}

class _Gate implements PermissionGate {
  _Gate({required this.needs});

  final bool needs;
  final List<AppPermission> explained = [];

  @override
  Future<bool> needsRationale(AppPermission permission) async => needs && !explained.contains(permission);

  @override
  Future<void> markExplained(AppPermission permission) async => explained.add(permission);
}

/// Beri giliran I/O sungguhan (file) di antara frame tes.
Future<void> flushIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator progres).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
