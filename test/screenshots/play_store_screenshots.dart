// Screenshot Play Store dari layar aplikasi yang sebenarnya (widget test,
// data contoh). Tidak ikut `flutter test` biasa (nama file tanpa akhiran
// `_test.dart`). Jalankan:
//
//   SHOTS_DIR=/path/keluaran flutter test test/screenshots/play_store_screenshots.dart
//
// Hasil: phone-*.png 1080x1920, tablet7-*.png 1200x1920, tablet10-*.png
// 1600x2560 (PNG tanpa alfa tidak wajib; Play menerima PNG/JPEG 24-bit).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai_flow_test.dart' as ai;
import '../reports_flow_test.dart' as reports;
import '../support/fakes.dart';
import '../support/file_fakes.dart';

const _products = [
  Product(id: 1, name: 'Kopi Susu Gula Aren', unit: 'gelas', price: '22000.00'),
  Product(id: 2, name: 'Americano', unit: 'gelas', price: '20000.00'),
  Product(id: 3, name: 'Cappuccino', unit: 'gelas', price: '26000.00'),
  Product(id: 4, name: 'Es Teh Leci', unit: 'gelas', price: '18000.00'),
  Product(id: 5, name: 'Matcha Latte', unit: 'gelas', price: '28000.00'),
  Product(id: 6, name: 'Roti Bakar Cokelat', unit: 'porsi', price: '17000.00', trackInventory: true, stockQuantity: '24.000000'),
  Product(id: 7, name: 'Croissant Butter', unit: 'pcs', price: '21000.00', trackInventory: true, stockQuantity: '12.000000'),
  Product(id: 8, name: 'Pisang Goreng Keju', unit: 'porsi', price: '16000.00', trackInventory: true, stockQuantity: '3.000000', minimumStock: '5.000000'),
  Product(id: 9, name: 'Nasi Goreng Kampung', unit: 'porsi', price: '32000.00'),
  Product(id: 10, name: 'Air Mineral', unit: 'botol', price: '6000.00', trackInventory: true, stockQuantity: '48.000000'),
];

