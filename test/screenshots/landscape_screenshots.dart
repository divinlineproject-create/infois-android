// Tampilan tablet miring (tablet kasir bersama) untuk ditinjau: kasir,
// bayar, catatan, laporan, Tim AI, kunci PIN. Tinggi layar sudah dikurangi
// bilah status & navigasi Android. Tidak ikut `flutter test` biasa. Jalankan:
//
//   SHOTS_DIR=/path/keluaran flutter test test/screenshots/landscape_screenshots.dart
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
import '../records_flow_test.dart' as records;
import '../reports_flow_test.dart' as reports;
import '../support/fakes.dart';
import '../support/file_fakes.dart';

const _products = [
  Product(id: 1, categoryId: 1, categoryName: 'Kopi', name: 'Kopi Susu Gula Aren', unit: 'gelas', price: '22000.00'),
  Product(id: 2, categoryId: 1, categoryName: 'Kopi', name: 'Americano', unit: 'gelas', price: '20000.00'),
  Product(id: 3, categoryId: 1, categoryName: 'Kopi', name: 'Cappuccino', unit: 'gelas', price: '26000.00'),
  Product(id: 4, categoryId: 2, categoryName: 'Minuman', name: 'Es Teh Leci', unit: 'gelas', price: '18000.00'),
  Product(id: 5, categoryId: 1, categoryName: 'Kopi', name: 'Matcha Latte', unit: 'gelas', price: '28000.00'),
  Product(id: 6, categoryId: 3, categoryName: 'Makanan', name: 'Roti Bakar Cokelat', unit: 'porsi', price: '17000.00', trackInventory: true, stockQuantity: '24.000000'),
  Product(id: 7, categoryId: 3, categoryName: 'Makanan', name: 'Croissant Butter', unit: 'pcs', price: '21000.00', trackInventory: true, stockQuantity: '12.000000'),
  Product(id: 8, categoryId: 3, categoryName: 'Makanan', name: 'Pisang Goreng Keju', unit: 'porsi', price: '16000.00', trackInventory: true, stockQuantity: '3.000000', minimumStock: '5.000000'),
  Product(id: 9, categoryId: 3, categoryName: 'Makanan', name: 'Nasi Goreng Kampung', unit: 'porsi', price: '32000.00'),
  Product(id: 10, categoryId: 2, categoryName: 'Minuman', name: 'Air Mineral', unit: 'botol', price: '6000.00', trackInventory: true, stockQuantity: '48.000000'),
];

Map<String, dynamic>? Function(RequestOptions, Map<String, dynamic>?) _handler() {
  final aiHandler = ai.aiHandler();
  final reportsHandler = reports.reportsHandler();
  final recordsHandler = records.recordsHandler();
  return (options, body) {
    final path = options.path;
    if (path == 'sync/pull') {
      return {
        'cursor': 'c1',
        'full': true,
        'tenant': {'id': 1, 'name': 'Kopi Senja', 'prices_include_tax': true, 'sales_tax_name': 'PPN', 'sales_tax_rate': '0.00'},
        'receipt': {'width': 58, 'company': {'name': 'Kopi Senja'}},
        'device': {'id': 3, 'code': 'K1', 'name': 'HP Kasir'},
        'menus': {'pos': true, 'shift': true, 'ai': true, 'reports': true, 'records': true, 'printer': true, 'stock': true},
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
    if (path.startsWith('records/')) {
      return recordsHandler(options, body);
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
  final outDir = Platform.environment['SHOTS_DIR'] ?? 'build/landscape-shots';

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

  const ownerPermissions = ['ViewAny:Invoice', 'View:Invoice', 'ViewAny:Bill', 'ViewAny:JournalEntry', 'ViewAny:Account', 'ViewAny:ProductService', 'ViewAny:Customer', 'ViewAny:Supplier', 'void-invoice', 'view-reports'];

  Future<void> pumpApp(WidgetTester tester, Size size, double ratio) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    const tenant = TenantSummary(id: 1, name: 'Kopi Senja', roleLabel: 'Pemilik', menus: Menus(pos: true, shift: true, ai: true, reports: true, records: true, stock: true, cashJournal: true), permissions: ownerPermissions);
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
      await seedMaster(db, menus: {'pos': true, 'shift': true, 'add_customer': true, 'printer': true, 'ai': true, 'reports': true, 'records': true, 'stock': true});
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

  Future<void> tab(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key('nav-$key')));
    await settle(tester);
  }

  // Tinggi = layar dikurangi bilah status (24 dp) & navigasi Android (48 dp).
  final devices = <String, (Size, double)>{
    'tab8': (const Size(1340, 692), 1.5), // 893×461 dp (8" miring)
    'tab7': (const Size(2048, 1056), 2), // 1024×528 dp (7" miring)
    'tab10': (const Size(2560, 1456), 2), // 1280×728 dp (10" miring)
  };

  for (final MapEntry(key: device, value: (size, ratio)) in devices.entries) {
    testWidgets('$device miring: kasir, bayar, catatan, laporan, Tim AI', (tester) async {
      await pumpApp(tester, size, ratio);
      await shot(tester, '$device-0-kasir-belum-dibuka', ratio);
      await tester.tap(find.byKey(const Key('open-shift')));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, '200000');
      await tester.tap(find.byKey(const Key('opening-save')));
      await settle(tester);

      for (final id in [3, 3, 2, 7, 5]) {
        await tester.ensureVisible(find.byKey(Key('product-$id')));
        await tester.tap(find.byKey(Key('product-$id')));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await shot(tester, '$device-1-kasir', ratio);

      await tester.tap(find.byKey(const Key('go-pay')));
      await settle(tester);
      await shot(tester, '$device-2-bayar', ratio);
      Navigator.of(tester.element(find.byKey(const Key('pay-submit')))).pop();
      await settle(tester);

      await tab(tester, 'catatan');
      await shot(tester, '$device-3-catatan', ratio);

      await tab(tester, 'laporan');
      await shot(tester, '$device-4-laporan', ratio);

      await tab(tester, 'ai');
      await shot(tester, '$device-5-tim-ai', ratio);

      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('HP tegak: Catatan dengan bilah samping (laci)', (tester) async {
    await pumpApp(tester, const Size(1080, 2340), 2.625);
    await tester.tap(find.byKey(const Key('nav-catatan')));
    await settle(tester);
    await shot(tester, 'hp-1-catatan', 2.625);
    await tester.tap(find.byKey(const Key('catatan-menu')));
    await settle(tester);
    await shot(tester, 'hp-2-catatan-laci', 2.625);
    await tester.pumpWidget(const SizedBox());
  });
}
