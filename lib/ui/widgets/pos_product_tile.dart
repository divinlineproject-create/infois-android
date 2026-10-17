import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../theme.dart';
import 'product_image.dart';

export 'product_image.dart' show posInitials, posInitialsColor, posTileColor;

/// Tinggi kartu barang di grid kasir.
const double posTileHeight = 204;

/// Grid barang kasir (dipakai grid dan kerangka muat).
const posGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 172, mainAxisExtent: posTileHeight, crossAxisSpacing: Space.m, mainAxisSpacing: Space.m);

/// Kotak barang di grid kasir: foto (atau inisial berwarna), kategori, nama,
/// harga, label stok, dan badge jumlah di keranjang. Stok habis tampil redup
/// (tetap bisa dijual; server yang menentukan stok otomatis/perlu ditinjau).
class PosProductTile extends StatefulWidget {
  const PosProductTile({super.key, required this.product, required this.inCart, required this.onTap, required this.onLongPress});

  final Product product;

  /// Qty barang ini di keranjang (string desimal).
  final String inCart;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<PosProductTile> createState() => _PosProductTileState();
}

class _PosProductTileState extends State<PosProductTile> {
  bool _pressed = false;

  Product get product => widget.product;

  bool get outOfStock => product.trackInventory && product.stockQuantity != null && !Money.isPositive(product.stockQuantity);

  void _press(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = Money.isPositive(widget.inCart);
    final stock = product.stockQuantity;
    _StockLabel? stockLabel;
    if (product.trackInventory && stock != null) {
      stockLabel = outOfStock
          ? const _StockLabel('Habis', Brand.danger, Colors.white)
          : (product.isLowStock()
              ? _StockLabel('Sisa ${qty(stock)}', Brand.nota, Brand.ink)
              : _StockLabel('Stok ${qty(stock)}', scheme.surface.withValues(alpha: 0.92), mutedText(context)));
    }

    return AnimatedScale(
      scale: _pressed ? 0.97 : 1,
      duration: const Duration(milliseconds: 90),
      child: Opacity(
        opacity: outOfStock ? 0.55 : 1,
        child: Material(
          color: scheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.l),
            side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2 : 1),
          ),
          child: InkWell(
            key: Key('product-${product.id}'),
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onHighlightChanged: _press,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  ProductImage(product: product),
                  if (stockLabel != null)
                    Positioned(
                      left: Space.s,
                      top: Space.s,
                      child: _Pill(text: stockLabel.text, background: stockLabel.background, foreground: stockLabel.foreground),
                    ),
                  if (selected)
                    Positioned(
                      right: Space.s,
                      top: Space.s,
                      child: TweenAnimationBuilder<double>(
                        key: ValueKey(widget.inCart),
                        tween: Tween(begin: 1.3, end: 1),
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutBack,
                        builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
                        child: Container(
                          key: Key('product-badge-${product.id}'),
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: Space.s),
                          decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(14), border: Border.all(color: scheme.surface, width: 2)),
                          child: Text(qty(widget.inCart), textAlign: TextAlign.center, style: TextStyle(color: scheme.onPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                  // Bahan baku yang ditampilkan di kasir: diberi label supaya
                  // tidak tertukar dengan barang jadi.
                  if (product.isRawMaterial)
                    Positioned(
                      left: Space.s,
                      bottom: Space.s,
                      child: _Pill(key: Key('product-kind-${product.id}'), text: product.kindLabel ?? 'Bahan baku', background: scheme.surface.withValues(alpha: 0.92), foreground: mutedText(context)),
                    ),
                  if (product.units.isNotEmpty || product.tiers.isNotEmpty)
                    Positioned(
                      right: Space.s,
                      bottom: Space.s,
                      child: Container(
                        padding: const EdgeInsets.all(Space.xs),
                        decoration: BoxDecoration(color: scheme.surface.withValues(alpha: 0.92), shape: BoxShape.circle),
                        child: Icon(product.tiers.isNotEmpty ? Icons.sell_outlined : Icons.straighten, size: 14, color: scheme.primary),
                      ),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.m - 2, Space.s, Space.m - 2, Space.m - 2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (product.categoryName != null)
                    Text(
                      product.categoryName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: mutedText(context), letterSpacing: 0.2),
                    ),
                  Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, height: 1.25)),
                  const SizedBox(height: 2),
                  Text(rupiah(product.price), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: scheme.primary)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _StockLabel {
  const _StockLabel(this.text, this.background, this.foreground);

  final String text;
  final Color background;
  final Color foreground;
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.text, required this.background, required this.foreground});

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: 3),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(Radii.s)),
        child: Text(text, maxLines: 1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: foreground)),
      );
}

/// Kerangka grid saat katalog dimuat (kotak diam, tanpa animasi berat).
class PosGridSkeleton extends StatelessWidget {
  const PosGridSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double width, double height) =>
        Container(width: width, height: height, decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Radii.s / 2)));
    return GridView.builder(
      key: const Key('product-skeleton'),
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, Space.s),
      gridDelegate: posGridDelegate,
      itemCount: 6,
      itemBuilder: (context, _) => DecoratedBox(
        decoration: BoxDecoration(color: scheme.surface, borderRadius: BorderRadius.circular(Radii.l), border: Border.all(color: scheme.outlineVariant)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(1),
              decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.l))),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.m - 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar(90, 10), const SizedBox(height: 6), bar(60, 12)]),
          ),
        ]),
      ),
    );
  }
}
