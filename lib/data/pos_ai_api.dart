import 'dart:io';

import 'package:dio/dio.dart';

import '../domain/pos_ai.dart';
import 'ai_api.dart';
import 'api_client.dart';

/// Input AI kasir: `POST pos/ai-input` (API.md › 5). Multipart: `mode`
/// (text | voice | photo), `text`, `file` (rekaman/foto), `seconds`.
class PosAiApi {
  const PosAiApi(this.client);

  final ApiClient client;

  Future<PosAiResult> send(PosAiMode mode, {String? text, String? path, String? name, int? seconds}) async {
    final form = FormData();
    form.fields.add(MapEntry('mode', mode.code));
    if (text != null && text.trim().isNotEmpty) {
      form.fields.add(MapEntry('text', text.trim()));
    }
    if (path != null) {
      if (!File(path).existsSync()) {
        throw ApiException(mode == PosAiMode.voice ? 'Rekaman sudah tidak ada di HP. Rekam lagi.' : 'Foto sudah tidak ada di HP. Ambil lagi.', code: 'lampiran_hilang');
      }
      final filename = name ?? path.split('/').last;
      form.files.add(MapEntry('file', await MultipartFile.fromFile(path, filename: filename, contentType: AiApi.mimeTypeFor(filename))));
    }
    if (seconds != null && seconds > 0) {
      form.fields.add(MapEntry('seconds', seconds.clamp(1, 120).toString()));
    }
    return PosAiResult.fromJson(await client.post('pos/ai-input', data: form, timeout: const Duration(minutes: 2)));
  }
}
