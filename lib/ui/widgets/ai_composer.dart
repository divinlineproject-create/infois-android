import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ai_models.dart';
import '../../services/ai_media.dart';
import '../../services/permission_gate.dart';
import '../theme.dart';
import 'common.dart';

/// Kotak tulis pesan Tim AI bergaya aplikasi chat: satu kartu membulat berisi
/// lampiran (foto, file, voice note), kolom teks yang memanjang otomatis, dan
/// bilah alat (+ di kiri; mikrofon / Kirim / sedang bekerja di kanan).
/// Voice note: tahan mikrofon untuk merekam, lepas untuk selesai, geser ke
/// kiri untuk batal. Lampiran dicek ukurannya sebelum dikirim.
class AiComposer extends ConsumerStatefulWidget {
  const AiComposer({
    super.key,
    required this.enabled,
    required this.limits,
    required this.onSend,
    this.initialText,
    this.disabledReason,
    this.working = false,
    this.workingLabel,
    this.progress,
    this.fastMode,
    this.onFastModeChanged,
    this.onContentChanged,
  });

  /// Boleh menulis & melampirkan (online, Tim AI tersedia).
  final bool enabled;
  final AiLimits limits;
  final Future<void> Function(String text, List<AiDraftAttachment> attachments) onSend;
  final String? initialText;

  /// Keterangan singkat saat tidak bisa menulis (offline, Tim AI istirahat).
  final String? disabledReason;

  /// Tim AI sedang mengerjakan pesan sebelumnya: teks tetap bisa ditulis,
  /// tetapi tombol Kirim menjadi tanda "sedang bekerja".
  final bool working;
  final String? workingLabel;

  /// Kemajuan unggah lampiran 0–1 (cincin di tombol "sedang bekerja").
  final double? progress;

  /// Mode cepat (null = pilihan tidak ditampilkan).
  final bool? fastMode;
  final Future<void> Function(bool enabled)? onFastModeChanged;

  /// Kotak tulis mulai / berhenti berisi (teks atau lampiran), mis. untuk
  /// menyembunyikan saran di layar awal selama mengetik.
  final ValueChanged<bool>? onContentChanged;

  @override
  ConsumerState<AiComposer> createState() => AiComposerState();
}

class AiComposerState extends ConsumerState<AiComposer> {
  late final TextEditingController _text = TextEditingController(text: widget.initialText ?? '');
  final FocusNode _focus = FocusNode(debugLabel: 'ai-text');
  final List<AiDraftAttachment> _attachments = [];
  bool _recording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  bool _hasText = false;

  /// Jari masih menahan tombol mikrofon. Nomor tekanan membedakan tekanan
  /// lama yang baru selesai menunggu izin dari tekanan baru.
  bool _micPressed = false;
  int _micPress = 0;

  /// Jarak geser ke kiri (px) untuk membatalkan rekaman.
  static const double cancelSlide = 80;
  double _slide = 0;

