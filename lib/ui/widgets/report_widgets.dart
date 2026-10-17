import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../data/api_client.dart';
import '../../domain/report_models.dart';
import '../../state/reports_state.dart';
import '../../state/sync_controller.dart';
import '../theme.dart';
import 'common.dart';

/// Rupiah singkat untuk label grafik/ubin: "850 rb", "20,3 jt", "1,2 M".
/// Satuan dipilih setelah pembulatan, jadi 999.950 menjadi "1 jt" (bukan
/// "1000 rb").
String compactRupiah(Object? value) {
  final number = double.tryParse(Money.normalize(value)) ?? 0;
  final sign = number < 0 ? '-' : '';
  final abs = number.abs();
  String one(double v) => v.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '').replaceAll('.', ',');
  if (abs.round() < 1000) {
    return '$sign${abs.round()}';
  }
  if ((abs / 1e3).round() < 1000) {
    return '$sign${(abs / 1e3).round()} rb';
  }
  if (double.parse((abs / 1e6).toStringAsFixed(1)) < 1000) {
    return '$sign${one(abs / 1e6)} jt';
  }
  return '$sign${one(abs / 1e9)} M';
}

/// Rentang tanggal terpanjang yang diterima server (laporan & buku kas).
const int maxRangeDays = 366;

/// Jumlah hari rentang, termasuk tanggal awal dan akhir (cara server menghitung).
int inclusiveDays(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays + 1;

/// Pesan galat untuk pengguna: pesan server bila ada, selain itu kalimat
/// umum tanpa istilah teknis (rinciannya hanya ke log).
String friendlyError(Object error) {
  if (error is ApiException) {
    return error.message;
  }
  debugPrint('Galat tak terduga: $error');
  return 'Data dari server belum bisa dibaca. Coba lagi atau perbarui aplikasi.';
}

/// Teks "berhasil/masuk" (hijau) yang tetap kontras di mode gelap.
Color successText(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? Theme.of(context).colorScheme.primary : Brand.green;

/// Salin teks ke papan klip dan beri tahu pengguna.
Future<void> copyText(BuildContext context, String text, {String message = 'Teks disalin. Tempel di WhatsApp atau catatan Anda.'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    showMessage(context, message);
  }
}

/// Pilihan periode: Hari ini · Kemarin · Minggu ini · Bulan ini · Bulan lalu ·
/// 30 hari · Pilih tanggal (rentang bebas, maks. 366 hari).
class PeriodChips extends ConsumerWidget {
  const PeriodChips({super.key});

  Future<void> _pickRange(BuildContext context, WidgetRef ref) async {
    final current = ref.read(reportPeriodProvider);
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: current.isCustom && current.from != null && current.to != null ? DateTimeRange(start: current.from!, end: current.to!) : null,
      locale: const Locale('id', 'ID'),
      helpText: 'Pilih rentang tanggal',
      saveText: 'Pakai',
      cancelText: 'Batal',
      confirmText: 'Pakai',
    );
    if (range == null) {
      return;
    }
    if (inclusiveDays(range.start, range.end) > maxRangeDays) {
      if (context.mounted) {
        showMessage(context, 'Rentang tanggal maksimal $maxRangeDays hari. Persempit periodenya.', error: true);
      }
      return;
    }
    ref.read(reportPeriodProvider.notifier).state = ReportPeriodChoice('custom', from: DateTime(range.start.year, range.start.month, range.start.day), to: DateTime(range.end.year, range.end.month, range.end.day));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(reportPeriodProvider);
    // Semua chip dibangun sekaligus (bukan ListView malas) supaya pilihan di
    // luar layar tetap bisa dicari pembaca layar dan tes.
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
        for (final entry in ReportPeriodChoice.presets.entries) ...[
          ChoiceChip(
            key: Key('period-${entry.key}'),
            label: Text(entry.value),
            selected: selected.preset == entry.key,
            showCheckmark: false,
            onSelected: (_) => ref.read(reportPeriodProvider.notifier).state = ReportPeriodChoice(entry.key),
          ),
          const SizedBox(width: 8),
        ],
        ChoiceChip(
          key: const Key('period-custom'),
          avatar: Icon(Icons.date_range_outlined, size: 18, color: selected.isCustom ? Theme.of(context).colorScheme.onSecondaryContainer : null),
          label: Text(selected.isCustom ? selected.label : 'Pilih tanggal'),
          selected: selected.isCustom,
          showCheckmark: false,
          onSelected: (_) => _pickRange(context, ref),
        ),
        ]),
      ),
    );
  }
}

