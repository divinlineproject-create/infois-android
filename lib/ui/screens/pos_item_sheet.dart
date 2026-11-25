import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../services/product_photos.dart';
import '../../state/pos_state.dart';
import '../theme.dart';
import '../widgets/product_image.dart';

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

/// Ketuk barang yang punya satuan lain: pilih satuan yang dibeli (mis. pcs
/// atau karton isi 6) supaya kasir tidak menghitung isinya. Satu ketukan
/// menambah 1 satuan itu; "Atur jumlah & catatan" membuka lembar barang.
Future<void> showPosUnitPicker(BuildContext context, Product product) async {
  final details = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => PosUnitPicker(product: product),
  );
  if (details == true && context.mounted) {
    await showPosItemSheet(context, product);
  }
}

class PosUnitPicker extends ConsumerWidget {
  const PosUnitPicker({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final levelId = ref.watch(cartProvider.select((cart) => cart.levelId));
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(product.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          for (final option in product.unitOptions()) ...[
            OutlinedButton(
              key: Key('unit-pick-${option.name}'),
              onPressed: () {
                HapticFeedback.selectionClick();
                ref.read(cartProvider.notifier).add(product, unit: option.name);
                Navigator.pop(context, false);
              },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                padding: const EdgeInsets.symmetric(horizontal: Space.l),
                foregroundColor: scheme.onSurface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.m)),
              ),
              child: Row(children: [
                Expanded(child: Text(product.unitLabel(option), style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600))),
                const SizedBox(width: Space.s),
                Text(rupiah(product.priceFor(option.name, '1', levelId: levelId)), style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: scheme.primary)),
              ]),
            ),
            const SizedBox(height: Space.s),
          ],
          const SizedBox(height: Space.s),
          OutlinedButton(
            key: const Key('unit-pick-details'),
            onPressed: () => Navigator.pop(context, true),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('Atur jumlah & catatan'),
          ),
        ]),
      ),
    );
  }
}

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
    final customer = ref.watch(cartProvider.select((cart) => cart.customer));
    final quote = product.quoteFor(_unit, _quantity, levelId: customer?.levelId);
    final price = quote.price;
    final lineTotal = Money.mul(price, _quantity);
    final tiers = product.tiersFor(_unit, levelId: customer?.levelId);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (product.hasPhoto) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.l),
              child: SizedBox(height: 180, child: ProductImage(key: const Key('item-photo'), product: product, size: PhotoSize.full, initialsSize: 44)),
            ),
            const SizedBox(height: Space.m),
          ],
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!product.hasPhoto) ...[
              ClipRRect(borderRadius: BorderRadius.circular(Radii.m), child: SizedBox(width: 64, height: 64, child: ProductPlaceholder(name: product.name, fontSize: 20))),
              const SizedBox(width: Space.m),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (product.categoryName != null)
                  Text(product.categoryName!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: mutedText(context))),
                Text(product.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text.rich(TextSpan(children: [
                  TextSpan(text: rupiah(price), style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
                  TextSpan(text: ' / $_unit${product.isRawMaterial ? ' · ${product.kindLabel ?? 'Bahan baku'}' : ''}', style: TextStyle(color: mutedText(context))),
                ])),
                if (product.trackInventory && product.stockQuantity != null)
                  Text('Stok ${qty(product.stockQuantity!)} ${product.unit}', style: TextStyle(fontSize: 12.5, color: product.isLowStock() ? warningText(context) : mutedText(context))),
              ]),
            ),
          ]),
          if (options.length > 1) ...[
            const SizedBox(height: 16),
            const Text('Satuan', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final option in options)
                ChoiceChip(
                  key: Key('item-unit-${option.name}'),
                  label: Text(product.unitLabel(option)),
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
          if (tiers.isNotEmpty) ...[
            const SizedBox(height: 16),
            PosPriceTiers(option: product.optionFor(_unit), tiers: tiers, quote: quote, fallbackLevel: customer?.level),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const Key('item-note'),
            controller: _note,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Catatan barang (opsional)', hintText: posNoteHint, counterText: ''),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('item-add'),
            onPressed: () {
              HapticFeedback.mediumImpact();
              ref.read(cartProvider.notifier).add(product, unit: _unit, quantity: _quantity, note: _note.text);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: Text('Tambah · ${rupiah(lineTotal)}'),
          ),
          if (product.trackInventory && product.stockQuantity != null && !Money.isPositive(product.stockQuantity)) ...[
            const SizedBox(height: 8),
            Text('Stok tercatat habis.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: warningText(context))),
          ],
        ]),
      ),
    );
  }
}

/// Contoh isian catatan barang (netral, untuk semua jenis usaha).
const posNoteHint = 'mis. warna, ukuran, atau permintaan khusus';

/// Daftar "Harga bertingkat" satu satuan: harga normal lalu setiap tingkat
/// (umum dan level pelanggan keranjang). Baris yang sedang berlaku untuk
/// jumlah terpilih diberi warna utama + tanda centang.
class PosPriceTiers extends StatelessWidget {
  const PosPriceTiers({super.key, required this.option, required this.tiers, required this.quote, this.fallbackLevel});

  final UnitOption option;
  final List<PriceTier> tiers;
  final PriceQuote quote;

  /// Nama level pelanggan bila tingkat dari server tidak membawa namanya.
  final String? fallbackLevel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget row(Key key, String label, String price, bool active) => Padding(
          key: key,
          padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
          child: Semantics(
            selected: active,
            child: Row(children: [
              Expanded(child: Text(label, style: TextStyle(fontSize: 13.5, color: active ? scheme.primary : null, fontWeight: active ? FontWeight.w600 : FontWeight.w400))),
              const SizedBox(width: Space.s),
              Text(rupiah(price), style: TextStyle(fontSize: 13.5, color: active ? scheme.primary : null, fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
              SizedBox(width: 26, child: active ? Icon(Icons.check, key: const Key('price-row-check'), size: 18, color: scheme.primary) : null),
            ]),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Harga bertingkat', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      DecoratedBox(
        key: const Key('item-price-tiers'),
        decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(Radii.m)),
        child: Column(children: [
          row(const Key('price-row-normal'), 'Harga normal', option.price, quote.source == PriceSource.normal),
          for (final (index, tier) in tiers.indexed) ...[
            Divider(height: 1, color: scheme.outlineVariant),
            row(
              Key('price-row-$index'),
              'Mulai ${qty(tier.minQuantity)} ${option.name}${tier.levelId != null ? ' · ${tier.level ?? fallbackLevel ?? 'level pelanggan'}' : ''}',
              tier.price,
              identical(quote.tier, tier),
            ),
          ],
        ]),
      ),
    ]);
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
