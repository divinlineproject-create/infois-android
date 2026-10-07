import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/cart.dart';
import '../../domain/models.dart';
import '../../state/pos_state.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'customer_picker.dart';

Future<void> showCartSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => const FractionallySizedBox(heightFactor: 0.92, child: CartSheet()),
    );

/// Keranjang: ubah jumlah/satuan/harga/diskon, pilih pelanggan, lalu Bayar.
class CartSheet extends ConsumerWidget {
  const CartSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final master = ref.watch(masterDataProvider).valueOrNull;
    final inclusive = master?.tenant.pricesIncludeTax ?? false;
    final totals = cart.totals(pricesIncludeTax: inclusive);
    final notifier = ref.read(cartProvider.notifier);

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
        child: Row(children: [
          Expanded(child: Text('Keranjang', overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
          if (!cart.isEmpty)
            IconButton(
              tooltip: 'Kosongkan keranjang',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Kosongkan keranjang?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kosongkan')),
                    ],
                  ),
                );
                if (ok == true) {
                  notifier.clear();
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                }
              },
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ]),
      ),
      Expanded(
        child: cart.isEmpty
            ? const EmptyState(icon: Icons.shopping_basket_outlined, title: 'Keranjang kosong')
            : ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                for (final line in cart.lines) _LineTile(line: line, amounts: cart.amountsFor(line, pricesIncludeTax: inclusive)),
                const Divider(height: 24),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline),
                  title: Text(cart.customer?.name ?? 'Pelanggan umum'),
                  subtitle: const Text('Wajib dipilih bila bayar nanti (bon)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final customer = await pickCustomer(context, ref);
                    if (customer != null) {
                      notifier.setCustomer(customer.isWalkIn ? null : customer);
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.local_offer_outlined),
                  title: Text(Money.isPositive(cart.notaDiscountPercent) ? 'Diskon nota ${percentLabel(cart.notaDiscountPercent)}%' : 'Diskon nota'),
                  subtitle: const Text('Berlaku untuk semua barang'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final value = await askPercent(context, 'Diskon nota (%)', cart.notaDiscountPercent);
                    if (value != null) {
                      notifier.setNotaDiscount(value);
                    }
                  },
                ),
                const SizedBox(height: 8),
                AmountRow('Subtotal', rupiah(totals.subtotal)),
                if (Money.isPositive(totals.discountTotal)) AmountRow('Diskon', '-${rupiah(totals.discountTotal)}'),
                if (Money.isPositive(totals.taxTotal)) AmountRow('${master?.tenant.salesTaxName ?? 'PPN'}${inclusive ? ' (termasuk)' : ''}', rupiah(totals.taxTotal)),
                AmountRow('Total', rupiah(totals.total), bold: true, large: true),
                const SizedBox(height: 16),
              ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            key: const Key('go-pay'),
            onPressed: cart.isEmpty || !Money.isPositive(totals.total)
                ? null
                : () {
                    Navigator.pop(context);
                    context.push('/bayar');
                  },
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: Text('Bayar ${rupiah(totals.total)}'),
          ),
        ),
      ),
    ]);
  }
}

class _LineTile extends ConsumerWidget {
  const _LineTile({required this.line, required this.amounts});

  final CartLine line;
  final LineAmounts amounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(cartProvider.notifier);
    final discount = amounts.discountPercent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: InkWell(
            onTap: () => showLineEditor(context, ref, line),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(line.description, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                '${qty(line.quantity)} ${line.unit} × ${rupiah(line.unitPrice)}${Money.isPositive(discount) ? ' · diskon ${percentLabel(discount)}%' : ''}',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
              Text(rupiah(amounts.lineTotal), style: const TextStyle(fontWeight: FontWeight.w600, color: Brand.green)),
            ]),
          ),
        ),
        IconButton(
          tooltip: 'Kurangi',
          onPressed: () {
            final next = Money.sub(line.quantity, '1');
            if (Money.isPositive(next)) {
              notifier.update(line.key, (current) => current.copyWith(quantity: next));
            } else {
              notifier.remove(line.key);
            }
          },
          icon: const Icon(Icons.remove_circle_outline),
        ),
        GestureDetector(
          onTap: () => showLineEditor(context, ref, line),
          child: SizedBox(width: 44, child: Text(qty(line.quantity), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
        ),
        IconButton(
          key: Key('plus-${line.key}'),
          tooltip: 'Tambah',
          onPressed: () => notifier.update(line.key, (current) => current.copyWith(quantity: Money.add([current.quantity, '1']))),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ]),
    );
  }
}

