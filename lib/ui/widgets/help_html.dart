import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../core/store_policy.dart';
import '../../domain/help_models.dart';
import '../theme.dart';

/// Tautan yang diketuk di artikel: [helpSlug] diisi server
/// (`data-help-article`) untuk tautan ke artikel bantuan lain.
typedef HelpLinkHandler = void Function(String href, String? helpSlug);

/// Isi artikel Pusat Bantuan (HTML yang sudah disanitasi server, API.md ›
/// Pusat Bantuan) sebagai widget Flutter: judul (dengan anchor daftar isi),
/// paragraf, daftar, kutipan, kode, tabel, gambar (lewat [imageBuilder],
/// diunduh dengan token), kartu video, dan kotak tips. Unsur lain dibaca
/// sebagai teks biasa; iframe/video/skrip tidak pernah ditampilkan.
///
/// Kebijakan Google Play: paragraf/butir yang mengajak membeli paket/koin
/// ([purchasePattern]) tidak ditampilkan.
class HelpHtml extends StatefulWidget {
  const HelpHtml({super.key, required this.html, required this.anchors, required this.onLink, required this.onVideo, required this.imageBuilder});

  final String html;

  /// Anchor judul (`id`) → key, untuk lompat dari daftar isi.
  final Map<String, GlobalKey> anchors;
  final HelpLinkHandler onLink;
  final void Function(HelpVideo video) onVideo;
  final Widget Function(String src, String? alt) imageBuilder;

  @override
  State<HelpHtml> createState() => _HelpHtmlState();
}

class _HelpHtmlState extends State<HelpHtml> {
  final List<TapGestureRecognizer> _recognizers = [];
  dom.DocumentFragment? _fragment;
  String? _parsed;

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

  @override
  Widget build(BuildContext context) {
    if (_parsed != widget.html) {
      _fragment = html_parser.parseFragment(widget.html);
      _parsed = widget.html;
    }
    _disposeRecognizers();
    final theme = Theme.of(context);
    final base = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(fontSize: 15.5, height: 1.6);
    final builder = _HelpHtmlBuilder(context: context, widget: widget, recognizers: _recognizers, base: base);
    return Column(
      key: const Key('help-html'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: builder.blocks(_fragment!.nodes),
    );
  }
}

/// Potongan teks sebaris dengan gaya dan tautannya.
class _Piece {
  _Piece(this.text, this.style, {this.href, this.helpSlug});

  String text;
  final TextStyle style;
  final String? href;
  final String? helpSlug;
}

const _blockTags = {
  'p', 'div', 'section', 'article', 'header', 'footer', 'main', 'nav', 'details', 'summary', //
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'blockquote', 'pre', 'hr', 'figure', 'figcaption', 'aside', 'table',
  'iframe', 'video', 'audio', 'script', 'style', 'object', 'embed', 'form', 'input', 'button',
};

const _ignoredTags = {'iframe', 'video', 'audio', 'script', 'style', 'object', 'embed', 'form', 'input', 'button', 'template', 'noscript'};

class _HelpHtmlBuilder {
  _HelpHtmlBuilder({required this.context, required this.widget, required this.recognizers, required this.base});

  final BuildContext context;
  final HelpHtml widget;
  final List<TapGestureRecognizer> recognizers;
  final TextStyle base;
  int _videos = 0;
  int _images = 0;

  ColorScheme get scheme => Theme.of(context).colorScheme;

  static String _classes(dom.Element element) => element.attributes['class'] ?? '';

  static bool _hasClass(dom.Element element, String name) => _classes(element).split(RegExp(r'\s+')).contains(name);

  /// Teks yang mengajak membeli paket/koin (kebijakan Google Play).
  static bool _purchaseText(dom.Element element) => purchasePattern.hasMatch(element.text);

