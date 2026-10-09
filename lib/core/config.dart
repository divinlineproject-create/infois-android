import 'package:flutter/foundation.dart' show kReleaseMode;

/// Konfigurasi aplikasi.
class AppConfig {
  AppConfig._();

  static const String name = 'Infois';

  /// Versi aplikasi (samakan dengan pubspec.yaml); dikirim di header X-App-Version.
  static const String version = '1.0.0';

  /// Server bawaan: rilis → produksi; debug → emulator Android (localhost
  /// komputer = 10.0.2.2). HP fisik saat uji coba harus mengganti alamat ini
  /// di layar Masuk › Server (mis. http://192.168.1.10:8000).
  static const String productionServerUrl = 'https://dashboard.infois.ai';
  static const String defaultServerUrl = String.fromEnvironment('INFOIS_SERVER', defaultValue: kReleaseMode ? productionServerUrl : 'http://10.0.2.2:8000');

  /// Batas waktu cek internet ke /ping.
  static const Duration pingTimeout = Duration(seconds: 5);

  /// Minta jatah nomor baru bila sisa nomor kurang dari ini.
  static const int numberBlockLowWatermark = 100;
}

/// Bandingkan versi "1.2.3": negatif bila a < b.
int compareVersions(String a, String b) {
  List<int> parts(String value) => value.split(RegExp(r'[.+-]')).take(3).map((part) => int.tryParse(part) ?? 0).toList();
  final left = parts(a);
  final right = parts(b);
  for (var i = 0; i < 3; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) {
      return l.compareTo(r);
    }
  }
  return 0;
}
