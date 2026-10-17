import 'dart:io';

import 'package:dio/dio.dart';

import '../domain/ai_models.dart';
import 'api_client.dart';

/// Semua panggilan Tim AI ke `/api/v1/ai/*` (API.md › 6). Satu-satunya
/// tempat yang tahu bentuk JSON server, supaya perubahan kontrak cukup
/// diubah di sini.
class AiApi {
  const AiApi(this.client);

  final ApiClient client;

  Future<AiOverview> overview() async => AiOverview.fromJson(await client.get('ai/overview'));

  Future<bool> setFastMode(bool enabled) async {
    final response = await client.patch('ai/settings', data: {'fast_mode': enabled});
    return response['fast_mode'] == true;
  }

  /// Daftar percakapan, terbaru dulu. [cursor] dari halaman sebelumnya.
  Future<({List<AiConversation> items, String? nextCursor})> conversations({String? cursor}) async {
    final response = await client.get('ai/conversations', query: cursor == null ? null : {'cursor': cursor});
    return (
      items: [for (final item in (response['data'] as List? ?? const [])) AiConversation.fromJson(Map<String, dynamic>.from(item as Map))],
      nextCursor: response['next_cursor']?.toString(),
    );
  }

  Future<AiConversation> createConversation() async {
    final response = await client.post('ai/conversations');
    return AiConversation.fromJson(Map<String, dynamic>.from(response['conversation'] as Map));
  }

  /// Seluruh pesan, atau hanya pesan dengan id > [after].
  Future<AiConversationDetail> conversation(int id, {int? after}) async =>
      AiConversationDetail.fromJson(await client.get('ai/conversations/$id', query: after == null ? null : {'after': after}));

  Future<void> deleteConversation(int id) => client.delete('ai/conversations/$id');

  /// Kirim pesan (multipart). [attachments] maks. sesuai `limits`; voice note
  /// menyertakan `durations[i]` untuk menghitung koin audio.
  Future<AiSendResult> send({int? conversationId, String text = '', List<AiDraftAttachment> attachments = const [], void Function(double progress)? onProgress}) async {
    final form = FormData();
    if (conversationId != null) {
      form.fields.add(MapEntry('conversation_id', conversationId.toString()));
    }
    if (text.trim().isNotEmpty) {
      form.fields.add(MapEntry('text', text.trim()));
    }
    for (var i = 0; i < attachments.length; i++) {
      final file = attachments[i];
      // File sementara (foto kamera, rekaman) bisa sudah dibersihkan sistem.
      if (!File(file.path).existsSync()) {
        throw ApiException('Lampiran ${file.isAudio ? 'voice note' : file.name} sudah tidak ada di HP. Pilih atau rekam lagi.', code: 'lampiran_hilang');
      }
      form.files.add(MapEntry('attachments[]', await MultipartFile.fromFile(file.path, filename: file.name, contentType: mimeTypeFor(file.name))));
      if (file.seconds != null && file.seconds! > 0) {
        form.fields.add(MapEntry('durations[$i]', file.seconds!.clamp(1, 600).toString()));
      }
    }
    final response = await client.post(
      'ai/messages',
      data: form,
      timeout: const Duration(minutes: 3),
      onSendProgress: onProgress == null ? null : (sent, total) => onProgress(total <= 0 ? 0 : (sent / total).clamp(0, 1).toDouble()),
    );
    return AiSendResult.fromJson(response);
  }

  Future<AiRun> run(int id) async => AiRun.fromJson(await client.get('ai/runs/$id'));

  /// Setujui usulan; [edits] = isian yang diubah pengguna (hanya key di
  /// `editable_fields`). Melempar [ApiException] `ditolak` (usulan tetap
  /// menunggu) atau `sudah_diproses`.
  /// `message` = kalimat hasil, `details` = rinciannya (mis. "Kas bertambah
  /// Rp … · saldo Rp …", "📎 2 bukti transaksi dilampirkan"). Gagal → 422
  /// `ditolak` dengan `message` "Gagal dicatat: …", `reason`, dan `proposal`.
  Future<({AiProposal proposal, String message, List<String> details})> approve(int id, {Map<String, dynamic>? edits}) async {
    final response = await client.post('ai/proposals/$id/approve', data: edits == null || edits.isEmpty ? null : {'edits': edits}, timeout: const Duration(seconds: 90));
    return _decision(response, 'Tercatat');
  }

  Future<({AiProposal proposal, String message, List<String> details})> reject(int id) async {
    final response = await client.post('ai/proposals/$id/reject');
    return _decision(response, 'Usulan ditolak');
  }

  static ({AiProposal proposal, String message, List<String> details}) _decision(Map<String, dynamic> response, String fallback) {
    final proposal = AiProposal.fromJson(Map<String, dynamic>.from(response['proposal'] as Map));
    final message = (response['message']?.toString() ?? '').trim();
    return (
      proposal: proposal,
      message: message.isNotEmpty ? message : (proposal.resultMessage ?? fallback),
      details: [for (final line in (response['details'] as List? ?? proposal.resultDetails)) if (line.toString().trim().isNotEmpty) line.toString()],
    );
  }

  /// Isi lampiran (foto, voice note, PDF) dengan header token + X-Tenant.
  /// URL dari server dipakai relatif terhadap `/api/v1/` supaya tetap benar
  /// walau `APP_URL` server berbeda dengan alamat yang dipakai HP.
  Future<List<int>> attachmentBytes(String url) => client.bytes(relativeApiPath(url));

  /// `https://server/api/v1/ai/attachments/40/0` → `ai/attachments/40/0`.
  static String relativeApiPath(String url) {
    final marker = url.indexOf('/api/v1/');
    return marker < 0 ? url : url.substring(marker + '/api/v1/'.length);
  }

  /// Jenis file multipart dari ekstensi (server tetap memeriksa isi file).
  static DioMediaType? mimeTypeFor(String name) {
    final extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (extension) {
      'jpg' || 'jpeg' => DioMediaType('image', 'jpeg'),
      'png' => DioMediaType('image', 'png'),
      'webp' => DioMediaType('image', 'webp'),
      'm4a' || 'mp4' => DioMediaType('audio', 'mp4'),
      'aac' => DioMediaType('audio', 'aac'),
      'ogg' || 'oga' => DioMediaType('audio', 'ogg'),
      'mp3' => DioMediaType('audio', 'mpeg'),
      'wav' => DioMediaType('audio', 'wav'),
      'webm' => DioMediaType('audio', 'webm'),
      'pdf' => DioMediaType('application', 'pdf'),
      'xlsx' => DioMediaType('application', 'vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
      'csv' => DioMediaType('text', 'csv'),
      _ => null,
    };
  }
}
