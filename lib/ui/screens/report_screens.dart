import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/report_models.dart';
import '../../services/file_downloads.dart';
import '../../state/printer_controller.dart';
import '../../state/reports_state.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/report_widgets.dart';
import 'pay_screen.dart' show printMessage;

/// Kerangka layar laporan berperiode: judul, pilihan periode, tombol
/// Bagikan, dan isi dari provider; galat/offline ditampilkan ramah.
class _ReportScaffold<T> extends ConsumerWidget {
  const _ReportScaffold({required this.title, required this.value, required this.onRetry, required this.builder, this.shareText, this.withPeriod = true, this.actions = const []});

  final String title;
  final AsyncValue<T?> value;
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) builder;
  final String Function(T data)? shareText;
  final bool withPeriod;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = value.valueOrNull;
    final period = ref.watch(reportPeriodProvider);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text(title, overflow: TextOverflow.ellipsis), if (withPeriod) Text(period.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: mutedText(context)))],
        ),
        actions: [
          ...actions,
          if (shareText != null && data != null)
            IconButton(key: const Key('share-report'), tooltip: 'Bagikan', icon: const Icon(Icons.share_outlined), onPressed: () => shareTextOrCopy(context, ref, shareText!(data))),
        ],
      ),
      body: Column(
        children: [
          if (withPeriod) const Padding(padding: EdgeInsets.only(top: 8, bottom: 4), child: PeriodChips()),
          Expanded(
            child:
                data == null
                    ? (value.hasError ? ReportProblem(error: value.error!, onRetry: onRetry) : const Center(child: CircularProgressIndicator()))
                    // Periode baru sedang dimuat: angka lama diredupkan + garis muat.
                    : ReloadingContent(reloading: value.isLoading, child: RefreshIndicator(onRefresh: () async => onRetry(), child: builder(context, data))),
          ),
        ],
      ),
    );
  }
}

