// Uji coba Tim AI langsung ke server Laravel sungguhan (bukan bagian `flutter test` biasa).
// Jalankan:
//   flutter test test_live/ai_live_test.dart --dart-define=INFOIS_LIVE=http://127.0.0.1:8099 \
//     --dart-define=INFOIS_LIVE_EMAIL=pemilik@contoh.id --dart-define=INFOIS_LIVE_PASSWORD=rahasia
// (variabel lingkungan INFOIS_LIVE / INFOIS_LIVE_EMAIL / INFOIS_LIVE_PASSWORD juga bisa dipakai.)
//
// Server tanpa kunci OpenAI yang valid tetap bisa diuji: bila `enabled: false`
// (kunci kosong) kirim pesan harus ditolak 503 berbahasa Indonesia; bila kunci
// ada tapi tidak valid, proses berakhir `failed` dengan pesan ramah dan koin
// yang ditahan dikembalikan.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:infois/data/ai_api.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/domain/ai_models.dart';
import 'package:infois/domain/models.dart';
import 'package:path/path.dart' as p;

const _tones = ['sky', 'amber', 'emerald', 'indigo', 'violet', 'rose', 'teal', 'orange'];
const _runStatuses = ['queued', 'running', 'completed', 'failed'];

String? _setting(String key, String define) => define.isNotEmpty ? define : Platform.environment[key];

