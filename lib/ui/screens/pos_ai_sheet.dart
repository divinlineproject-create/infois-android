import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/store_policy.dart';
import '../../data/api_client.dart';
import '../../domain/pos_ai.dart';
import '../../services/ai_media.dart';
import '../../services/permission_gate.dart';
import '../../state/pos_state.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Input AI di kasir (online saja): pesanan diketik, diucapkan (ketuk
/// tombol), atau difoto. Barang langsung masuk keranjang (tanpa Setujui;
/// keranjang tempat memeriksa). Yang tidak cocok tidak dimasukkan dan bisa
/// dipilih dari saran. Setiap pemakaian memakai koin perusahaan.
Future<void> showPosAiSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: const PosAiSheet(),
      ),
    );

/// Cara input terakhir yang dipilih (diingat selama aplikasi terbuka).
PosAiMode _lastMode = PosAiMode.text;

class PosAiSheet extends ConsumerStatefulWidget {
  const PosAiSheet({super.key});

  /// Rekaman terpanjang (detik).
  static const int maxSeconds = 120;

  @override
  ConsumerState<PosAiSheet> createState() => _PosAiSheetState();
}

class _PosAiSheetState extends ConsumerState<PosAiSheet> {
  final _text = TextEditingController();
  late PosAiMode _mode = _lastMode;
  bool _busy = false;
  bool _recording = false;
  bool _pressed = false;
  int _press = 0;
  int _seconds = 0;
  Timer? _timer;
  String? _error;
  String? _hint;
  PosAiResult? _result;
  List<PosAiAdded> _added = const [];
  List<PosAiUnmatched> _unmatched = const [];

  @override
  void dispose() {
    _timer?.cancel();
    if (_recording) {
      unawaited(ref.read(voiceRecorderProvider).cancel().catchError((_) {}));
    }
    _text.dispose();
    super.dispose();
  }

  void _setMode(PosAiMode mode) {
    if (_busy || _recording) {
      return;
    }
    setState(() {
      _mode = mode;
      _lastMode = mode;
      _error = null;
      _hint = null;
    });
  }

