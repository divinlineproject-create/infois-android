import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/report_models.dart';
import '../../state/records_state.dart';
import '../../state/reports_state.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/report_widgets.dart';

/// Tab Laporan: periode, ringkasan penjualan periode itu, ubin hari ini /
/// kemarin / bulan ini, grafik 14 hari, kas, piutang, stok, dan pintu masuk
/// ke setiap laporan rinci. Butuh internet; angka sama dengan laporan web.
class LaporanScreen extends ConsumerWidget {
  const LaporanScreen({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(reportOverviewProvider);
    ref.invalidate(salesSummaryProvider);
    await Future.wait([ref.read(reportOverviewProvider.future), ref.read(salesSummaryProvider.future)]).catchError((_) => <Object?>[]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final overview = ref.watch(reportOverviewProvider);
    final summary = ref.watch(salesSummaryProvider);
    final period = ref.watch(reportPeriodProvider);
    final access = ref.watch(recordAccessProvider);
    final tenantName = ref.watch(sessionProvider).valueOrNull?.tenant?.name ?? '';
    final offline = sync.connection == ConnectionStatus.offline;
    final data = overview.valueOrNull;

    if (data == null && (offline && !overview.isLoading || overview.hasError)) {
      return ReportProblem(error: overview.error ?? 'offline', onRetry: () => _refresh(ref));
    }
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final summaryData = summary.valueOrNull;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: ListView(padding: const EdgeInsets.fromLTRB(0, 12, 0, 32), children: [
          if (offline)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                child: const Row(children: [
                  Icon(Icons.cloud_off_outlined, color: Brand.amber),
                  SizedBox(width: 10),
                  Expanded(child: Text('Laporan butuh internet. Angka di bawah dari pembukaan terakhir.', style: TextStyle(fontSize: 13))),
                ]),
              ),
            ),
          const PeriodChips(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SectionTitle(
                'Penjualan · ${period.label}',
                trailing: summaryData == null
                    ? null
                    : TextButton.icon(
                        key: const Key('share-summary'),
                        onPressed: () => copyText(context, _shareText(tenantName, summaryData)),
                        icon: const Icon(Icons.share_outlined, size: 18),
                        label: const Text('Bagikan'),
                      ),
              ),
              if (summary.isLoading && summaryData == null)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (summary.hasError && summaryData == null)
                Card(child: ListTile(leading: Icon(Icons.error_outline, color: dangerText(context)), title: const Text('Ringkasan belum bisa dimuat'), subtitle: Text(friendlyError(summary.error!)), onTap: () => ref.invalidate(salesSummaryProvider)))
              else if (summaryData != null)
                // Saat periode baru dimuat, angka periode lama diredupkan
                // (bukan ditampilkan seolah angka periode yang baru dipilih).
                ReloadingContent(
                  reloading: summary.isLoading,
                  child: _PeriodSummaryCard(summary: summaryData, onOpen: () => context.push('/laporan/ringkasan')),
                ),
              const SectionTitle('Sekilas'),
              _Tiles(children: [
                StatTile(label: 'Hari ini', value: rupiah(data.today.total), valueKey: const Key('tile-today'), caption: '${data.today.count} nota · laba kotor ${compactRupiah(data.today.grossProfit)}'),
                StatTile(label: 'Kemarin', value: rupiah(data.yesterday.total), caption: '${data.yesterday.count} nota · ${_compare(data.today.total, data.yesterday.total)}'),
                StatTile(label: data.month.label ?? 'Bulan ini', value: rupiah(data.month.total), caption: '${data.month.count} nota · margin ${percentText(data.month.margin)}'),
                StatTile(label: 'Rata-rata per nota', value: rupiah(data.month.average), caption: 'bulan ini'),
              ]),
              const SectionTitle('14 hari terakhir'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: BarSeriesChart(
                    labels: [for (final point in data.sparkline) _shortDate(point.date)],
                    values: [for (final point in data.sparkline) point.value],
                    semanticLabel: 'Grafik omzet 14 hari terakhir',
                  ),
                ),
              ),
              const SectionTitle('Keuangan & stok'),
              _Tiles(children: [
                StatTile(label: 'Saldo kas & bank', value: rupiah(data.cashBalance), onTap: access.cash ? () => context.push('/catatan/bagian/cash') : null),
                StatTile(
                  label: 'Piutang pelanggan',
                  value: rupiah(data.receivables.outstandingTotal),
                  caption: data.receivables.overdueCount > 0 ? '${data.receivables.overdueCount} lewat jatuh tempo · ${compactRupiah(data.receivables.overdueTotal)}' : '${data.receivables.outstandingCount} nota belum lunas',
                  color: data.receivables.overdueCount > 0 ? warningText(context) : null,
                  onTap: () => context.push('/laporan/umur/receivables'),
                ),
                StatTile(
                  label: 'Hutang ke pemasok',
                  value: rupiah(data.payables.outstandingTotal),
                  caption: data.payables.overdueCount > 0 ? '${data.payables.overdueCount} lewat jatuh tempo · ${compactRupiah(data.payables.overdueTotal)}' : '${data.payables.outstandingCount} tagihan belum lunas',
                  color: data.payables.overdueCount > 0 ? warningText(context) : null,
                  onTap: () => context.push('/laporan/umur/payables'),
                ),
                StatTile(
                  label: 'Stok menipis/habis',
                  value: '${data.lowStock + data.emptyStock} barang',
                  caption: data.emptyStock > 0 ? '${data.emptyStock} habis · ${data.lowStock} menipis' : (data.lowStock > 0 ? 'di bawah stok minimum' : 'semua barang masih ada'),
                  color: data.lowStock > 0 || data.emptyStock > 0 ? warningText(context) : null,
                  onTap: access.stock ? () => context.push('/catatan/bagian/stock?low=1') : null,
                ),
              ]),
              const SectionTitle('Laporan rinci'),
              Card(
                child: Column(children: [
                  _ReportLink(icon: Icons.stacked_line_chart, title: 'Ringkasan penjualan', subtitle: 'Grafik per hari/jam dan metode bayar', route: '/laporan/ringkasan'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.local_cafe_outlined, title: 'Barang terlaris', subtitle: 'Jumlah, omzet, dan laba per barang', route: '/laporan/peringkat/by-product'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.people_outline, title: 'Per pelanggan', subtitle: 'Omzet dan piutang tiap pelanggan', route: '/laporan/peringkat/by-customer'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.badge_outlined, title: 'Per kasir', subtitle: 'Omzet tiap pengguna yang membuat nota', route: '/laporan/peringkat/by-cashier'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.phone_android_outlined, title: 'Per HP kasir', subtitle: 'Omzet tiap perangkat kasir', route: '/laporan/peringkat/by-device'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.schedule_outlined, title: 'Per jam', subtitle: 'Jam ramai untuk mengatur jadwal', route: '/laporan/per-jam'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.request_quote_outlined, title: 'Piutang pelanggan', subtitle: 'Umur piutang per pelanggan', route: '/laporan/umur/receivables'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.outbox_outlined, title: 'Hutang ke pemasok', subtitle: 'Umur hutang per pemasok', route: '/laporan/umur/payables'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.balance_outlined, title: 'Laba rugi', subtitle: 'Pendapatan, HPP, beban, laba bersih', route: '/laporan/laba-rugi'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.swap_vert_outlined, title: 'Arus kas', subtitle: 'Uang masuk dan keluar per aktivitas', route: '/laporan/arus-kas'),
                  const Divider(height: 1),
                  _ReportLink(icon: Icons.point_of_sale_outlined, title: 'Shift kasir', subtitle: 'Laporan tutup kasir tiap shift', route: '/laporan/shift'),
                ]),
              ),
              if (data.generatedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('Diperbarui ${dateTimeLabel(data.generatedAt!.toLocal())}', style: TextStyle(fontSize: 11, color: mutedText(context))),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  static String _compare(String today, String yesterday) {
    final diff = Money.sub(today, yesterday);
    if (Money.isZero(diff)) {
      return 'sama dengan hari ini';
    }
    return Money.isPositive(diff) ? 'hari ini naik ${compactRupiah(diff)}' : 'hari ini turun ${compactRupiah(diff.replaceFirst('-', ''))}';
  }

  static String _shortDate(String iso) {
    final date = DateTime.tryParse(iso);
    return date == null ? iso : '${date.day}/${date.month}';
  }

  static String _shareText(String tenant, SalesSummary summary) => shareLines('Laporan penjualan $tenant · ${summary.period.label}', [
        ('Omzet', rupiah(summary.totals.total)),
        ('Jumlah nota', '${summary.totals.count}'),
        ('Rata-rata per nota', rupiah(summary.totals.average)),
        ('Laba kotor', '${rupiah(summary.totals.grossProfit)} (${percentText(summary.totals.margin)})'),
        ('Sudah dibayar', rupiah(summary.totals.paid)),
        ('Belum dibayar', rupiah(summary.totals.outstanding)),
        for (final payment in summary.payments) (payment.label, '${rupiah(payment.total)} (${payment.count} nota)'),
      ]);
}

/// Kartu ringkasan periode terpilih: omzet, nota, laba kotor, grafik, metode bayar.
class _PeriodSummaryCard extends StatelessWidget {
  const _PeriodSummaryCard({required this.summary, required this.onOpen});

  final SalesSummary summary;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final totals = summary.totals;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Omzet', style: TextStyle(fontSize: 12, color: mutedText(context))),
            Text(rupiah(totals.total), key: const Key('period-total'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Wrap(spacing: 14, runSpacing: 4, children: [
              _Mini('Nota', '${totals.count}'),
              _Mini('Rata-rata', compactRupiah(totals.average)),
              _Mini('Laba kotor', '${compactRupiah(totals.grossProfit)} · ${percentText(totals.margin)}'),
              if (Money.isPositive(totals.outstanding)) _Mini('Belum dibayar', compactRupiah(totals.outstanding), color: warningText(context)),
            ]),
            const SizedBox(height: 12),
            BarSeriesChart(
              labels: [for (final point in summary.points) point.label],
              values: [for (final point in summary.points) point.value],
              height: 110,
              semanticLabel: summary.seriesUnit == 'hour' ? 'Grafik omzet per jam' : 'Grafik omzet per hari',
            ),
            const SizedBox(height: 8),
            for (final payment in summary.payments)
              AmountRow('${payment.label} · ${payment.count} nota', rupiah(payment.total), color: payment.method == 'bon' && Money.isPositive(payment.total) ? warningText(context) : null),
            Align(alignment: Alignment.centerRight, child: Text('Lihat rincian ›', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600))),
          ]),
        ),
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => RichText(
        text: TextSpan(style: TextStyle(fontSize: 12, color: mutedText(context), fontFamily: 'Poppins'), children: [
          TextSpan(text: '$label '),
          TextSpan(text: value, style: TextStyle(fontWeight: FontWeight.w600, color: color ?? Theme.of(context).colorScheme.onSurface)),
        ]),
      );
}

/// Dua ubin per baris, muat di layar 360 px.
class _Tiles extends StatelessWidget {
  const _Tiles({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        final width = (constraints.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final child in children) SizedBox(width: width, child: child)]);
      });
}

class _ReportLink extends StatelessWidget {
  const _ReportLink({required this.icon, required this.title, required this.subtitle, required this.route});

  final IconData icon;
  final String title;
  final String subtitle;
  final String route;

  @override
  Widget build(BuildContext context) => ListTile(
        key: Key('report-${route.split('/').last}'),
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push(route),
      );
}
