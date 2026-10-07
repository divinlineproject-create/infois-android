import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'data/app_storage.dart';
import 'services/background_sync.dart';
import 'state/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('id_ID');
  final storage = await AppStorage.load();
  try {
    await registerBackgroundSync();
  } on Exception {
    // Sinkron latar opsional; sinkron utama tetap saat aplikasi dibuka.
  }
  runApp(ProviderScope(overrides: [storageProvider.overrideWithValue(storage)], child: const InfoisApp()));
}
