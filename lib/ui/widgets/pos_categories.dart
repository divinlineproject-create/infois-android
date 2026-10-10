import 'package:flutter/material.dart';

import '../../domain/models.dart';

/// Kelompok barang untuk chip di kasir.
///
/// Data sinkron belum punya kategori barang, jadi kelompok diturunkan dari
/// data yang ada: jenis (Barang/Jasa) dan satuan dasar ("Gelas", "Porsi",
/// "Pcs" — di kafe/warung satuan biasanya sudah memisahkan minuman & makanan).
class PosCategory {
  const PosCategory(this.key, this.label, this.matches);

  final String key;
  final String label;
  final bool Function(Product product) matches;

  static final all = PosCategory('all', 'Semua', (_) => true);
}

String _capitalize(String text) => text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

/// Kelompok yang berguna untuk katalog ini (hanya yang membedakan barang).
List<PosCategory> posCategories(List<Product> products) {
  final categories = <PosCategory>[PosCategory.all];
  if (products.length < 2) {
    return categories;
  }
  final hasService = products.any((product) => product.type == 'service');
  final hasGoods = products.any((product) => product.type != 'service');
  if (hasService && hasGoods) {
    categories
      ..add(PosCategory('type:product', 'Barang', (product) => product.type != 'service'))
      ..add(PosCategory('type:service', 'Jasa', (product) => product.type == 'service'));
  }

  final counts = <String, int>{};
  for (final product in products) {
    final unit = product.unit.trim().toLowerCase();
    if (unit.isNotEmpty) {
      counts[unit] = (counts[unit] ?? 0) + 1;
    }
  }
  if (counts.length >= 2) {
    final units = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!) != 0 ? counts[b]!.compareTo(counts[a]!) : a.compareTo(b));
    for (final unit in units.take(8)) {
      categories.add(PosCategory('unit:$unit', _capitalize(unit), (product) => product.unit.trim().toLowerCase() == unit));
    }
  }
  return categories;
}

/// Baris chip kelompok barang (geser ke samping).
class PosCategoryChips extends StatelessWidget {
  const PosCategoryChips({super.key, required this.categories, required this.selected, required this.onSelected});

  final List<PosCategory> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    if (categories.length < 2) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = categories[index];
          return ChoiceChip(
            key: Key('category-${category.key}'),
            label: Text(category.label),
            selected: category.key == selected,
            showCheckmark: false,
            onSelected: (_) => onSelected(category.key),
          );
        },
      ),
    );
  }
}
