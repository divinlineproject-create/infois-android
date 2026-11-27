import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Tanda Infois POS (folder BRAND POS): kotak mirip printer struk bertulisan
/// POS. Di latar hijau selalu di atas kotak putih ([PosBrandTile]).
const posBrandMark = 'assets/images/infois-pos-mark.png';

/// Tagline aplikasi Infois POS; kata [posTaglineHighlights] berwarna kuning
/// nota (sama dengan feature graphic Play Store).
const posTagline = 'Transaksi simpel kalau punya asisten keuangan.';
const posTaglineHighlights = {'simpel', 'keuangan'};

/// Tanda Infois POS di kotak putih berbayang hijau tua, untuk latar hijau.
class PosBrandTile extends StatelessWidget {
  const PosBrandTile({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(size * 0.24),
          boxShadow: [BoxShadow(color: Brand.greenDark, offset: Offset(0, size * 0.05))],
        ),
        padding: EdgeInsets.all(size * 0.08),
        child: Image.asset(posBrandMark, key: const Key('pos-brand-mark'), fit: BoxFit.contain, semanticLabel: 'Infois POS'),
      );
}

/// Logo Infois POS untuk latar hijau: kotak tanda + tulisan "Infois POS".
class PosBrandLockup extends StatelessWidget {
  const PosBrandLockup({super.key, required this.height});

  /// Tinggi kotak tanda; tulisan mengikuti.
  final double height;

  /// Panel sempit (mis. tablet kecil mendatar): logo diperkecil, tidak terpotong.
  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          PosBrandTile(size: height),
          SizedBox(width: height * 0.32),
          Text(
            'Infois POS',
            style: TextStyle(color: Colors.white, fontSize: height * 0.6, height: 1.1, fontWeight: FontWeight.w700, letterSpacing: -0.3),
          ),
        ]),
      );
}

/// Kalimat dengan kata tagline yang disorot kuning nota; kalimat lain
/// (mis. nama perusahaan di layar kunci) tampil polos.
class PosTaglineText extends StatelessWidget {
  const PosTaglineText(this.text, {super.key, required this.style, this.textAlign = TextAlign.start, this.maxLines});

  final String text;
  final TextStyle style;
  final TextAlign textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    if (text != posTagline) {
      return Text(text, style: style, textAlign: textAlign, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
    }
    final words = text.split(' ');
    return Text.rich(
      TextSpan(children: [
        for (final (i, word) in words.indexed)
          TextSpan(
            text: i == words.length - 1 ? word : '$word ',
            style: posTaglineHighlights.contains(word.replaceAll(RegExp(r'[^A-Za-z]'), '')) ? const TextStyle(color: Brand.nota) : null,
          ),
      ]),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

/// Layar masuk / kunci tablet: separuh layar panel brand (latar hijau
/// Infois, logo Infois POS, tagline, motif tangga), separuh lagi formulir.
/// Layar sempit (HP tegak): panel brand menjadi spanduk di atas, formulir di
/// bawahnya.
class AuthSplitLayout extends StatelessWidget {
  const AuthSplitLayout({super.key, required this.child, this.headline = defaultHeadline, this.lead = defaultLead, this.maxFormWidth = 420});

  final Widget child;
  final String headline;
  final String lead;
  final double maxFormWidth;

  static const defaultHeadline = posTagline;
  static const defaultLead = 'Infois mencatat penjualan, membaca nota, menyiapkan jurnal, dan menagih pelanggan. Anda tinggal memeriksa dan menyetujui.';

  /// Lebar minimum untuk tata letak kiri-kanan.
  static const splitBreakpoint = 720.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(builder: (context, constraints) {
        final split = constraints.maxWidth >= splitBreakpoint;
        final form = Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, split ? 32 : 24, 24, 32),
            child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxFormWidth), child: child),
          ),
        );
        if (split) {
          return Row(children: [
            Expanded(child: _BrandPanel(headline: headline, lead: lead, roomy: true)),
            Expanded(child: SafeArea(left: false, child: form)),
          ]);
        }
        // HP tegak: spanduk ± sepertiga layar, ikut tergulung bersama
        // formulir. Ikon status bar di atas spanduk hijau: putih.
        final bannerHeight = (constraints.maxHeight * 0.34).clamp(200.0, 300.0);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(height: bannerHeight + MediaQuery.paddingOf(context).top, child: _BrandPanel(headline: headline, lead: lead, roomy: false)),
                Center(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 32 + MediaQuery.paddingOf(context).bottom),
                    child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxFormWidth), child: child),
                  ),
                ),
              ]),
            ),
          ),
        );
      }),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel({required this.headline, required this.lead, required this.roomy});

  final String headline;
  final String lead;

  /// Panel kiri penuh (tablet / HP mendatar) vs spanduk atas (HP tegak).
  final bool roomy;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      key: const Key('auth-brand-panel'),
      color: Brand.green,
      child: Stack(children: [
        // Panel penuh: motif di sudut bawah; spanduk HP: sejajar logo di kanan atas (tidak menutupi teks).
        if (roomy) const Positioned(right: 40, bottom: 40, child: _Stairs(size: 34)) else Positioned(right: 24, top: 20 + top, child: const _Stairs(size: 12)),
        Padding(
          padding: EdgeInsets.fromLTRB(roomy ? 48 : 24, (roomy ? 48 : 20) + top, roomy ? 48 : 24, roomy ? 48 : 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PosBrandLockup(key: const Key('auth-brand-logo'), height: roomy ? 52 : 34),
            const Spacer(),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                PosTaglineText(
                  headline,
                  style: TextStyle(color: Colors.white, fontSize: roomy ? 34 : 22, height: 1.15, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                ),
                SizedBox(height: roomy ? 16 : 8),
                Text(
                  lead,
                  maxLines: roomy ? 6 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: roomy ? 16 : 13, height: 1.55),
                ),
              ]),
            ),
            if (roomy) const Spacer(),
          ]),
        ),
      ]),
    );
  }
}

/// Motif khas brand: kotak bertangga (sama dengan panel masuk web), putih
/// tipis di atas latar hijau.
class _Stairs extends StatelessWidget {
  const _Stairs({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final gap = size * 0.3;
    Widget cell(bool on) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: on ? Colors.white.withValues(alpha: 0.28) : Colors.transparent, borderRadius: BorderRadius.circular(size * 0.25)),
        );
    const rows = [
      [true, false, false],
      [true, true, false],
      [false, true, true],
    ];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final (i, row) in rows.indexed) ...[
        if (i > 0) SizedBox(height: gap),
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (j, on) in row.indexed) ...[
            if (j > 0) SizedBox(width: gap),
            cell(on),
          ],
        ]),
      ],
    ]);
  }
}
