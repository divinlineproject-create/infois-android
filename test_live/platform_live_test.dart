// Uji coba platform aplikasi (masuk, unduh PDF ke Download, keluar) langsung
// ke server Laravel sungguhan (bukan bagian `flutter test` biasa).
// Jalankan:
//   flutter test test_live/platform_live_test.dart --dart-define=INFOIS_LIVE=http://127.0.0.1:8099 \
//     --dart-define=INFOIS_LIVE_EMAIL=pemilik@contoh.id --dart-define=INFOIS_LIVE_PASSWORD=rahasia
// (variabel lingkungan INFOIS_LIVE / INFOIS_LIVE_EMAIL / INFOIS_LIVE_PASSWORD juga bisa dipakai.)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/state/session.dart';

import '../test/support/file_fakes.dart';

String? _setting(String key, String define) => define.isNotEmpty ? define : Platform.environment[key];

void main() {
  final server = _setting('INFOIS_LIVE', const String.fromEnvironment('INFOIS_LIVE'));
  final email = _setting('INFOIS_LIVE_EMAIL', const String.fromEnvironment('INFOIS_LIVE_EMAIL'));
  final password = _setting('INFOIS_LIVE_PASSWORD', const String.fromEnvironment('INFOIS_LIVE_PASSWORD'));

  test('masuk → hanya perusahaan yang boleh aplikasi HP → unduh PDF nota → keluar mencabut token', () async {
    Map<String, dynamic> login;
    try {
      login = await ApiClient(baseUrl: server!).post('auth/login', data: {
        'email': email,
        'password': password,
        'device_name': 'HP Live Test Platform',
        'device_uid': 'hp-live-platform-${DateTime.now().millisecondsSinceEpoch}',
        'platform': 'android',
      });
    } on ApiException catch (error) {
      // Akun tanpa perusahaan yang boleh: pesan + alasan untuk layar Masuk.
      expect(error.code, ApiException.mobileAccessDeniedCode);
      final notice = AccessNotice.fromError(error);
      expect(notice.message, isNotEmpty);
      expect(notice.tenants, isNotEmpty);
      markTestSkipped('Akun uji tidak punya perusahaan yang boleh memakai aplikasi HP: ${notice.message}');
      return;
    }

    final rawTenants = [for (final item in login['tenants'] as List) Map<String, dynamic>.from(item as Map)];
    expect(rawTenants, isNotEmpty);
    for (final tenant in rawTenants) {
      if (tenant.containsKey('mobile_eligible')) {
        expect(tenant['mobile_eligible'], isTrue, reason: 'Login hanya mendaftar perusahaan yang boleh memakai aplikasi HP.');
      }
    }
    final tenants = [for (final item in rawTenants) TenantSummary.fromJson(item)];
    final tenant = tenants.firstWhere((item) => item.menus.records, orElse: () => tenants.first);
    final token = login['token'] as String;
    final client = ApiClient(baseUrl: server, token: token, tenantId: tenant.id);

    final me = await client.get('me');
    expect((me['tenants'] as List).map((item) => (item as Map)['id']), containsAll(tenants.map((item) => item.id)));

    if (tenant.menus.records) {
      final sales = await client.get('records/sales', query: {'limit': 1});
      final rows = sales['data'] as List;
      if (rows.isNotEmpty) {
        final sale = Map<String, dynamic>.from(rows.first as Map);
        final files = FakeFilePlatform();
        final progress = <double?>[];
        final saved = await FileDownloads(files).download(client, 'records/sales/${sale['id']}/pdf', '${sale['number']}.pdf', onProgress: progress.add);
        final bytes = File(saved.path).readAsBytesSync();
        expect(String.fromCharCodes(bytes.take(4)), '%PDF', reason: 'PDF asli dari server, diunduh dengan token + X-Tenant.');
        expect(saved.name, isNot(contains('/')));
        expect(saved.mime, 'application/pdf');
        expect(files.downloads.single.$2, saved.name);
        expect(progress, isNotEmpty);
      }
    }

    // Keluar: token dicabut di server; token lama ditolak 401.
    await ApiClient(baseUrl: server, token: token).post('auth/logout');
    try {
      await ApiClient(baseUrl: server, token: token).get('me');
      fail('Token lama masih diterima setelah keluar.');
    } on ApiException catch (error) {
      expect(error.unauthenticated, isTrue);
    }
  });
}