  Future<void> _send({String? text, String? path, String? name, int? seconds}) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
      _result = null;
    });
    try {
      final (result, applied) = await ref.read(posActionsProvider).aiInput(_mode, text: text, path: path, name: name, seconds: seconds);
      if (!mounted) {
        return;
      }
      if (applied.added.isNotEmpty) {
        HapticFeedback.mediumImpact();
      }
      setState(() {
        _result = result;
        _added = applied.added;
        _unmatched = applied.unmatched;
        if (_mode == PosAiMode.text) {
          _text.clear();
        }
      });
    } catch (error) {
      if (error is ApiException && error.unauthenticated) {
        unawaited(ref.read(sessionProvider.notifier).expire());
      }
      if (mounted) {
        setState(() => _error = switch (error) {
              ApiException(code: 'koin_habis') => posAiCoinsShortMessage,
              ApiException(offline: true) => 'Input AI butuh internet. Sambungkan internet lalu coba lagi.',
              _ => plainError(error, fallback: 'Input AI belum berhasil. Coba lagi.'),
            });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _sendText() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Tulis pesanannya dulu, mis. "kopsus 2, nasduk 1".');
      return;
    }
    await _send(text: text);
  }

  // ------------------------------------------------------------- suara

  Future<void> _startRecording() async {
    // _pressed: masih menunggu izin mikrofon dari ketukan sebelumnya.
    if (_busy || _recording || _pressed) {
      return;
    }
    final press = ++_press;
    _pressed = true;
    setState(() {
      _error = null;
      _hint = null;
      _result = null;
    });
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
      setState(() => _error = 'Izinkan mikrofon untuk memakai Input AI suara.');
      return;
    }
    // Dibatalkan / sheet berganti selagi menunggu izin / perekam siap.
    if (!_pressed || press != _press) {
      await recorder.cancel().catchError((_) {});
      return;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _recording = true;
      _seconds = 0;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() => _seconds++);
      if (_seconds >= PosAiSheet.maxSeconds) {
        _stopRecording();
      }
    });
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    _pressed = false;
    if (!_recording) {
      return;
    }
    _timer?.cancel();
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
        setState(() => _hint = 'Rekaman terlalu pendek. Ketuk mikrofon, bicara, lalu ketuk lagi untuk kirim.');
        return;
      }
      await _send(path: file.path, name: file.name, seconds: file.seconds);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Rekaman gagal disimpan. Coba lagi.');
      }
    }
  }

  // -------------------------------------------------------------- foto

  Future<void> _pickPhoto({required bool camera}) async {
    if (_busy) {
      return;
    }
    try {
      final file = await ref.read(aiMediaPickerProvider).pickImage(camera: camera);
      if (file == null || !mounted) {
        return;
      }
      await _send(path: file.path, name: file.name);
    } catch (_) {
      if (mounted) {
        setState(() => _error = camera ? 'Kamera tidak bisa dibuka. Periksa izin kamera di pengaturan HP.' : 'Galeri tidak bisa dibuka.');
      }
    }
  }

  // ------------------------------------------------------------- hasil

  Future<void> _addSuggestion(PosAiUnmatched row, PosAiSuggestion suggestion) async {
    final product = await ref.read(posActionsProvider).activeProduct(suggestion.id);
    if (!mounted || product == null) {
      return;
    }
    HapticFeedback.selectionClick();
    final added = ref.read(cartProvider.notifier).addAiSuggestion(product, row);
    setState(() {
      _unmatched = _unmatched.where((item) => !identical(item, row)).toList();
      _added = [..._added, added];
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Input AI', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Space.xs),
        Text(
          'Tulis, ucapkan, atau foto pesanan. Barang langsung masuk keranjang; periksa di keranjang.',
          style: TextStyle(color: mutedText(context), fontSize: 13),
        ),
        const SizedBox(height: Space.m),
        Row(children: [
          for (final mode in PosAiMode.values) ...[
            if (mode != PosAiMode.text) const SizedBox(width: Space.s),
            Expanded(child: _ModeButton(mode: mode, selected: mode == _mode, enabled: !_busy && !_recording, onTap: () => _setMode(mode))),
          ],
        ]),
        const SizedBox(height: Space.m),
        switch (_mode) {
          PosAiMode.text => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                key: const Key('pos-ai-text'),
                controller: _text,
                enabled: !_busy,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                maxLength: 500,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(hintText: 'mis. "kopsus 2, nasduk 1" atau "dua kopi susu satu nasi uduk"', counterText: ''),
                onSubmitted: (_) => _sendText(),
              ),
              const SizedBox(height: Space.s),
              FilledButton(key: const Key('pos-ai-send'), onPressed: _busy ? null : _sendText, child: const Text('Masukkan ke keranjang')),
            ]),
          PosAiMode.voice => Column(children: [
              const SizedBox(height: Space.s),
              GestureDetector(
                key: const Key('pos-ai-mic'),
                onTap: _busy ? null : (_recording ? _stopRecording : _startRecording),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: _recording ? 104 : 96,
                  height: _recording ? 104 : 96,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: _recording ? Brand.danger : (_busy ? scheme.surfaceContainerHighest : scheme.primary)),
                  child: Icon(_recording ? Icons.stop : Icons.mic, size: 40, color: _recording ? Colors.white : scheme.onPrimary),
                ),
              ),
              const SizedBox(height: Space.s),
              Text(_recording ? 'Merekam… $_seconds dtk · ketuk untuk berhenti & kirim' : (_pressed ? 'Menunggu izin mikrofon…' : 'Ketuk untuk mulai bicara'), key: const Key('pos-ai-mic-label'), style: const TextStyle(fontWeight: FontWeight.w600)),
              if (_recording)
                TextButton(key: const Key('pos-ai-mic-cancel'), onPressed: () => _stopRecording(cancel: true), child: const Text('Batal'))
              else
                Text('mis. "dua kopi susu, satu nasi uduk"', style: TextStyle(color: mutedText(context), fontSize: 12.5)),
            ]),
          PosAiMode.photo => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Foto catatan pesanan atau nota. Tulisan tangan boleh; foto dekat, terang, dan tegak.', style: TextStyle(color: mutedText(context), fontSize: 13)),
              const SizedBox(height: Space.s),
              Row(children: [
                Expanded(child: FilledButton.icon(key: const Key('pos-ai-camera'), onPressed: _busy ? null : () => _pickPhoto(camera: true), icon: const Icon(Icons.photo_camera_outlined), label: const Text('Kamera'))),
                const SizedBox(width: Space.s),
                Expanded(child: OutlinedButton.icon(key: const Key('pos-ai-gallery'), onPressed: _busy ? null : () => _pickPhoto(camera: false), icon: const Icon(Icons.photo_library_outlined), label: const Text('Galeri'))),
              ]),
            ]),
        },
        if (_busy) ...[
          const SizedBox(height: Space.m),
          const Row(key: Key('pos-ai-busy'), children: [
            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: Space.m),
            Text('AI membaca pesanan…'),
          ]),
        ],
        if (_hint != null) ...[
          const SizedBox(height: Space.s),
          Text(_hint!, style: TextStyle(color: mutedText(context), fontSize: 12.5)),
        ],
        if (_error != null) ...[
          const SizedBox(height: Space.m),
          _Notice(key: const Key('pos-ai-error'), text: _error!, color: dangerText(context)),
        ],
        if (_result != null) ..._resultView(context),
      ]),
    );
  }

  List<Widget> _resultView(BuildContext context) {
    final result = _result!;
    final scheme = Theme.of(context).colorScheme;
    return [
      const SizedBox(height: Space.m),
      if (result.heard != null && result.heard!.isNotEmpty) ...[
        Text('Terbaca: “${result.heard}”', style: TextStyle(color: mutedText(context), fontSize: 12.5)),
        const SizedBox(height: Space.s),
      ],
      if (result.message != null) ...[
        _Notice(text: result.message!, color: dangerText(context)),
        const SizedBox(height: Space.s),
      ],
      if (_added.isNotEmpty)
        Container(
          key: const Key('pos-ai-added'),
          padding: const EdgeInsets.all(Space.m),
          decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(Radii.m)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.check_circle_outline, color: scheme.onPrimaryContainer),
            const SizedBox(width: Space.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_added.length} barang masuk keranjang', style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer)),
                for (final row in _added) Text('${qty(row.quantity)} ${row.unit} ${row.name}', style: TextStyle(fontSize: 13, color: scheme.onPrimaryContainer)),
              ]),
            ),
          ]),
        ),
      if (_unmatched.isNotEmpty) ...[
        const SizedBox(height: Space.m),
        const Text('Tidak ditemukan (tidak dimasukkan)', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: Space.xs),
        for (final (index, row) in _unmatched.indexed)
          Container(
            key: Key('pos-ai-unmatched-$index'),
            margin: const EdgeInsets.only(top: Space.s),
            padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.xs, Space.s),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Radii.m)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('“${row.said}”', style: const TextStyle(fontWeight: FontWeight.w600))),
                IconButton(
                  tooltip: 'Abaikan',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => setState(() => _unmatched = _unmatched.where((item) => !identical(item, row)).toList()),
                ),
              ]),
              if (row.suggestions.isEmpty)
                Text('Tidak ada barang yang mirip di kasir. Cari manual bila perlu.', style: TextStyle(color: mutedText(context), fontSize: 12.5))
              else
                Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('Maksudnya:', style: TextStyle(color: mutedText(context), fontSize: 12.5)),
                  for (final suggestion in row.suggestions)
                    ActionChip(
                      key: Key('pos-ai-suggestion-${suggestion.id}'),
                      visualDensity: VisualDensity.compact,
                      label: Text('+ ${suggestion.name}', style: const TextStyle(fontSize: 12.5)),
                      onPressed: () => _addSuggestion(row, suggestion),
                    ),
                ]),
            ]),
          ),
      ],
      const SizedBox(height: Space.m),
      const SizedBox(height: Space.s),
      OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Selesai')),
    ];
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.mode, required this.selected, required this.enabled, required this.onTap});

  final PosAiMode mode;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.m), side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant)),
      child: InkWell(
        key: Key('pos-ai-mode-${mode.code}'),
        borderRadius: BorderRadius.circular(Radii.m),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s, horizontal: Space.xs),
          child: Column(children: [
            Text(mode.label, style: TextStyle(fontWeight: FontWeight.w600, color: foreground)),
          ]),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(Space.m),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(Radii.m)),
        child: Text(text, style: TextStyle(color: color, fontSize: 13.5)),
      );
}
