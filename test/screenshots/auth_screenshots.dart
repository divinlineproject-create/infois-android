// Gambar layar Masuk & kunci tablet (PIN) untuk ditinjau pemilik. Tidak ikut
// `flutter test` biasa. Jalankan:
//
//   SHOTS_DIR=/path/keluaran flutter test test/screenshots/auth_screenshots.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';
import '../support/file_fakes.dart';

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
  await family('FlutterTest', poppins);
  await family('Roboto', poppins);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final icons = '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  if (File(icons).existsSync()) {
    await family('MaterialIcons', [icons]);
  }
}

void main() {
  final outDir = Platform.environment['SHOTS_DIR'] ?? 'build/auth-shots';
  final boundaryKey = GlobalKey();

  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await _loadFonts();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester tester, Size size, double ratio, {required bool loggedIn}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(loggedIn
        ? {
            'session': jsonEncode({
              'user': {'id': 1, 'name': 'Sari Wulandari', 'email': 'sari@kopisenja.example'},
              'tenants': [const TenantSummary(id: 1, name: 'Kopi Senja', roleLabel: 'Owner', menus: Menus(pos: true), hasPin: true).toJson()],
            }),
            'tenant_id': 1,
            'pin_lock': true,
          }
        : {});
    FlutterSecureStorage.setMockInitialValues(loggedIn ? {'auth_token': 'token', 'device_uid': 'tablet'} : {});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db);
      return db;
    });
    final server = FakeServer((options, _) => switch (options.path) {
          'pin/users' => {
              'users': [
                {'id': 1, 'name': 'Sari Wulandari', 'role_label': 'Owner'},
                {'id': 2, 'name': 'Budi Santoso', 'role_label': 'Kasir'},
                {'id': 3, 'name': 'Dewi Lestari', 'role_label': 'Kasir'},
                {'id': 4, 'name': 'Raka Pratama', 'role_label': 'Kasir'},
              ],
            },
          _ => {},
        });
    await tester.pumpWidget(RepaintBoundary(
      key: boundaryKey,
      child: ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          localDbOpenerProvider.overrideWithValue((_) async => local!),
          apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
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

  testWidgets('masuk: HP tegak', (tester) async {
    await pump(tester, const Size(1080, 2340), 3, loggedIn: false);
    await shot(tester, 'masuk-hp', 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('masuk: tablet mendatar', (tester) async {
    await pump(tester, const Size(2560, 1600), 2, loggedIn: false);
    await shot(tester, 'masuk-tablet', 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kunci tablet: pilih nama lalu PIN', (tester) async {
    await pump(tester, const Size(2560, 1600), 2, loggedIn: true);
    await shot(tester, 'kunci-pilih-nama', 1);
    await tester.tap(find.byKey(const Key('lock-user-2')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('pin-key-2')));
    await tester.tap(find.byKey(const Key('pin-key-7')));
    await settle(tester);
    await shot(tester, 'kunci-pin', 1);
    await tester.pumpWidget(const SizedBox());
  });
}
