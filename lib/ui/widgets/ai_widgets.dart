import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/format.dart';
import '../../data/ai_api.dart';
import '../../domain/ai_models.dart';
import '../../services/file_downloads.dart';
import '../../state/ai_state.dart';
import '../theme.dart';
import 'common.dart';

/// Warna tim (sama dengan kelas Tailwind di web: bg-{tone}-100 text-{tone}-700).
({Color background, Color foreground}) toneColors(String tone, {bool dark = false}) {
  final (light, strong, bright) = switch (tone) {
    'amber' => (const Color(0xFFFEF3C7), const Color(0xFFB45309), const Color(0xFFFCD34D)),
    'emerald' => (const Color(0xFFD1FAE5), const Color(0xFF047857), const Color(0xFF6EE7B7)),
    'indigo' => (const Color(0xFFE0E7FF), const Color(0xFF4338CA), const Color(0xFFA5B4FC)),
    'violet' => (const Color(0xFFEDE9FE), const Color(0xFF6D28D9), const Color(0xFFC4B5FD)),
    'rose' => (const Color(0xFFFFE4E6), const Color(0xFFBE123C), const Color(0xFFFDA4AF)),
    'teal' => (const Color(0xFFCCFBF1), const Color(0xFF0F766E), const Color(0xFF5EEAD4)),
    'orange' => (const Color(0xFFFFEDD5), const Color(0xFFC2410C), const Color(0xFFFDBA74)),
    _ => (const Color(0xFFE0F2FE), const Color(0xFF0369A1), const Color(0xFF7DD3FC)),
  };
  return dark ? (background: strong.withValues(alpha: 0.25), foreground: bright) : (background: light, foreground: strong);
}

/// Ikon tim dari nama Heroicon di web.
IconData teamIcon(String icon) => switch (icon) {
      'shopping-bag' => Icons.shopping_bag_outlined,
      'cube' => Icons.inventory_2_outlined,
      'banknotes' => Icons.payments_outlined,
      'calculator' => Icons.calculate_outlined,
      'chart-bar' => Icons.bar_chart_rounded,
      'shield-check' => Icons.verified_user_outlined,
      'truck' => Icons.local_shipping_outlined,
      'users' => Icons.people_outline,
      _ => Icons.auto_awesome,
    };

/// Avatar bundar tim dengan warna & ikon web; gembok bila belum termasuk paket.
class TeamAvatar extends StatelessWidget {
  const TeamAvatar({super.key, required this.tone, this.icon = '', this.size = 44, this.locked = false});

  final String tone;
  final String icon;
  final double size;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final colors = toneColors(tone, dark: Theme.of(context).brightness == Brightness.dark);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: colors.background, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Icon(teamIcon(icon), size: size * 0.5, color: colors.foreground),
        ),
        if (locked)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, shape: BoxShape.circle),
              child: Icon(Icons.lock, size: size * 0.3, color: mutedText(context)),
            ),
          ),
      ]),
    );
  }
}

/// Tiga titik berkedip: "sedang mengerjakan".
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color});

  final Color? color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return Semantics(
      label: 'Sedang mengerjakan',
      child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Opacity(
              opacity: 0.3 + 0.7 * (0.5 + 0.5 * (1 - ((_controller.value - i / 3) % 1.0 - 0.5).abs() * 2)),
              child: Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            ),
          ),
      ]),
      ),
    );
  }
}

