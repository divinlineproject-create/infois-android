/// Konfigurasi aplikasi.
class AppConfig {
  AppConfig._();

  static const String name = 'Infois POS';

  /// Versi aplikasi (samakan dengan pubspec.yaml); dikirim di header X-App-Version.
  static const String version = '1.1.0';

  /// Alamat server produksi.
  static const String productionServerUrl = 'https://dashboard.infois.ai';

  /// Server aplikasi, PERMANEN sejak build (semua mode, termasuk debug).
  /// Tidak bisa diganti dari aplikasi: pindah server = rilis baru di Play
  /// Store. Pengembang menguji ke server lain dengan
  /// `--dart-define=INFOIS_SERVER=http://127.0.0.1:8099` (emulator Android:
  /// `http://10.0.2.2:8000`).
  static const String serverUrl = String.fromEnvironment('INFOIS_SERVER', defaultValue: productionServerUrl);

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