/// Grafik batang sederhana (CustomPaint, tanpa paket tambahan). Label
/// sumbu-x ditampilkan untuk titik pertama, tengah, dan terakhir. Pembaca
/// layar mendengar judul, nilai tertinggi, dan totalnya.
class BarSeriesChart extends StatelessWidget {
  const BarSeriesChart({super.key, required this.labels, required this.values, this.height = 140, this.highlight, this.semanticLabel});

  final List<String> labels;
  final List<double> values;
  final double height;

  /// Indeks batang yang ditonjolkan (mis. jam ramai).
  final int? highlight;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final max = values.isEmpty ? 0.0 : values.reduce(math.max);
    return Semantics(
      label: chartSummary(semanticLabel ?? 'Grafik penjualan', labels, values),
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: values.isEmpty || max <= 0
            ? Center(child: Text('Belum ada penjualan di periode ini', style: TextStyle(fontSize: 12, color: mutedText(context))))
            : CustomPaint(
                painter: _BarPainter(
                  labels: labels,
                  values: values,
                  max: max,
                  highlight: highlight,
                  bar: scheme.primary,
                  dim: scheme.primary.withValues(alpha: 0.45),
                  axis: scheme.onSurface.withValues(alpha: 0.15),
                  text: mutedText(context),
                ),
              ),
      ),
    );
  }
}

/// Ringkasan grafik untuk pembaca layar: "Omzet per hari. Tertinggi 9 Okt
/// 9,9 jt. Total 120 jt."
String chartSummary(String title, List<String> labels, List<double> values) {
  if (values.isEmpty || values.every((value) => value <= 0)) {
    return '$title. Belum ada penjualan.';
  }
  var peak = 0;
  for (var i = 1; i < values.length; i++) {
    if (values[i] > values[peak]) {
      peak = i;
    }
  }
  final total = values.fold<double>(0, (sum, value) => sum + value);
  final peakLabel = peak < labels.length ? labels[peak] : '';
  return '$title. Tertinggi $peakLabel ${compactRupiah(values[peak].toStringAsFixed(2))}. Total ${compactRupiah(total.toStringAsFixed(2))}.';
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.labels, required this.values, required this.max, this.highlight, required this.bar, required this.dim, required this.axis, required this.text});

  final List<String> labels;
  final List<double> values;
  final double max;
  final int? highlight;
  final Color bar;
  final Color dim;
  final Color axis;
  final Color text;

  @override
  void paint(Canvas canvas, Size size) {
    const labelHeight = 16.0;
    const topPad = 14.0;
    final chartHeight = size.height - labelHeight - topPad;
    final count = values.length;
    final slot = size.width / count;
    final barWidth = (slot * 0.62).clamp(2.0, 28.0);
    final axisPaint = Paint()
      ..color = axis
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, topPad + chartHeight), Offset(size.width, topPad + chartHeight), axisPaint);

    // Garis bantu nilai maksimum.
    canvas.drawLine(Offset(0, topPad), Offset(size.width, topPad), axisPaint..color = axis.withValues(alpha: 0.5));
    _text(canvas, compactRupiah(max.toStringAsFixed(2)), Offset(size.width, 0), align: TextAlign.right, maxWidth: size.width, canvasWidth: size.width);

    for (var i = 0; i < count; i++) {
      final value = values[i];
      final h = max <= 0 ? 0.0 : (value / max) * chartHeight;
      final left = i * slot + (slot - barWidth) / 2;
      final rect = RRect.fromRectAndRadius(Rect.fromLTWH(left, topPad + chartHeight - h, barWidth, h), const Radius.circular(3));
      final paint = Paint()..color = highlight == null || highlight == i ? bar : dim;
      if (h > 0) {
        canvas.drawRRect(rect, paint);
      }
    }

    final labelIndexes = count <= 3 ? [for (var i = 0; i < count; i++) i] : {0, count ~/ 2, count - 1}.toList();
    for (final i in labelIndexes) {
      if (i < labels.length) {
        _text(canvas, labels[i], Offset(i * slot + slot / 2, topPad + chartHeight + 2), align: TextAlign.center, maxWidth: math.max(slot, 60), canvasWidth: size.width);
      }
    }
  }

  /// [maxWidth] membatasi lebar teks; posisi dijepit ke lebar kanvas supaya
  /// label pertama/terakhir tidak keluar tepi.
  void _text(Canvas canvas, String value, Offset at, {required TextAlign align, required double maxWidth, required double canvasWidth}) {
    final painter = TextPainter(text: TextSpan(text: value, style: TextStyle(fontFamily: 'Poppins', fontSize: 10, color: text)), textDirection: TextDirection.ltr, textAlign: align)..layout(maxWidth: maxWidth);
    final dx = switch (align) {
      TextAlign.right => at.dx - painter.width,
      TextAlign.center => at.dx - painter.width / 2,
      _ => at.dx,
    };
    painter.paint(canvas, Offset(dx.clamp(0, math.max(0, canvasWidth - painter.width)).toDouble(), at.dy));
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) => old.values != values || old.labels != labels || old.highlight != highlight || old.bar != bar;
}