/// Markdown sederhana dari pesan asisten: **tebal**, _miring_, `kode`,
/// daftar `- `, nomor `1. `, judul `#`.
class MarkdownLite extends StatelessWidget {
  const MarkdownLite(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final children = <Widget>[];
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }
      final heading = RegExp(r'^(#{1,4})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text.rich(TextSpan(children: inlineSpans(heading.group(2)!, base.copyWith(fontWeight: FontWeight.w700, fontSize: (base.fontSize ?? 14) + 1)))),
        ));
        continue;
      }
      final bullet = RegExp(r'^\s*([-*•]|\d+[.)])\s+(.*)$').firstMatch(line);
      if (bullet != null) {
        final marker = bullet.group(1)!;
        children.add(Padding(
          padding: const EdgeInsets.only(left: 4, top: 1, bottom: 1),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 20, child: Text(RegExp(r'^\d').hasMatch(marker) ? marker : '•', style: base)),
            Expanded(child: Text.rich(TextSpan(children: inlineSpans(bullet.group(2)!, base)))),
          ]),
        ));
        continue;
      }
      children.add(Text.rich(TextSpan(children: inlineSpans(line, base))));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }

  /// Pecah satu baris menjadi potongan tebal/miring/kode.
  static List<InlineSpan> inlineSpans(String text, TextStyle base) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'(\*\*(.+?)\*\*)|(`(.+?)`)|((?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w))|((?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w))');
    var index = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: text.substring(index, match.start), style: base));
      }
      if (match.group(2) != null) {
        spans.add(TextSpan(text: match.group(2), style: base.copyWith(fontWeight: FontWeight.w700)));
      } else if (match.group(4) != null) {
        spans.add(TextSpan(text: match.group(4), style: base.copyWith(fontFamily: 'monospace', backgroundColor: (base.color ?? Colors.black).withValues(alpha: 0.08))));
      } else {
        spans.add(TextSpan(text: match.group(6) ?? match.group(8), style: base.copyWith(fontStyle: FontStyle.italic)));
      }
      index = match.end;
    }
    if (index < text.length) {
      spans.add(TextSpan(text: text.substring(index), style: base));
    }
    return spans;
  }
}

/// Bilah pemakaian koin bulan ini dalam bahasa sehari-hari (tanpa istilah teknis).
class CoinUsageBar extends StatelessWidget {
  const CoinUsageBar(this.coins, {super.key});

  final AiCoins coins;

  @override
  Widget build(BuildContext context) {
    final color = coins.percent >= 90 ? dangerText(context) : (coins.percent >= 70 ? warningText(context) : Theme.of(context).colorScheme.primary);
    final resets = coins.resetsAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Jatah Tim AI bulan ini', style: TextStyle(fontWeight: FontWeight.w600))),
            Text('${coins.percent}% terpakai', style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(key: const Key('coin-usage-bar'), value: coins.percent / 100, minHeight: 8, color: color, backgroundColor: color.withValues(alpha: 0.15), semanticsLabel: 'Jatah Tim AI terpakai', semanticsValue: '${coins.percent}%'),
          ),
          const SizedBox(height: 10),
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 4, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('Tersisa ', style: TextStyle(fontSize: 13)),
              CoinAmount(_num(coins.available), size: 16, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            if (resets != null) Text('Diisi lagi ${dateLabel(resets.toLocal())}', style: TextStyle(fontSize: 12, color: mutedText(context))),
          ]),
        ]),
      ),
    );
  }

  static num _num(String value) => num.tryParse(value) ?? 0;
}

/// Gambar lampiran: dari file HP (baru dikirim) atau diunduh dengan token.
class AttachmentImage extends ConsumerWidget {
  const AttachmentImage(this.attachment, {super.key, this.size = 160});

