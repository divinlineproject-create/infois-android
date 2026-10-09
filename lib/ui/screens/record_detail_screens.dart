import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../data/api_client.dart';
import '../../domain/record_models.dart';
import '../../state/printer_controller.dart';
import '../../state/records_state.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/report_widgets.dart';
import 'catatan_screen.dart';
import 'pay_screen.dart' show printMessage;

/// Kerangka layar rincian: judul, isi dari provider, galat ramah.
class _DetailScaffold<T> extends StatelessWidget {
  const _DetailScaffold({required this.title, required this.value, required this.onRetry, required this.builder, this.actions = const []});

  final String title;
  final AsyncValue<T?> value;
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) builder;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final data = value.valueOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis), actions: actions),
      body: data == null
          ? (value.hasError ? ReportProblem(error: value.error!, what: 'Catatan', onRetry: onRetry) : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(onRefresh: () async => onRetry(), child: builder(context, data)),
    );
  }
}

/// Kartu info berisi baris label–nilai.
class _InfoCard extends StatelessWidget {
  const _InfoCard({this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (title != null) ...[Text(title!, style: const TextStyle(fontWeight: FontWeight.w600)), const SizedBox(height: 6)],
              ...children,
            ]),
          ),
        ),
      );
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) => value == null || value!.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 110, child: Text(label, style: TextStyle(fontSize: 13, color: mutedText(context)))),
            Expanded(child: Text(value!, style: const TextStyle(fontSize: 13))),
          ]),
        );
}

/// Baris barang: nama, qty × harga, total.
class _LineRow extends StatelessWidget {
  const _LineRow(this.line);

  final SaleLine line;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(line.description, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
              Text(
                '${qty(line.quantity)} ${line.unit ?? ''} × ${rupiah(line.unitPrice)}${Money.isPositive(line.discountPercent) ? ' · diskon ${percentLabel(line.discountPercent)}%' : ''}${Money.isPositive(line.taxRate) ? ' · pajak ${percentLabel(line.taxRate)}%' : ''}${line.account == null ? '' : ' · ${line.account!.name}'}',
                style: TextStyle(fontSize: 12, color: mutedText(context)),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Text(rupiah(line.lineTotal), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        ]),
      );
}

/// Deretan lampiran (foto kecil / chip file) yang bisa dibuka.
class AttachmentStrip extends ConsumerWidget {
  const AttachmentStrip(this.attachments, {super.key});

  final List<RecordAttachment> attachments;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (attachments.isEmpty) {
      return const SizedBox.shrink();
    }
    return _InfoCard(title: 'Lampiran', children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final attachment in attachments)
          InkWell(
            key: Key('attachment-${attachment.index}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => context.push('/catatan/lampiran', extra: attachment),
            child: attachment.isImage && attachment.url != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 88,
                      height: 88,
                      child: ref.watch(recordAttachmentBytesProvider(attachment.url!)).when(
                            loading: () => const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                            error: (_, __) => Icon(Icons.broken_image_outlined, color: mutedText(context)),
                            data: (bytes) => Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 264),
                          ),
                    ),
                  )
                : Container(
                    padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Theme.of(context).dividerColor)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(attachment.kind == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.insert_drive_file_outlined, size: 20, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                    ]),
                  ),
          ),
      ]),
    ]);
  }
}

