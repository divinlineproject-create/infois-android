import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ai_models.dart';
import '../../services/ai_media.dart';
import '../theme.dart';
import 'common.dart';

/// Kotak tulis pesan Tim AI: teks, foto (kamera/galeri), file PDF/Excel,
/// dan voice note tahan-untuk-rekam. Lampiran dicek ukurannya sebelum dikirim.
class AiComposer extends ConsumerStatefulWidget {
  const AiComposer({super.key, required this.enabled, required this.limits, required this.onSend, this.initialText, this.disabledReason});

  final bool enabled;
  final AiLimits limits;
  final Future<void> Function(String text, List<AiDraftAttachment> attachments) onSend;
  final String? initialText;

  /// Keterangan singkat saat tidak bisa mengirim (offline, sedang diproses).
  final String? disabledReason;

  @override
  ConsumerState<AiComposer> createState() => _AiComposerState();
}

class _AiComposerState extends ConsumerState<AiComposer> {
  late final TextEditingController _text = TextEditingController(text: widget.initialText ?? '');
  final List<AiDraftAttachment> _attachments = [];
  bool _recording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  bool _hasText = false;

  /// Jari masih menahan tombol mikrofon. Nomor tekanan membedakan tekanan
  /// lama yang baru selesai menunggu izin dari tekanan baru.
  bool _micPressed = false;
  int _micPress = 0;