  @override
  void initState() {
    super.initState();
    _hasText = _text.text.trim().isNotEmpty;
    _text.addListener(() {
      final hasText = _text.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
        _notifyContent();
      }
    });
  }

  bool _reportedContent = false;

  void _notifyContent() {
    final has = _hasContent;
    if (has != _reportedContent) {
      _reportedContent = has;
      widget.onContentChanged?.call(has);
    }
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Isi kotak tulis (mis. dari saran di layar awal) lalu fokus ke sana.
  void fill(String text) {
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    if (widget.enabled) {
      _focus.requestFocus();
    }
  }

  bool get _hasContent => _hasText || _attachments.isNotEmpty;

  bool get _canSend => widget.enabled && !widget.working && !_recording && _hasContent;

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
    _notifyContent();
  }

  Future<void> _openTools() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ToolsSheet(limits: widget.limits, fastMode: widget.fastMode, onFastModeChanged: widget.onFastModeChanged),
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
    _slide = 0;
    // Pertama kali: jelaskan dulu kegunaan mikrofon sebelum jendela izin
    // sistem. Setelah itu tekan-tahan lagi untuk merekam.
    if (!await explainPermission(context, ref, AppPermission.microphone) || !mounted) {
      return;
    }
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
    // Jari sudah dilepas (atau digeser untuk batal) selagi menunggu izin
    // mikrofon / perekam siap: jangan mulai merekam tanpa ada yang menahan.
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
    setState(() {
      _recording = false;
      _slide = 0;
    });
    try {
      if (cancel) {
        await recorder.cancel();
        if (mounted) {
          showMessage(context, 'Rekaman dibatalkan.');
        }
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

  void _onSlide(LongPressMoveUpdateDetails details) {
    final dx = details.offsetFromOrigin.dx;
    if (dx <= -cancelSlide) {
      // Digeser cukup jauh: batalkan (juga bila perekam belum siap).
      _stopRecording(cancel: true);
      return;
    }
    if (_recording) {
      setState(() => _slide = dx.clamp(-cancelSlide, 0).toDouble());
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
    _notifyContent();
    await widget.onSend(text, attachments);
  }

  static String _clock(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  /// Tinggi bilah alat (tombol 48 + jarak bawah 6): selalu terlihat walau
  /// ruang sempit (keyboard terbuka); kolom teks & lampiran yang menggulir.
  static const double toolbarHeight = 54;

  void _removeAttachment(int index) {
    setState(() => _attachments.removeAt(index));
    _notifyContent();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hint = _recording ? 'Merekam voice note…' : (widget.enabled ? 'Pesan untuk Tim AI' : (widget.disabledReason ?? 'Tunggu sebentar…'));

    final Widget trailing;
    if (widget.working && !_recording) {
      trailing = _WorkingButton(label: widget.workingLabel ?? 'Tim AI sedang bekerja', progress: widget.progress);
    } else if (_hasContent && !_recording) {
      trailing = IconButton.filled(
        key: const Key('ai-send'),
        tooltip: 'Kirim',
        style: IconButton.styleFrom(minimumSize: const Size(40, 40), fixedSize: const Size(40, 40), padding: EdgeInsets.zero),
        onPressed: _canSend ? _send : null,
        icon: const Icon(Icons.arrow_upward_rounded, size: 22),
      );
    } else {
      // Satu GestureDetector tanpa IconButton/Tooltip di dalamnya: Tooltip
      // punya pengenal tekan-lama sendiri yang merebut gestur. Tombol ini
      // tetap di tempat yang sama selama merekam supaya gestur tidak putus.
      trailing = Semantics(
        button: true,
        enabled: widget.enabled,
        label: _recording ? 'Merekam voice note. Lepas untuk selesai' : 'Tahan untuk merekam voice note',
        child: GestureDetector(
          key: const Key('ai-mic'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? () => showMessage(context, 'Tahan tombol mikrofon sambil bicara, lepas untuk selesai.') : null,
          onLongPressStart: widget.enabled ? (_) => _startRecording() : null,
          onLongPressMoveUpdate: widget.enabled ? _onSlide : null,
          onLongPressEnd: (_) => _stopRecording(),
          onLongPressCancel: () => _stopRecording(cancel: true),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: _recording ? 44 : 40,
                height: _recording ? 44 : 40,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _recording ? Brand.danger : Colors.transparent),
                child: Icon(_recording ? Icons.mic : Icons.mic_none_rounded, color: _recording ? Colors.white : (widget.enabled ? scheme.onSurfaceVariant : Theme.of(context).disabledColor)),
              ),
            ),
          ),
        ),
      );
    }

    // Kiri: "+" (atau jam rekaman). Tengah: chip Mode cepat (atau gelombang
    // rekaman). Kanan: mikrofon / Kirim / sedang bekerja, selalu rata kanan
    // dan di posisi yang sama (tidak bergeser di bawah jari saat merekam).
    final Widget leading =
        _recording
            ? _RecordingClock(clock: _clock(_recordSeconds))
            : IconButton(
              key: const Key('ai-attach'),
              tooltip: 'Foto, file, dan pilihan lain',
              onPressed: widget.enabled ? _openTools : null,
              style: IconButton.styleFrom(side: BorderSide(color: AiColors.border(context)), minimumSize: const Size(40, 40), fixedSize: const Size(40, 40), padding: EdgeInsets.zero),
              icon: const Icon(Icons.add_rounded),
            );
    final Widget middle;
    if (_recording) {
      middle = _RecordingTrack(slide: _slide);
    } else if (widget.fastMode == true) {
      middle = Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Semantics(
            label: 'Mode cepat aktif',
            child: Container(
              key: const Key('ai-fast-chip'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt_rounded, size: 16, color: scheme.primary),
                  const SizedBox(width: 2),
                  Flexible(child: Text('Cepat', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary))),
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      middle = const SizedBox.shrink();
    }

    final editable = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_attachments.isNotEmpty)
          SizedBox(
            height: 76,
            child: ListView.separated(
              key: const Key('ai-attachments'),
              scrollDirection: Axis.horizontal,
              // Tiap kartu sudah memberi ruang 11dp atas/kanan untuk area ketuk ×.
              padding: const EdgeInsets.fromLTRB(12, 1, 1, 0),
              itemCount: _attachments.length,
              separatorBuilder: (_, __) => const SizedBox(width: 1),
              itemBuilder:
                  (context, index) =>
                      _DraftPreview(key: Key('ai-draft-$index'), file: _attachments[index], removeKey: Key('ai-remove-$index'), onRemove: _recording ? null : () => _removeAttachment(index)),
            ),
          ),
        TextField(
          key: const Key('ai-text'),
          controller: _text,
          focusNode: _focus,
          enabled: widget.enabled,
          readOnly: _recording,
          minLines: 1,
          maxLines: 6,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          textCapitalization: TextCapitalization.sentences,
          // Bilah alat di bawah kolom teks ikut terlihat di atas keyboard.
          scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 84),
          style: const TextStyle(fontSize: 16, height: 1.4),
          decoration: InputDecoration(
            hintText: hint,
            hintMaxLines: 1,
            hintStyle: TextStyle(color: mutedText(context), fontSize: 16, overflow: TextOverflow.ellipsis),
            filled: false,
            isDense: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            contentPadding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
          ),
        ),
      ],
    );

    final toolbar = Padding(
      key: const Key('ai-toolbar'),
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            SizedBox(width: 48, height: 48, child: Center(child: leading)),
            Expanded(child: middle),
            KeyedSubtree(key: const ValueKey('ai-trailing'), child: SizedBox(width: 48, height: 48, child: Center(child: trailing))),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Ruang terbatas (keyboard terbuka, HP kecil, huruf besar): lampiran +
        // teks menggulir di dalam kotak, bilah alat dengan Kirim tetap tampil.
        final bounded = constraints.maxHeight.isFinite;
        final maxEditable = bounded ? math.max(48.0, constraints.maxHeight - toolbarHeight - 2) : double.infinity;
        return Container(
          key: const Key('ai-composer'),
          decoration: BoxDecoration(
            color: AiColors.composerFill(context),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AiColors.border(context)),
            boxShadow: AiColors.composerShadow(context),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [ConstrainedBox(constraints: BoxConstraints(maxHeight: maxEditable), child: SingleChildScrollView(key: const Key('ai-editable'), reverse: true, child: editable)), toolbar],
          ),
        );
      },
    );
  }
}