  List<Widget> blocks(List<dom.Node> nodes, {TextStyle? style}) {
    final out = <Widget>[];
    final pieces = <_Piece>[];
    final textStyle = style ?? base;

    void flush() {
      final paragraph = _paragraph(pieces);
      pieces.clear();
      if (paragraph != null) {
        out.add(Padding(padding: const EdgeInsets.only(bottom: 12), child: paragraph));
      }
    }

    for (final node in nodes) {
      if (node is dom.Text) {
        pieces.add(_Piece(node.text, textStyle));
      } else if (node is dom.Element) {
        final tag = node.localName ?? '';
        if (tag == 'img') {
          flush();
          out.add(_image(node));
        } else if (tag == 'a' && _hasClass(node, 'help-video')) {
          flush();
          out.add(_video(node));
        } else if (tag == 'br') {
          pieces.add(_Piece('\n', textStyle));
        } else if (_blockTags.contains(tag) || _containsBlock(node)) {
          flush();
          out.addAll(_block(node, textStyle));
        } else {
          _inline(node, textStyle, pieces);
        }
      }
    }
    flush();
    return out;
  }

  /// Unsur sebaris yang membungkus gambar/kartu video (mis. `<a><img></a>`).
  static bool _containsBlock(dom.Element element) => element.querySelector('img, a.help-video, p, div, ul, ol, table, figure') != null;

