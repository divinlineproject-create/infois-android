import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/record_models.dart';
import '../../state/records_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/report_widgets.dart';

/// Tab Catatan: Penjualan · Pembayaran · Pembelian · Kas & Bank · Stok ·
/// Pelanggan · Pemasok, masing-masing tampil hanya bila hak aksesnya ada.
/// Setiap bagian baru memanggil server saat pertama dibuka.
class CatatanScreen extends ConsumerStatefulWidget {
  const CatatanScreen({super.key});

  @override
  ConsumerState<CatatanScreen> createState() => _CatatanScreenState();
}

class _CatatanScreenState extends ConsumerState<CatatanScreen> {
  RecordSection? _selected;

  @override
  Widget build(BuildContext context) {
    final sections = ref.watch(recordAccessProvider).sections;
    if (sections.isEmpty) {
      return const EmptyState(icon: Icons.lock_outline, title: 'Belum punya akses catatan', message: 'Minta pemilik usaha memberi hak lihat penjualan, stok, atau kas di website Infois.');
    }
    final index = sections.indexWhere((section) => section == _selected).clamp(0, sections.length - 1);
    return Column(children: [
      SizedBox(
        height: 52,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(children: [
            for (final (i, section) in sections.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              ChoiceChip(
                key: Key('section-${section.name}'),
                avatar: Icon(section.icon, size: 18, color: i == index ? Theme.of(context).colorScheme.onSecondaryContainer : null),
                label: Text(section.label),
                selected: i == index,
                showCheckmark: false,
                onSelected: (_) => setState(() => _selected = section),
              ),
            ],
          ]),
        ),
      ),
      Expanded(
        child: IndexedStack(index: index, children: [
          // Kunci per bagian: bila daftar bagian berubah (hak akses berubah),
          // isi yang tersimpan ikut bagiannya, bukan posisinya.
          for (final (i, section) in sections.indexed) LazyTab(key: ValueKey(section.name), active: i == index, builder: () => RecordSectionView(section: section)),
        ]),
      ),
    ]);
  }
}

/// Satu bagian Catatan sebagai layar sendiri (dibuka dari Laporan).
class RecordSectionScreen extends StatelessWidget {
  const RecordSectionScreen({super.key, required this.section, this.initialParams = const {}});

  final RecordSection section;
  final Map<String, String> initialParams;

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(section.label)), body: RecordSectionView(section: section, initialParams: initialParams));
}

class RecordSectionView extends StatelessWidget {
  const RecordSectionView({super.key, required this.section, this.initialParams = const {}});

  final RecordSection section;
  final Map<String, String> initialParams;

  @override
  Widget build(BuildContext context) => switch (section) {
        RecordSection.sales => _SalesSection(extra: initialParams),
        RecordSection.payments => const _PaymentsSection(),
        RecordSection.purchases => const _PurchasesSection(),
        RecordSection.cash => const _CashSection(),
        RecordSection.stock => _StockSection(lowOnly: initialParams['low'] == '1'),
        RecordSection.customers => const _CustomersSection(),
        RecordSection.suppliers => const _SuppliersSection(),
      };
}

/// Satu pilihan filter cepat (chip) dengan parameter query-nya.
class FilterChoice {
  const FilterChoice(this.label, [this.params = const {}]);

  final String label;
  final Map<String, String?> params;
}

/// Kotak cari (dengan jeda ketik), chip filter, dan rentang tanggal.
class RecordFilterBar extends StatefulWidget {
  const RecordFilterBar({super.key, required this.hint, this.choices = const [], this.selected = 0, this.withDates = true, required this.onChanged, this.sectionKey = '', this.maxDays});

  final String hint;
  final List<FilterChoice> choices;
  final int selected;
  final bool withDates;
  final String sectionKey;

  /// Rentang tanggal terpanjang yang diterima server untuk bagian ini (hari, termasuk ujung).
  final int? maxDays;

  /// Dipanggil saat cari/chip/tanggal berubah.
  final void Function(String query, int choice, DateTime? from, DateTime? to) onChanged;

