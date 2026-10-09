import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../domain/ai_models.dart';

/// Pemilih foto (kamera/galeri) dan file (PDF/Excel) untuk lampiran Tim AI.
/// Dipisah dari layar supaya bisa diganti di tes.
abstract class AiMediaPicker {
  Future<AiDraftAttachment?> pickImage({required bool camera});

  Future<List<AiDraftAttachment>> pickFiles();
}

/// Perekam voice note (AAC/m4a).
abstract class VoiceRecorder {
  /// Mulai merekam; false bila izin mikrofon ditolak.
  Future<bool> start();

  /// Berhenti dan kembalikan file rekaman (null bila terlalu pendek/gagal).
  Future<AiDraftAttachment?> stop();

  Future<void> cancel();
}

class DeviceMediaPicker implements AiMediaPicker {
  final ImagePicker _images = ImagePicker();

  @override
  Future<AiDraftAttachment?> pickImage({required bool camera}) async {
    final file = await _images.pickImage(source: camera ? ImageSource.camera : ImageSource.gallery, maxWidth: 2000, imageQuality: 85);
    if (file == null) {
      return null;
    }
    return AiDraftAttachment(path: file.path, name: p.basename(file.path), size: await File(file.path).length(), kind: 'image');
  }

  /// Hanya jenis yang diterima server (API.md › 6): .xls lama tidak termasuk.
  @override
  Future<List<AiDraftAttachment>> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf', 'xlsx', 'csv', 'jpg', 'jpeg', 'png', 'webp'], allowMultiple: true);
    if (result == null) {
      return const [];
    }
    return [
      for (final file in result.files)
        if (file.path != null) AiDraftAttachment(path: file.path!, name: file.name, size: file.size, kind: _kindOf(file.name)),
    ];
  }

  static String _kindOf(String name) {
    final extension = p.extension(name).toLowerCase();
    return const ['.jpg', '.jpeg', '.png', '.webp'].contains(extension) ? 'image' : 'file';
  }
}

class DeviceVoiceRecorder implements VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  DateTime? _startedAt;
  String? _path;

  @override
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) {
      return false;
    }
    final directory = await getTemporaryDirectory();
    _path = p.join(directory.path, 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a');
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1), path: _path!);
    _startedAt = DateTime.now();
    return true;
  }

  @override
  Future<AiDraftAttachment?> stop() async {
    final path = await _recorder.stop() ?? _path;
    final startedAt = _startedAt;
    _startedAt = null;
    _path = null;
    if (path == null || startedAt == null) {
      return null;
    }
    final seconds = DateTime.now().difference(startedAt).inSeconds;
    final file = File(path);
    if (seconds < 1 || !file.existsSync()) {
      if (file.existsSync()) {
        await file.delete();
      }
      return null;
    }
    return AiDraftAttachment(path: path, name: p.basename(path), size: await file.length(), kind: 'audio', seconds: seconds.clamp(1, 600));
  }

  @override
  Future<void> cancel() async {
    final path = await _recorder.stop() ?? _path;
    _startedAt = null;
    _path = null;
    if (path != null && File(path).existsSync()) {
      await File(path).delete();
    }
  }
}

final aiMediaPickerProvider = Provider<AiMediaPicker>((ref) => DeviceMediaPicker());

final voiceRecorderProvider = Provider<VoiceRecorder>((ref) => DeviceVoiceRecorder());