  List<Widget> _block(dom.Element element, TextStyle style) {
    final tag = element.localName ?? '';
    if (_ignoredTags.contains(tag)) {
      return const [];
    }
    switch (tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        if (_purchaseText(element)) {
          return const [];
        }
        final level = int.parse(tag.substring(1));
        final size = switch (level) {
          1 => 22.0,
          2 => 19.0,
          3 => 17.0,
          _ => 15.5,
        };
        final pieces = <_Piece>[];
        for (final child in element.nodes) {
          _inlineNode(child, base.copyWith(fontSize: size, fontWeight: FontWeight.w700, height: 1.35), pieces);
        }
        final text = _paragraph(pieces);
        if (text == null) {
          return const [];
        }
        final id = element.id;
        final key = id.isEmpty ? null : widget.anchors.putIfAbsent(id, GlobalKey.new);
        return [
          Padding(
            key: key,
            padding: EdgeInsets.only(top: level <= 2 ? 14 : 8, bottom: 8),
            child: Semantics(header: true, child: text),
          ),
        ];
      case 'p':
        if (_purchaseText(element)) {
          return const [];
        }
        if (_hasClass(element, 'help-callout-title')) {
          return blocks(element.nodes, style: style.copyWith(fontWeight: FontWeight.w700));
        }
        return blocks(element.nodes, style: style);
      case 'ul' || 'ol':
        return [_list(element, ordered: tag == 'ol', style: style)];
      case 'li':
        return blocks(element.nodes, style: style);
      case 'blockquote':
        return [
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.only(left: 12, top: 2),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.primary.withValues(alpha: 0.5), width: 3))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: blocks(element.nodes, style: style.copyWith(color: mutedText(context)))),
          ),
        ];
      case 'pre':
        return [
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: AiColors.codeFill(context), borderRadius: BorderRadius.circular(10)),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: Text(element.text.replaceAll(RegExp(r'\n$'), ''), style: base.copyWith(fontFamily: 'monospace', fontSize: 13.5, height: 1.45)),
            ),
          ),
        ];
      case 'hr':
        return [Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Divider(height: 1, color: AiColors.border(context)))];
      case 'figure':
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: blocks(element.nodes, style: style)),
          ),
        ];
      case 'figcaption':
        final caption = element.text.trim();
        if (caption.isEmpty) {
          return const [];
        }
        return [
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 12),
            child: Text(caption, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: mutedText(context), fontStyle: FontStyle.italic)),
          ),
        ];
      case 'aside':
        if (_hasClass(element, 'help-callout')) {
          return _callout(element, style);
        }
        return blocks(element.nodes, style: style);
      case 'table':
        return [_table(element)];
      default:
        return blocks(element.nodes, style: style);
    }
  }

  Widget _list(dom.Element element, {required bool ordered, required TextStyle style}) {
    final start = int.tryParse(element.attributes['start'] ?? '') ?? 1;
    final items = element.children.where((child) => child.localName == 'li' && !_purchaseText(child)).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, item) in items.indexed)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: ordered ? 28 : 20,
                  child: Text(ordered ? '${start + i}.' : '•', style: style.copyWith(fontWeight: FontWeight.w700, color: ordered ? null : scheme.primary)),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    // Jarak antar butir lebih rapat dari antar paragraf.
                    children: [for (final child in blocks(item.nodes, style: style)) child is Padding && child.padding == const EdgeInsets.only(bottom: 12) ? Padding(padding: const EdgeInsets.only(bottom: 6), child: child.child) : child],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  List<Widget> _callout(dom.Element element, TextStyle style) {
    if (_purchaseText(element)) {
      return const [];
    }
    final variant = _hasClass(element, 'help-callout-warning') ? 'warning' : (_hasClass(element, 'help-callout-info') ? 'info' : 'tip');
    final (color, icon) = switch (variant) {
      'warning' => (warningText(context), Icons.warning_amber_rounded),
      'info' => (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF7DD3FC) : const Color(0xFF0369A1), Icons.info_outline),
      _ => (scheme.primary, Icons.lightbulb_outline),
    };
    final children = blocks(element.nodes, style: style);
    return [
      Container(
        key: Key('help-callout-$variant'),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.35))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 3), child: Icon(icon, size: 20, color: color)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
          ],
        ),
      ),
    ];
  }

  Widget _table(dom.Element element) {
    final rows = element.querySelectorAll('tr');
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    final columns = rows.map((row) => row.children.where((cell) => cell.localName == 'td' || cell.localName == 'th').length).fold<int>(0, (a, b) => a > b ? a : b);
    if (columns == 0) {
      return const SizedBox.shrink();
    }
    final border = BorderSide(color: AiColors.border(context));
    Widget cell(dom.Element? cell) {
      final head = cell?.localName == 'th';
      final pieces = <_Piece>[];
      for (final child in cell?.nodes ?? const <dom.Node>[]) {
        _inlineNode(child, base.copyWith(fontSize: 14, height: 1.4, fontWeight: head ? FontWeight.w600 : null), pieces);
      }
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: _paragraph(pieces) ?? const SizedBox.shrink()),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: SingleChildScrollView(
        key: const Key('help-table'),
        scrollDirection: Axis.horizontal,
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border.fromBorderSide(border), borderRadius: BorderRadius.circular(10)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder(horizontalInside: border, verticalInside: border),
              children: [
                for (final row in rows)
                  TableRow(
                    decoration: row.children.any((cell) => cell.localName == 'th') ? BoxDecoration(color: AiColors.codeFill(context)) : null,
                    children: [
                      for (var c = 0; c < columns; c++) cell(c < row.children.where((cell) => cell.localName == 'td' || cell.localName == 'th').length ? row.children.where((cell) => cell.localName == 'td' || cell.localName == 'th').elementAt(c) : null),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _image(dom.Element element) {
    final src = element.attributes['src'] ?? '';
    if (src.isEmpty) {
      return const SizedBox.shrink();
    }
    final alt = element.attributes['alt'];
    return Padding(
      key: Key('help-image-${_images++}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: widget.imageBuilder(src, alt == null || alt.trim().isEmpty ? null : alt.trim()),
    );
  }

  Widget _video(dom.Element element) {
    final video = HelpVideo(kind: element.attributes['data-video'] ?? 'upload', url: element.attributes['href'] ?? '');
    final index = _videos++;
    final (icon, subtitle) = switch (video.kind) {
      'youtube' => (Icons.smart_display_outlined, 'Dibuka di YouTube'),
      'vimeo' => (Icons.ondemand_video_outlined, 'Dibuka di Vimeo'),
      _ => (Icons.play_circle_outline, 'Diputar dengan pemutar video di HP'),
    };
    final label = element.text.trim().isEmpty ? 'Putar video' : element.text.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: Key('help-video-$index'),
          borderRadius: BorderRadius.circular(14),
          onTap: video.url.isEmpty ? null : () => widget.onVideo(video),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(icon, size: 36, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
                      Text(subtitle, style: TextStyle(fontSize: 12.5, color: mutedText(context))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _inline(dom.Element element, TextStyle style, List<_Piece> out, {String? href, String? helpSlug}) {
    final tag = element.localName ?? '';
    if (_ignoredTags.contains(tag)) {
      return;
    }
    var next = style;
    var link = href;
    var slug = helpSlug;
    switch (tag) {
      case 'strong' || 'b':
        next = style.copyWith(fontWeight: FontWeight.w700);
      case 'em' || 'i' || 'cite':
        next = style.copyWith(fontStyle: FontStyle.italic);
      case 'u':
        next = style.copyWith(decoration: TextDecoration.underline);
      case 's' || 'del' || 'strike':
        next = style.copyWith(decoration: TextDecoration.lineThrough);
      case 'code' || 'kbd':
        next = style.copyWith(fontFamily: 'monospace', fontSize: (style.fontSize ?? 15) * 0.9, backgroundColor: AiColors.codeFill(context));
      case 'mark':
        next = style.copyWith(backgroundColor: Brand.amber.withValues(alpha: 0.3));
      case 'small' || 'sub' || 'sup':
        next = style.copyWith(fontSize: (style.fontSize ?? 15) * 0.85);
      case 'a':
        link = element.attributes['href'];
        slug = element.attributes['data-help-article'];
        if (link != null && link.trim().isNotEmpty) {
          next = style.copyWith(color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary.withValues(alpha: 0.5));
        }
      case 'br':
        out.add(_Piece('\n', style, href: href, helpSlug: helpSlug));
        return;
      case 'img':
        final alt = element.attributes['alt'];
        if (alt != null && alt.trim().isNotEmpty) {
          out.add(_Piece(alt.trim(), style, href: href, helpSlug: helpSlug));
        }
        return;
    }
    for (final child in element.nodes) {
      _inlineNode(child, next, out, href: link, helpSlug: slug);
    }
  }

  void _inlineNode(dom.Node node, TextStyle style, List<_Piece> out, {String? href, String? helpSlug}) {
    if (node is dom.Text) {
      out.add(_Piece(node.text, style, href: href, helpSlug: helpSlug));
    } else if (node is dom.Element) {
      _inline(node, style, out, href: href, helpSlug: helpSlug);
    }
  }

  /// Satu paragraf dari potongan sebaris: spasi dirapatkan seperti browser,
  /// baris baru dari `<br>` dipertahankan. Null bila kosong.
  Widget? _paragraph(List<_Piece> pieces) {
    final merged = <_Piece>[];
    var lastSpace = true;
    for (final piece in pieces) {
      var text = piece.text == '\n' ? '\n' : piece.text.replaceAll(RegExp(r'\s+'), ' ');
      if (text == '\n') {
        if (merged.isNotEmpty) {
          merged.last.text = merged.last.text.trimRight();
        }
        merged.add(_Piece('\n', piece.style));
        lastSpace = true;
        continue;
      }
      if (lastSpace) {
        text = text.trimLeft();
      }
      if (text.isEmpty) {
        continue;
      }
      merged.add(_Piece(text, piece.style, href: piece.href, helpSlug: piece.helpSlug));
      lastSpace = text.endsWith(' ');
    }
    while (merged.isNotEmpty && merged.last.text.trim().isEmpty) {
      merged.removeLast();
    }
    if (merged.isEmpty) {
      return null;
    }
    merged.last.text = merged.last.text.trimRight();
    final spans = <InlineSpan>[];
    for (final piece in merged) {
      TapGestureRecognizer? recognizer;
      final href = piece.href?.trim();
      if (href != null && href.isNotEmpty) {
        final slug = piece.helpSlug;
        recognizer = TapGestureRecognizer()..onTap = () => widget.onLink(href, slug);
        recognizers.add(recognizer);
      }
      spans.add(TextSpan(text: piece.text, style: piece.style, recognizer: recognizer));
    }
    return Text.rich(TextSpan(children: spans));
  }
}
