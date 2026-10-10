import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/file_downloads.dart';
import '../theme.dart';

/// Satu blok Markdown jawaban Tim AI.
sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);

  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);

  final String text;
}

class MdListItem {
  const MdListItem({required this.marker, required this.text, this.indent = 0});

  /// `•` untuk butir biasa, atau nomor asli (`1.`, `2)`).
  final String marker;
  final String text;
  final int indent;

  bool get ordered => marker != '•';
}

class MdList extends MdBlock {
  const MdList(this.items);

  final List<MdListItem> items;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);

  final String text;
}

class MdCode extends MdBlock {
  const MdCode(this.text);

  final String text;
}

class MdRule extends MdBlock {
  const MdRule();
}

class MdTable extends MdBlock {
  const MdTable({required this.header, required this.rows, required this.alignRight});

  final List<String> header;
  final List<List<String>> rows;

  /// Kolom rata kanan (`--:` di baris pemisah, atau isinya angka/rupiah).
  final List<bool> alignRight;
}

final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*$');
final _rule = RegExp(r'^(?:-\s*){3,}$|^(?:\*\s*){3,}$|^(?:_\s*){3,}$');
final _listItem = RegExp(r'^(\s*)([-*+•]|\d{1,3}[.)])\s+(.*)$');
final _tableSeparator = RegExp(r'^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$');
final _numeric = RegExp(r'^[-+]?\s*(Rp\.?\s?)?[\d.,]+\s*%?$', caseSensitive: false);

List<String> _cells(String line) {
  var row = line.trim();
  if (row.startsWith('|')) {
    row = row.substring(1);
  }
  if (row.endsWith('|') && !row.endsWith(r'\|')) {
    row = row.substring(0, row.length - 1);
  }
  return [for (final cell in row.split(RegExp(r'(?<!\\)\|'))) cell.trim().replaceAll(r'\|', '|')];
}

/// Pecah teks Markdown sederhana menjadi blok: judul, paragraf, daftar,
/// kutipan, kode, garis, dan tabel.
List<MdBlock> parseMarkdown(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <MdBlock>[];
  final paragraph = <String>[];

  void flush() {
    if (paragraph.isNotEmpty) {
      blocks.add(MdParagraph(paragraph.join('\n')));
      paragraph.clear();
    }
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i].trimRight();
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      flush();
      i++;
      continue;
    }
    if (trimmed.startsWith('```')) {
      flush();
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        code.add(lines[i].trimRight());
        i++;
      }
      i++; // pagar penutup
      blocks.add(MdCode(code.join('\n')));
      continue;
    }
    final heading = _heading.firstMatch(trimmed);
    if (heading != null) {
      flush();
      blocks.add(MdHeading(heading.group(1)!.length, heading.group(2)!));
      i++;
      continue;
    }
    if (_rule.hasMatch(trimmed)) {
      flush();
      blocks.add(const MdRule());
      i++;
      continue;
    }
    if (trimmed.contains('|') && i + 1 < lines.length && _tableSeparator.hasMatch(lines[i + 1].trim())) {
      flush();
      final header = _cells(trimmed);
      final separator = _cells(lines[i + 1]);
      final rows = <List<String>>[];
      i += 2;
      while (i < lines.length && lines[i].trim().isNotEmpty && lines[i].contains('|')) {
        final cells = _cells(lines[i]);
        rows.add([for (var c = 0; c < header.length; c++) c < cells.length ? cells[c] : '']);
        i++;
      }
      final alignRight = [
        for (var c = 0; c < header.length; c++)
          (c < separator.length && separator[c].endsWith(':') && !separator[c].startsWith(':')) ||
              (rows.isNotEmpty && rows.every((row) => row[c].isEmpty || _numeric.hasMatch(row[c].replaceAll('*', '')))),
      ];
      blocks.add(MdTable(header: header, rows: rows, alignRight: alignRight));
      continue;
    }
    if (trimmed.startsWith('>')) {
      flush();
      final quote = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        quote.add(lines[i].trim().substring(1).trimLeft());
        i++;
      }
      blocks.add(MdQuote(quote.join('\n')));
      continue;
    }
    if (_listItem.hasMatch(line)) {
      flush();
      final items = <MdListItem>[];
      while (i < lines.length) {
        final current = lines[i].trimRight();
        final match = _listItem.firstMatch(current);
        if (match != null) {
          final marker = match.group(2)!;
          items.add(MdListItem(marker: RegExp(r'^\d').hasMatch(marker) ? marker : '•', text: match.group(3)!, indent: (match.group(1)!.replaceAll('\t', '    ').length ~/ 2).clamp(0, 3)));
          i++;
          continue;
        }
        // Baris lanjutan yang menjorok ikut butir sebelumnya.
        if (current.trim().isNotEmpty && current.startsWith('  ') && items.isNotEmpty) {
          final last = items.removeLast();
          items.add(MdListItem(marker: last.marker, text: '${last.text}\n${current.trim()}', indent: last.indent));
          i++;
          continue;
        }
        break;
      }
      blocks.add(MdList(items));
      continue;
    }
    paragraph.add(trimmed);
    i++;
  }
  flush();
  return blocks;
}

