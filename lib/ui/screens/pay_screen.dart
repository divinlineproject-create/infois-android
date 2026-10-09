import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../services/pos_service.dart';
import '../../state/pos_state.dart';
import '../../state/printer_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'customer_picker.dart';
import 'shift_screens.dart';

/// Nominal cepat untuk tunai: uang pas, pembulatan ke atas, 20rb/50rb/100rb.
List<String> quickCashAmounts(String total) {
  final whole = BigInt.parse(Money.normalize(total).split('.').first);
  final hasCents = !Money.normalize(total).endsWith('.00');
  final base = hasCents ? whole + BigInt.one : whole;
  BigInt ceilTo(int step) {
    final s = BigInt.from(step);
    return ((base + s - BigInt.one) ~/ s) * s;
  }

  final values = <BigInt>{
    base,
    ceilTo(1000),
    ceilTo(5000),
    ceilTo(10000),
    ceilTo(50000),
    ceilTo(100000),
    for (final note in [20000, 50000, 100000]) BigInt.from(note),
  }.where((value) => value >= base).toList()
    ..sort();
  return [for (final value in values.take(6)) Money.normalize(value.toString())];
}

/// Layar Bayar: tunai (kembalian), transfer (rekening tujuan), bon, campuran.
class PayScreen extends ConsumerStatefulWidget {
  const PayScreen({super.key});

  @override
  ConsumerState<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends ConsumerState<PayScreen> {
  /// Dibuat sekali per layar: bayar ditekan dua kali tetap satu nota.
  final String _clientUuid = PosService.newUuid();
  final _cash = TextEditingController();
  PayMode _mode = PayMode.cash;
  CashAccount? _account;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _cash.dispose();
    super.dispose();
  }

  Future<void> _pay(String total) async {
    if (_busy) {
      return;
    }
    final shift = await ref.read(openShiftProvider.future);
    final master = await ref.read(masterDataProvider.future);
    if ((master?.menus.shift ?? false) && shift == null) {
      if (!mounted) {
        return;
      }
      final opened = await showOpenShiftDialog(context, ref);
      if (!opened) {
        return;
      }
    }
    final cash = _mode == PayMode.cash ? (_cash.text.trim().isEmpty ? total : parseMoneyInput(_cash.text)) : parseMoneyInput(_cash.text);
    if ((_mode == PayMode.cash || _mode == PayMode.mixed) && cash == null) {
      setState(() => _error = 'Isi jumlah uang tunai.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await ref.read(posActionsProvider).checkout(
            clientUuid: _clientUuid,
            payment: PaymentInput(mode: _mode, cashReceived: cash, transferAccountId: _account?.id, transferAccountName: _account?.name),
          );
      if (mounted) {
        context.pushReplacement('/selesai', extra: {'sale': outcome.sale, 'print': outcome.print?.name});
      }
    } on CheckoutException catch (error) {
      setState(() => _error = error.message);
    } catch (error) {
      setState(() => _error = 'Penjualan belum tersimpan: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final master = ref.watch(masterDataProvider).valueOrNull;
    final inclusive = master?.tenant.pricesIncludeTax ?? false;
    final total = cart.totals(pricesIncludeTax: inclusive).total;
    final accounts = master?.transferAccounts ?? const <CashAccount>[];
    _account ??= accounts.where((account) => account.id == master?.defaultTransferId).firstOrNull ?? accounts.firstOrNull;
    final cashValue = parseMoneyInput(_cash.text);
    final change = _mode == PayMode.cash && cashValue != null && Money.compare(cashValue, total) >= 0 ? Money.sub(cashValue, total) : null;
    final transferPart = _mode == PayMode.mixed && cashValue != null ? Money.sub(total, cashValue) : null;
    final needsCustomer = _mode == PayMode.bon;

    return Scaffold(
      appBar: AppBar(title: const Text('Bayar')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              const Text('Total belanja'),
              const SizedBox(height: 4),
              Text(rupiah(total), key: const Key('pay-total'), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: Brand.green)),
              Text('${cart.itemCount} barang · ${cart.customer?.name ?? 'Pelanggan umum'}', style: TextStyle(color: mutedText(context))),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        SegmentedButton<PayMode>(
          segments: const [
            ButtonSegment(value: PayMode.cash, label: Text('Tunai'), icon: Icon(Icons.payments_outlined)),
            ButtonSegment(value: PayMode.transfer, label: Text('Transfer'), icon: Icon(Icons.account_balance_outlined)),
            ButtonSegment(value: PayMode.bon, label: Text('Bon'), icon: Icon(Icons.schedule_outlined)),
            ButtonSegment(value: PayMode.mixed, label: Text('Campur'), icon: Icon(Icons.call_split)),
          ],
          selected: {_mode},
          showSelectedIcon: false,
          onSelectionChanged: (value) => setState(() {
            _mode = value.first;
            _cash.clear();
            _error = null;
          }),
        ),
        const SizedBox(height: 20),
        if (_mode == PayMode.cash) ...[
          const Text('Uang diterima', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (index, amount) in quickCashAmounts(total).indexed)
              ActionChip(
                key: Key('quick-$index'),
                label: Text(index == 0 && Money.compare(amount, total) == 0 ? 'Uang pas' : rupiah(amount)),
                onPressed: () => setState(() => _cash.text = rupiah(amount, symbol: false)),
              ),
          ]),
          const SizedBox(height: 12),
          _MoneyField(controller: _cash, label: 'Jumlah uang (kosong = uang pas)', onChanged: () => setState(() {})),
          if (change != null) ...[
            const SizedBox(height: 16),
            Text('Kembalian', style: TextStyle(color: mutedText(context))),
            Text(rupiah(change), key: const Key('pay-change'), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          ],
        ],
        if (_mode == PayMode.transfer || _mode == PayMode.mixed) ...[
          if (_mode == PayMode.mixed) ...[
            _MoneyField(controller: _cash, label: 'Bagian tunai', onChanged: () => setState(() {})),
            if (transferPart != null && Money.isPositive(transferPart)) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Sisanya transfer: ${rupiah(transferPart)}')),
            const SizedBox(height: 16),
          ],
          DropdownButtonFormField<int>(
            value: _account?.id,
            decoration: const InputDecoration(labelText: 'Rekening tujuan transfer'),
            items: [for (final account in accounts) DropdownMenuItem(value: account.id, child: Text(account.name))],
            onChanged: (id) => setState(() => _account = accounts.firstWhere((account) => account.id == id)),
          ),
        ],
        if (needsCustomer) ...[
          const Text('Bon dicatat sebagai piutang pelanggan.'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final customer = await pickCustomer(context, ref);
              if (customer != null) {
                ref.read(cartProvider.notifier).setCustomer(customer.isWalkIn ? null : customer);
              }
            },
            icon: const Icon(Icons.person_outline),
            label: Text(cart.customer == null ? 'Pilih pelanggan' : 'Pelanggan: ${cart.customer!.name}'),
          ),
        ],
        if (_error != null) ...[const SizedBox(height: 16), Text(_error!, key: const Key('pay-error'), style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w500))],
        const SizedBox(height: 24),
        Consumer(builder: (context, ref, _) {
          final printer = ref.watch(printerProvider);
          return Text(
            printer.printer == null ? 'Belum ada printer. Struk bisa dicetak nanti dari riwayat.' : 'Struk dicetak otomatis ke ${printer.printer!.name}.',
            style: TextStyle(fontSize: 13, color: mutedText(context)),
          );
        }),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            key: const Key('pay-submit'),
            onPressed: _busy || cart.isEmpty ? null : () => _pay(total),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: _busy ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : Text(_mode == PayMode.bon ? 'Simpan bon' : 'Bayar'),
          ),
        ),
      ),
    );
  }
}