/// Ringkasan penjualan: total, grafik per hari/jam, metode bayar.
class SalesSummaryScreen extends ConsumerWidget {
  const SalesSummaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tenant = ref.watch(sessionProvider).valueOrNull?.tenant?.name ?? '';
    return _ReportScaffold<SalesSummary>(
      title: 'Ringkasan penjualan',
      value: ref.watch(salesSummaryProvider),
      onRetry: () => ref.invalidate(salesSummaryProvider),
      shareText: (data) => shareLines('Ringkasan penjualan $tenant · ${data.period.label}', _rows(data)),
      builder: (context, data) {
        final totals = data.totals;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Omzet (termasuk pajak)', style: TextStyle(fontSize: 12, color: mutedText(context))),
                    Text(rupiah(totals.total), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    BarSeriesChart(
                      labels: [for (final point in data.points) point.label],
                      values: [for (final point in data.points) point.value],
                      semanticLabel: data.seriesUnit == 'hour' ? 'Omzet per jam' : 'Omzet per hari',
                    ),
                    Text(data.seriesUnit == 'hour' ? 'Per jam (waktu server)' : 'Per hari', style: TextStyle(fontSize: 11, color: mutedText(context))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            TotalsCard(title: 'Angka periode ini', rows: _rows(data)),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Metode bayar', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    if (data.payments.isEmpty) Text('Belum ada pembayaran di periode ini.', style: TextStyle(fontSize: 13, color: mutedText(context))),
                    for (final payment in data.payments) ...[
                      AmountRow('${payment.label} · ${payment.count} nota', rupiah(payment.total), color: payment.method == 'bon' && Money.isPositive(payment.total) ? warningText(context) : null),
                      ShareBar(_share(payment.total, totals.total), color: payment.method == 'bon' ? Brand.amber : null),
                      const SizedBox(height: 6),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static double _share(String part, String whole) {
    final p = double.tryParse(part) ?? 0;
    final w = double.tryParse(whole) ?? 0;
    return w <= 0 ? 0 : (p / w * 100).clamp(0, 100);
  }

  static List<(String, String)> _rows(SalesSummary data) {
    final t = data.totals;
    return [
      ('Jumlah nota', '${t.count}'),
      ('Pelanggan', '${t.customers}'),
      ('Penjualan kotor', rupiah(t.gross)),
      ('Diskon', rupiah(t.discount)),
      ('Penjualan bersih', rupiah(t.net)),
      ('Pajak', rupiah(t.tax)),
      ('Omzet', rupiah(t.total)),
      ('Rata-rata per nota', rupiah(t.average)),
      ('HPP', rupiah(t.cogs)),
      ('Laba kotor', rupiah(t.grossProfit)),
      ('Margin laba kotor', percentText(t.margin)),
      ('Sudah dibayar', rupiah(t.paid)),
      ('Belum dibayar', rupiah(t.outstanding)),
      ('Nota belum lunas', '${t.unpaidCount}'),
      if (Money.isPositive(t.returns)) ('Retur', rupiah(t.returns)),
    ];
  }
}

/// Peringkat per barang / pelanggan / kasir / HP kasir.
class RankedReportScreen extends ConsumerStatefulWidget {
  const RankedReportScreen({super.key, required this.kind});

  /// `by-product` | `by-customer` | `by-cashier` | `by-device`.
  final String kind;

  static String titleOf(String kind) => switch (kind) {
    'by-product' => 'Barang terlaris',
    'by-customer' => 'Per pelanggan',
    'by-cashier' => 'Per kasir',
    'by-device' => 'Per HP kasir',
    _ => 'Peringkat',
  };

  @override
  ConsumerState<RankedReportScreen> createState() => _RankedReportScreenState();
}

class _RankedReportScreenState extends ConsumerState<RankedReportScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 200) {
        ref.read(rankedReportProvider(widget.kind).notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isProduct = widget.kind == 'by-product';
    return _ReportScaffold<RankedState>(
      title: RankedReportScreen.titleOf(widget.kind),
      value: ref.watch(rankedReportProvider(widget.kind)),
      onRetry: () => ref.read(rankedReportProvider(widget.kind).notifier).refresh(),
      shareText:
          (data) => shareLines('${RankedReportScreen.titleOf(widget.kind)} · ${data.report.period.label}', [
            for (final (index, row) in data.rows.take(20).indexed) ('${index + 1}. ${row.name}', '${rupiah(row.net)} (${percentText(row.share)})'),
            ('Total penjualan bersih', rupiah(data.report.totals.net)),
          ]),
      builder: (context, data) {
        final totals = data.report.totals;
        if (data.rows.isEmpty) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [SizedBox(height: 80), EmptyState(icon: Icons.inbox_outlined, title: 'Belum ada penjualan', message: 'Tidak ada nota terbit di periode ini.')],
          );
        }
        final notifier = ref.read(rankedReportProvider(widget.kind).notifier);
        return SegmentedListView(
          controller: _scroll,
          itemCount: data.rows.length,
          itemBuilder: (context, index) {
            final row = data.rows[index];
            return RankTile(
              key: Key('rank-${index + 1}'),
              rank: index + 1,
              title: row.name,
              subtitle:
                  isProduct
                      ? [
                        if (row.sku != null && row.sku!.isNotEmpty) row.sku,
                        if (row.quantity != null) '${qty(row.quantity)} ${row.unit ?? ''}'.trim(),
                        '${row.lines} baris',
                      ].whereType<String>().join(' · ')
                      : '${row.count} nota${Money.isPositive(row.outstanding) ? ' · belum dibayar ${compactRupiah(row.outstanding)}' : ''}',
              value: rupiah(row.net),
              caption: '${percentText(row.share)} · laba ${compactRupiah(row.grossProfit)}',
              share: row.shareValue,
            );
          },
          footer: [
            LoadMoreFooter(loading: data.loadingMore, error: data.loadMoreError, onRetry: () => notifier.loadMore(retry: true)),
            const SizedBox(height: 12),
            TotalsCard(
              title: 'Total · ${data.report.totalRows} baris',
              rows: [
                ('Penjualan bersih', rupiah(totals.net)),
                ('Diskon', rupiah(totals.discount)),
                ('Pajak', rupiah(totals.tax)),
                ('Omzet', rupiah(totals.total)),
                ('HPP', rupiah(totals.cogs)),
                ('Laba kotor', rupiah(totals.grossProfit)),
                ('Margin laba kotor', percentText(totals.margin)),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Penjualan per jam: 24 batang, jam ramai ditonjolkan.
class HourlyReportScreen extends ConsumerWidget {
  const HourlyReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ReportScaffold<RankedReport>(
    title: 'Per jam',
    value: ref.watch(hourlyReportProvider),
    onRetry: () => ref.invalidate(hourlyReportProvider),
    shareText:
        (data) => shareLines('Penjualan per jam · ${data.period.label}', [
          if (data.peakHour != null) ('Jam ramai', '${data.peakHour.toString().padLeft(2, '0')}:00'),
          for (final row in data.rows.where((row) => row.count > 0)) (row.label ?? '${row.hour}:00', '${rupiah(row.net)} (${row.count} nota)'),
        ]),
    builder: (context, data) {
      final active = data.rows.where((row) => row.count > 0).toList();
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.peakHour == null ? 'Belum ada penjualan di periode ini' : 'Jam ramai: ${data.peakHour.toString().padLeft(2, '0')}:00', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  BarSeriesChart(
                    labels: [for (final row in data.rows) row.label ?? '${row.hour}'],
                    values: [for (final row in data.rows) double.tryParse(row.net) ?? 0],
                    highlight: data.peakHour,
                    semanticLabel: 'Penjualan bersih per jam',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (active.isNotEmpty)
            Card(
              child: Column(
                children: [
                  for (final (index, row) in active.indexed) ...[
                    if (index > 0) const Divider(height: 1),
                    RankTile(
                      rank: index + 1,
                      title: row.label ?? '${row.hour}:00',
                      subtitle: '${row.count} nota · laba ${compactRupiah(row.grossProfit)}',
                      value: rupiah(row.net),
                      caption: percentText(row.share),
                      share: row.shareValue,
                      trailingColor: row.hour == data.peakHour ? Theme.of(context).colorScheme.primary : null,
                    ),
                  ],
                ],
              ),
            ),
        ],
      );
    },
  );
}

/// Umur piutang (pelanggan) / hutang (pemasok) per hari ini.
class AgingReportScreen extends ConsumerStatefulWidget {
  const AgingReportScreen({super.key, required this.kind});

  /// `receivables` | `payables`.
  final String kind;

  @override
  ConsumerState<AgingReportScreen> createState() => _AgingReportScreenState();
}

class _AgingReportScreenState extends ConsumerState<AgingReportScreen> {
  final _scroll = ScrollController();

  bool get _receivable => widget.kind == 'receivables';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 200) {
        ref.read(agingReportProvider(widget.kind).notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = _receivable ? 'Piutang pelanggan' : 'Hutang ke pemasok';
    return _ReportScaffold<AgingState>(
      title: title,
      withPeriod: false,
      value: ref.watch(agingReportProvider(widget.kind)),
      onRetry: () => ref.read(agingReportProvider(widget.kind).notifier).refresh(),
      shareText:
          (data) => shareLines('$title per ${dateFromIso(data.report.asOf)}', [
            for (final bucket in data.report.buckets) (bucket.label, rupiah(bucket.total)),
            ('Total', rupiah(data.report.total)),
            ('Lewat jatuh tempo', rupiah(data.report.overdue)),
            for (final row in data.rows.take(20)) (row.party, '${rupiah(row.total)}${Money.isPositive(row.overdue) ? ' (lewat ${compactRupiah(row.overdue)})' : ''}'),
          ]),
      builder: (context, data) {
        final report = data.report;
        final notifier = ref.read(agingReportProvider(widget.kind).notifier);
        return SegmentedListView(
          controller: _scroll,
          header: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Per ${dateFromIso(report.asOf)}', style: TextStyle(fontSize: 12, color: mutedText(context))),
                    Text(rupiah(report.total), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                    Text(
                      '${report.parties} ${_receivable ? 'pelanggan' : 'pemasok'} · lewat jatuh tempo ${rupiah(report.overdue)}',
                      style: TextStyle(fontSize: 13, color: Money.isPositive(report.overdue) ? warningText(context) : mutedText(context)),
                    ),
                    const SizedBox(height: 12),
                    for (final (index, bucket) in report.buckets.indexed) ...[
                      AmountRow(bucket.label, rupiah(bucket.total), color: index > 0 && Money.isPositive(bucket.total) ? warningText(context) : null),
                      ShareBar(_share(bucket.total, report.total), color: index == 0 ? null : Brand.amber),
                      const SizedBox(height: 4),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (data.rows.isEmpty) EmptyState(icon: Icons.task_alt, title: _receivable ? 'Tidak ada piutang' : 'Tidak ada hutang', message: 'Semua sudah lunas.'),
          ],
          itemCount: data.rows.length,
          itemBuilder: (context, index) {
            final row = data.rows[index];
            return RankTile(
              rank: index + 1,
              title: row.party,
              subtitle: '${row.documentCount} ${_receivable ? 'nota' : 'tagihan'}${Money.isPositive(row.overdue) ? ' · lewat jatuh tempo ${compactRupiah(row.overdue)}' : ''}',
              value: rupiah(row.total),
              share: _share(row.total, report.total),
              trailingColor: Money.isPositive(row.overdue) ? warningText(context) : null,
              onTap: row.partyId == null ? null : () => context.push(_receivable ? '/catatan/pelanggan/${row.partyId}' : '/catatan/pemasok/${row.partyId}'),
            );
          },
          footer: [LoadMoreFooter(loading: data.loadingMore, error: data.loadMoreError, onRetry: () => notifier.loadMore(retry: true))],
        );
      },
    );
  }

  static double _share(String part, String whole) {
    final p = double.tryParse(part) ?? 0;
    final w = double.tryParse(whole) ?? 0;
    return w <= 0 ? 0 : (p / w * 100).clamp(0, 100);
  }
}

/// Laba rugi dari buku besar.
class ProfitLossScreen extends ConsumerWidget {
  const ProfitLossScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ReportScaffold<ProfitLossReport>(
    title: 'Laba rugi',
    value: ref.watch(profitLossProvider),
    onRetry: () => ref.invalidate(profitLossProvider),
    shareText: (data) => shareLines('Laba rugi · ${data.period.label}', _rows(data)),
    builder:
        (context, data) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Laba bersih', style: TextStyle(fontSize: 12, color: mutedText(context))),
                    Text(rupiah(data.netIncome), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: signedColor(context, data.netIncome))),
                    Text('Margin bersih ${percentText(data.netMargin)}', style: TextStyle(fontSize: 13, color: mutedText(context))),
                    const Divider(height: 20),
                    for (final (label, value) in _rows(data)) AmountRow(label, value, bold: label.startsWith('Laba')),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final section in data.sections) _SectionCard(section: section),
          ],
        ),
  );

  static List<(String, String)> _rows(ProfitLossReport data) => [
    ('Pendapatan usaha', rupiah(data.revenue)),
    ('HPP', rupiah(data.cogs)),
    ('Laba kotor', rupiah(data.grossProfit)),
    ('Margin laba kotor', percentText(data.grossMargin)),
    ('Beban usaha', rupiah(data.operatingExpense)),
    ('Laba usaha', rupiah(data.operatingIncome)),
    if (Money.isPositive(data.otherRevenue)) ('Pendapatan lain', rupiah(data.otherRevenue)),
    if (Money.isPositive(data.otherExpense)) ('Beban lain', rupiah(data.otherExpense)),
    ('Laba bersih', rupiah(data.netIncome)),
    ('Margin bersih', percentText(data.netMargin)),
  ];
}

/// Arus kas per aktivitas.
class CashFlowScreen extends ConsumerWidget {
  const CashFlowScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ReportScaffold<CashFlowReport>(
    title: 'Arus kas',
    value: ref.watch(cashFlowProvider),
    onRetry: () => ref.invalidate(cashFlowProvider),
    shareText:
        (data) => shareLines('Arus kas · ${data.period.label}', [
          ('Saldo awal', rupiah(data.opening)),
          for (final category in data.categories) (category.label, rupiah(category.total)),
          ('Perubahan bersih', rupiah(data.netChange)),
          ('Saldo akhir', rupiah(data.closing)),
        ]),
    builder:
        (context, data) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Perubahan kas & bank', style: TextStyle(fontSize: 12, color: mutedText(context))),
                    Text(rupiah(data.netChange), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: signedColor(context, data.netChange))),
                    const Divider(height: 20),
                    AmountRow('Saldo awal', rupiah(data.opening)),
                    for (final category in data.categories) AmountRow(category.label, rupiah(category.total), color: signedColor(context, category.total)),
                    AmountRow('Saldo akhir', rupiah(data.closing), bold: true),
                    const SizedBox(height: 4),
                    Text('Angka negatif = uang keluar.', style: TextStyle(fontSize: 11, color: mutedText(context))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final category in data.categories) _SectionCard(section: category, signed: true),
          ],
        ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section, this.signed = false});

  final ReportSection section;
  final bool signed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Card(
      child: ExpansionTile(
        key: Key('section-${section.key}'),
        initiallyExpanded: section.rows.isNotEmpty && section.rows.length <= 6,
        title: Text(section.label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        trailing: Text(rupiah(section.total), style: TextStyle(fontWeight: FontWeight.w600, color: signed ? signedColor(context, section.total) : null)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (section.rows.isEmpty) Align(alignment: Alignment.centerLeft, child: Text('Tidak ada', style: TextStyle(fontSize: 13, color: mutedText(context)))),
          for (final row in section.rows) AmountRow('${row.code} ${row.name}', rupiah(row.amount), color: signed ? signedColor(context, row.amount) : null),
        ],
      ),
    ),
  );
}

/// Daftar shift kasir yang sudah ditutup.
class ShiftsScreen extends ConsumerStatefulWidget {
  const ShiftsScreen({super.key});

  @override
  ConsumerState<ShiftsScreen> createState() => _ShiftsScreenState();
}

class _ShiftsScreenState extends ConsumerState<ShiftsScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 200) {
        ref.read(shiftsProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ReportScaffold<ShiftsState>(
    title: 'Shift kasir',
    value: ref.watch(shiftsProvider),
    onRetry: () => ref.read(shiftsProvider.notifier).refresh(),
    builder: (context, data) {
      if (data.items.isEmpty) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [SizedBox(height: 80), EmptyState(icon: Icons.point_of_sale_outlined, title: 'Belum ada shift ditutup', message: 'Shift yang ditutup di HP kasir akan tampil di sini.')],
        );
      }
      final notifier = ref.read(shiftsProvider.notifier);
      return SegmentedListView(
        controller: _scroll,
        itemCount: data.items.length,
        footer: [LoadMoreFooter(loading: data.loadingMore, error: data.loadMoreError, onRetry: () => notifier.loadMore(retry: true))],
        itemBuilder: (context, index) {
          final shift = data.items[index];
          return ListTile(
            key: Key('shift-${shift.id}'),
            onTap: () => context.push('/laporan/shift/${shift.id}'),
            title: Text(
              '${shift.device?.display ?? 'Kasir'} · ${shift.cashier?.name ?? '-'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: Text('${shift.openedAt == null ? '' : dateTimeLabel(shift.openedAt!.toLocal())} · ${shift.summary.salesCount} nota', style: const TextStyle(fontSize: 12)),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(rupiah(shift.summary.salesTotal), style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  _differenceLabel(shift.difference),
                  style: TextStyle(fontSize: 12, color: shift.difference == null || Money.isZero(shift.difference) ? successText(context) : warningText(context)),
                ),
              ],
            ),
          );
        },
      );
    },
  );

  static String _differenceLabel(String? difference) {
    if (difference == null || Money.isZero(difference)) {
      return 'Kas pas';
    }
    return Money.isPositive(difference) ? 'Lebih ${compactRupiah(difference)}' : 'Kurang ${compactRupiah(difference.replaceFirst('-', ''))}';
  }
}