final _inline = RegExp(
  r'(`+)(.+?)\1' // 1-2 kode
  r'|\*\*(.+?)\*\*' // 3 tebal
  r'|__(.+?)__' // 4 tebal
  r'|~~(.+?)~~' // 5 coret
  r'|\[([^\]]+)\]\(([^)\s]+)\)' // 6-7 tautan
  r'|(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])' // 8 miring
  r'|(?<![\w])_(?![\s_])(.+?)(?<![\s_])_(?![\w])' // 9 miring
  r'''|(https?://[^\s<>()]*[^\s<>().,;:!?'"])''', // 10 alamat web
);

/// Teks polos dari Markdown (untuk Salin dan cuplikan riwayat): tanda
/// tebal/miring/kode dibuang, tautan menjadi "teks (alamat)".
String markdownToPlainText(String source) {
  final out = <String>[];
  for (final block in parseMarkdown(source)) {
    switch (block) {
      case MdHeading(:final text):
      case MdParagraph(:final text):
        out.add(_plainInline(text));
      case MdList(:final items):
        out.add([for (final item in items) '${'  ' * item.indent}${item.marker} ${_plainInline(item.text)}'].join('\n'));
      case MdQuote(:final text):
        out.add(_plainInline(text));
      case MdCode(:final text):
        out.add(text);
      case MdRule():
        out.add('—');
      case MdTable(:final header, :final rows):
        out.add([header.map(_plainInline).join(' | '), for (final row in rows) row.map(_plainInline).join(' | ')].join('\n'));
    }
  }
  return out.join('\n\n');
}

/// Teks lebih panjang dari ini ditampilkan polos tanpa tanda tebal/miring/
/// tautan: pencocokan pola pada teks sangat panjang terlalu lambat di HP.
const int mdInlineLimit = 2000;

/// Batas tabel yang digambar (sisanya diringkas "… N baris lagi"); Salin
/// tetap menyalin seluruh tabel.
const int mdMaxTableRows = 60;
const int mdMaxTableColumns = 12;

String _plainInline(String text) => text.length > mdInlineLimit ? text : text.replaceAllMapped(_inline, (m) {
  if (m.group(2) != null) {
    return m.group(2)!;
  }
  if (m.group(6) != null) {
    return m.group(6) == m.group(7) ? m.group(7)! : '${_plainInline(m.group(6)!)} (${m.group(7)})';
  }
  if (m.group(10) != null) {
    return m.group(10)!;
  }
  return _plainInline(m.group(3) ?? m.group(4) ?? m.group(5) ?? m.group(8) ?? m.group(9) ?? '');
});

/// Apa yang terjadi saat tautan di jawaban Tim AI diketuk.
enum AiLinkAction {
  /// Bukan http/https (mis. tel:, mailto:, intent:, javascript:): diabaikan.
  block,

  /// Situs Infois atau WhatsApp (wa.me) dengan teks yang tidak menyesatkan.
  open,

  /// Situs lain, atau teks tautan menyebut alamat yang berbeda: tanya dulu.
  confirm,
}

final _hostLike = RegExp(r'^(?:https?://)?(?:www\.)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?:[/:?#]\S*)?$', caseSensitive: false);

/// Tautan di jawaban Tim AI bisa dipengaruhi isi yang dibaca Tim AI (foto
/// nota, nama pelanggan/barang), jadi hanya http/https yang dibuka; situs di
/// luar Infois/WhatsApp, atau teks yang menyamar sebagai alamat lain,
/// dikonfirmasi dulu dengan menampilkan alamat aslinya.
AiLinkAction aiLinkAction(String url, {String? label}) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) || uri.host.isEmpty) {
    return AiLinkAction.block;
  }
  final host = uri.host.toLowerCase();
  final trusted = host == 'infois.ai' || host.endsWith('.infois.ai') || host == 'wa.me';
  final shown = label == null ? null : _hostLike.firstMatch(label.trim())?.group(1)?.toLowerCase();
  final misleading = shown != null && shown != host && shown != host.replaceFirst(RegExp(r'^www\.'), '');
  return trusted && !misleading ? AiLinkAction.open : AiLinkAction.confirm;
}

