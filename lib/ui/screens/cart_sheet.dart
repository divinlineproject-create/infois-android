import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/cart.dart';
import '../../domain/models.dart';
import '../../state/pos_state.dart';
import '../theme.dart';
import 'pos_item_sheet.dart';
import 'pos_order_panel.dart';

Future<void> showCartSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => const FractionallySizedBox(heightFactor: 0.92, child: CartSheet()),
    );

/// Keranjang (HP): panel pesanan di lembar bawah, lalu Bayar.
class CartSheet extends StatelessWidget {
  const CartSheet({super.key});

  @override
  Widget build(BuildContext context) => PosOrderPanel(
        onClose: () {
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
          }
        },
        onPay: () {
          Navigator.pop(context);
          context.push('/bayar');
        },
      );
}

/// Ubah satu baris: jumlah (boleh desimal), satuan, harga, diskon, catatan.
Future<void> showLineEditor(BuildContext context, WidgetRef ref, CartLine line) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
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
  late final TextEditingController _note = TextEditingController(text: widget.line.note ?? '');
  late String _unit = widget.line.unit;
  bool _priceEdited = false;
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    _price.dispose();
    _discount.dispose();
    _note.dispose();
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
              ? line.copyWith(quantity: quantity, unit: _unit, discountPercent: discount, unitPrice: price, manualPrice: true, note: _note.text)
              : line.copyWith(quantity: quantity, unit: _unit, discountPercent: discount, note: _note.text),
        );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.line.product;
    final options = product?.unitOptions() ?? const <UnitOption>[];
    return SafeArea(
      child: SingleChildScrollView(
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
          const SizedBox(height: 12),
          TextField(
            key: const Key('line-note'),
            controller: _note,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Catatan barang', hintText: 'mis. tanpa gula, less ice', counterText: ''),
          ),
          const SizedBox(height: 8),
          PosNoteChips(controller: _note),
          if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: TextStyle(color: dangerText(context)))],
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