void main() {
  final server = _setting('INFOIS_LIVE', const String.fromEnvironment('INFOIS_LIVE'));
  final email = _setting('INFOIS_LIVE_EMAIL', const String.fromEnvironment('INFOIS_LIVE_EMAIL'));
  final password = _setting('INFOIS_LIVE_PASSWORD', const String.fromEnvironment('INFOIS_LIVE_PASSWORD'));

  test('Tim AI: ringkasan → percakapan → kirim teks & foto → proses → riwayat → hapus', () async {
    final login = await ApiClient(baseUrl: server!).post('auth/login', data: {
      'email': email,
      'password': password,
      'device_name': 'HP Live Test AI',
      'device_uid': 'hp-live-ai-${DateTime.now().millisecondsSinceEpoch}',
      'platform': 'android',
    });
    final tenants = [for (final item in login['tenants'] as List) TenantSummary.fromJson(Map<String, dynamic>.from(item as Map))];
    final tenant = tenants.firstWhere((item) => item.menus.ai, orElse: () => tenants.first);
    expect(tenant.menus.ai, isTrue, reason: 'Akun uji harus punya menu Tim AI (permission use-ai-assistant).');

    final client = ApiClient(baseUrl: server, token: login['token'] as String, tenantId: tenant.id);
    final api = AiApi(client);
    final created = <int>[];
    final scratch = Directory.systemTemp.createTempSync('infois-ai-live');

    try {
      // Ringkasan: tim, jatah koin, batas unggah.
      final overview = await api.overview();
      expect(overview.teams, isNotEmpty);
      expect(overview.teams.map((team) => team.tone), everyElement(isIn(_tones)));
      expect(overview.teams.map((team) => team.key), everyElement(isNotEmpty));
      expect(overview.teams.map((team) => team.icon), everyElement(isNot(startsWith('heroicon'))));
      expect(overview.teams.where((team) => team.locked).map((team) => team.unlockPlan), everyElement(isNotNull));
      expect(overview.coins.available, matches(r'^\d+\.\d{3}$'), reason: 'Koin string 3 desimal.');
      expect(overview.coins.used, matches(r'^\d+\.\d{3}$'));
      expect(overview.coins.percent, inInclusiveRange(0, 100));
      expect(overview.coins.resetsAt, isNotNull);
      expect(overview.limits.maxAttachments, 5);
      expect(overview.limits.maxText, 4000);
      expect(overview.limits.maxUploadKb, greaterThan(0));
      expect(overview.suggestions, isNotEmpty);

      // Percakapan kosong lalu detailnya.
      final conversation = await api.createConversation();
      created.add(conversation.id);
      expect(conversation.title, 'Percakapan baru');
      expect(conversation.channel, 'mobile');
      expect(conversation.pendingProposals, 0);
      expect(conversation.working, isFalse);
      final emptyDetail = await api.conversation(conversation.id);
      expect(emptyDetail.conversation.id, conversation.id);
      expect(emptyDetail.messages, isEmpty);
      expect(emptyDetail.working, isFalse);
      expect(emptyDetail.activeRunId, isNull);

      // Mode cepat: ubah lalu kembalikan.
      expect(await api.setFastMode(!overview.fastMode), !overview.fastMode);
      expect((await api.overview()).fastMode, !overview.fastMode);
      expect(await api.setFastMode(overview.fastMode), overview.fastMode);

      if (!overview.enabled) {
        // Server tanpa kunci OpenAI: kirim ditolak dengan pesan Indonesia, tanpa membuat proses.
        final refused = await _expectApiError(() => api.send(conversationId: conversation.id, text: 'uji coba, abaikan'));
        expect(refused.status, 503);
        expect(refused.code, 'ai_tidak_tersedia');
        expect(refused.message, 'Asisten AI sedang tidak tersedia. Silakan coba lagi nanti.');
        expect((await api.conversation(conversation.id)).messages, isEmpty);
        // ignore: avoid_print
        print('AI nonaktif di $server: jalur 503 ai_tidak_tersedia terverifikasi.');
      } else {
        // Validasi: tanpa teks dan tanpa lampiran.
        final empty = await _expectApiError(() => api.send(conversationId: conversation.id));
        expect(empty.status, 422);
        expect(empty.message, 'Tulis pesan, rekam suara, atau lampirkan file.');

        // Kirim teks → proses → jawaban.
        final before = overview.coins;
        final text = 'Uji coba dari tes HP otomatis ${DateTime.now().millisecondsSinceEpoch}, abaikan';
        final sent = await api.send(conversationId: conversation.id, text: text);
        expect(sent.conversationId, conversation.id);
        expect(sent.messageId, isNotNull);
        expect(sent.status, isIn(_runStatuses));
        final run = await _awaitRun(api, sent.runId);
        expect(run.conversationId, conversation.id);
        final reply = run.assistantMessage;
        expect(reply, isNotNull, reason: 'Proses selesai harus menyertakan pesan asisten.');
        expect(reply!.role, 'assistant');
        expect(reply.runId, sent.runId);
        expect(reply.runStatus, run.status);
        expect(reply.content, isNotEmpty);
        if (run.failed) {
          // Kunci OpenAI tidak valid di server uji: gagal dengan pesan ramah, koin dikembalikan.
          expect(run.error, isNotNull);
          expect(reply.failed, isTrue);
          expect(reply.content, startsWith('Maaf'));
          expect(reply.content, contains('Koin Anda tidak terpakai'));
          expect(reply.proposals, isEmpty);
          expect(double.parse(run.coinsCharged ?? '0'), 0);
          final after = (await api.overview()).coins;
          expect(after.available, before.available, reason: 'Koin yang ditahan harus dilepas lagi.');
          expect(after.used, before.used);
        } else {
          expect(reply.failed, isFalse);
          expect(reply.teams, isNotEmpty);
          expect(run.coinsCharged, matches(r'^\d+\.\d{3}$'));
        }

        // Detail percakapan: judul dari pesan pertama, pesan pengguna + asisten, ?after=.
        final detail = await api.conversation(conversation.id);
        expect(detail.conversation.title, text);
        expect(detail.working, isFalse);
        expect(detail.activeRunId, isNull);
        expect(detail.messages.map((message) => message.role), ['user', 'assistant']);
        final userMessage = detail.messages.first;
        expect(userMessage.id, sent.messageId);
        expect(userMessage.content, text);
        expect(userMessage.runId, sent.runId);
        expect(userMessage.runStatus, run.status);
        expect(userMessage.attachments, isEmpty);
        expect(detail.messages.last.id, reply.id);
        expect(detail.messages.last.failed, reply.failed);
        final tail = await api.conversation(conversation.id, after: sent.messageId);
        expect(tail.messages.map((message) => message.id), [reply.id]);

        // Foto PNG tanpa conversation_id → percakapan baru berjudul dari teks.
        final png = _generatePng();
        final photoFile = File(p.join(scratch.path, 'nota-uji.png'))..writeAsBytesSync(png);
        final progress = <double>[];
        final photo = await api.send(
          text: 'Foto uji dari tes HP, abaikan',
          attachments: [AiDraftAttachment(path: photoFile.path, name: 'nota-uji.png', size: png.length, kind: 'image')],
          onProgress: progress.add,
        );
        created.add(photo.conversationId);
        expect(photo.conversationId, isNot(conversation.id));
        expect(progress, isNotEmpty);
        expect(progress.last, closeTo(1, 0.001));
        final photoRun = await _awaitRun(api, photo.runId);
        expect(photoRun.conversationId, photo.conversationId);
        final photoDetail = await api.conversation(photo.conversationId);
        expect(photoDetail.conversation.title, 'Foto uji dari tes HP, abaikan');
        expect(photoDetail.conversation.channel, 'mobile');
        final attachment = photoDetail.messages.first.attachments.single;
        expect(attachment.index, 0);
        expect(attachment.name, 'nota-uji.png');
        expect(attachment.kind, 'image');
        expect(attachment.mime, 'image/png');
        expect(attachment.size, png.length);
        expect(attachment.seconds, isNull);
        expect(attachment.url, endsWith('/api/v1/ai/attachments/${photo.messageId}/0'));
        expect(await api.attachmentBytes(attachment.url!), png, reason: 'Lampiran diunduh dengan token + X-Tenant.');

        // Lampiran yang tidak didukung (biner tak dikenal; .txt diterima server
        // sebagai CSV) ditolak dengan menyebut nama file.
        final binFile = File(p.join(scratch.path, 'data.bin'))..writeAsBytesSync([for (var i = 0; i < 64; i++) (i * 37 + 11) & 0xff]);
        final unsupported = await _expectApiError(
          () => api.send(conversationId: conversation.id, attachments: [AiDraftAttachment(path: binFile.path, name: 'data.bin', size: 64, kind: 'file')]),
        );
        expect(unsupported.status, 422);
        expect(unsupported.code, 'file_tidak_didukung');
        expect(unsupported.message, contains('data.bin'));
        expect((await api.conversation(conversation.id)).messages, hasLength(2), reason: 'Lampiran yang ditolak tidak membuat pesan.');
        // ignore: avoid_print
        print('AI aktif di $server: proses ${run.id} berakhir ${run.status}; percakapan ${created.join(', ')}.');
      }

      // Daftar percakapan: terbaru dulu, maks. 20 per halaman, cursor tanpa tumpang tindih.
      final page = await api.conversations();
      expect(page.items.length, inInclusiveRange(1, 20));
      expect(page.items.first.id, created.last, reason: 'Percakapan yang baru disentuh tampil paling atas.');
      expect(page.items.map((item) => item.id), containsAll(created));
      expect(page.items.map((item) => item.channel), everyElement(isIn(['web', 'telegram', 'mobile'])));
      for (var i = 1; i < page.items.length; i++) {
        expect(page.items[i].lastMessageAt!.isAfter(page.items[i - 1].lastMessageAt!), isFalse, reason: 'Urutan last_message_at menurun.');
      }
      final latest = page.items.first;
      expect(latest.working, isFalse);
      expect(latest.preview, overview.enabled ? isNotNull : isNull);
      final seen = {for (final item in page.items) item.id};
      var cursor = page.nextCursor;
      var pages = 1;
      while (cursor != null && pages < 4) {
        final next = await api.conversations(cursor: cursor);
        expect(next.items.map((item) => item.id).toSet().intersection(seen), isEmpty, reason: 'Halaman berikut tidak mengulang.');
        seen.addAll(next.items.map((item) => item.id));
        cursor = next.nextCursor;
        pages++;
      }

      // Hapus → 404 tidak_ditemukan.
      for (final id in List.of(created)) {
        await api.deleteConversation(id);
        created.remove(id);
        final gone = await _expectApiError(() => api.conversation(id));
        expect(gone.status, 404);
        expect(gone.code, 'tidak_ditemukan');
      }
      final unknownRun = await _expectApiError(() => api.run(999999999));
      expect(unknownRun.status, 404);
      expect(unknownRun.code, 'tidak_ditemukan');
      expect((await api.conversations()).items.map((item) => item.id), isNot(contains(conversation.id)));
    } finally {
      for (final id in created) {
        try {
          await api.deleteConversation(id);
        } on ApiException {
          // Dibiarkan; dibersihkan manual bila perlu.
        }
      }
      scratch.deleteSync(recursive: true);
      await client.post('auth/logout');
    }
  }, skip: server == null ? 'Set INFOIS_LIVE untuk uji langsung ke server.' : false, timeout: const Timeout(Duration(minutes: 4)));
}