  @override
  State<RecordFilterBar> createState() => _RecordFilterBarState();
}

class _RecordFilterBarState extends State<RecordFilterBar> {
  final _search = TextEditingController();
  Timer? _debounce;
  int _choice = 0;
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _choice = widget.selected;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(_search.text.trim(), _choice, _from, _to);

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _emit);
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _from != null && _to != null ? DateTimeRange(start: _from!, end: _to!) : null,
      locale: const Locale('id', 'ID'),
      helpText: 'Pilih rentang tanggal',
      saveText: 'Pakai',
      cancelText: 'Batal',
      confirmText: 'Pakai',
    );
    if (range == null) {
      return;
    }
    final maxDays = widget.maxDays;
    if (maxDays != null && inclusiveDays(range.start, range.end) > maxDays) {
      if (mounted) {
        showMessage(context, 'Rentang tanggal maksimal $maxDays hari. Persempit periodenya.', error: true);
      }
      return;
    }
    setState(() {
      _from = DateTime(range.start.year, range.start.month, range.start.day);
      _to = DateTime(range.end.year, range.end.month, range.end.day);
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            key: Key('search-${widget.sectionKey}'),
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: _onSearch,
            onSubmitted: (_) {
              _debounce?.cancel();
              _emit();
            },
            decoration: InputDecoration(
              hintText: widget.hint,
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Hapus pencarian',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _search.clear();
                        _debounce?.cancel();
                        _emit();
                      },
                    ),
            ),
          ),
          if (widget.choices.isNotEmpty || widget.withDates)
            SizedBox(
              height: 44,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                for (final (i, choice) in widget.choices.indexed) ...[
                  ChoiceChip(
                    key: Key('filter-${widget.sectionKey}-$i'),
                    label: Text(choice.label),
                    selected: _choice == i,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) {
                      setState(() => _choice = i);
                      _emit();
                    },
                  ),
                  const SizedBox(width: 6),
                ],
                if (widget.withDates)
                  InputChip(
                    key: Key('dates-${widget.sectionKey}'),
                    avatar: const Icon(Icons.date_range_outlined, size: 18),
                    label: Text(_from == null ? 'Tanggal' : '${dateLabel(_from!)} – ${dateLabel(_to!)}'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _pickDates,
                    onDeleted: _from == null
                        ? null
                        : () {
                            setState(() {
                              _from = null;
                              _to = null;
                            });
                            _emit();
                          },
                    deleteIcon: const Icon(Icons.close, size: 16),
                  ),
                ]),
              ),
            ),
        ]),
      );
}

/// Daftar berkursor: tarik untuk memuat ulang, gulir ke bawah untuk halaman
/// berikutnya, kosong/galat/offline ditampilkan ramah.
class RecordListView<T> extends ConsumerStatefulWidget {
  const RecordListView({
    super.key,
    required this.provider,
    required this.query,
    required this.itemBuilder,
    required this.emptyTitle,
    this.emptyMessage,
    this.header,
    this.footer,
  });

  final AutoDisposeAsyncNotifierProviderFamily<RecordListController<T>, RecordListState<T>, RecordQuery> provider;
  final RecordQuery query;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final String emptyTitle;
  final String? emptyMessage;

  /// Kepala daftar yang memakai `extra` halaman pertama (mis. saldo akun).
  final Widget Function(BuildContext context, RecordListState<T> state)? header;
  final Widget Function(BuildContext context, RecordListState<T> state)? footer;

  @override
  ConsumerState<RecordListView<T>> createState() => _RecordListViewState<T>();
}