/// Ubah satu baris: jumlah (boleh desimal), satuan, harga, diskon.
Future<void> showLineEditor(BuildContext context, WidgetRef ref, CartLine line) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _LineEditor(line: line),
      ),
    );

class _LineEditor extends ConsumerStatefulWidget {
  const _LineEditor({required this.line});

  final CartLine line;

  @override
  ConsumerState<_LineEditor> createState() => _LineEditorState();
}

class _LineEditorState extends ConsumerState<_LineEditor> {
  late final TextEditingController _quantity = TextEditingController(text: qty(widget.line.quantity).replaceAll('.', ''));
  late final TextEditingController _price = TextEditingController(text: rupiah(widget.line.unitPrice, symbol: false));
  late final TextEditingController _discount = TextEditingController(text: Money.isPositive(widget.line.discountPercent) ? percentLabel(widget.line.discountPercent) : '');
  late String _unit = widget.line.unit;
  bool _priceEdited = false;
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    _price.dispose();
    _discount.dispose();
    super.dispose();
  }

  void _save() {
    final quantity = parseQuantityInput(_quantity.text);
    if (quantity == null || !Money.isPositive(quantity)) {
      setState(() => _error = 'Jumlah harus lebih dari nol (maks. 6 angka di belakang koma).');
      return;
    }
    final discount = _discount.text.trim().isEmpty ? '0' : parseQuantityInput(_discount.text);
    if (discount == null || Money.compare(discount, '100') > 0 || Money.compare(discount, '0') < 0) {
      setState(() => _error = 'Diskon antara 0 dan 100%.');
      return;
    }
    final price = parseMoneyInput(_price.text);
    if (_priceEdited && (price == null || Money.compare(price, '0') < 0)) {
      setState(() => _error = 'Harga tidak valid.');
      return;
    }
    ref.read(cartProvider.notifier).update(
          widget.line.key,
          (line) => _priceEdited
              ? line.copyWith(quantity: quantity, unit: _unit, discountPercent: discount, unitPrice: price, manualPrice: true)
              : line.copyWith(quantity: quantity, unit: _unit, discountPercent: discount),
        );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.line.product;
    final options = product?.unitOptions() ?? const <UnitOption>[];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.line.description, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('line-quantity'),
                controller: _quantity,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                decoration: const InputDecoration(labelText: 'Jumlah'),
              ),
            ),
            if (options.length > 1) ...[
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _unit,
                  decoration: const InputDecoration(labelText: 'Satuan'),
                  items: [for (final option in options) DropdownMenuItem(value: option.name, child: Text(option.name))],
                  onChanged: (value) => setState(() => _unit = value ?? _unit),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _price,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'Harga satuan', prefixText: 'Rp ', helperText: _priceEdited ? 'Harga diubah manual' : 'Otomatis (harga grosir ikut jumlah)'),
                onChanged: (_) => setState(() => _priceEdited = true),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: TextField(
                controller: _discount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Diskon', suffixText: '%'),
              ),
            ),
          ]),
          if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: Brand.danger))],
          const SizedBox(height: 16),
          Row(children: [
            OutlinedButton.icon(
              onPressed: () {
                ref.read(cartProvider.notifier).remove(widget.line.key);
                Navigator.pop(context);
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Hapus'),
            ),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(key: const Key('line-save'), onPressed: _save, child: const Text('Simpan'))),
          ]),
        ]),
      ),
    );
  }
}

Future<String?> askPercent(BuildContext context, String title, String current) async {
  final controller = TextEditingController(text: Money.isPositive(current) ? percentLabel(current) : '');
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(suffixText: '%', hintText: '0'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Simpan')),
      ],
    ),
  );
  if (result == null) {
    return null;
  }
  final value = result.trim().isEmpty ? '0' : parseQuantityInput(result);
  if (value == null || Money.compare(value, '100') > 0 || Money.compare(value, '0') < 0) {
    return null;
  }
  return value;
}