/// Polling status proses seperti aplikasi (tiap ~1 detik di tes) sampai `done`.
Future<AiRun> _awaitRun(AiApi api, int runId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  while (true) {
    final run = await api.run(runId);
    expect(run.id, runId);
    expect(run.status, isIn(_runStatuses));
    if (run.done) {
      expect(run.status, isIn(['completed', 'failed']));
      return run;
    }
    expect(run.assistantMessage, isNull, reason: 'Belum ada jawaban selama proses berjalan.');
    expect(DateTime.now().isBefore(deadline), isTrue, reason: 'Proses $runId belum selesai setelah 2 menit (pekerja antrean ai jalan?).');
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

Future<ApiException> _expectApiError(Future<Object?> Function() action) async {
  try {
    await action();
  } on ApiException catch (error) {
    return error;
  }
  fail('Server seharusnya menolak permintaan ini.');
}

/// PNG kecil (32×32) menyerupai nota: latar krem dengan beberapa garis gelap.
List<int> _generatePng() {
  final image = img.Image(width: 32, height: 32);
  img.fill(image, color: img.ColorRgb8(250, 244, 230));
  for (final y in [6, 12, 18, 24]) {
    img.fillRect(image, x1: 4, y1: y, x2: 27, y2: y + 1, color: img.ColorRgb8(40, 40, 40));
  }
  return img.encodePng(image);
}