  final AiAttachment attachment;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Thumbnail didekode sebatas ukuran tampil (bukan resolusi penuh kamera);
    // foto ukuran asli hanya didekode di tampilan layar penuh.
    final cacheWidth = (size * MediaQuery.devicePixelRatioOf(context)).round();
    Widget frame(Widget child) => ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox(width: size, height: size, child: child));
    Widget tappable(Widget thumbnail, ImageProvider full) => Semantics(
          button: true,
          label: 'Foto ${attachment.name}, ketuk untuk memperbesar',
          child: GestureDetector(onTap: () => _open(context, full), child: frame(thumbnail)),
        );
    final localPath = attachment.localPath;
    if (localPath != null) {
      final file = File(localPath);
      return tappable(Image.file(file, fit: BoxFit.cover, cacheWidth: cacheWidth), FileImage(file));
    }
    final url = attachment.url;
    if (url == null) {
      return frame(const Icon(Icons.image_outlined));
    }
    final bytes = ref.watch(aiAttachmentBytesProvider(url));
    final placeholder = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06);
    return bytes.when(
      loading: () => frame(Container(color: placeholder, child: const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: 'Memuat foto'))))),
      error: (_, __) => frame(Container(color: placeholder, child: Icon(Icons.broken_image_outlined, color: mutedText(context), semanticLabel: 'Foto tidak bisa dimuat'))),
      data: (data) => tappable(Image.memory(data, fit: BoxFit.cover, cacheWidth: cacheWidth), MemoryImage(data)),
    );
  }

  void _open(BuildContext context, ImageProvider image) {
    final url = attachment.url;
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(children: [
              Positioned.fill(child: InteractiveViewer(child: Center(child: Image(image: image, fit: BoxFit.contain, semanticLabel: 'Foto ${attachment.name}')))),
              Positioned(
                top: 8,
                right: 8,
                child: SafeArea(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    // Foto dari server: simpan ke Download (Buka / Bagikan).
                    if (url != null && attachment.localPath == null)
                      Consumer(
                        builder: (context, ref, _) => IconButton(
                          key: const Key('attachment-image-save'),
                          tooltip: 'Simpan ke HP',
                          icon: const Icon(Icons.download_outlined, color: Colors.white),
                          onPressed: () => downloadAndOffer(context, ref, apiPath: AiApi.relativeApiPath(url), fileName: attachment.name),
                        ),
                      ),
                    IconButton(tooltip: 'Tutup', icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Chip file (PDF/Excel/laporan) dengan nama dan ukuran. File dari server
/// (lampiran terkirim, laporan buatan Tim AI) diketuk untuk diunduh ke folder
/// Download lalu dibuka / dibagikan.
class AttachmentChip extends ConsumerWidget {
  const AttachmentChip(this.attachment, {super.key, this.onRemove});

  final AiAttachment attachment;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = attachment.url;
    final chip = _chip(context, downloadable: onRemove == null && url != null);
    if (onRemove != null || url == null) {
      return chip;
    }
    return Semantics(
      button: true,
      label: 'Unduh ${attachment.name}',
      child: InkWell(
        key: Key('attachment-download-${attachment.index}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => downloadAndOffer(context, ref, apiPath: AiApi.relativeApiPath(url), fileName: attachment.name),
        child: chip,
      ),
    );
  }

  Widget _chip(BuildContext context, {required bool downloadable}) {
    final icon = switch (attachment.kind) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'sheet' => Icons.table_chart_outlined,
      'report' => Icons.description_outlined,
      'audio' => Icons.mic_none,
      'image' => Icons.image_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: Theme.of(context).dividerColor)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 170),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            Text(attachment.kind == 'report' ? 'Laporan dari Tim AI · ${attachment.sizeLabel}' : attachment.sizeLabel, style: TextStyle(fontSize: 11, color: mutedText(context))),
          ]),
        ),
        if (onRemove != null) IconButton(visualDensity: VisualDensity.compact, tooltip: 'Hapus lampiran', icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
        if (downloadable) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.download_outlined, size: 18, color: mutedText(context))),
      ]),
    );
  }
}

/// Pemutar voice note: tombol putar, posisi, dan hasil transkripsi.
class AudioNotePlayer extends ConsumerStatefulWidget {
  const AudioNotePlayer(this.attachment, {super.key, this.compact = false});

  final AiAttachment attachment;
  final bool compact;

  @override
  ConsumerState<AudioNotePlayer> createState() => _AudioNotePlayerState();
}