class _RecordListViewState<T> extends ConsumerState<RecordListView<T>> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 240) {
        ref.read(widget.provider(widget.query).notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      await ref.read(widget.provider(widget.query).notifier).refresh();
    } catch (error) {
      if (mounted) {
        showMessage(context, friendlyError(error), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(widget.provider(widget.query));
    final state = value.valueOrNull;
    if (state == null) {
      return value.hasError ? ReportProblem(error: value.error!, what: 'Catatan', onRetry: () => ref.invalidate(widget.provider(widget.query))) : const Center(child: CircularProgressIndicator());
    }
    final notifier = ref.read(widget.provider(widget.query).notifier);
    // Baris dibangun malas (hanya yang terlihat), jadi ribuan nota tetap ringan.
    return RefreshIndicator(
      onRefresh: _refresh,
      child: SegmentedListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        header: [
          if (widget.header != null) widget.header!(context, state),
          if (state.items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: EmptyState(
                icon: Icons.inbox_outlined,
                title: widget.emptyTitle,
                message: widget.emptyMessage,
                action: OutlinedButton(key: const Key('records-reload'), onPressed: _refresh, child: const Text('Muat ulang')),
              ),
            ),
        ],
        itemCount: state.items.length,
        itemBuilder: (context, index) => widget.itemBuilder(context, state.items[index]),
        footer: [
          LoadMoreFooter(loading: state.loadingMore, error: state.loadMoreError, onRetry: () => notifier.loadMore(retry: true)),
          if (widget.footer != null) widget.footer!(context, state),
        ],
      ),
    );
  }
}

/// Warna status dokumen (lunas hijau, batal merah, lainnya kuning).
Color statusColor(BuildContext context, String status) => switch (status) {
      'paid' => successText(context),
      'void' => dangerText(context),
      'draft' => mutedText(context),
      _ => warningText(context),
    };

/// Tanda status kecil.
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      );
}

/// Baris penjualan di daftar (juga dipakai di rincian pelanggan).
class SaleListTile extends StatelessWidget {
  const SaleListTile(this.sale, {super.key});

  final SaleRecord sale;

