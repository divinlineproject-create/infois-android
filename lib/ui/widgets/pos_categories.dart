import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../theme.dart';

/// Chip kategori di kasir: "Semua", lalu kategori barang dari Katalog web
/// (urutan lalu nama, hanya yang punya barang di kasir), lalu "Lainnya" untuk
/// barang tanpa kategori.
class PosCategory {
  const PosCategory(this.key, this.label, this.matches, {this.count = 0});

  final String key;
  final String label;
  final bool Function(Product product) matches;

  /// Jumlah barang di kategori ini.
  final int count;

  static final all = PosCategory('all', 'Semua', (_) => true);

  static const String noneKey = 'cat:none';
}

/// Kategori yang berguna untuk katalog [products]. [categories] = daftar
/// dari server (sync/pull); kategori yang hanya diketahui dari barang
/// (server lama / daftar belum tersimpan) tetap ikut, diurutkan menurut nama.
List<PosCategory> posCategories(List<Product> products, [List<ProductCategory> categories = const []]) {
  final counts = <int, int>{};
  final namesFromProducts = <int, String>{};
  var uncategorized = 0;
  for (final product in products) {
    final id = product.categoryId;
    if (id == null) {
      uncategorized++;
      continue;
    }
    counts[id] = (counts[id] ?? 0) + 1;
    if (product.categoryName != null) {
      namesFromProducts[id] ??= product.categoryName!;
    }
  }
  if (counts.isEmpty) {
    return [PosCategory.all];
  }

  final known = {for (final category in categories) category.id: category};
  final ordered = [
    for (final category in categories)
      if (counts.containsKey(category.id)) category,
  ];
  final extra = [
    for (final id in counts.keys)
      if (!known.containsKey(id)) ProductCategory(id: id, name: namesFromProducts[id] ?? 'Kategori', sort: 1 << 30),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  return [
    PosCategory('all', 'Semua', (_) => true, count: products.length),
    for (final category in [...ordered, ...extra])
      PosCategory('cat:${category.id}', category.name, (product) => product.categoryId == category.id, count: counts[category.id] ?? 0),
    if (uncategorized > 0) PosCategory(PosCategory.noneKey, 'Lainnya', (product) => product.categoryId == null, count: uncategorized),
  ];
}

/// Baris chip kategori (geser ke samping).
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
      height: 48,
      child: ListView.separated(
        key: const Key('category-chips'),
        padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.xs),
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: Space.s),
        itemBuilder: (context, index) {
          final category = categories[index];
          return ChoiceChip(
            key: Key('category-${category.key}'),
            label: Text(category.label),
            selected: category.key == selected,
            showCheckmark: false,
            tooltip: '${category.label}: ${category.count} barang',
            onSelected: (_) => onSelected(category.key),
          );
        },
      ),
    );
  }
}