/// Bilah porsi (share %) di bawah baris peringkat.
class ShareBar extends StatelessWidget {
  const ShareBar(this.percent, {super.key, this.color});

  /// 0–100.
  final double percent;
  final Color? color;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 5,
          child: LinearProgressIndicator(
            value: (percent / 100).clamp(0, 1),
            backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
            color: color ?? Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}

/// Baris peringkat: nomor urut, nama, keterangan, nilai, porsi.
class RankTile extends StatelessWidget {
  const RankTile({super.key, required this.rank, required this.title, this.subtitle, required this.value, this.share, this.caption, this.onTap, this.trailingColor});

  final int rank;
  final String title;
  final String? subtitle;
  final String value;

  /// Persen 0–100 untuk bilah porsi.
  final double? share;
  final String? caption;
  final VoidCallback? onTap;
  final Color? trailingColor;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 26, child: Text('$rank', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: mutedText(context)))),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  if (subtitle != null && subtitle!.isNotEmpty) Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: mutedText(context))),
                ]),
              ),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(value, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: trailingColor)),
                if (caption != null) Text(caption!, style: TextStyle(fontSize: 12, color: mutedText(context))),
              ]),
            ]),
            if (share != null) Padding(padding: const EdgeInsets.only(left: 26, top: 6), child: ShareBar(share!)),
          ]),
        ),
      );
}

/// Ubin angka kecil (label + nilai + keterangan).
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.caption, this.color, this.onTap, this.valueKey});

  final String label;
  final String value;
  final String? caption;
  final Color? color;
  final VoidCallback? onTap;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: mutedText(context))),
              const SizedBox(height: 4),
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, key: valueKey, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color))),
              if (caption != null) ...[const SizedBox(height: 2), Text(caption!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: mutedText(context)))],
            ]),
          ),
        ),
      );
}

/// Galat laporan/catatan sebagai layar kosong yang ramah: tanpa internet,
/// tidak berhak, atau galat lain dengan tombol Coba lagi.
class ReportProblem extends ConsumerWidget {
  const ReportProblem({super.key, required this.error, this.onRetry, this.what = 'Laporan'});

  final Object error;
  final VoidCallback? onRetry;

  /// "Laporan" atau "Catatan" untuk kalimat "… butuh internet".
  final String what;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = error is ApiException ? error as ApiException : null;
    final offline = api?.offline == true || ref.watch(syncProvider).connection == ConnectionStatus.offline && api == null;
    if (api?.offline == true || (api == null && offline)) {
      return EmptyState(
        icon: Icons.cloud_off_outlined,
        title: '$what butuh internet',
        message: 'Sambungkan internet lalu coba lagi. Kasir tetap bisa dipakai offline.',
        action: onRetry == null ? null : OutlinedButton(onPressed: onRetry, child: const Text('Coba lagi')),
      );
    }
    final (icon, title) = switch (api?.code) {
      'tidak_berhak' => (Icons.lock_outline, 'Belum punya akses'),
      'langganan_tidak_aktif' => (Icons.card_membership_outlined, 'Perusahaan sedang tidak aktif'),
      'perangkat_dicabut' => (Icons.phonelink_erase_outlined, 'Akses HP ini dicabut'),
      'tidak_ditemukan' => (Icons.search_off_outlined, 'Tidak ditemukan'),
      _ => (Icons.error_outline, '$what belum bisa dimuat'),
    };
    return EmptyState(
      icon: icon,
      title: title,
      message: friendlyError(error),
      action: api?.code == 'tidak_berhak' || onRetry == null ? null : OutlinedButton(onPressed: onRetry, child: const Text('Coba lagi')),
    );
  }
}