  @override
  Widget build(BuildContext context) => ListTile(
        key: Key('sale-${sale.id}'),
        onTap: () => context.push('/catatan/penjualan/${sale.id}'),
        title: Row(children: [
          Expanded(child: Text(sale.number, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
          const SizedBox(width: 8),
          StatusPill(sale.statusLabel, color: statusColor(context, sale.status)),
        ]),
        subtitle: Text('${dateFromIso(sale.date)} · ${sale.customer?.name ?? 'Pelanggan Umum'}${sale.cashier == null ? '' : ' · ${sale.cashier}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(rupiah(sale.total), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          if (Money.isPositive(sale.balanceDue) && sale.status != 'void') Text('sisa ${compactRupiah(sale.balanceDue)}', style: TextStyle(fontSize: 11, color: warningText(context))),
        ]),
      );
}

/// Baris pembayaran (masuk hijau, keluar merah).
class PaymentListTile extends StatelessWidget {
  const PaymentListTile(this.payment, {super.key});

  final PaymentRecord payment;

  @override
  Widget build(BuildContext context) {
    final color = payment.incoming ? successText(context) : dangerText(context);
    return ListTile(
      key: Key('payment-${payment.kind}-${payment.id}'),
      onTap: () => context.push('/catatan/pembayaran/${payment.kind}/${payment.id}'),
      leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.14), child: Icon(payment.incoming ? Icons.south_west : Icons.north_east, color: color, size: 20)),
      title: Text(payment.party?.name ?? payment.document?.number ?? payment.methodLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text('${dateFromIso(payment.date)} · ${payment.methodLabel}${payment.document == null ? '' : ' · ${payment.document!.number}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      trailing: Text('${payment.incoming ? '+' : '-'}${rupiah(payment.amount)}', style: TextStyle(fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class PurchaseListTile extends StatelessWidget {
  const PurchaseListTile(this.purchase, {super.key});

  final PurchaseRecord purchase;

  @override
  Widget build(BuildContext context) => ListTile(
        key: Key('purchase-${purchase.id}'),
        onTap: () => context.push('/catatan/pembelian/${purchase.id}'),
        title: Row(children: [
          Expanded(child: Text(purchase.supplier?.name ?? purchase.number, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
          const SizedBox(width: 8),
          StatusPill(purchase.statusLabel, color: statusColor(context, purchase.status)),
        ]),
        subtitle: Text('${dateFromIso(purchase.date)} · ${purchase.number}${purchase.overdueDays > 0 ? ' · lewat ${purchase.overdueDays} hari' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(rupiah(purchase.total), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          if (Money.isPositive(purchase.balanceDue) && purchase.status != 'void') Text('sisa ${compactRupiah(purchase.balanceDue)}', style: TextStyle(fontSize: 11, color: warningText(context))),
        ]),
      );
}

// Bagian-bagian ---------------------------------------------------------------

class _SalesSection extends ConsumerStatefulWidget {
  const _SalesSection({this.extra = const {}});

  /// Parameter tetap (mis. `customer_id` dari rincian pelanggan).
  final Map<String, String> extra;

  @override
  ConsumerState<_SalesSection> createState() => _SalesSectionState();
}

class _SalesSectionState extends ConsumerState<_SalesSection> {
  static const choices = [
    FilterChoice('Semua'),
    FilterChoice('Belum lunas', {'status': 'outstanding'}),
    FilterChoice('Lunas', {'status': 'paid'}),
    FilterChoice('Dari HP kasir', {'source': 'pos'}),
    FilterChoice('Nota saya', {'mine': '1'}),
    FilterChoice('Dibatalkan', {'status': 'void'}),
    FilterChoice('Draft', {'status': 'draft'}),
  ];
  late RecordQuery _query = RecordQuery(RecordSection.sales, widget.extra);

  @override
  Widget build(BuildContext context) => Column(children: [
        RecordFilterBar(
          sectionKey: 'sales',
          hint: 'Cari nomor nota atau pelanggan',
          choices: choices,
          onChanged: (q, choice, from, to) => setState(() => _query = RecordQuery(RecordSection.sales, {...widget.extra, 'q': q, ...choices[choice].params, 'from': from == null ? null : isoDate(from), 'to': to == null ? null : isoDate(to)})),
        ),
        Expanded(
          child: RecordListView<SaleRecord>(
            provider: salesListProvider,
            query: _query,
            emptyTitle: 'Belum ada penjualan',
            emptyMessage: 'Nota yang cocok dengan filter akan tampil di sini.',
            itemBuilder: (context, sale) => SaleListTile(sale),
          ),
        ),
      ]);
}

class _PaymentsSection extends ConsumerStatefulWidget {
  const _PaymentsSection();

  @override
  ConsumerState<_PaymentsSection> createState() => _PaymentsSectionState();
}

class _PaymentsSectionState extends ConsumerState<_PaymentsSection> {
  RecordQuery _query = RecordQuery(RecordSection.payments);

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(recordAccessProvider);
    final choices = [
      const FilterChoice('Semua'),
      if (access.paymentsIn) const FilterChoice('Uang masuk', {'kind': 'in'}),
      if (access.paymentsOut) const FilterChoice('Uang keluar', {'kind': 'out'}),
      const FilterChoice('Tunai', {'method': 'cash'}),
      const FilterChoice('Transfer', {'method': 'transfer'}),
    ];
    return Column(children: [
      RecordFilterBar(
        sectionKey: 'payments',
        hint: 'Cari referensi, nomor nota, atau nama',
        choices: choices,
        onChanged: (q, choice, from, to) => setState(() => _query = RecordQuery(RecordSection.payments, {'q': q, ...choices[choice].params, 'from': from == null ? null : isoDate(from), 'to': to == null ? null : isoDate(to)})),
      ),
      Expanded(
        child: RecordListView<PaymentRecord>(
          provider: paymentsListProvider,
          query: _query,
          emptyTitle: 'Belum ada pembayaran',
          itemBuilder: (context, payment) => PaymentListTile(payment),
        ),
      ),
    ]);
  }
}

class _PurchasesSection extends ConsumerStatefulWidget {
  const _PurchasesSection();

  @override
  ConsumerState<_PurchasesSection> createState() => _PurchasesSectionState();
}

class _PurchasesSectionState extends ConsumerState<_PurchasesSection> {
  static const choices = [
    FilterChoice('Semua'),
    FilterChoice('Belum lunas', {'status': 'outstanding'}),
    FilterChoice('Lunas', {'status': 'paid'}),
    FilterChoice('Dibatalkan', {'status': 'void'}),
    FilterChoice('Draft', {'status': 'draft'}),
  ];
  RecordQuery _query = RecordQuery(RecordSection.purchases);

  @override
  Widget build(BuildContext context) => Column(children: [
        RecordFilterBar(
          sectionKey: 'purchases',
          hint: 'Cari nomor tagihan atau pemasok',
          choices: choices,
          onChanged: (q, choice, from, to) => setState(() => _query = RecordQuery(RecordSection.purchases, {'q': q, ...choices[choice].params, 'from': from == null ? null : isoDate(from), 'to': to == null ? null : isoDate(to)})),
        ),
        Expanded(
          child: RecordListView<PurchaseRecord>(
            provider: purchasesListProvider,
            query: _query,
            emptyTitle: 'Belum ada pembelian',
            emptyMessage: 'Tagihan pemasok dicatat lewat website atau Tim AI.',
            itemBuilder: (context, purchase) => PurchaseListTile(purchase),
          ),
        ),
      ]);
}

class _CashSection extends ConsumerStatefulWidget {
  const _CashSection();

  @override
  ConsumerState<_CashSection> createState() => _CashSectionState();
}

class _CashSectionState extends ConsumerState<_CashSection> {
  static const choices = [
    FilterChoice('Semua'),
    FilterChoice('Uang masuk', {'direction': 'in'}),
    FilterChoice('Uang keluar', {'direction': 'out'}),
  ];
  RecordQuery _query = RecordQuery(RecordSection.cash);
  int? _accountId;

  RecordQuery _build(String q, int choice, DateTime? from, DateTime? to) =>
      RecordQuery(RecordSection.cash, {'q': q, ...choices[choice].params, 'from': from == null ? null : isoDate(from), 'to': to == null ? null : isoDate(to), 'account_id': _accountId?.toString()});

  @override
  Widget build(BuildContext context) => Column(children: [
        RecordFilterBar(
          sectionKey: 'cash',
          hint: 'Cari keterangan, nomor, atau referensi',
          choices: choices,
          maxDays: maxRangeDays,
          onChanged: (q, choice, from, to) => setState(() => _query = _build(q, choice, from, to)),
        ),
        Expanded(
          child: RecordListView<CashEntry>(
            provider: cashListProvider,
            query: _query,
            emptyTitle: 'Belum ada mutasi kas',
            emptyMessage: 'Uang masuk dan keluar di periode ini akan tampil di sini.',
            header: (context, state) {
              final header = CashBookHeader.fromJson(state.extra);
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${dateFromIso(header.from)} – ${dateFromIso(header.to)}', style: TextStyle(fontSize: 12, color: mutedText(context))),
                      AmountRow('Saldo awal', rupiah(header.opening)),
                      AmountRow('Uang masuk', rupiah(header.totalIn), color: successText(context)),
                      AmountRow('Uang keluar', rupiah(header.totalOut), color: dangerText(context)),
                      AmountRow('Saldo akhir', rupiah(header.closing), bold: true),
                    ]),
                  ),
                ),
                if (header.accounts.isNotEmpty)
                  SizedBox(
                    height: 44,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(children: [
                      ChoiceChip(
                        label: const Text('Semua akun'),
                        selected: _accountId == null,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() {
                          _accountId = null;
                          _query = _query.with_({'account_id': null});
                        }),
                      ),
                      for (final account in header.accounts) ...[
                        const SizedBox(width: 6),
                        ChoiceChip(
                          key: Key('cash-account-${account.id}'),
                          label: Text('${account.name} · ${compactRupiah(account.closing)}'),
                          selected: _accountId == account.id,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(() {
                            _accountId = account.id;
                            _query = _query.with_({'account_id': '${account.id}'});
                          }),
                        ),
                      ],
                      ]),
                    ),
                  ),
                const SizedBox(height: 8),
              ]);
            },
            itemBuilder: (context, entry) => _CashTile(entry),
          ),
        ),
      ]);
}