/// Jawaban Tim AI dalam Markdown ringan: **tebal**, _miring_, `kode`,
/// daftar butir/nomor, judul, kutipan, tabel (geser ke samping), dan tautan
/// yang bisa diketuk (dibuka di browser).
class AiMarkdown extends ConsumerStatefulWidget {
  const AiMarkdown(this.text, {super.key, this.style, this.onTapLink});

  final String text;
  final TextStyle? style;

  /// Default: lihat [aiLinkAction] (hanya http/https; situs di luar Infois
  /// dikonfirmasi dulu).
  final void Function(String url)? onTapLink;

  @override
  ConsumerState<AiMarkdown> createState() => _AiMarkdownState();
}

class _AiMarkdownState extends ConsumerState<AiMarkdown> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _openLink(String url, String label) async {
    if (widget.onTapLink != null) {
      widget.onTapLink!(url);
      return;
    }
    switch (aiLinkAction(url, label: label)) {
      case AiLinkAction.block:
        return;
      case AiLinkAction.open:
        break;
      case AiLinkAction.confirm:
        final host = Uri.parse(url.trim()).host;
        final ok = await showDialog<bool>(
          context: context,
          builder:
              (dialog) => AlertDialog(
                key: const Key('link-confirm'),
                title: const Text('Buka tautan?'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Tautan ini menuju situs di luar Infois:'),
                    const SizedBox(height: 8),
                    Text(host, style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(url, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: mutedText(dialog))),
                    const SizedBox(height: 8),
                    Text('Jangan masukkan kata sandi atau data pembayaran bila Anda ragu.', style: TextStyle(fontSize: 12.5, color: mutedText(dialog))),
                  ],
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Batal')),
                  FilledButton(key: const Key('link-confirm-open'), onPressed: () => Navigator.pop(dialog, true), child: const Text('Buka')),
                ],
              ),
        );
        if (ok != true || !mounted) {
          return;
        }
    }
    if (mounted) {
      await openExternalLink(context, ref, url.trim());
    }
  }

  List<InlineSpan> _spans(String text, TextStyle base) {
    if (text.length > mdInlineLimit) {
      return [TextSpan(text: text, style: base)];
    }
    final scheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    var index = 0;
    for (final m in _inline.allMatches(text)) {
      if (m.start > index) {
        spans.add(TextSpan(text: text.substring(index, m.start), style: base));
      }
      if (m.group(2) != null) {
        spans.add(TextSpan(text: m.group(2), style: base.copyWith(fontFamily: 'monospace', fontSize: (base.fontSize ?? 15) * 0.9, backgroundColor: AiColors.codeFill(context))));
      } else if (m.group(3) != null || m.group(4) != null) {
        spans.addAll(_spans(m.group(3) ?? m.group(4)!, base.copyWith(fontWeight: FontWeight.w700)));
      } else if (m.group(5) != null) {
        spans.addAll(_spans(m.group(5)!, base.copyWith(decoration: TextDecoration.lineThrough)));
      } else if (m.group(6) != null || m.group(10) != null) {
        final url = m.group(7) ?? m.group(10)!;
        final label = m.group(6) ?? url;
        final recognizer = TapGestureRecognizer()..onTap = () => _openLink(url, label);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: m.group(6) ?? url,
            style: base.copyWith(color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary.withValues(alpha: 0.5)),
            recognizer: recognizer,
          ),
        );
      } else {
        spans.addAll(_spans(m.group(8) ?? m.group(9)!, base.copyWith(fontStyle: FontStyle.italic)));
      }
      index = m.end;
    }
    if (index < text.length) {
      spans.add(TextSpan(text: text.substring(index), style: base));
    }
    return spans;
  }

  Widget _rich(String text, TextStyle base, {TextAlign align = TextAlign.start}) => Text.rich(TextSpan(children: _spans(text, base)), textAlign: align);

  /// Hasil terakhir: jawaban yang sama tidak diurai & disusun ulang setiap
  /// kali daftar pesan dibangun ulang (mis. pemantauan tiap 2 detik).
  Widget? _built;
  String? _builtText;
  TextStyle? _builtStyle;
  ThemeData? _builtTheme;
  void Function(String url)? _builtOnTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cached = _built;
    if (cached != null && _builtText == widget.text && _builtStyle == widget.style && identical(_builtTheme, theme) && _builtOnTap == widget.onTapLink) {
      return cached;
    }
    _disposeRecognizers();
    _builtText = widget.text;
    _builtStyle = widget.style;
    _builtTheme = theme;
    _builtOnTap = widget.onTapLink;
    return _built = _compose(context, theme);
  }

  Widget _compose(BuildContext context, ThemeData theme) {
    final base = (theme.textTheme.bodyMedium ?? const TextStyle()).merge(widget.style ?? const TextStyle(fontSize: 15, height: 1.5));
    final size = base.fontSize ?? 15;
    final muted = mutedText(context);
    final blocks = parseMarkdown(widget.text);
    final children = <Widget>[];
    for (var b = 0; b < blocks.length; b++) {
      final block = blocks[b];
      final last = b == blocks.length - 1;
      final gap = last ? 0.0 : 10.0;
      switch (block) {
        case MdHeading(:final level, :final text):
          final extra = switch (level) {
            1 => 5.0,
            2 => 3.0,
            3 => 1.5,
            _ => 0.0,
          };
          children.add(
            Padding(
              padding: EdgeInsets.only(top: b == 0 ? 0 : 6, bottom: last ? 0 : 6),
              child: Semantics(header: true, child: _rich(text, base.copyWith(fontSize: size + extra, fontWeight: FontWeight.w700, height: 1.35))),
            ),
          );
        case MdParagraph(:final text):
          children.add(Padding(padding: EdgeInsets.only(bottom: gap), child: _rich(text, base)));
        case MdList(:final items):
          children.add(
            Padding(
              padding: EdgeInsets.only(bottom: gap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in items)
                    Padding(
                      padding: EdgeInsets.only(left: 4 + item.indent * 18.0, top: 2, bottom: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: item.ordered ? 26 : 18,
                            child: Text(item.marker, style: base.copyWith(fontWeight: item.ordered ? FontWeight.w600 : FontWeight.w700, color: item.ordered ? null : theme.colorScheme.primary)),
                          ),
                          Expanded(child: _rich(item.text, base)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        case MdQuote(:final text):
          children.add(
            Container(
              margin: EdgeInsets.only(bottom: gap),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.5), width: 3))),
              child: _rich(text, base.copyWith(color: muted)),
            ),
          );
        case MdCode(:final text):
          children.add(
            Container(
              width: double.infinity,
              margin: EdgeInsets.only(bottom: gap),
              decoration: BoxDecoration(color: AiColors.codeFill(context), borderRadius: BorderRadius.circular(10)),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(12),
                child: Text(text, style: base.copyWith(fontFamily: 'monospace', fontSize: size * 0.88, height: 1.4)),
              ),
            ),
          );
        case MdRule():
          children.add(Padding(padding: EdgeInsets.only(bottom: gap), child: Divider(height: 12, color: AiColors.border(context))));
        case MdTable(header: final fullHeader, rows: final fullRows, :final alignRight):
          final border = BorderSide(color: AiColors.border(context));
          final header = fullHeader.length > mdMaxTableColumns ? fullHeader.sublist(0, mdMaxTableColumns) : fullHeader;
          final rows = fullRows.length > mdMaxTableRows ? fullRows.sublist(0, mdMaxTableRows) : fullRows;
          final hiddenRows = fullRows.length - rows.length;
          final hiddenColumns = fullHeader.length - header.length;
          Widget cell(String text, int column, {bool head = false}) => ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: _rich(text, base.copyWith(fontSize: size * 0.93, height: 1.35, fontWeight: head ? FontWeight.w600 : null), align: alignRight[column] ? TextAlign.end : TextAlign.start),
            ),
          );
          final more = [if (hiddenRows > 0) '… $hiddenRows baris lagi', if (hiddenColumns > 0) '$hiddenColumns kolom lagi'];
          final table = SingleChildScrollView(
                key: const Key('md-table'),
                scrollDirection: Axis.horizontal,
                child: DecoratedBox(
                  decoration: BoxDecoration(border: Border.fromBorderSide(border), borderRadius: BorderRadius.circular(10)),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Table(
                      defaultColumnWidth: const IntrinsicColumnWidth(),
                      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                      border: TableBorder(horizontalInside: border, verticalInside: border),
                      children: [
                        TableRow(decoration: BoxDecoration(color: AiColors.codeFill(context)), children: [for (var c = 0; c < header.length; c++) cell(header[c], c, head: true)]),
                        for (final row in rows) TableRow(children: [for (var c = 0; c < header.length; c++) cell(row[c], c)]),
                      ],
                    ),
                  ),
                ),
              );
          children.add(
            Padding(
              padding: EdgeInsets.only(bottom: gap),
              child:
                  more.isEmpty
                      ? table
                      : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          table,
                          Padding(
                            key: const Key('md-table-more'),
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('${more.join(' · ')} (salin jawaban untuk data lengkap)', style: TextStyle(fontSize: size * 0.85, color: muted)),
                          ),
                        ],
                      ),
            ),
          );
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }
}
