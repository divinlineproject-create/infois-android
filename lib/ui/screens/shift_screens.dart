import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../state/pos_state.dart';
import '../../state/printer_controller.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'pay_screen.dart';

/// Baris status shift di atas katalog.
class ShiftBar extends ConsumerWidget {
  const ShiftBar({super.key, required this.shift});

  final Map<String, dynamic>? shift;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (shift == null) {
      return Material(
        color: Brand.amber.withValues(alpha: 0.1),
        child: ListTile(
          leading: const Icon(Icons.lock_clock_outlined, color: Brand.amber),
          title: const Text('Kasir belum dibuka'),
          subtitle: const Text('Isi uang awal di laci sebelum mulai jualan.'),
          trailing: FilledButton(key: const Key('open-shift'), onPressed: () => showOpenShiftDialog(context, ref), child: const Text('Buka')),
        ),
      );
    }
    final opened = DateTime.tryParse(shift!['opened_at']?.toString() ?? '')?.toLocal();
    return Material(
      color: Brand.green.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(children: [
          const Icon(Icons.lock_open_outlined, size: 18, color: Brand.green),
          const SizedBox(width: 8),
          Expanded(child: Text('Kasir dibuka ${opened == null ? '' : dateTimeLabel(opened)}', style: const TextStyle(fontSize: 13))),
          TextButton(onPressed: () => context.push('/tutup-kasir'), child: const Text('Tutup kasir')),
        ]),
      ),
    );
  }
}

/// Buka kasir dengan uang awal. Kembalikan true bila shift dibuka.
Future<bool> showOpenShiftDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Buka kasir'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Berapa uang di laci sekarang?'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('opening-cash'),
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: const InputDecoration(prefixText: 'Rp ', hintText: '0'),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(key: const Key('opening-save'), onPressed: () => Navigator.pop(context, controller.text), child: const Text('Buka kasir')),
      ],
    ),
  );
  if (value == null) {
    return false;
  }
  final service = await ref.read(posServiceProvider.future);
  if (service == null) {
    return false;
  }
  await service.openShift(parseMoneyInput(value.isEmpty ? '0' : value) ?? '0');
  ref.read(dataVersionProvider.notifier).state++;
  await ref.read(syncProvider.notifier).refreshPending();
  ref.read(syncProvider.notifier).syncNow();
  return true;
}

/// Tutup kasir: hitung uang fisik, lihat selisih, cetak laporan.
class ShiftCloseScreen extends ConsumerStatefulWidget {
  const ShiftCloseScreen({super.key});

  @override
  ConsumerState<ShiftCloseScreen> createState() => _ShiftCloseScreenState();
}

class _ShiftCloseScreenState extends ConsumerState<ShiftCloseScreen> {
  final _counted = TextEditingController();
  Map<String, dynamic>? _summary;
  Map<String, dynamic>? _report;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _counted.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final shift = await ref.read(openShiftProvider.future);
    final service = await ref.read(posServiceProvider.future);
    if (shift == null || service == null) {
      return;
    }
    final summary = await service.shiftSummary(shift);
    if (mounted) {
      setState(() => _summary = summary);
    }
  }

  Future<void> _close() async {
    final counted = parseMoneyInput(_counted.text);
    if (counted == null) {
      showMessage(context, 'Isi jumlah uang di laci.', error: true);
      return;
    }
    setState(() => _busy = true);
    final shift = await ref.read(openShiftProvider.future);
    final service = await ref.read(posServiceProvider.future);
    if (shift == null || service == null) {
      return;
    }
    final report = await service.closeShift(shift, counted);
    ref.read(dataVersionProvider.notifier).state++;
    await ref.read(syncProvider.notifier).refreshPending();
    ref.read(syncProvider.notifier).syncNow();
    final printed = await ref.read(printerProvider.notifier).printShiftReport(report);
    if (!mounted) {
      return;
    }
    setState(() {
      _report = report;
      _busy = false;
    });
    if (printed != PrintResult.printed) {
      showMessage(context, printMessage(printed.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _report ?? _summary;
    final counted = parseMoneyInput(_counted.text);
    final difference = _report?['difference'] ?? (summary != null && counted != null ? Money.sub(counted, summary['expected_cash']) : null);
    return Scaffold(
      appBar: AppBar(title: Text(_report == null ? 'Tutup kasir' : 'Kasir ditutup')),
      body: summary == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    AmountRow('Jumlah nota', '${summary['sales_count']}'),
                    AmountRow('Total penjualan', rupiah(summary['sales_total'])),
                    AmountRow('Tunai', rupiah(summary['cash_total'])),
                    AmountRow('Transfer', rupiah(summary['transfer_total'])),
                    AmountRow('Bon (belum dibayar)', rupiah(summary['unpaid_total'])),
                    const Divider(),
                    AmountRow('Uang awal', rupiah(summary['opening_cash'])),
                    AmountRow('Seharusnya di laci', rupiah(summary['expected_cash']), bold: true),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              if (_report == null)
                TextField(
                  controller: _counted,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(labelText: 'Uang di laci (hitung fisik)', prefixText: 'Rp '),
                  onChanged: (_) => setState(() {}),
                ),
              if (difference != null) ...[
                const SizedBox(height: 16),
                AmountRow(
                  Money.isZero(difference) ? 'Pas, tidak ada selisih' : (Money.isPositive(difference) ? 'Lebih' : 'Kurang'),
                  rupiah(difference),
                  bold: true,
                  large: true,
                  color: Money.isZero(difference) ? Brand.green : Brand.amber,
                ),
              ],
              const SizedBox(height: 24),
              if (_report == null)
                FilledButton(onPressed: _busy ? null : _close, child: const Text('Tutup kasir & cetak laporan'))
              else ...[
                OutlinedButton.icon(
                  onPressed: () => ref.read(printerProvider.notifier).printShiftReport(_report!),
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Cetak ulang laporan'),
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => context.pop(), child: const Text('Selesai')),
              ],
            ]),
    );
  }
}