/// Rincian satu shift: ringkasan tersimpan vs terkini, nota, cetak ulang.
class ShiftDetailScreen extends ConsumerWidget {
  const ShiftDetailScreen({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ReportScaffold<ShiftDetail>(
    title: 'Laporan shift',
    withPeriod: false,
    value: ref.watch(shiftDetailProvider(id)),
    onRetry: () => ref.invalidate(shiftDetailProvider(id)),
    shareText: (data) => shareLines('Laporan tutup kasir ${data.shift.device?.display ?? ''}', _rows(data)),
    builder: (context, data) {
      final shift = data.shift;
      final live = data.summary;
      final differs = live.salesCount != shift.summary.salesCount || Money.compare(live.salesTotal, shift.summary.salesTotal) != 0;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${shift.device?.display ?? 'Kasir'} · ${shift.cashier?.name ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    '${shift.openedAt == null ? '-' : dateTimeLabel(shift.openedAt!.toLocal())} → ${shift.closedAt == null ? 'masih buka' : dateTimeLabel(shift.closedAt!.toLocal())}${shift.durationMinutes == null ? '' : ' · ${_duration(shift.durationMinutes!)}'}',
                    style: TextStyle(fontSize: 12, color: mutedText(context)),
                  ),
                  if (shift.open) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Shift masih dibuka', style: TextStyle(color: warningText(context), fontWeight: FontWeight.w600))),
                  const Divider(height: 20),
                  for (final (label, value) in _rows(data)) AmountRow(label, value, bold: label == 'Seharusnya di laci' || label == 'Selisih'),
                  if (differs) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Saat ditutup tercatat ${shift.summary.salesCount} nota · ${rupiah(shift.summary.salesTotal)}; angka di atas sudah termasuk nota yang tersinkron belakangan.',
                      style: TextStyle(fontSize: 12, color: warningText(context)),
                    ),
                  ],
                  if (shift.notes != null && shift.notes!.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Catatan: ${shift.notes}', style: const TextStyle(fontSize: 13))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('print-shift'),
            onPressed: () async {
              final result = await ref.read(printerProvider.notifier).printShiftReport(shift.toPrintMap(live));
              if (context.mounted) {
                showMessage(context, printMessage(result.name), error: result != PrintResult.printed);
              }
            },
            icon: const Icon(Icons.print_outlined),
            label: const Text('Cetak ulang laporan'),
          ),
          const SectionTitle('Nota di shift ini'),
          if (data.sales.isEmpty)
            Text('Belum ada nota yang sampai ke server untuk shift ini.', style: TextStyle(fontSize: 13, color: mutedText(context)))
          else
            Card(
              child: Column(
                children: [
                  for (final (index, sale) in data.sales.indexed) ...[
                    if (index > 0) const Divider(height: 1),
                    ListTile(
                      dense: true,
                      onTap: () => context.push('/catatan/penjualan/${sale.id}'),
                      title: Text(sale.number, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      subtitle: Text(
                        '${sale.time == null ? '' : '${sale.time!.toLocal().hour.toString().padLeft(2, '0')}:${sale.time!.toLocal().minute.toString().padLeft(2, '0')} · '}${sale.customer ?? 'Pelanggan Umum'} · ${sale.methods.map(_method).join(', ')}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(rupiah(sale.total), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          Text(
                            sale.statusLabel,
                            style: TextStyle(fontSize: 11, color: sale.status == 'paid' ? successText(context) : (sale.status == 'void' ? dangerText(context) : warningText(context))),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      );
    },
  );

  static String _method(String method) => switch (method) {
    'cash' => 'tunai',
    'transfer' => 'transfer',
    'qris' => 'QRIS',
    'giro' => 'giro/cek',
    'card' => 'kartu',
    'deposit' => 'uang muka',
    'credit_note' => 'nota kredit',
    _ => 'lainnya',
  };

  static String _duration(int minutes) => minutes < 60 ? '$minutes mnt' : '${minutes ~/ 60} jam ${minutes % 60} mnt';

  static List<(String, String)> _rows(ShiftDetail data) {
    final live = data.summary;
    final shift = data.shift;
    return [
      ('Jumlah nota', '${live.salesCount}'),
      ('Total penjualan', rupiah(live.salesTotal)),
      ('Tunai', rupiah(live.cashTotal)),
      ('Transfer', rupiah(live.transferTotal)),
      ('Bon (belum dibayar)', rupiah(live.unpaidTotal)),
      ('Uang awal', rupiah(live.openingCash)),
      ('Seharusnya di laci', rupiah(live.expectedCash)),
      if (shift.closingCash != null) ('Uang dihitung', rupiah(shift.closingCash)),
      if (shift.difference != null) ('Selisih', rupiah(shift.difference)),
    ];
  }
}
