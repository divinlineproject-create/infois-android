import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme.dart';

/// Layar masuk / kunci tablet: separuh layar panel brand (seperti halaman
/// masuk dashboard web: latar Tinta, logo, kalimat utama, motif tangga),
/// separuh lagi formulir. Layar sempit (HP tegak): panel brand menjadi
/// spanduk di atas, formulir di bawahnya.
class AuthSplitLayout extends StatelessWidget {
  const AuthSplitLayout({super.key, required this.child, this.headline = defaultHeadline, this.lead = defaultLead, this.maxFormWidth = 420});

  final Widget child;
  final String headline;
  final String lead;
  final double maxFormWidth;

  static const defaultHeadline = 'Pekerjaan keuangan selesai lebih dulu.';
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
        // HP tegak: spanduk ± sepertiga layar, ikut tergulung bersama formulir.
        final bannerHeight = (constraints.maxHeight * 0.34).clamp(200.0, 300.0);
        return SingleChildScrollView(
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
      color: Brand.ink,
      child: Stack(children: [
        // Panel penuh: motif di sudut bawah; spanduk HP: sejajar logo di kanan atas (tidak menutupi teks).
        if (roomy) const Positioned(right: 40, bottom: 40, child: _Stairs(size: 34)) else Positioned(right: 24, top: 20 + top, child: const _Stairs(size: 12)),
        Padding(
          padding: EdgeInsets.fromLTRB(roomy ? 48 : 24, (roomy ? 48 : 20) + top, roomy ? 48 : 24, roomy ? 48 : 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SvgPicture.asset('assets/images/infois-logo-on-dark.svg', height: roomy ? 52 : 34, alignment: Alignment.centerLeft),
            const Spacer(),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  headline,
                  style: TextStyle(color: Colors.white, fontSize: roomy ? 34 : 22, height: 1.15, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                ),
                SizedBox(height: roomy ? 16 : 8),
                Text(
                  lead,
                  maxLines: roomy ? 6 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: roomy ? 16 : 13, height: 1.55),
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

/// Motif khas brand: kotak bertangga (sama dengan panel masuk web).
class _Stairs extends StatelessWidget {
  const _Stairs({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final gap = size * 0.3;
    Widget cell(bool on) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: on ? Brand.green : Colors.transparent, borderRadius: BorderRadius.circular(size * 0.25)),
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