Map<String, dynamic>? Function(RequestOptions, Map<String, dynamic>?) _handler() {
  final aiHandler = ai.aiHandler();
  final reportsHandler = reports.reportsHandler();
  return (options, body) {
    final path = options.path;
    if (path == 'sync/pull') {
      return {
        'cursor': 'c1',
        'full': true,
        'tenant': {'id': 1, 'name': 'Kopi Senja', 'prices_include_tax': true, 'sales_tax_name': 'PPN', 'sales_tax_rate': '0.00'},
        'receipt': {'width': 58, 'company': {'name': 'Kopi Senja'}},
        'device': {'id': 3, 'code': 'K1', 'name': 'HP Kasir'},
        'menus': {'pos': true, 'shift': false, 'ai': true, 'reports': true, 'records': true, 'printer': true},
        'products': {'items': [], 'ids': [for (final product in _products) product.id]},
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
    }
    if (path.startsWith('reports/')) {
      return reportsHandler(options, body);
    }
    return aiHandler(options, body);
  };
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final file in files) {
      loader.addFont(File(file).readAsBytes().then((bytes) => ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  final poppins = [for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/Poppins-$weight.ttf'];
  await family('Poppins', poppins);
  // Teks tanpa fontFamily (mis. label grafik CustomPaint) memakai font tes
  // berbentuk kotak; di HP memakai font sistem. Ganti dengan Poppins.
  await family('FlutterTest', poppins);
  await family('Roboto', poppins);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final icons = '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  if (File(icons).existsSync()) {
    await family('MaterialIcons', [icons]);
  }
}

void main() {
  final outDir = Platform.environment['SHOTS_DIR'] ?? 'build/play-shots';

  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
    await _loadFonts();
  });

  final boundaryKey = GlobalKey();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpApp(WidgetTester tester, Size size, double ratio) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    const tenant = TenantSummary(id: 1, name: 'Kopi Senja', roleLabel: 'Pemilik', menus: Menus(pos: true, ai: true, reports: true, records: true));
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@kopisenja.example'},
        'tenants': [tenant.toJson()],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: {'pos': true, 'shift': false, 'add_customer': true, 'printer': true, 'ai': true, 'reports': true, 'records': true});
      await db.upsertProducts(_products);
      await db.setJson(MetaKeys.tenant, {'id': 1, 'name': 'Kopi Senja', 'prices_include_tax': true, 'sales_tax_name': 'PPN', 'sales_tax_rate': '0.00'});
      return db;
    });
    await tester.pumpWidget(RepaintBoundary(
      key: boundaryKey,
      child: ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          localDbOpenerProvider.overrideWithValue((_) async => local!),
          apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(FakeServer(_handler()))),
          connectivityStreamProvider.overrideWithValue(const Stream.empty()),
          printerTransportProvider.overrideWithValue(FakePrinter()),
          filePlatformProvider.overrideWithValue(FakeFilePlatform()),
        ],
        child: const InfoisApp(),
      ),
    ));
    await settle(tester);
  }

  Future<void> shot(WidgetTester tester, String name, double ratio) async {
    await settle(tester);
    final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$outDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(NavigationDestination, label));
    await settle(tester);
  }

  // Ikon resolusi tinggi 512x512 dan grafik fitur 1024x500 untuk halaman toko.
  testWidgets('grafik toko: ikon 512 & grafik fitur 1024x500', (tester) async {
    final bytes = await tester.runAsync(() => File('assets/images/infois-mark.png').readAsBytes());
    final mark = MemoryImage(bytes!);

    Future<void> render(String name, Size size, Widget child) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RepaintBoundary(key: boundaryKey, child: Directionality(textDirection: TextDirection.ltr, child: child)));
      await tester.runAsync(() => precacheImage(mark, tester.element(find.byType(Directionality))));
      await tester.pump();
      await shot(tester, name, 1);
    }

    await render(
      'store-icon-512',
      const Size(512, 512),
      ColoredBox(color: Colors.white, child: Center(child: Image(image: mark, width: 360, height: 360))),
    );
    await render(
      'feature-graphic-1024x500',
      const Size(1024, 500),
      ColoredBox(
        color: const Color(0xFF0A7F3E),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 72),
          child: Row(children: [
            Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(44)),
              child: Center(child: Image(image: mark, width: 150, height: 150)),
            ),
            const SizedBox(width: 56),
            const Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Infois POS', style: TextStyle(fontFamily: 'Poppins', fontSize: 64, fontWeight: FontWeight.w700, color: Colors.white, height: 1.1)),
                SizedBox(height: 12),
                Text('Kasir, pembukuan, dan Tim AI untuk usaha Anda', style: TextStyle(fontFamily: 'Poppins', fontSize: 30, fontWeight: FontWeight.w500, color: Colors.white, height: 1.3)),
              ]),
            ),
          ]),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  final devices = <String, (Size, double)>{
    'phone': (const Size(1080, 1920), 2.625),
    'tablet7': (const Size(1200, 1920), 2),
    'tablet10': (const Size(1600, 2560), 2),
  };

  for (final MapEntry(key: device, value: (size, ratio)) in devices.entries) {
    testWidgets('$device: kasir, keranjang, Tim AI, laporan', (tester) async {
      await pumpApp(tester, size, ratio);

      // 1. Kasir: katalog + pesanan berjalan.
      for (final name in ['Cappuccino', 'Cappuccino', 'Americano', 'Croissant Butter']) {
        await tester.tap(find.text(name).first);
        await tester.pump(const Duration(milliseconds: 100));
      }
      await shot(tester, '$device-1-kasir', ratio);

      // 2. Tim AI: tim & saran.
      await tab(tester, 'Tim AI');
      await shot(tester, '$device-2-tim-ai', ratio);

      // 3. Percakapan dengan usulan penjualan.
      await tester.tap(find.byKey(const Key('ai-history')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('conversation-12')));
      await settle(tester);
      // Gulir ke atas: pesan pengguna + jawaban Tim AI + kartu usulan.
      await tester.dragFrom(Offset(size.width / ratio / 2, size.height / ratio * 0.3), Offset(0, size.height / ratio * 0.5));
      await settle(tester);
      await shot(tester, '$device-3-usulan', ratio);

      // 4. Laporan.
      await tab(tester, 'Laporan');
      await shot(tester, '$device-4-laporan', ratio);

      await tester.pumpWidget(const SizedBox());
    });
  }
}
