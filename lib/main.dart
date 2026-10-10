import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'data/app_storage.dart';
import 'services/background_sync.dart';
import 'state/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('id_ID');
  await lockPhoneToPortrait();
  final storage = await AppStorage.load();
  try {
    await registerBackgroundSync();
  } on Exception {
    // Sinkron latar opsional; sinkron utama tetap saat aplikasi dibuka.
  }
  runApp(ProviderScope(overrides: [storageProvider.overrideWithValue(storage)], child: const InfoisApp()));
}

/// HP (sisi terpendek < 600 dp) hanya tegak: dalam posisi miring layar Kasir
/// terlalu pendek untuk katalog + bilah pesanan. Tablet bebas berputar
/// (dua panel: katalog + pesanan).
Future<void> lockPhoneToPortrait() async {
  final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
  if (view == null || view.devicePixelRatio <= 0) {
    return;
  }
  if (isPhoneSize(view.physicalSize / view.devicePixelRatio)) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  }
}

bool isPhoneSize(Size logical) => logical.shortestSide > 0 && logical.shortestSide < 600;