class _MoneyField extends StatelessWidget {
  const _MoneyField({required this.controller, required this.label, required this.onChanged});

  final TextEditingController controller;
  final String label;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
        key: const Key('pay-cash'),
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        decoration: InputDecoration(labelText: label, prefixText: 'Rp '),
        onChanged: (_) => onChanged(),
      );
}

/// Pesan hasil cetak untuk ditampilkan.
String printMessage(String? result) => switch (result) {
      'printed' => 'Struk tercetak.',
      'noPrinter' => 'Belum ada printer. Atur di Akun › Printer.',
      'failed' => 'Struk belum tercetak. Periksa printer lalu tekan Cetak ulang.',
      _ => '',
    };

/// Penjualan selesai: nomor nota, kembalian, cetak ulang, transaksi baru.
class SaleDoneScreen extends ConsumerWidget {
  const SaleDoneScreen({super.key, required this.sale, this.printResult});

  final Map<String, dynamic> sale;
  final String? printResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final change = sale['change']?.toString() ?? '0';
    final unpaid = Money.sub(sale['total'], sale['paid']);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Spacer(),
            const Icon(Icons.check_circle, size: 88, color: Brand.green),
            const SizedBox(height: 12),
            Text('Penjualan tersimpan', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(sale['number']?.toString() ?? 'Nomor nota menyusul saat sinkron', key: const Key('done-number')),
            const SizedBox(height: 24),
            AmountRow('Total', rupiah(sale['total']), bold: true),
            if (Money.isPositive(change)) AmountRow('Kembalian', rupiah(change), bold: true, large: true),
            if (Money.isPositive(unpaid)) AmountRow('Belum dibayar (bon)', rupiah(unpaid), bold: true, color: Brand.amber),
            const SizedBox(height: 16),
            if (printResult != null && printResult != 'printed') Text(printMessage(printResult), textAlign: TextAlign.center, style: const TextStyle(color: Brand.amber)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () async {
                final result = await ref.read(printerProvider.notifier).printSale(sale, reprint: printResult == 'printed');
                if (context.mounted) {
                  showMessage(context, printMessage(result.name), error: result != PrintResult.printed);
                }
              },
              icon: const Icon(Icons.print_outlined),
              label: Text(printResult == 'printed' ? 'Cetak ulang' : 'Cetak struk'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('new-sale'),
              onPressed: () => context.pop(),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              child: const Text('Transaksi baru'),
            ),
          ]),
        ),
      ),
    );
  }
}
