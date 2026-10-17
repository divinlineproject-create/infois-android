import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../services/product_photos.dart';
import '../../state/photo_state.dart';

/// Warna tetap per nama barang (tanpa foto): tile mudah dikenali.
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

/// Warna inisial barang: di mode gelap dicampur putih (kontras ≥ 4.5:1 di
/// kartu gelap); di mode terang warna aslinya.
Color posInitialsColor(Color color, Brightness brightness) => brightness == Brightness.dark ? Color.lerp(color, Colors.white, 0.55)! : color;

/// Pengganti foto: kotak berwarna lembut dengan inisial barang.
class ProductPlaceholder extends StatelessWidget {
  const ProductPlaceholder({super.key, required this.name, this.fontSize = 26});

  final String name;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final color = posTileColor(name);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: color.withValues(alpha: dark ? 0.2 : 0.1),
      alignment: Alignment.center,
      child: Text(
        posInitials(name),
        maxLines: 1,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: posInitialsColor(color, Theme.of(context).brightness), letterSpacing: 1),
      ),
    );
  }
}

/// Foto barang dari cache HP (diunduh dengan token bila belum ada). Selama
/// memuat, tanpa foto, atau offline: [ProductPlaceholder]. Foto muncul
/// dengan fade singkat; foto yang sudah dimuat di sesi ini tampil langsung.
class ProductImage extends ConsumerStatefulWidget {
  const ProductImage({super.key, required this.product, this.size = PhotoSize.thumb, this.initialsSize = 26});

  final Product product;
  final PhotoSize size;
  final double initialsSize;

  @override
  ConsumerState<ProductImage> createState() => _ProductImageState();
}

class _ProductImageState extends ConsumerState<ProductImage> {
  File? _file;
  Object? _requestedFor;

  String get _identity => '${widget.product.id}:${widget.product.photoVersion}:${widget.product.hasPhoto}:${widget.size.name}';

  @override
  void didUpdateWidget(covariant ProductImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = '${oldWidget.product.id}:${oldWidget.product.photoVersion}:${oldWidget.product.hasPhoto}:${oldWidget.size.name}';
    if (before != _identity) {
      _file = null;
      _requestedFor = null;
    }
  }

  void _request(ProductPhotoStore store) {
    final token = (store, _identity);
    if (_requestedFor == token) {
      return;
    }
    _requestedFor = token;
    final identity = _identity;
    store.load(widget.product, widget.size).then((file) {
      if (mounted && file != null && identity == _identity) {
        setState(() => _file = file);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final placeholder = ProductPlaceholder(name: product.name, fontSize: widget.initialsSize);
    if (!product.hasPhoto) {
      return placeholder;
    }
    final store = ref.watch(productPhotoStoreProvider).valueOrNull;
    final file = store?.peek(product, widget.size) ?? _file;
    if (file == null) {
      if (store != null) {
        _request(store);
      }
      return placeholder;
    }
    final pixels = (widget.size == PhotoSize.thumb ? 256 : 900);
    return Stack(fit: StackFit.expand, children: [
      placeholder,
      Image.file(
        file,
        key: Key('product-photo-${product.id}'),
        fit: BoxFit.cover,
        cacheWidth: pixels,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, sync) => sync
            ? child
            : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 180), curve: Curves.easeOut, child: child),
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    ]);
  }
}
