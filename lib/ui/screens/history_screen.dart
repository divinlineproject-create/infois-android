import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../state/printer_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'pay_screen.dart';

(String, Color) saleSyncLabel(String? status) => switch (status) {
      'terkirim' => ('Terkirim', Brand.green),
      'perlu_ditinjau' => ('Perlu ditinjau', Brand.amber),
      'ditolak' => ('Ditolak server', Brand.danger),
      _ => ('Menunggu kirim', Colors.blueGrey),
    };

/// Riwayat nota di HP ini: status sinkron dan cetak ulang struk.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(recentSalesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Riwayat nota')),
      body: sales.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(plainError(error, fallback: 'Riwayat nota belum bisa dibuka. Coba lagi.'))),
        data: (items) => items.isEmpty
            ? const EmptyState(icon: Icons.receipt_long_outlined, title: 'Belum ada penjualan di HP ini')
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final sale = items[index];
                  final (label, color) = saleSyncLabel(sale['sync_status'] as String?);
                  final createdAt = DateTime.tryParse(sale['created_at']?.toString() ?? '')?.toLocal();
                  return ListTile(
                    title: Text(sale['number']?.toString() ?? 'Menunggu nomor', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${createdAt == null ? '' : dateTimeLabel(createdAt)} · ${sale['customer_name'] ?? ''}'),
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(rupiah(sale['total']), style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(label, style: TextStyle(fontSize: 12, color: color)),
                    ]),
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (context) => _SaleDetail(sale: sale),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _SaleDetail extends ConsumerWidget {
  const _SaleDetail({required this.sale});

  final Map<String, dynamic> sale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (label, color) = saleSyncLabel(sale['sync_status'] as String?);
    final unpaid = Money.sub(sale['total'], sale['paid']);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(sale['number']?.toString() ?? 'Menunggu nomor', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          if (sale['sync_message'] != null) Text(sale['sync_message'].toString(), style: const TextStyle(fontSize: 13)),
          const Divider(height: 24),
          for (final item in (sale['items'] as List? ?? const []))
            AmountRow('${item['description']} · ${qty(item['quantity'])} ${item['unit'] ?? ''}', rupiah(item['line_total'])),
          const Divider(height: 24),
          AmountRow('Total', rupiah(sale['total']), bold: true),
          for (final payment in (sale['payments'] as List? ?? const []))
            AmountRow(payment['method'] == 'cash' ? 'Tunai' : 'Transfer', rupiah(payment['amount'])),
          if (Money.isPositive(unpaid)) AmountRow('Belum dibayar', rupiah(unpaid), color: Brand.amber),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () async {
              final result = await ref.read(printerProvider.notifier).printSale(sale, reprint: true);
              if (context.mounted) {
                showMessage(context, printMessage(result.name), error: result != PrintResult.printed);
              }
            },
            icon: const Icon(Icons.print_outlined),
            label: const Text('Cetak ulang struk'),
          ),
        ]),
      ),
    );
  }
}