class _CashTile extends StatelessWidget {
  const _CashTile(this.entry);

  final CashEntry entry;

  String? get _route => switch ((entry.sourceType, entry.sourceId)) {
        ('sale', final int id) => '/catatan/penjualan/$id',
        ('payment_in', final int id) => '/catatan/pembayaran/in/$id',
        ('purchase', final int id) => '/catatan/pembelian/$id',
        ('payment_out', final int id) => '/catatan/pembayaran/out/$id',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final color = entry.incoming ? successText(context) : dangerText(context);
    final route = _route;
    return ListTile(
      key: Key('cash-${entry.id}'),
      onTap: route == null ? null : () => context.push(route),
      title: Text(entry.description ?? entry.sourceLabel, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      subtitle: Text('${dateFromIso(entry.date)} · ${entry.account?.name ?? ''}${entry.counterpart == null ? '' : ' ↔ ${entry.counterpart}'}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('${entry.incoming ? '+' : '-'}${rupiah(entry.amount)}', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: color)),
        Text('saldo ${compactRupiah(entry.balance)}', style: TextStyle(fontSize: 11, color: mutedText(context))),
      ]),
    );
  }
}

class _StockSection extends ConsumerStatefulWidget {
  const _StockSection({this.lowOnly = false});

  final bool lowOnly;