  @override
  void initState() {
    super.initState();
    _hasText = _text.text.trim().isNotEmpty;
    _text.addListener(() {
      final hasText = _text.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _text.dispose();
    super.dispose();
  }

  bool get _canSend => widget.enabled && (_hasText || _attachments.isNotEmpty);

  void _add(AiDraftAttachment file) {
    if (_attachments.length >= widget.limits.maxAttachments) {
      showMessage(context, 'Maksimal ${widget.limits.maxAttachments} lampiran per pesan.', error: true);
      return;
    }
    if (file.size > widget.limits.maxUploadBytes) {
      showMessage(context, 'File ${file.name} terlalu besar (maks. ${widget.limits.maxUploadLabel}).', error: true);
      return;
    }
    setState(() => _attachments.add(file));
  }

  Future<void> _pickAttachment() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Foto nota (kamera)'), onTap: () => Navigator.pop(context, 'camera')),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Pilih dari galeri'), onTap: () => Navigator.pop(context, 'gallery')),
          ListTile(leading: const Icon(Icons.attach_file), title: const Text('File PDF, Excel/CSV, atau foto'), subtitle: Text('Maks. ${widget.limits.maxUploadLabel} per file', style: const TextStyle(fontSize: 12)), onTap: () => Navigator.pop(context, 'file')),
        ]),
      ),
    );
    if (choice == null || !mounted) {
      return;
    }
    final picker = ref.read(aiMediaPickerProvider);
    try {
      if (choice == 'file') {
        for (final file in await picker.pickFiles()) {
          _add(file);
        }
      } else {
        final image = await picker.pickImage(camera: choice == 'camera');
        if (image != null) {
          _add(image);
        }
      }
    } catch (_) {
      if (mounted) {
        showMessage(context, choice == 'camera' ? 'Kamera tidak bisa dibuka. Periksa izin kamera di pengaturan HP.' : 'File tidak bisa dibuka.', error: true);
      }
    }
  }

  Future<void> _startRecording() async {
    if (!widget.enabled || _recording) {
      return;
    }
    final press = ++_micPress;
    _micPressed = true;
    final recorder = ref.read(voiceRecorderProvider);
    bool ok;
    try {
      ok = await recorder.start();
    } catch (_) {
      ok = false;
    }
    if (!mounted) {
      return;
    }
    if (!ok) {
      showMessage(context, 'Izinkan mikrofon untuk merekam voice note.', error: true);
      return;
    }
    // Jari sudah dilepas selagi menunggu izin mikrofon / perekam siap:
    // jangan mulai merekam tanpa ada yang menahan tombol.
    if (!_micPressed || press != _micPress) {
      try {
        await recorder.cancel();
      } catch (_) {
        // Rekaman kosong yang gagal dibatalkan tidak perlu dilaporkan.
      }
      return;
    }
    setState(() {
      _recording = true;
      _recordSeconds = 0;
    });
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() => _recordSeconds++);
      if (_recordSeconds >= 600) {
        _stopRecording();
      }
    });
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    _micPressed = false;
    if (!_recording) {
      return;
    }
    _recordTimer?.cancel();
    final recorder = ref.read(voiceRecorderProvider);
    setState(() => _recording = false);
    try {
      if (cancel) {
        await recorder.cancel();
        return;
      }
      final file = await recorder.stop();
      if (!mounted) {
        return;
      }
      if (file == null) {
        showMessage(context, 'Rekaman terlalu pendek. Tahan tombol mikrofon sambil bicara.');
        return;
      }
      _add(file);
    } catch (_) {
      if (mounted) {
        showMessage(context, 'Rekaman gagal disimpan.', error: true);
      }
    }
  }

  Future<void> _send() async {
    if (!_canSend) {
      return;
    }
    final text = _text.text.trim();
    if (text.length > widget.limits.maxText) {
      showMessage(context, 'Pesan terlalu panjang (maks. ${widget.limits.maxText} huruf).', error: true);
      return;
    }
    final attachments = List<AiDraftAttachment>.from(_attachments);
    setState(() {
      _text.clear();
      _attachments.clear();
    });
    await widget.onSend(text, attachments);
  }

  static String _clock(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_attachments.isNotEmpty)
              SizedBox(
                height: 76,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: _attachments.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => _DraftPreview(file: _attachments[index], onRemove: () => setState(() => _attachments.removeAt(index))),
                ),
              ),
            if (widget.disabledReason != null && !widget.enabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 14, color: mutedText(context)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(widget.disabledReason!, style: TextStyle(fontSize: 12, color: mutedText(context)))),
                ]),
              ),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(key: const Key('ai-attach'), tooltip: 'Lampirkan foto atau file', onPressed: widget.enabled && !_recording ? _pickAttachment : null, icon: const Icon(Icons.add_circle_outline)),
              Expanded(
                child: _recording
                    ? Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(color: Brand.danger.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(24)),
                        child: Row(children: [
                          Icon(Icons.mic, color: dangerText(context)),
                          const SizedBox(width: 8),
                          Text('Merekam ${_clock(_recordSeconds)}', style: TextStyle(fontWeight: FontWeight.w600, color: dangerText(context))),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Lepas untuk selesai', textAlign: TextAlign.end, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: mutedText(context)))),
                        ]),
                      )
                    : TextField(
                        key: const Key('ai-text'),
                        controller: _text,
                        enabled: widget.enabled,
                        minLines: 1,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: widget.enabled ? 'Tulis perintah, mis. "kopi susu 2 tunai"' : (widget.disabledReason ?? 'Tunggu sebentar…'),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              // Satu GestureDetector tanpa IconButton/Tooltip di dalamnya:
              // Tooltip punya pengenal tekan-lama sendiri yang merebut gestur.
              Semantics(
                button: true,
                enabled: widget.enabled,
                label: 'Tahan untuk merekam voice note',
                child: GestureDetector(
                  key: const Key('ai-mic'),
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.enabled ? () => showMessage(context, 'Tahan tombol mikrofon sambil bicara, lepas untuk selesai.') : null,
                  onLongPressStart: widget.enabled ? (_) => _startRecording() : null,
                  onLongPressEnd: (_) => _stopRecording(),
                  onLongPressCancel: () => _stopRecording(cancel: true),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        _recording ? Icons.mic : Icons.mic_none,
                        color: _recording ? dangerText(context) : (widget.enabled ? scheme.onSurfaceVariant : Theme.of(context).disabledColor),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton.filled(
                key: const Key('ai-send'),
                tooltip: 'Kirim',
                onPressed: _canSend && !_recording ? _send : null,
                icon: const Icon(Icons.send_rounded),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _DraftPreview extends StatelessWidget {
  const _DraftPreview({required this.file, required this.onRemove});

  final AiDraftAttachment file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final icon = file.isAudio ? Icons.mic : (file.name.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf_outlined : Icons.table_chart_outlined);
    return Stack(children: [
      Container(
        width: file.isImage ? 72 : 150,
        height: 72,
        margin: const EdgeInsets.only(top: 4, right: 8),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Theme.of(context).dividerColor)),
        clipBehavior: Clip.antiAlias,
        child: file.isImage
            ? Image.file(File(file.path), fit: BoxFit.cover, cacheWidth: (72 * MediaQuery.devicePixelRatioOf(context)).round(), semanticLabel: 'Foto ${file.name}')
            : Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  Icon(icon, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(file.isAudio ? 'Voice note' : file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                      Text(file.isAudio ? '${file.seconds ?? 0} detik' : '${(file.size / 1024).round()} KB', style: TextStyle(fontSize: 11, color: mutedText(context))),
                    ]),
                  ),
                ]),
              ),
      ),
      Positioned(
        top: 0,
        right: 0,
        child: InkWell(
          onTap: onRemove,
          customBorder: const CircleBorder(),
          child: Semantics(
            button: true,
            label: 'Hapus lampiran ${file.isAudio ? 'voice note' : file.name}',
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).dividerColor)),
              child: const Icon(Icons.close, size: 14),
            ),
          ),
        ),
      ),
    ]);
  }
}
