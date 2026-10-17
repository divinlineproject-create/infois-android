import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../state/pos_state.dart';
import '../theme.dart';

/// Catatan cepat yang sering dipakai kasir (ketuk untuk menambah).
const posQuickNotes = ['Tanpa gula', 'Sedikit gula', 'Tanpa es', 'Es sedikit', 'Pedas', 'Tidak pedas', 'Dibungkus'];

/// Chip catatan cepat: ketuk menambahkan teks ke [controller].
class PosNoteChips extends StatelessWidget {
  const PosNoteChips({super.key, required this.controller, this.onChanged});

  final TextEditingController controller;
  final VoidCallback? onChanged;

  void _append(String note) {
    final current = controller.text.trim();
    if (current.toLowerCase().contains(note.toLowerCase())) {
      return;
    }
    controller.text = current.isEmpty ? note : '$current, $note';
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final note in posQuickNotes)
          ActionChip(
            label: Text(note, style: const TextStyle(fontSize: 12.5)),
            visualDensity: VisualDensity.compact,
            onPressed: () => _append(note),
          ),
      ]);
}

/// Tekan lama barang: pilih satuan, jumlah, dan catatan sebelum masuk keranjang.
Future<void> showPosItemSheet(BuildContext context, Product product) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: PosItemSheet(product: product),
      ),
    );

class PosItemSheet extends ConsumerStatefulWidget {
  const PosItemSheet({super.key, required this.product});

  final Product product;

  @override
  ConsumerState<PosItemSheet> createState() => _PosItemSheetState();
}

class _PosItemSheetState extends ConsumerState<PosItemSheet> {
  late String _unit = widget.product.optionFor(null).name;
  String _quantity = '1';
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _step(int delta) {
    final next = Money.add([_quantity, '$delta']);
    if (Money.isPositive(next)) {
      setState(() => _quantity = Money.normalize(next, 0));
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final options = product.unitOptions();
    final price = product.priceFor(_unit, _quantity);
    final lineTotal = Money.mul(price, _quantity);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(product.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text('${rupiah(price)} / $_unit${product.isRawMaterial ? ' · ${product.kindLabel ?? 'Bahan baku'}' : ''}', style: TextStyle(color: mutedText(context))),
          if (options.length > 1) ...[
            const SizedBox(height: 16),
            const Text('Satuan', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final option in options)
                ChoiceChip(
                  key: Key('item-unit-${option.name}'),
                  label: Text(Money.compare(option.factor, '1') == 0 ? option.name : '${option.name} (isi ${qty(option.factor)})'),
                  selected: option.name == _unit,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _unit = option.name),
                ),
            ]),
          ],
          const SizedBox(height: 16),
          Row(children: [
            const Expanded(child: Text('Jumlah', style: TextStyle(fontWeight: FontWeight.w600))),
            IconButton.outlined(key: const Key('item-qty-minus'), onPressed: () => _step(-1), icon: const Icon(Icons.remove)),
            SizedBox(width: 56, child: Text(qty(_quantity), key: const Key('item-qty'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
            IconButton.filledTonal(key: const Key('item-qty-plus'), onPressed: () => _step(1), icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 16),
          TextField(
            key: const Key('item-note'),
            controller: _note,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Catatan barang (opsional)', hintText: 'mis. tanpa gula, less ice', counterText: ''),
          ),
          const SizedBox(height: 8),
          PosNoteChips(controller: _note),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('item-add'),
            onPressed: () {
              ref.read(cartProvider.notifier).add(product, unit: _unit, quantity: _quantity, note: _note.text);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: Text('Tambah · ${rupiah(lineTotal)}'),
          ),
          if (product.tiers.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Harga grosir otomatis mengikuti jumlah.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: mutedText(context))),
          ],
          if (product.trackInventory && product.stockQuantity != null && !Money.isPositive(product.stockQuantity)) ...[
            const SizedBox(height: 8),
            Text('Stok tercatat habis.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: warningText(context))),
          ],
        ]),
      ),
    );
  }
}

/// Warna aksen untuk teks catatan barang di keranjang.
Color noteColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);

/// Teks catatan barang kecil (ikon + miring) di bawah nama barang.
class PosNoteText extends StatelessWidget {
  const PosNoteText(this.note, {super.key});

  final String note;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.sticky_note_2_outlined, size: 14, color: noteColor(context)),
          const SizedBox(width: 4),
          Expanded(child: Text(note, style: TextStyle(fontSize: 12.5, fontStyle: FontStyle.italic, color: noteColor(context)))),
        ]),
      );
}