/// Simpan byte ke folder dokumen aplikasi; kembalikan jalurnya.
Future<String> saveToDocuments(String fileName, List<int> bytes) async {
  final directory = await getApplicationDocumentsDirectory();
  final folder = Directory(p.join(directory.path, 'infois'));
  await folder.create(recursive: true);
  final file = File(p.join(folder.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

String safeFileName(String name) => name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '').toLowerCase();

/// Rincian penjualan: barang, pembayaran, lampiran, cetak ulang struk,
/// kirim WhatsApp, unduh PDF, batalkan (bila berhak).
class SaleDetailScreen extends ConsumerStatefulWidget {
  const SaleDetailScreen({super.key, required this.id});

  final int id;

  @override
  ConsumerState<SaleDetailScreen> createState() => _SaleDetailScreenState();
}

class _SaleDetailScreenState extends ConsumerState<SaleDetailScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (error) {
      if (mounted) {
        showMessage(context, error.message, error: true);
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, friendlyError(error), error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _print() => _run(() async {
        final receipt = await ref.read(recordActionsProvider).receipt(widget.id);
        final result = await ref.read(printerProvider.notifier).printSale(receipt, reprint: true);
        if (mounted) {
          showMessage(context, printMessage(result.name), error: result != PrintResult.printed);
        }
      });

  Future<void> _pdf(SaleDetail sale) => _run(() async {
        final bytes = await ref.read(recordActionsProvider).salePdf(widget.id);
        final path = await saveToDocuments('${safeFileName(sale.summary.number)}.pdf', bytes);
        if (mounted) {
          showMessage(context, 'PDF tersimpan di $path. Buka lewat aplikasi Berkas di HP untuk membagikannya.');
        }
      });

  String _whatsappText(SaleDetail sale, String tenant) {
    final s = sale.summary;
    final lines = <String>[
      'Halo ${s.customer?.name ?? ''}'.trim(),
      'Berikut nota $tenant ${s.number} tanggal ${dateFromIso(s.date)}:',
      for (final line in sale.items) '- ${line.description} ${qty(line.quantity)} ${line.unit ?? ''} = ${rupiah(line.lineTotal)}',
      'Total: ${rupiah(s.total)}',
      if (Money.isPositive(s.balanceDue) && s.status != 'void') 'Belum dibayar: ${rupiah(s.balanceDue)}${s.dueDate == null ? '' : ' (jatuh tempo ${dateFromIso(s.dueDate!)})'}' else if (s.status != 'void') 'Status: Lunas',
      if (sale.verificationUrl != null) 'Cek keaslian nota: ${sale.verificationUrl}',
      'Terima kasih.',
    ];
    return lines.join('\n');
  }

  Future<void> _void(SaleDetail sale) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Batalkan penjualan?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${sale.summary.number} akan dibatalkan: stok kembali dan pembukuan dibalik. Tidak bisa diurungkan.'),
          const SizedBox(height: 12),
          TextField(key: const Key('void-reason'), controller: controller, autofocus: true, maxLength: 200, decoration: const InputDecoration(labelText: 'Alasan', hintText: 'Mis. salah input')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Kembali')),
          FilledButton(key: const Key('void-confirm'), style: FilledButton.styleFrom(backgroundColor: Brand.danger), onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Batalkan penjualan')),
        ],
      ),
    );
    if (reason == null) {
      return;
    }
    if (reason.isEmpty) {
      if (mounted) {
        showMessage(context, 'Isi alasan pembatalan.', error: true);
      }
      return;
    }
    await _run(() async {
      final message = await ref.read(recordActionsProvider).voidSale(widget.id, reason);
      if (mounted) {
        showMessage(context, message);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tenant = ref.watch(sessionProvider).valueOrNull?.tenant?.name ?? 'Infois';
    final hasPrinter = ref.watch(printerProvider).printer != null;
    return _DetailScaffold<SaleDetail>(
      title: 'Penjualan',
      value: ref.watch(saleDetailProvider(widget.id)),
      onRetry: () => ref.invalidate(saleDetailProvider(widget.id)),
      builder: (context, sale) {
        final s = sale.summary;
        return ListView(padding: const EdgeInsets.all(16), children: [
          _InfoCard(children: [
            Row(children: [
              Expanded(child: Text(s.number, key: const Key('sale-number'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
              StatusPill(s.statusLabel, color: statusColor(context, s.status)),
            ]),
            const SizedBox(height: 8),
            _Info('Tanggal', dateFromIso(s.date)),
            if (s.dueDate != null && s.outstanding) _Info('Jatuh tempo', dateFromIso(s.dueDate!)),
            _Info('Pelanggan', s.customer?.name ?? 'Pelanggan Umum'),
            if (s.customer?.phone != null) _Info('Telepon', s.customer!.phone),
            _Info('Kasir', s.cashier),
            if (s.device != null) _Info('HP kasir', s.device!.display),
            if (sale.warehouse != null) _Info('Gudang', sale.warehouse!.name),
            _Info('Sumber', _sourceLabel(s.source)),
            if (sale.notes != null && sale.notes!.isNotEmpty) _Info('Catatan', sale.notes),
            if (s.status == 'void') ...[
              const Divider(),
              Text('Dibatalkan ${sale.voidedAt == null ? '' : dateTimeLabel(sale.voidedAt!.toLocal())}${sale.voidReason == null ? '' : ' · ${sale.voidReason}'}', style: TextStyle(fontSize: 13, color: dangerText(context))),
            ],
          ]),
          _InfoCard(title: 'Barang', children: [
            for (final line in sale.items) _LineRow(line),
            const Divider(),
            AmountRow('Subtotal', rupiah(sale.subtotal)),
            if (Money.isPositive(sale.discountTotal)) AmountRow('Diskon', '-${rupiah(sale.discountTotal)}'),
            if (Money.isPositive(sale.taxTotal)) AmountRow('${sale.taxName}${sale.pricesIncludeTax ? ' (termasuk)' : ''}', rupiah(sale.taxTotal)),
            AmountRow('Total', rupiah(s.total), bold: true, large: true),
            AmountRow('Sudah dibayar', rupiah(s.amountPaid)),
            if (Money.isPositive(s.balanceDue) && s.status != 'void') AmountRow('Belum dibayar', rupiah(s.balanceDue), bold: true, color: warningText(context)),
          ]),
          if (sale.payments.isNotEmpty)
            _InfoCard(title: 'Pembayaran', children: [
              for (final payment in sale.payments)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  onTap: () => context.push('/catatan/pembayaran/${payment.kind}/${payment.id}'),
                  title: Text('${payment.methodLabel}${payment.account == null ? '' : ' · ${payment.account!.name}'}', style: const TextStyle(fontSize: 13)),
                  subtitle: Text('${dateFromIso(payment.date)}${payment.reference == null || payment.reference!.isEmpty ? '' : ' · ${payment.reference}'}', style: const TextStyle(fontSize: 12)),
                  trailing: Text(rupiah(payment.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ]),
          if (sale.creditNotes.isNotEmpty)
            _InfoCard(title: 'Retur', children: [
              for (final note in sale.creditNotes) AmountRow('${note.number} · ${dateFromIso(note.date)}${note.reason == null ? '' : ' · ${note.reason}'}', rupiah(note.total)),
            ]),
          AttachmentStrip(sale.attachments),
          if (s.status != 'draft') ...[
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('reprint'),
                  onPressed: _busy ? null : _print,
                  icon: const Icon(Icons.print_outlined),
                  label: Text(hasPrinter ? 'Cetak ulang struk' : 'Cetak struk'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('whatsapp'),
                  onPressed: _busy || s.status == 'void' ? null : () => copyText(context, _whatsappText(sale, tenant), message: 'Pesan struk disalin. Buka WhatsApp, pilih pelanggan, lalu tempel.'),
                  icon: const Icon(Icons.chat_outlined),
                  label: const Text('Kirim via WhatsApp'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            OutlinedButton.icon(key: const Key('pdf'), onPressed: _busy ? null : () => _pdf(sale), icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Unduh PDF nota')),
            if (!hasPrinter) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Belum ada printer. Atur di Akun › Printer.', style: TextStyle(fontSize: 12, color: mutedText(context)))),
            const SizedBox(height: 10),
            if (sale.canVoid)
              OutlinedButton.icon(
                key: const Key('void-sale'),
                style: OutlinedButton.styleFrom(foregroundColor: Brand.danger),
                onPressed: _busy ? null : () => _void(sale),
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Batalkan penjualan'),
              ),
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('Retur barang dilakukan lewat website Infois.', style: TextStyle(fontSize: 12, color: mutedText(context)))),
          ],
        ]);
      },
    );
  }

  static String _sourceLabel(String source) => switch (source) {
        'pos' => 'Kasir HP',
        'ai' => 'Tim AI',
        'telegram' => 'Telegram',
        _ => 'Website',
      };
}

/// Rincian pembayaran masuk/keluar.
class PaymentDetailScreen extends ConsumerWidget {
  const PaymentDetailScreen({super.key, required this.kind, required this.id});

  final String kind;
  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _DetailScaffold<PaymentRecord>(
        title: kind == 'in' ? 'Uang masuk' : 'Uang keluar',
        value: ref.watch(paymentDetailProvider('$kind:$id')),
        onRetry: () => ref.invalidate(paymentDetailProvider('$kind:$id')),
        builder: (context, payment) => ListView(padding: const EdgeInsets.all(16), children: [
          _InfoCard(children: [
            Text(rupiah(payment.amount), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: payment.incoming ? successText(context) : dangerText(context))),
            Text('${payment.methodLabel} · ${dateFromIso(payment.date)}', style: TextStyle(fontSize: 13, color: mutedText(context))),
            const SizedBox(height: 8),
            _Info(payment.incoming ? 'Dari' : 'Kepada', payment.party?.name),
            _Info('Akun', payment.account?.display),
            _Info('Referensi', payment.reference),
            if (Money.isPositive(payment.withholdingAmount)) _Info('Potongan pajak', '${rupiah(payment.withholdingAmount)}${payment.withholdingType == null ? '' : ' (${payment.withholdingType})'}'),
            if (payment.exchangeRate != null && payment.currency != 'IDR') _Info('Kurs', '${payment.currency} ${payment.exchangeRate}'),
            _Info('Jurnal', payment.journal?.name),
            _Info('Uang muka', payment.deposit?.name),
            if (payment.createdAt != null) _Info('Dicatat', dateTimeLabel(payment.createdAt!.toLocal())),
          ]),
          if (payment.document != null)
            Card(
              child: ListTile(
                key: const Key('payment-document'),
                leading: Icon(payment.document!.type == 'sale' ? Icons.receipt_long_outlined : Icons.shopping_bag_outlined),
                title: Text(payment.document!.number, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: Text(payment.document!.type == 'sale' ? 'Penjualan · ${saleStatusLabel(payment.document!.status ?? '')}' : 'Pembelian · ${saleStatusLabel(payment.document!.status ?? '')}', style: const TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(payment.document!.type == 'sale' ? '/catatan/penjualan/${payment.document!.id}' : '/catatan/pembelian/${payment.document!.id}'),
              ),
            ),
          const SizedBox(height: 12),
          AttachmentStrip(payment.attachments),
        ]),
      );
}

/// Rincian pembelian / tagihan pemasok (baca saja).
class PurchaseDetailScreen extends ConsumerWidget {
  const PurchaseDetailScreen({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _DetailScaffold<PurchaseDetail>(
        title: 'Pembelian',
        value: ref.watch(purchaseDetailProvider(id)),
        onRetry: () => ref.invalidate(purchaseDetailProvider(id)),
        builder: (context, purchase) {
          final s = purchase.summary;
          return ListView(padding: const EdgeInsets.all(16), children: [
            _InfoCard(children: [
              Row(children: [
                Expanded(child: Text(s.number, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                StatusPill(s.statusLabel, color: statusColor(context, s.status)),
              ]),
              const SizedBox(height: 8),
              _Info('Pemasok', s.supplier?.name),
              _Info('Nota pemasok', s.supplierReference),
              _Info('Tanggal', dateFromIso(s.date)),
              if (s.dueDate != null) _Info('Jatuh tempo', '${dateFromIso(s.dueDate!)}${s.overdueDays > 0 ? ' · lewat ${s.overdueDays} hari' : ''}'),
              if (purchase.warehouse != null) _Info('Gudang', purchase.warehouse!.name),
              if (purchase.notes != null && purchase.notes!.isNotEmpty) _Info('Catatan', purchase.notes),
              if (s.status == 'void') Text('Dibatalkan${purchase.voidReason == null ? '' : ' · ${purchase.voidReason}'}', style: TextStyle(fontSize: 13, color: dangerText(context))),
            ]),
            _InfoCard(title: 'Barang', children: [
              for (final line in purchase.items) _LineRow(line),
              const Divider(),
              AmountRow('Subtotal', rupiah(purchase.subtotal)),
              if (Money.isPositive(purchase.taxTotal)) AmountRow('Pajak', rupiah(purchase.taxTotal)),
              AmountRow('Total', rupiah(s.total), bold: true, large: true),
              AmountRow('Sudah dibayar', rupiah(s.amountPaid)),
              if (Money.isPositive(s.balanceDue) && s.status != 'void') AmountRow('Belum dibayar', rupiah(s.balanceDue), bold: true, color: warningText(context)),
            ]),
            if (purchase.payments.isNotEmpty)
              _InfoCard(title: 'Pembayaran', children: [
                for (final payment in purchase.payments)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    onTap: () => context.push('/catatan/pembayaran/${payment.kind}/${payment.id}'),
                    title: Text('${payment.methodLabel}${payment.account == null ? '' : ' · ${payment.account!.name}'}', style: const TextStyle(fontSize: 13)),
                    subtitle: Text(dateFromIso(payment.date), style: const TextStyle(fontSize: 12)),
                    trailing: Text(rupiah(payment.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
              ]),
            if (purchase.debitNotes.isNotEmpty)
              _InfoCard(title: 'Retur ke pemasok', children: [
                for (final note in purchase.debitNotes) AmountRow('${note.number} · ${dateFromIso(note.date)}', rupiah(note.total)),
              ]),
            AttachmentStrip(purchase.attachments),
            Text('Pembelian dicatat dan diubah lewat website atau Tim AI.', style: TextStyle(fontSize: 12, color: mutedText(context))),
          ]);
        },
      );
}

/// Rincian pelanggan: piutang, nota belum lunas, kirim tagihan.
class CustomerDetailScreen extends ConsumerWidget {
  const CustomerDetailScreen({super.key, required this.id});

  final int id;

  String _billText(CustomerRecord customer, String tenant) => [
        'Halo ${customer.name},',
        'Berikut tagihan dari $tenant yang belum lunas:',
        for (final sale in customer.outstandingInvoices) '- ${sale.number} (${dateFromIso(sale.date)}): ${rupiah(sale.balanceDue)}${sale.dueDate == null ? '' : ', jatuh tempo ${dateFromIso(sale.dueDate!)}'}',
        'Total: ${rupiah(customer.receivable)}',
        'Mohon konfirmasi bila sudah dibayar. Terima kasih.',
      ].join('\n');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tenant = ref.watch(sessionProvider).valueOrNull?.tenant?.name ?? 'Infois';
    return _DetailScaffold<CustomerRecord>(
      title: 'Pelanggan',
      value: ref.watch(customerDetailProvider(id)),
      onRetry: () => ref.invalidate(customerDetailProvider(id)),
      builder: (context, customer) => ListView(padding: const EdgeInsets.all(16), children: [
        _InfoCard(children: [
          Text(customer.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _Info('Kontak', customer.contactPerson),
          _Info('Telepon', customer.phone),
          _Info('Email', customer.email),
          _Info('Alamat', customer.address),
          _Info('NPWP', customer.npwp),
          _Info('Catatan', customer.notes),
          const Divider(),
          AmountRow('Piutang', rupiah(customer.receivable), bold: true, color: Money.isPositive(customer.receivable) ? warningText(context) : null),
          AmountRow('Nota belum lunas', '${customer.outstandingCount}'),
          if (customer.overdueCount > 0) AmountRow('Lewat jatuh tempo', '${customer.overdueCount}', color: dangerText(context)),
          if (Money.isPositive(customer.depositsAvailable)) AmountRow('Uang muka tersedia', rupiah(customer.depositsAvailable)),
          AmountRow('Total nota', '${customer.invoicesCount}'),
        ]),
        if (customer.outstandingInvoices.isNotEmpty) ...[
          FilledButton.icon(
            key: const Key('send-bill'),
            onPressed: () => copyText(context, _billText(customer, tenant), message: 'Pesan tagihan disalin. Buka WhatsApp, pilih pelanggan, lalu tempel.'),
            icon: const Icon(Icons.chat_outlined),
            label: const Text('Kirim tagihan via WhatsApp'),
          ),
          const SectionTitle('Nota belum lunas'),
          Card(
            child: Column(children: [
              for (final (index, sale) in customer.outstandingInvoices.indexed) ...[
                if (index > 0) const Divider(height: 1),
                SaleListTile(sale),
              ],
            ]),
          ),
        ],
        if (customer.lastPayment != null) ...[
          const SectionTitle('Pembayaran terakhir'),
          Card(child: PaymentListTile(customer.lastPayment!)),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/catatan/bagian/sales?customer_id=${customer.id}'),
          icon: const Icon(Icons.receipt_long_outlined),
          label: const Text('Semua nota pelanggan ini'),
        ),
      ]),
    );
  }
}

/// Rincian pemasok: hutang dan tagihan belum lunas.
class SupplierDetailScreen extends ConsumerWidget {
  const SupplierDetailScreen({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _DetailScaffold<SupplierRecord>(
        title: 'Pemasok',
        value: ref.watch(supplierDetailProvider(id)),
        onRetry: () => ref.invalidate(supplierDetailProvider(id)),
        builder: (context, supplier) => ListView(padding: const EdgeInsets.all(16), children: [
          _InfoCard(children: [
            Text(supplier.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            _Info('Kontak', supplier.contactPerson),
            _Info('Telepon', supplier.phone),
            _Info('Email', supplier.email),
            _Info('Alamat', supplier.address),
            _Info('Rekening', supplier.bankInfo),
            _Info('NPWP', supplier.npwp),
            _Info('Catatan', supplier.notes),
            const Divider(),
            AmountRow('Hutang', rupiah(supplier.payable), bold: true, color: Money.isPositive(supplier.payable) ? warningText(context) : null),
            AmountRow('Tagihan belum lunas', '${supplier.outstandingCount}'),
            if (supplier.overdueCount > 0) AmountRow('Lewat jatuh tempo', '${supplier.overdueCount}', color: dangerText(context)),
            if (Money.isPositive(supplier.depositsAvailable)) AmountRow('Uang muka tersedia', rupiah(supplier.depositsAvailable)),
            AmountRow('Total tagihan', '${supplier.billsCount}'),
          ]),
          if (supplier.outstandingBills.isNotEmpty) ...[
            const SectionTitle('Tagihan belum lunas'),
            Card(
              child: Column(children: [
                for (final (index, bill) in supplier.outstandingBills.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  PurchaseListTile(bill),
                ],
              ]),
            ),
          ],
          if (supplier.lastPayment != null) ...[
            const SectionTitle('Pembayaran terakhir'),
            Card(child: PaymentListTile(supplier.lastPayment!)),
          ],
        ]),
      );
}

/// Kartu stok satu barang: stok per gudang + mutasi terakhir.
class StockItemScreen extends ConsumerStatefulWidget {
  const StockItemScreen({super.key, required this.productId, this.item});

  final int productId;
  final StockLevel? item;

  @override
  ConsumerState<StockItemScreen> createState() => _StockItemScreenState();
}

class _StockItemScreenState extends ConsumerState<StockItemScreen> {
  late RecordQuery _query = RecordQuery(RecordSection.stock, {'product_id': '${widget.productId}'});

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Scaffold(
      appBar: AppBar(title: Text(item?.name ?? 'Kartu stok', overflow: TextOverflow.ellipsis)),
      body: Column(children: [
        RecordFilterBar(
          sectionKey: 'movements',
          hint: 'Cari keterangan mutasi',
          choices: const [
            FilterChoice('Semua'),
            FilterChoice('Masuk', {'type': 'purchase,adjustment,sale_return,transfer_in,production_in'}),
            FilterChoice('Keluar', {'type': 'sale,purchase_return,transfer_out,production_out'}),
          ],
          onChanged: (q, choice, from, to) => setState(() => _query = RecordQuery(RecordSection.stock, {
                'product_id': '${widget.productId}',
                'q': q,
                ...const [
                  <String, String?>{},
                  {'type': 'purchase,adjustment,sale_return,transfer_in,production_in'},
                  {'type': 'sale,purchase_return,transfer_out,production_out'},
                ][choice],
                'from': from == null ? null : isoDate(from),
                'to': to == null ? null : isoDate(to),
              })),
        ),
        Expanded(
          child: RecordListView<StockMovement>(
            provider: stockMovementsProvider,
            query: _query,
            emptyTitle: 'Belum ada mutasi',
            emptyMessage: 'Pembelian, penjualan, dan opname barang ini akan tampil di sini.',
            header: item == null
                ? null
                : (context, _) => _InfoCard(children: [
                      Row(children: [
                        Expanded(child: Text(item.sku ?? '', style: TextStyle(fontSize: 12, color: mutedText(context)))),
                        if (item.empty) StatusPill('Habis', color: dangerText(context)) else if (item.low) StatusPill('Menipis', color: warningText(context)),
                      ]),
                      Text('${qty(item.quantity)} ${item.unit}', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: item.empty ? dangerText(context) : (item.low ? warningText(context) : null))),
                      if (item.minimumStock != null) Text('Stok minimum ${qty(item.minimumStock)} ${item.unit}', style: TextStyle(fontSize: 12, color: mutedText(context))),
                      const Divider(),
                      for (final warehouse in item.warehouses) AmountRow(warehouse.name, '${qty(warehouse.quantity)} ${item.unit}'),
                      const Divider(),
                      AmountRow('Harga jual', rupiah(item.price)),
                      AmountRow('Harga pokok rata-rata', rupiah(item.averageCost)),
                      AmountRow('Nilai stok', rupiah(item.stockValue), bold: true),
                    ]),
            itemBuilder: (context, movement) {
              final color = movement.incoming ? successText(context) : dangerText(context);
              final route = switch ((movement.reference?.type, movement.reference?.id)) {
                ('sale', final int id) => '/catatan/penjualan/$id',
                ('purchase', final int id) => '/catatan/pembelian/$id',
                _ => null,
              };
              return ListTile(
                key: Key('movement-${movement.id}'),
                onTap: route == null ? null : () => context.push(route),
                title: Text('${movement.typeLabel}${movement.reference == null ? '' : ' · ${movement.reference!.number}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                subtitle: Text('${dateFromIso(movement.date)}${movement.warehouse == null ? '' : ' · ${movement.warehouse!.name}'}${item == null && movement.product != null ? ' · ${movement.product!.name}' : ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${movement.incoming ? '+' : ''}${qty(movement.quantity)} ${movement.unit ?? ''}', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: color)),
                  Text('sisa ${qty(movement.balanceQuantity)}', style: TextStyle(fontSize: 11, color: mutedText(context))),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Lampiran dokumen: foto layar penuh, atau unduh file PDF/lainnya.
class AttachmentScreen extends ConsumerStatefulWidget {
  const AttachmentScreen({super.key, required this.attachment});

  final RecordAttachment attachment;

  @override
  ConsumerState<AttachmentScreen> createState() => _AttachmentScreenState();
}

class _AttachmentScreenState extends ConsumerState<AttachmentScreen> {
  bool _busy = false;

  Future<void> _download() async {
    final url = widget.attachment.url;
    if (url == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await ref.read(recordAttachmentBytesProvider(url).future);
      final path = await saveToDocuments(safeFileName(widget.attachment.name), bytes);
      if (mounted) {
        showMessage(context, 'Tersimpan di $path. Buka lewat aplikasi Berkas di HP.');
      }
    } on ApiException catch (error) {
      if (mounted) {
        showMessage(context, error.message, error: true);
      }
    } catch (error) {
      if (mounted) {
        debugPrint('Lampiran gagal disimpan: $error');
        showMessage(context, 'Berkas belum bisa disimpan di HP. Coba lagi.', error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    final url = attachment.url;
    return Scaffold(
      appBar: AppBar(
        title: Text(attachment.name, overflow: TextOverflow.ellipsis),
        actions: [IconButton(tooltip: 'Unduh', icon: const Icon(Icons.download_outlined), onPressed: _busy || url == null ? null : _download)],
      ),
      body: url == null
          ? const EmptyState(icon: Icons.broken_image_outlined, title: 'Lampiran tidak tersedia')
          : attachment.isImage
              ? ref.watch(recordAttachmentBytesProvider(url)).when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (error, _) => ReportProblem(error: error, what: 'Lampiran', onRetry: () => ref.invalidate(recordAttachmentBytesProvider(url))),
                    data: (bytes) => Container(color: Colors.black, child: InteractiveViewer(child: Center(child: Image.memory(bytes, fit: BoxFit.contain, semanticLabel: 'Foto ${attachment.name}')))),
                  )
              : EmptyState(
                  icon: attachment.kind == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.insert_drive_file_outlined,
                  title: attachment.name,
                  message: 'File ini tidak bisa ditampilkan langsung. Unduh lalu buka lewat aplikasi Berkas di HP.',
                  action: FilledButton.icon(onPressed: _busy ? null : _download, icon: const Icon(Icons.download_outlined), label: const Text('Unduh')),
                ),
    );
  }
}