  @override
  ConsumerState<_StockSection> createState() => _StockSectionState();
}

class _StockSectionState extends ConsumerState<_StockSection> {
  static const choices = [
    FilterChoice('Semua'),
    FilterChoice('Menipis/habis', {'low': '1'}),
    FilterChoice('Paling sedikit', {'sort': 'quantity'}),
  ];
  late RecordQuery _query = RecordQuery(RecordSection.stock, widget.lowOnly ? const {'low': '1'} : const {});

  @override
  Widget build(BuildContext context) => Column(children: [
        RecordFilterBar(
          sectionKey: 'stock',
          hint: 'Cari nama atau SKU barang',
          choices: choices,
          selected: widget.lowOnly ? 1 : 0,
          withDates: false,
          onChanged: (q, choice, _, __) => setState(() => _query = RecordQuery(RecordSection.stock, {'q': q, ...choices[choice].params})),
        ),
        Expanded(
          child: RecordListView<StockLevel>(
            provider: stockListProvider,
            query: _query,
            emptyTitle: 'Belum ada barang berstok',
            emptyMessage: 'Hanya barang yang stoknya dilacak yang tampil di sini.',
            header: (context, state) {
              final low = state.extra['low_count'];
              return low is int && low > 0
                  ? Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('$low barang menipis/habis', style: TextStyle(fontWeight: FontWeight.w600, color: warningText(context))))
                  : const SizedBox.shrink();
            },
            itemBuilder: (context, item) => ListTile(
              key: Key('stock-${item.id}'),
              onTap: () => context.push('/catatan/stok/${item.id}', extra: item),
              title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text('${item.sku ?? ''}${item.sku == null ? '' : ' · '}${item.warehouses.length} gudang · nilai ${compactRupiah(item.stockValue)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
              trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${qty(item.quantity)} ${item.unit}', style: TextStyle(fontWeight: FontWeight.w600, color: item.empty ? dangerText(context) : (item.low ? warningText(context) : null))),
                if (item.empty) Text('Habis', style: TextStyle(fontSize: 11, color: dangerText(context))) else if (item.low) Text('Menipis', style: TextStyle(fontSize: 11, color: warningText(context))),
              ]),
            ),
          ),
        ),
      ]);
}

class _CustomersSection extends ConsumerStatefulWidget {
  const _CustomersSection();