/// Tombol kanan saat Tim AI bekerja: cincin berputar (atau kemajuan unggah)
/// dengan kotak "stop". Kirim dimatikan; ketuk untuk penjelasan.
class _WorkingButton extends StatelessWidget {
  const _WorkingButton({required this.label, this.progress});

  final String label;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        key: const Key('ai-stop'),
        customBorder: const CircleBorder(),
        onTap: () => showMessage(context, '$label. Pesan berikutnya bisa dikirim setelah selesai.'),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(width: 36, height: 36, child: CircularProgressIndicator(value: progress, strokeWidth: 2.5, color: scheme.primary, backgroundColor: scheme.primary.withValues(alpha: 0.15))),
              Container(width: 12, height: 12, decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(3))),
            ],
          ),
        ),
      ),
    );
  }
}

/// Titik merah berkedip + waktu rekaman (di tempat tombol "+").
class _RecordingClock extends StatelessWidget {
  const _RecordingClock({required this.clock});

  final String clock;

  @override
  Widget build(BuildContext context) {
    final danger = dangerText(context);
    return Semantics(
      liveRegion: true,
      label: 'Merekam $clock',
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: danger, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(clock, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: danger, fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
      ),
    );
  }
}

/// Gelombang suara + petunjuk "geser untuk batal" di bilah alat selama
/// merekam. Petunjuk ikut bergeser (lewat tata letak, bukan digambar
/// menimpa) sehingga tidak pernah menutupi gelombang.
class _RecordingTrack extends StatelessWidget {
  const _RecordingTrack({required this.slide});