class _AudioNotePlayerState extends ConsumerState<AudioNotePlayer> {
  AudioPlayer? _player;
  bool _loading = false;
  String? _error;
  bool _showTranscript = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    var player = _player;
    if (player == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        player = AudioPlayer();
        final local = widget.attachment.localPath;
        if (local != null) {
          await player.setFilePath(local);
        } else {
          final bytes = await ref.read(aiAttachmentBytesProvider(widget.attachment.url ?? '').future);
          final directory = await getTemporaryDirectory();
          final file = File(p.join(directory.path, 'ai-audio-${widget.attachment.url.hashCode}${p.extension(widget.attachment.name).isEmpty ? '.m4a' : p.extension(widget.attachment.name)}'));
          await file.writeAsBytes(bytes, flush: true);
          await player.setFilePath(file.path);
        }
        _player = player;
        player.playerStateStream.listen((state) {
          if (state.processingState == ProcessingState.completed) {
            player!.pause();
            player.seek(Duration.zero);
          }
          if (mounted) {
            setState(() {});
          }
        });
      } catch (error) {
        player?.dispose();
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Rekaman tidak bisa diputar.';
          });
        }
        return;
      }
      if (mounted) {
        setState(() => _loading = false);
      }
    }
    if (player.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  static String _clock(Duration value) => '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final total = Duration(seconds: widget.attachment.seconds ?? 0);
    final transcript = widget.attachment.transcript;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: Theme.of(context).dividerColor)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _loading
              ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(
                  tooltip: player?.playing ?? false ? 'Jeda' : 'Putar voice note',
                  icon: Icon(player?.playing ?? false ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 36, color: Theme.of(context).colorScheme.primary),
                  onPressed: _toggle,
                ),
          SizedBox(
            width: widget.compact ? 90 : 140,
            child: player == null
                ? Row(children: [for (var i = 0; i < (widget.compact ? 12 : 18); i++) Expanded(child: Container(margin: const EdgeInsets.symmetric(horizontal: 1), height: 6 + (i * 7) % 14, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)))])
                : StreamBuilder<Duration>(
                    stream: player.positionStream,
                    builder: (context, snapshot) {
                      final position = snapshot.data ?? Duration.zero;
                      final max = player.duration ?? total;
                      return SliderTheme(
                        data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: SliderComponentShape.noOverlay),
                        child: Slider(
                          label: 'Posisi voice note',
                          semanticFormatterCallback: (value) => _clock(Duration(milliseconds: (max.inMilliseconds * value).round())),
                          value: max.inMilliseconds == 0 ? 0 : (position.inMilliseconds / max.inMilliseconds).clamp(0, 1).toDouble(),
                          onChanged: (value) => player.seek(Duration(milliseconds: (max.inMilliseconds * value).round())),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(width: 8),
          Text(_clock(player?.duration ?? total), style: TextStyle(fontSize: 12, color: mutedText(context))),
        ]),
      ),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 4, left: 8), child: Text(_error!, style: const TextStyle(fontSize: 12, color: Brand.danger))),
      if (transcript != null && transcript.trim().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 8),
          child: InkWell(
            onTap: () => setState(() => _showTranscript = !_showTranscript),
            child: Text(
              _showTranscript ? '“$transcript”' : 'Lihat teks rekaman',
              style: TextStyle(fontSize: 12, color: _showTranscript ? null : Theme.of(context).colorScheme.primary, fontStyle: _showTranscript ? FontStyle.italic : null),
            ),
          ),
        ),
    ]);
  }
}

/// Kartu usulan AI (penjualan, pembelian, pembayaran, …) dengan tombol
/// Setujui · Ubah · Tolak. Isi ringkasan mengikuti `preview` per jenis (API.md).
class ProposalCard extends StatelessWidget {
  const ProposalCard({super.key, required this.proposal, this.busy = false, this.onApprove, this.onReject, this.onEdit});