/// Pemuat di bawah daftar saat halaman berikutnya diambil.
class LoadingMoreRow extends StatelessWidget {
  const LoadingMoreRow({super.key});

  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.all(16), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))));
}

/// Kaki daftar berhalaman: pemuat, atau "Gagal memuat · Coba lagi" bila
/// halaman berikutnya gagal (mis. offline) supaya bisa diulang di bawah.
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({super.key, required this.loading, this.error, required this.onRetry});

  final bool loading;

  /// Pesan galat halaman berikutnya (null bila tidak gagal).
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const LoadingMoreRow();
    }
    if (error == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: [
        Icon(Icons.error_outline, size: 18, color: dangerText(context)),
        const SizedBox(width: 8),
        Expanded(child: Text('Gagal memuat lanjutan. $error', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: dangerText(context)))),
        TextButton(key: const Key('load-more-retry'), onPressed: onRetry, child: const Text('Coba lagi')),
      ]),
    );
  }
}

/// Garis tipis "sedang memuat ulang" di atas isi laporan saat angka periode
/// baru belum datang; isi lama diredupkan supaya tidak terbaca sebagai angka
/// periode yang baru dipilih.
class ReloadingContent extends StatelessWidget {
  const ReloadingContent({super.key, required this.reloading, required this.child});

  final bool reloading;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.passthrough, children: [
        AnimatedOpacity(
          opacity: reloading ? 0.35 : 1,
          duration: const Duration(milliseconds: 150),
          child: IgnorePointer(ignoring: reloading, child: child),
        ),
        if (reloading) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(key: Key('reloading'), minHeight: 3)),
      ]);
}

/// Daftar panjang yang dibangun malas (hanya baris yang terlihat) tetapi
/// tampil seperti satu kartu: kepala, baris-baris bersambung dengan garis
/// pemisah, lalu kaki.
class SegmentedListView extends StatelessWidget {
  const SegmentedListView({
    super.key,
    this.controller,
    this.padding = const EdgeInsets.all(16),
    this.header = const [],
    required this.itemCount,
    required this.itemBuilder,
    this.footer = const [],
  });

  final ScrollController? controller;
  final EdgeInsetsGeometry padding;
  final List<Widget> header;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) => ListView.builder(
        controller: controller,
        // Tetap bisa ditarik (pull-to-refresh) walau isinya pendek.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        itemCount: header.length + itemCount + footer.length,
        itemBuilder: (context, index) {
          if (index < header.length) {
            return header[index];
          }
          final item = index - header.length;
          if (item < itemCount) {
            return CardSegment(first: item == 0, last: item == itemCount - 1, child: itemBuilder(context, item));
          }
          return footer[item - itemCount];
        },
      );
}

/// Potongan kartu untuk [SegmentedListView]: sudut bulat hanya di ujung.
class CardSegment extends StatelessWidget {
  const CardSegment({super.key, required this.first, required this.last, required this.child});

  final bool first;
  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = theme.cardTheme.shape;
    final side = shape is RoundedRectangleBorder ? shape.side : BorderSide.none;
    const radius = Radius.circular(16);
    final borderRadius = BorderRadius.vertical(top: first ? radius : Radius.zero, bottom: last ? radius : Radius.zero);
    return Container(
      foregroundDecoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border(left: side, right: side, top: first ? side : BorderSide.none, bottom: last ? side : BorderSide.none),
      ),
      child: Material(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!first) const Divider(height: 1),
          child,
        ]),
      ),
    );
  }
}

/// Kartu total di kaki laporan.
class TotalsCard extends StatelessWidget {
  const TotalsCard({super.key, required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final (label, value) in rows) AmountRow(label, value),
          ]),
        ),
      );
}

/// Judul kecil di antara bagian.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Warna nilai uang: hijau positif, merah negatif, abu nol.
Color? signedColor(BuildContext context, Object? value) {
  final cmp = Money.compare(value, '0');
  if (cmp > 0) {
    return Theme.of(context).colorScheme.primary;
  }
  if (cmp < 0) {
    return dangerText(context);
  }
  return null;
}

/// Teks ringkas untuk dibagikan: judul + baris "label: nilai".
String shareLines(String title, List<(String, String)> rows) => [title, for (final (label, value) in rows) '$label: $value'].join('\n');

String dateFromIso(String value) {
  final parsed = DateTime.tryParse(value);
  return parsed == null ? value : dateLabel(parsed);
}
