import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../theme.dart';

/// Warna tetap per nama barang (katalog belum punya foto): tile mudah dikenali.
Color posTileColor(String name) {
  const palette = [
    Color(0xFF0A7F3E),
    Color(0xFF0E7490),
    Color(0xFF7C3AED),
    Color(0xFFB45309),
    Color(0xFFBE185D),
    Color(0xFF1D4ED8),
    Color(0xFF4D7C0F),
    Color(0xFF9F1239),
  ];
  var hash = 0;
  for (final unit in name.toLowerCase().codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}

/// Inisial dua huruf: "Kopi Susu" → "KS", "Gula" → "GU".
String posInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) {
    return '?';
  }
  if (words.length == 1) {
    final word = words.first;
    return (word.length >= 2 ? word.substring(0, 2) : word).toUpperCase();
  }
  return '${words[0][0]}${words[1][0]}'.toUpperCase();
}

/// Kotak barang di grid kasir: inisial berwarna, nama, harga, stok, badge
/// jumlah di keranjang. Stok habis tampil redup (tetap bisa dijual; server
/// yang menentukan stok otomatis/perlu ditinjau).
class PosProductTile extends StatelessWidget {
  const PosProductTile({super.key, required this.product, required this.inCart, required this.onTap, required this.onLongPress});

  final Product product;

  /// Qty barang ini di keranjang (string desimal).
  final String inCart;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  bool get outOfStock => product.trackInventory && product.stockQuantity != null && !Money.isPositive(product.stockQuantity);

  @override
  Widget build(BuildContext context) {
    final color = posTileColor(product.name);
    final selected = Money.isPositive(inCart);
    final stock = product.stockQuantity;
    final String? stockLabel;
    Color? stockColor;
    if (product.trackInventory && stock != null) {
      if (outOfStock) {
        stockLabel = 'Habis';
        stockColor = dangerText(context);
      } else {
        stockLabel = 'Stok ${qty(stock)}';
        stockColor = product.isLowStock() ? warningText(context) : mutedText(context);
      }
    } else {
      stockLabel = null;
    }

    return Opacity(
      opacity: outOfStock ? 0.5 : 1,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: selected ? Brand.green : Theme.of(context).dividerColor.withValues(alpha: 0.4), width: selected ? 2 : 1),
        ),
        child: InkWell(
          key: Key('product-${product.id}'),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Stack(children: [
                Positioned.fill(
                  child: Container(
                    color: color.withValues(alpha: 0.12),
                    alignment: Alignment.center,
                    // Mode gelap: warna inisial dicerahkan supaya tetap terbaca di kartu gelap.
                    child: Text(posInitials(product.name), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: posInitialsColor(color, Theme.of(context).brightness), letterSpacing: 1)),
                  ),
                ),
                if (stockLabel != null)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)),
                      child: Text(stockLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: stockColor)),
                    ),
                  ),
                if (selected)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      key: Key('product-badge-${product.id}'),
                      constraints: const BoxConstraints(minWidth: 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: Brand.green, borderRadius: BorderRadius.circular(14)),
                      child: Text(qty(inCart), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                if (product.units.isNotEmpty || product.tiers.isNotEmpty)
                  Positioned(
                    right: 6,
                    bottom: 4,
                    child: Icon(product.tiers.isNotEmpty ? Icons.sell_outlined : Icons.straighten, size: 16, color: color),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, height: 1.2)),
                const SizedBox(height: 2),
                Text(rupiah(product.price), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Warna inisial barang: di mode gelap dicampur putih (kontras ≥ 4.5:1 di
/// kartu gelap); di mode terang warna aslinya.
Color posInitialsColor(Color color, Brightness brightness) => brightness == Brightness.dark ? Color.lerp(color, Colors.white, 0.55)! : color;