  final double slide;

  @override
  Widget build(BuildContext context) {
    final progress = (-slide / AiComposerState.cancelSlide).clamp(0.0, 1.0);
    final cancelling = progress >= 0.6;
    final danger = dangerText(context);
    final color = cancelling ? danger : mutedText(context);
    return Padding(
      key: const Key('ai-recording'),
      padding: const EdgeInsets.only(left: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Ruang sempit (huruf besar): petunjuk dipendekkan, tidak terpotong.
          final short = constraints.maxWidth < 200 * (MediaQuery.textScalerOf(context).scale(12) / 12);
          final label = cancelling ? (short ? 'Lepas' : 'Lepas untuk batal') : (short ? 'Batal' : 'Geser untuk batal');
          return Row(
            children: [
              const Expanded(child: ClipRect(child: _WaveBars())),
              SizedBox(width: 10 + progress * 36),
              Opacity(
                opacity: 1 - progress * 0.35,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chevron_left_rounded, size: 18, color: color),
                    Text(label, maxLines: 1, style: TextStyle(fontSize: 12, fontWeight: cancelling ? FontWeight.w600 : FontWeight.w400, color: color)),
                  ],
                ),
              ),
              SizedBox(width: 4 + (1 - progress) * 4),
            ],
          );
        },
      ),
    );
  }
}

/// Batang-batang "gelombang suara" yang bergerak selama merekam.
class _WaveBars extends StatefulWidget {
  const _WaveBars();

  @override
  State<_WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<_WaveBars> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = dangerText(context);
    return ExcludeSemantics(
      child: SizedBox(
        height: 22,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final count = (constraints.maxWidth / 6).floor().clamp(3, 28);
            return AnimatedBuilder(
              animation: _controller,
              builder:
                  (context, _) => Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (var i = 0; i < count; i++)
                        Container(
                          width: 3,
                          height: 4 + 16 * (0.5 + 0.5 * math.sin(_controller.value * 2 * math.pi + i * 0.7)).abs() * (0.4 + 0.6 * ((i * 37) % 10) / 10),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(2)),
                        ),
                    ],
                  ),
            );
          },
        ),
      ),
    );
  }
}

/// Lembar "+" : Kamera, Galeri, Berkas, dan Mode cepat.
class _ToolsSheet extends StatefulWidget {
  const _ToolsSheet({required this.limits, this.fastMode, this.onFastModeChanged});

  final AiLimits limits;
  final bool? fastMode;
  final Future<void> Function(bool enabled)? onFastModeChanged;

  @override
  State<_ToolsSheet> createState() => _ToolsSheetState();
}

class _ToolsSheetState extends State<_ToolsSheet> {
  late bool? _fast = widget.fastMode;
  bool _saving = false;

