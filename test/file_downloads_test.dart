import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/data/outbox_store.dart';
import 'package:infois/domain/ai_models.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/widgets/ai_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/file_fakes.dart';

/// Unduhan (PDF nota, lampiran, file Tim AI): byte diunduh dengan token,
/// disimpan ke folder Download, lalu bisa dibuka / dibagikan.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Server palsu: setiap path dijawab JSON (isi file palsu).
  FakeServer fileServer() => FakeServer((options, _) => switch (options.path) {
        'records/sales/5/pdf' => {'isi': 'PDF nota palsu'},
        'ai/attachments/40/0' => {'isi': 'laporan laba rugi'},
        'records/attachments/invoice/5/0' => {'_status': 404, 'code': 'tidak_ditemukan', 'message': 'Lampiran tidak ditemukan.'},
        _ => null,
      });

  test('download: byte dari server tersimpan, masuk Download, jenis file sesuai', () async {
    final server = fileServer();
    final files = FakeFilePlatform();
    final downloads = FileDownloads(files);
    final progress = <double?>[];

    final saved = await downloads.download(fakeApi(server), 'records/sales/5/pdf', 'POS-K1/000005.pdf', onProgress: progress.add);

    expect(server.requests.single.path, 'records/sales/5/pdf');
    expect(server.requests.single.headers['Authorization'], 'Bearer token');
    expect(server.requests.single.headers['X-Tenant'], '1');
    expect(File(saved.path).readAsStringSync(), contains('PDF nota palsu'));
    expect(saved.name, 'POS-K1-000005.pdf', reason: 'Garis miring tidak boleh ada di nama file.');
    expect(saved.mime, 'application/pdf');
    expect(saved.inDownloads, isTrue);
    expect(files.downloads.single.$2, 'POS-K1-000005.pdf');
    expect(progress, isNotEmpty);

    expect(await downloads.open(saved), isTrue);
    expect(files.opened.single, (saved.path, 'application/pdf'));
    expect(await downloads.share(saved), isTrue);
    expect(files.sharedFiles.single.$1, saved.path);
  });

  test('Download tidak tersedia (izin ditolak): file tetap tersimpan di HP dan bisa dibuka', () async {
    final files = FakeFilePlatform(downloadsResult: null);
    final saved = await FileDownloads(files).save('Laba rugi Oktober.xlsx', [1, 2, 3]);
    expect(saved.inDownloads, isFalse);
    expect(saved.mime, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    expect(File(saved.path).lengthSync(), 3);
  });

  test('nama file, jenis file, dan tautan WhatsApp', () {
    expect(cleanFileName('Nota: POS/K1*01?.pdf'), 'Nota- POS-K1-01-.pdf');
    expect(cleanFileName('  '), 'berkas');
    expect(mimeTypeForName('foto.JPG'), 'image/jpeg');
    expect(mimeTypeForName('data.csv'), 'text/csv');
    expect(mimeTypeForName('tanpa-ekstensi'), 'application/octet-stream');

    final withPhone = whatsappUri('Halo Bu Ani\nTotal: Rp 26.000', phone: '0812-3456-7890');
    expect(withPhone.toString(), startsWith('https://wa.me/6281234567890?text='));
    expect(withPhone.queryParameters['text'], 'Halo Bu Ani\nTotal: Rp 26.000');
    expect(whatsappUri('x', phone: '+62 812 3456 7890').path, '/6281234567890');
    expect(whatsappUri('x', phone: null).path, '/');
    expect(whatsappUri('x', phone: '123').path, '/', reason: 'Nomor tidak lengkap: WhatsApp meminta pilih kontak.');
  });

  group('tampilan', () {
    late FakeFilePlatform files;
    late FakeServer server;
    late LocalDb local;

    Future<void> pump(WidgetTester tester, Widget Function(BuildContext context, WidgetRef ref) builder) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final storage = await AppStorage.load();
      local = (await tester.runAsync(memoryDb))!;
      files = FakeFilePlatform();
      server = fileServer();
      const tenant = TenantSummary(id: 1, name: 'Warung Tes');
      await tester.pumpWidget(ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          filePlatformProvider.overrideWithValue(files),
          workspaceProvider.overrideWith(
            (ref) async => Workspace(
              storage: storage,
              user: const SessionUser(id: 1, name: 'Sari', email: 'sari@tes.id'),
              tenant: tenant,
              local: local,
              outbox: OutboxStore(local),
              api: fakeApi(server),
            ),
          ),
        ],
        child: MaterialApp(home: Scaffold(body: Center(child: Consumer(builder: (context, ref, _) => builder(context, ref))))),
      ));
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      // Tulis file memakai I/O sungguhan (runAsync); pesan baru tampil setelah
      // animasi pesan progres selesai.
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    testWidgets('Unduh: progres, lalu "Tersimpan di Download" dengan Buka dan Bagikan', (tester) async {
      await pump(tester, (context, ref) => FilledButton(onPressed: () => downloadAndOffer(context, ref, apiPath: 'records/sales/5/pdf', fileName: 'POS-K1-000005.pdf'), child: const Text('Unduh PDF')));
      await tester.tap(find.text('Unduh PDF'));
      await tester.pump();
      expect(find.byKey(const Key('download-progress')), findsOneWidget);
      await settle(tester);

      expect(find.text('Tersimpan di Download'), findsOneWidget);
      expect(find.text('POS-K1-000005.pdf'), findsOneWidget);
      await tester.tap(find.byKey(const Key('download-open')));
      await settle(tester);
      expect(files.opened.single.$2, 'application/pdf');
      await tester.tap(find.byKey(const Key('download-share')));
      await settle(tester);
      expect(files.sharedFiles, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Unduh gagal (404): pesan dari server, tidak ada file', (tester) async {
      await pump(tester, (context, ref) => FilledButton(onPressed: () => downloadAndOffer(context, ref, apiPath: 'records/attachments/invoice/5/0', fileName: 'lampiran.pdf'), child: const Text('Unduh')));
      await tester.tap(find.text('Unduh'));
      await settle(tester);
      expect(find.text('Lampiran tidak ditemukan.'), findsOneWidget);
      expect(files.downloads, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Tim AI: file laporan diketuk → diunduh dengan token ke Download', (tester) async {
      const report = AiAttachment(index: 0, name: 'Laba rugi Oktober.pdf', kind: 'report', size: 2048, url: 'https://dashboard.infois.ai/api/v1/ai/attachments/40/0');
      await pump(tester, (context, ref) => const AttachmentChip(report));
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      await tester.tap(find.byKey(const Key('attachment-download-0')));
      await settle(tester);

      expect(server.requests.single.path, 'ai/attachments/40/0', reason: 'Alamat relatif ke server yang dipakai HP.');
      expect(files.downloads.single.$2, 'Laba rugi Oktober.pdf');
      expect(find.text('Tersimpan di Download'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('lampiran yang sedang dikirim (masih di HP) tidak bisa diunduh', (tester) async {
      const draft = AiAttachment(index: 0, name: 'nota.pdf', kind: 'pdf', localPath: '/tmp/nota.pdf');
      await pump(tester, (context, ref) => AttachmentChip(draft, onRemove: () {}));
      expect(find.byKey(const Key('attachment-download-0')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