  @override
  ConsumerState<_CustomersSection> createState() => _CustomersSectionState();
}

class _CustomersSectionState extends ConsumerState<_CustomersSection> {
  static const choices = [
    FilterChoice('Semua'),
    FilterChoice('Ada piutang', {'has_receivable': '1'}),
    FilterChoice('Perlu ditagih', {'to_collect': '1'}),
    FilterChoice('Lewat jatuh tempo', {'overdue': '1'}),
  ];
  RecordQuery _query = RecordQuery(RecordSection.customers);

  @override
  Widget build(BuildContext context) => Column(children: [
        RecordFilterBar(
          sectionKey: 'customers',
          hint: 'Cari nama, telepon, atau email',
          choices: choices,
          withDates: false,
          onChanged: (q, choice, _, __) => setState(() => _query = RecordQuery(RecordSection.customers, {'q': q, ...choices[choice].params})),
        ),
        Expanded(
          child: RecordListView<CustomerRecord>(
            provider: customersListProvider,
            query: _query,
            emptyTitle: 'Belum ada pelanggan',
            itemBuilder: (context, customer) => ListTile(
              key: Key('customer-${customer.id}'),
              onTap: () => context.push('/catatan/pelanggan/${customer.id}'),
              title: Text(customer.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text('${customer.phone ?? 'tanpa telepon'} · ${customer.invoicesCount} nota', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
              trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(Money.isPositive(customer.receivable) ? rupiah(customer.receivable) : '-', style: TextStyle(fontWeight: FontWeight.w600, color: Money.isPositive(customer.receivable) ? warningText(context) : null)),
                if (customer.needsCollection) Text('Perlu ditagih', style: TextStyle(fontSize: 11, color: dangerText(context))) else if (Money.isPositive(customer.receivable)) Text('piutang', style: TextStyle(fontSize: 11, color: mutedText(context))),
              ]),
            ),
          ),
        ),
      ]);
}

class _SuppliersSection extends ConsumerStatefulWidget {
  const _SuppliersSection();

  @override
  ConsumerState<_SuppliersSection> createState() => _SuppliersSectionState();
}

class _SuppliersSectionState extends ConsumerState<_SuppliersSection> {
  static const choices = [
    FilterChoice('Semua'),
    FilterChoice('Ada hutang', {'has_payable': '1'}),
    FilterChoice('Lewat jatuh tempo', {'overdue': '1'}),
  ];
  RecordQuery _query = RecordQuery(RecordSection.suppliers);

  @override
  Widget build(BuildContext context) => Column(children: [
        RecordFilterBar(
          sectionKey: 'suppliers',
          hint: 'Cari nama pemasok',
          choices: choices,
          withDates: false,
          onChanged: (q, choice, _, __) => setState(() => _query = RecordQuery(RecordSection.suppliers, {'q': q, ...choices[choice].params})),
        ),
        Expanded(
          child: RecordListView<SupplierRecord>(
            provider: suppliersListProvider,
            query: _query,
            emptyTitle: 'Belum ada pemasok',
            itemBuilder: (context, supplier) => ListTile(
              key: Key('supplier-${supplier.id}'),
              onTap: () => context.push('/catatan/pemasok/${supplier.id}'),
              title: Text(supplier.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text('${supplier.phone ?? 'tanpa telepon'} · ${supplier.billsCount} tagihan', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
              trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(Money.isPositive(supplier.payable) ? rupiah(supplier.payable) : '-', style: TextStyle(fontWeight: FontWeight.w600, color: Money.isPositive(supplier.payable) ? warningText(context) : null)),
                if (supplier.overdueCount > 0) Text('${supplier.overdueCount} lewat jatuh tempo', style: TextStyle(fontSize: 11, color: dangerText(context))) else if (Money.isPositive(supplier.payable)) Text('hutang', style: TextStyle(fontSize: 11, color: mutedText(context))),
              ]),
            ),
          ),
        ),
      ]);
}