  Future<void> _toggleFast(bool value) async {
    final change = widget.onFastModeChanged;
    if (change == null || _saving) {
      return;
    }
    setState(() {
      _saving = true;
      _fast = value;
    });
    try {
      await change(value);
    } catch (_) {
      if (mounted) {
        setState(() => _fast = !value);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget tile(String key, IconData icon, String label) => Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: AiColors.codeFill(context),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: Key('ai-pick-$key'),
            borderRadius: BorderRadius.circular(16),
            onTap: () => Navigator.pop(context, key),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
              child: Column(
                children: [
                  Icon(icon, size: 26, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 8),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                tile('camera', Icons.photo_camera_outlined, 'Kamera'),
                const SizedBox(width: 10),
                tile('gallery', Icons.photo_library_outlined, 'Galeri'),
                const SizedBox(width: 10),
                tile('file', Icons.description_outlined, 'Berkas'),
              ],
            ),
            const SizedBox(height: 10),
            Text('Foto nota, PDF, atau Excel/CSV · maks. ${widget.limits.maxUploadLabel} per file', style: TextStyle(fontSize: 12, color: mutedText(context))),
            if (_fast != null) ...[
              const SizedBox(height: 8),
              const Divider(),
              SwitchListTile(
                key: const Key('ai-fast-mode'),
                contentPadding: EdgeInsets.zero,
                secondary: Icon(Icons.bolt_rounded, color: Theme.of(context).colorScheme.primary),
                title: const Text('Mode cepat', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Penjualan barang dari Katalog yang harganya jelas langsung tercatat, tanpa perlu Setujui.', style: TextStyle(fontSize: 12)),
                value: _fast!,
                onChanged: widget.onFastModeChanged == null || _saving ? null : _toggleFast,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DraftPreview extends StatelessWidget {
  const _DraftPreview({super.key, required this.file, required this.removeKey, this.onRemove});

  final AiDraftAttachment file;
  final Key removeKey;
  final VoidCallback? onRemove;

  static const double _removeOverhang = 11;

  /// "PDF · 240 KB" (jenis file dari akhiran nama).
  static String detail(AiDraftAttachment file) {
    final dot = file.name.lastIndexOf('.');
    final ext = dot > 0 && dot < file.name.length - 1 ? file.name.substring(dot + 1).toUpperCase() : '';
    final kb = (file.size / 1024).round();
    final size = kb >= 1024 ? '${(kb / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB' : '$kb KB';
    return ext.isEmpty || ext.length > 5 ? size : '$ext · $size';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lower = file.name.toLowerCase();
    final icon = file.isAudio ? Icons.graphic_eq_rounded : (lower.endsWith('.pdf') ? Icons.picture_as_pdf_outlined : (file.isImage ? Icons.image_outlined : Icons.table_chart_outlined));
    // Huruf besar: nama satu baris supaya tetap muat di kartu setinggi 64.
    final bigText = MediaQuery.textScalerOf(context).scale(12) > 13.5;
    final body =
        file.isImage
            ? Image.file(File(file.path), width: 64, height: 64, fit: BoxFit.cover, cacheWidth: (64 * MediaQuery.devicePixelRatioOf(context)).round(), semanticLabel: 'Foto ${file.name}')
            : Container(
              width: file.isAudio ? 132 : 204,
              height: 64,
              padding: const EdgeInsets.fromLTRB(8, 6, 24, 6),
              color: AiColors.codeFill(context),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                    child: Icon(icon, size: 20, color: scheme.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.isAudio ? 'Voice note' : file.name,
                          maxLines: file.isAudio || bigText ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.25),
                        ),
                        Text(
                          file.isAudio ? AiComposerState._clock(file.seconds ?? 0) : detail(file),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, height: 1.3, color: mutedText(context)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
    // Kartu digeser 11dp dari atas/kanan supaya area ketuk × 48×48 berada
    // di dalam Stack (ketukan di luar batas Stack tidak sampai ke tombol).
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: _removeOverhang, right: _removeOverhang),
          child: Semantics(
            container: true,
            label: file.isAudio ? 'Voice note ${AiComposerState._clock(file.seconds ?? 0)}' : (file.isImage ? null : '${file.name}, ${detail(file)}'),
            excludeSemantics: !file.isImage,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AiColors.border(context))),
                child: body,
              ),
            ),
          ),
        ),
        if (onRemove != null)
          // Lingkaran × 22dp, area ketuk 48×48 (pedoman aksesibilitas)
          // berpusat di lingkaran yang sama seperti sebelumnya.
          Positioned(
            top: 0,
            right: 0,
            child: Semantics(
              container: true,
              button: true,
              label: 'Hapus lampiran ${file.isAudio ? 'voice note' : file.name}',
              child: SizedBox(
                width: 48,
                height: 48,
                child: InkWell(
                  key: removeKey,
                  onTap: onRemove,
                  customBorder: const CircleBorder(),
                  child: Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