  final AiProposal proposal;
  final bool busy;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final (statusColor, statusIcon) = switch (proposal.status) {
      'executed' => (Brand.green, Icons.check_circle),
      'rejected' => (Colors.blueGrey, Icons.cancel_outlined),
      'failed' => (Brand.danger, Icons.error_outline),
      _ => (warningText(context), Icons.hourglass_top_rounded),
    };
    final muted = mutedText(context);
    return Card(
      key: Key('proposal-${proposal.id}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(_typeIcon(proposal.type), size: 22, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(proposal.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
          ]),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(statusIcon, size: 14, color: statusColor),
              const SizedBox(width: 6),
              Flexible(child: Text(proposal.statusLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: statusColor))),
            ]),
          ),
          const SizedBox(height: 10),
          ..._body(context, muted),
          for (final warning in proposal.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: warningText(context)),
                const SizedBox(width: 6),
                Expanded(child: Text(warning, style: TextStyle(fontSize: 12, color: warningText(context)))),
              ]),
            ),
          if (proposal.error != null && proposal.error!.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Brand.danger.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
              child: Text(proposal.error!, style: TextStyle(fontSize: 13, color: dangerText(context))),
            ),
          if (proposal.executed && proposal.resultLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Icon(Icons.receipt_long_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(child: Text(proposal.resultLabel!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary))),
              ]),
            ),
          // Cetak invoice / rincian lengkap: dibuka di browser (website Infois).
          if (proposal.executed && (proposal.printLinks.isNotEmpty || proposal.resultUrl != null))
            Consumer(
              builder: (context, ref, _) => Wrap(spacing: 4, children: [
                for (final link in proposal.printLinks)
                  if (link['url'] != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: () => openExternalLink(context, ref, link['url'].toString()),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(link['label']?.toString() ?? 'Buka di web'),
                    ),
                if (proposal.resultUrl != null)
                  TextButton.icon(
                    key: Key('result-link-${proposal.id}'),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => openExternalLink(context, ref, proposal.resultUrl!),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Lihat di web'),
                  ),
              ]),
            ),
          if (proposal.pending) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              key: Key('approve-${proposal.id}'),
              style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 46)),
              onPressed: busy ? null : onApprove,
              icon: busy ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary, semanticsLabel: 'Menyimpan')) : const Icon(Icons.check, size: 18),
              label: const Text('Setujui'),
            ),
          ],
          if (proposal.pending || proposal.failed) ...[
            const SizedBox(height: 6),
            Row(children: [
              if (proposal.pending && proposal.editable) ...[
                Expanded(child: OutlinedButton(key: Key('edit-${proposal.id}'), style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)), onPressed: busy ? null : onEdit, child: const Text('Ubah'))),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: TextButton(
                  key: Key('reject-${proposal.id}'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 42), foregroundColor: dangerText(context)),
                  onPressed: busy ? null : onReject,
                  child: Text(proposal.failed ? 'Abaikan' : 'Tolak'),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  static IconData _typeIcon(String type) => switch (type) {
        'sale' || 'sales_order' => Icons.point_of_sale_outlined,
        'purchase' => Icons.shopping_cart_outlined,
        'payment' || 'collection' => Icons.payments_outlined,
        'journal' => Icons.account_balance_wallet_outlined,
        'products' || 'product_update' => Icons.inventory_2_outlined,
        'delivery' => Icons.local_shipping_outlined,
        'production' => Icons.precision_manufacturing_outlined,
        'stock_opname' => Icons.fact_check_outlined,
        'void' => Icons.block,
        'settings' => Icons.settings_outlined,
        _ => Icons.description_outlined,
      };

  List<Widget> _body(BuildContext context, Color muted) {
    final preview = proposal.preview;
    final payload = proposal.payload;
    Widget row(String label, String value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 110, child: Text(label, style: TextStyle(fontSize: 13, color: muted))),
            Expanded(child: Text(value, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w600 : FontWeight.w400))),
          ]),
        );
    String money(Object? value) => rupiah(value ?? 0);

    switch (proposal.type) {
      case 'sale':
      case 'sales_order':
      case 'purchase':
        final lines = _maps(preview['lines'] ?? payload['items']);
        final totals = _map(preview['totals']);
        final contact = preview['contact']?.toString() ?? payload['customer_name']?.toString() ?? '-';
        return [
          row(proposal.type == 'purchase' ? 'Pemasok' : 'Pelanggan', '$contact${preview['new_contact'] == true ? ' (baru)' : ''}'),
          if (payload['date'] != null) row('Tanggal', _dateText(payload['date'])),
          if (payload['delivery_date'] != null) row('Kirim', _dateText(payload['delivery_date'])),
          const SizedBox(height: 4),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${line['description'] ?? line['name'] ?? '-'}${line['account_label'] != null ? ' · ${line['account_label']}' : ''}', style: const TextStyle(fontSize: 13)),
                    Text('${qty(line['quantity'] ?? 0)} ${line['unit'] ?? ''} × ${money(line['unit_price'])}', style: TextStyle(fontSize: 12, color: muted)),
                  ]),
                ),
                const SizedBox(width: 8),
                Text(money(line['total'] ?? line['line_total']), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              ]),
            ),
          if (totals.isNotEmpty) ...[
            const Divider(height: 14),
            if ((totals['tax_total']?.toString() ?? '0.00') != '0.00') row('Pajak', money(totals['tax_total'])),
            row('Total', money(totals['total']), bold: true),
          ],
          if (preview['payment'] != null) row('Pembayaran', preview['payment'].toString()),
        ];
      case 'payment':
        return [
          if (preview['document'] != null) row('Dokumen', preview['document'].toString()),
          if (preview['contact'] != null) row('Nama', preview['contact'].toString()),
          if (preview['balance_before'] != null) row('Sisa tagihan', money(preview['balance_before'])),
          row('Jumlah', money(preview['amount'] ?? payload['amount']), bold: true),
          if (preview['payment'] != null) row('Lewat', preview['payment'].toString()),
          if (payload['date'] != null) row('Tanggal', _dateText(payload['date'])),
        ];
      case 'journal':
        final entries = _maps(preview['journal']);
        return [
          if (payload['description'] != null) row('Keterangan', payload['description'].toString()),
          if (payload['amount'] != null) row('Jumlah', money(payload['amount']), bold: true),
          if (payload['date'] != null) row('Tanggal', _dateText(payload['date'])),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text(entry['account']?.toString() ?? '-', style: const TextStyle(fontSize: 13))),
                Flexible(
                  child: Text(
                    (entry['debit']?.toString() ?? '0.00') != '0.00' ? 'Masuk ${money(entry['debit'])}' : 'Keluar ${money(entry['credit'])}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
              ]),
            ),
        ];
      case 'products':
        final items = _maps(payload['items']);
        return [
          row('Barang', '${preview['count'] ?? items.length} barang${preview['new'] != null ? ', ${preview['new']} baru' : ''}'),
          for (final item in items.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text('${item['name'] ?? '-'} (${item['unit'] ?? 'unit'})', style: const TextStyle(fontSize: 13))),
                Flexible(child: Text(item['sale_price'] == null ? '' : 'Jual ${money(item['sale_price'])}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted))),
              ]),
            ),
          if (items.length > 8) Text('… dan ${items.length - 8} lainnya', style: TextStyle(fontSize: 12, color: muted)),
        ];
      case 'delivery':
        return [
          if (preview['order'] != null) row('Pesanan', preview['order'].toString()),
          if (preview['contact'] != null) row('Pelanggan', preview['contact'].toString()),
          for (final line in _maps(preview['lines'] ?? payload['lines']))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text(line['description']?.toString() ?? '-', style: const TextStyle(fontSize: 13))),
                Flexible(child: Text('Kirim ${qty(line['quantity'] ?? 0)} ${line['unit'] ?? ''}${line['remaining'] != null ? ' dari sisa ${qty(line['remaining'])}' : ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted))),
              ]),
            ),
        ];
      case 'production':
        return [
          for (final material in _maps(preview['materials']))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text(material['name']?.toString() ?? '-', style: const TextStyle(fontSize: 13))),
                Flexible(child: Text('${qty(material['quantity'] ?? 0)} ${material['unit'] ?? ''}${material['stock'] != null ? ' (stok ${qty(material['stock'])})' : ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted))),
              ]),
            ),
          for (final cost in _maps(preview['costs']))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text(cost['name']?.toString() ?? cost['label']?.toString() ?? 'Biaya', style: const TextStyle(fontSize: 13))),
                Text(money(cost['amount']), style: TextStyle(fontSize: 12, color: muted)),
              ]),
            ),
        ];
      default:
        final changes = preview['changes'] ?? payload['changes'];
        final rows = <Widget>[];
        if (changes is List) {
          for (final change in changes) {
            rows.add(Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(change is Map ? _changeText(Map<String, dynamic>.from(change)) : '• $change', style: const TextStyle(fontSize: 13))));
          }
        } else if (changes is Map) {
          for (final entry in changes.entries) {
            rows.add(row(entry.key.toString(), entry.value.toString()));
          }
        }
        return rows;
    }
  }

  static String _changeText(Map<String, dynamic> change) {
    final label = change['label'] ?? change['field'] ?? change['name'] ?? '';
    final from = change['from'] ?? change['old'];
    final to = change['to'] ?? change['new'] ?? change['value'];
    if (to != null && from != null) {
      return '• $label: $from → $to';
    }
    if (to != null) {
      return '• $label: $to';
    }
    return '• ${change.values.map((value) => value.toString()).join(' · ')}';
  }

  static String _dateText(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed == null ? value.toString() : dateLabel(parsed);
  }

  static Map<String, dynamic> _map(Object? value) => value is Map ? Map<String, dynamic>.from(value) : const {};

  static List<Map<String, dynamic>> _maps(Object? value) => [for (final item in (value as List? ?? const [])) if (item is Map) Map<String, dynamic>.from(item)];
}
