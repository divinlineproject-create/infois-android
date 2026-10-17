// Screenshot alur input pesanan di Kasir (POS) untuk ditinjau pemilik:
// katalog dengan foto, kategori, lembar barang, keranjang, panel pesanan,
// scan barcode, bayar, selesai, pesanan tersimpan, mode gelap, dan tablet.
// Data contoh kafe "Kopi Senja"; foto barang digambar di kode (tanpa aset
// luar). Tidak ikut `flutter test` biasa (nama file tanpa akhiran
// `_test.dart`). Jalankan:
//
//   SHOTS_DIR=/path/keluaran flutter test test/screenshots/pos_order_screenshots.dart
//
// Hasil: 01-kasir.png … 11-panel-pesanan-gelap.png (HP 1080x2340, rasio
// 2,75) dan 12-tablet-kasir.png / 12b-tablet-kasir-rasio2.png (tablet
// lanskap 1920x1200).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/cart.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/code_scanner.dart';
import 'package:infois/services/permission_gate.dart';
import 'package:infois/services/pos_service.dart';
import 'package:infois/services/product_photos.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:infois/state/photo_state.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/pos_order_panel.dart';
import 'package:infois/ui/screens/scan_screen.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

// ---------------------------------------------------------------------------
// Data contoh: kafe Kopi Senja.
// ---------------------------------------------------------------------------

const _kopi = ProductCategory(id: 1, name: 'Kopi', sort: 1);
const _nonKopi = ProductCategory(id: 2, name: 'Non-Kopi', sort: 2);
const _makanan = ProductCategory(id: 3, name: 'Makanan', sort: 3);
const _snack = ProductCategory(id: 4, name: 'Snack', sort: 4);
const _categories = [_kopi, _nonKopi, _makanan, _snack];

/// Barcode botol kopi susu (dipakai di layar scan).
const _bottleBarcode = '8997035112250';

Product _product(int id, String name, String unit, int price, ProductCategory category,
        {bool photo = false, String? barcode, String? stock, String? minimum, String? sku}) =>
    Product(
      id: id,
      name: name,
      unit: unit,
      price: '$price.00',
      sku: sku,
      barcode: barcode,
      categoryId: category.id,
      categoryName: category.name,
      hasPhoto: photo,
      photoVersion: photo ? 'v1' : null,
      trackInventory: stock != null,
      stockQuantity: stock,
      minimumStock: minimum,
    );

final _products = [
  _product(1, 'Americano', 'gelas', 20000, _kopi, photo: true, sku: 'KP-01'),
  _product(2, 'Cappuccino', 'gelas', 26000, _kopi, photo: true, sku: 'KP-02'),
  _product(3, 'Es Kopi Susu Gula Aren', 'gelas', 22000, _kopi, photo: true, sku: 'KP-03'),
  _product(4, 'Kopi Tubruk', 'gelas', 15000, _kopi, sku: 'KP-04'),
  _product(5, 'Kopi Susu Botol 250 ml', 'botol', 25000, _kopi, photo: true, barcode: _bottleBarcode, sku: 'KP-05', stock: '18.000000', minimum: '6.000000'),
  _product(6, 'Cokelat Panas', 'gelas', 24000, _nonKopi, photo: true, sku: 'NK-01'),
  _product(7, 'Es Teh Leci', 'gelas', 18000, _nonKopi, photo: true, sku: 'NK-02'),
  _product(8, 'Matcha Latte', 'gelas', 28000, _nonKopi, sku: 'NK-03'),
  _product(9, 'Nasi Goreng Kampung', 'porsi', 32000, _makanan, photo: true, sku: 'MK-01'),
  _product(10, 'Roti Bakar Cokelat', 'porsi', 17000, _makanan, sku: 'MK-02', stock: '20.000000', minimum: '5.000000'),
  _product(11, 'Croissant Butter', 'pcs', 21000, _snack, photo: true, sku: 'SN-01', stock: '3.000000', minimum: '5.000000'),
  _product(12, 'Kentang Goreng', 'porsi', 18000, _snack, sku: 'SN-02'),
];

Product _byName(String name) => _products.firstWhere((product) => product.name == name);

Key _tile(String name) => Key('product-${_byName(name).id}');

const _tenant = {'id': 1, 'name': 'Kopi Senja', 'prices_include_tax': true, 'sales_tax_name': 'PB1', 'sales_tax_rate': '0.00'};
const _receipt = {
  'width': 58,
  'company': {'name': 'Kopi Senja', 'address': 'Jl. Braga No. 21, Bandung', 'phone': '0812-2233-4455'},
  'footer_text': 'Terima kasih, sampai jumpa lagi!',
};
const _menus = {'pos': true, 'shift': false, 'add_customer': true, 'printer': true, 'ai': true, 'reports': true, 'records': true};
const _numberBlocks = [
  {'id': 1, 'format': 'KS-K1/{SEQ:5}', 'start': 1, 'end': 9999, 'last_used': 127},
];

Map<String, dynamic>? _handler(RequestOptions options, Map<String, dynamic>? body) {
  switch (options.path) {
    case 'sync/pull':
      return {
        'cursor': 'c1',
        'full': true,
        'tenant': _tenant,
        'receipt': _receipt,
        'device': {'id': 3, 'code': 'K1', 'name': 'HP Kasir'},
        'user': {'id': 1, 'name': 'Sari'},
        'menus': _menus,
        'products': {
          'items': [for (final product in _products) product.toJson()],
          'ids': [for (final product in _products) product.id],
        },
        'categories': {
          'items': [for (final category in _categories) category.toJson()],
          'ids': [for (final category in _categories) category.id],
        },
        'customers': {'items': [], 'ids': [7]},
        'accounts': {
          'items': [
            {'id': 11, 'code': '1-1100', 'name': 'Kas', 'kind': 'cash'},
            {'id': 12, 'code': '1-1200', 'name': 'Bank BCA', 'kind': 'bank'},
          ],
          'ids': [11, 12],
          'default_cash_id': 11,
          'default_transfer_id': 12,
        },
        'warehouses': {'items': [], 'ids': []},
        'number_blocks': _numberBlocks,
        'open_shift': null,
      };
    case 'sync/push':
      // Semua penjualan diterima server (status "Online", tanpa antrean).
      return {
        'results': [
          for (final item in (body?['items'] as List? ?? const []))
            {'client_uuid': (item as Map)['client_uuid'], 'type': item['type'], 'status': 'ok', 'number': (item['data'] as Map?)?['number']},
        ],
      };
    case 'ping':
      return {'ok': true, 'server_time': DateTime.now().toUtc().toIso8601String()};
  }
  return {};
}

// ---------------------------------------------------------------------------
// Foto barang digambar di kode: ubin warna dengan cangkir / gelas / botol /
// piring sederhana (tampak atas atau samping).
// ---------------------------------------------------------------------------

enum _Kind { hot, iced, bottle, plate, croissant }

class _Art {
  const _Art(this.kind, this.background, this.drink, {this.accent, this.latte = false, this.topping = false});

  final _Kind kind;
  final Color background;
  final Color drink;
  final Color? accent;
  final bool latte;
  final bool topping;
}

const _arts = <int, _Art>{
  1: _Art(_Kind.hot, Color(0xFF457B9D), Color(0xFF2B1A10)),
  2: _Art(_Kind.hot, Color(0xFFC8553D), Color(0xFF7A4A2A), latte: true),
  3: _Art(_Kind.iced, Color(0xFF3D5A80), Color(0xFFD9B48F), accent: Color(0xFF5C3317)),
  5: _Art(_Kind.bottle, Color(0xFF264653), Color(0xFFB98459)),
  6: _Art(_Kind.hot, Color(0xFF8E5572), Color(0xFF4E2618), topping: true),
  7: _Art(_Kind.iced, Color(0xFF6A994E), Color(0xFFE8A33D), accent: Color(0xFFC77C1E), topping: true),
  9: _Art(_Kind.plate, Color(0xFFBC4749), Color(0xFFC9803F)),
  11: _Art(_Kind.croissant, Color(0xFFE0A458), Color(0xFFD08A2E)),
};

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

Paint _fill(Color color) => Paint()
  ..color = color
  ..isAntiAlias = true;

void _shadow(Canvas canvas, Rect oval, double blur, {double alpha = 0.28}) => canvas.drawOval(
      oval,
      Paint()
        ..color = Colors.black.withValues(alpha: alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
    );

Path _heart(Offset c, double s) => Path()
  ..moveTo(c.dx, c.dy + s * 0.55)
  ..cubicTo(c.dx - s * 1.1, c.dy - s * 0.1, c.dx - s * 0.55, c.dy - s * 0.95, c.dx, c.dy - s * 0.35)
  ..cubicTo(c.dx + s * 0.55, c.dy - s * 0.95, c.dx + s * 1.1, c.dy - s * 0.1, c.dx, c.dy + s * 0.55)
  ..close();

/// Lingkaran tidak rata (nasi, telur) dengan [seed] tetap.
Path _blob(Offset c, double r, int seed, {double wobble = 0.12, int points = 14}) {
  final random = math.Random(seed);
  final radii = [for (var i = 0; i < points; i++) r * (1 - wobble + random.nextDouble() * wobble * 2)];
  Offset at(int i) {
    final angle = i / points * math.pi * 2;
    final radius = radii[i % points];
    return c + Offset(math.cos(angle) * radius, math.sin(angle) * radius);
  }

  final path = Path();
  for (var i = 0; i <= points; i++) {
    final p0 = at(i);
    final p1 = at(i + 1);
    final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
    if (i == 0) {
      path.moveTo(mid.dx, mid.dy);
    } else {
      path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
    }
  }
  return path..close();
}

void _paintArt(Canvas canvas, Size size, _Art art) {
  final w = size.width;
  final h = size.height;
  final c = Offset(w / 2, h / 2);
  final r = math.min(w, h) * 0.36;

  // Latar: warna penuh dengan cahaya lembut di tengah.
  canvas.drawRect(
    Offset.zero & size,
    Paint()..shader = ui.Gradient.radial(c.translate(-r * 0.3, -r * 0.4), math.max(w, h) * 0.8, [_mix(art.background, Colors.white, 0.18), _mix(art.background, Colors.black, 0.18)]),
  );
  // Garis serat meja yang samar.
  final grain = Paint()
    ..color = Colors.white.withValues(alpha: 0.05)
    ..strokeWidth = r * 0.012;
  for (var y = h * 0.08; y < h; y += r * 0.22) {
    canvas.drawLine(Offset(0, y), Offset(w, y + r * 0.05), grain);
  }

  switch (art.kind) {
    case _Kind.hot:
      _hotCup(canvas, c, r, art);
    case _Kind.iced:
      _icedGlass(canvas, c, r, art);
    case _Kind.bottle:
      _bottle(canvas, c, r, art);
    case _Kind.plate:
      _friedRice(canvas, c, r, art);
    case _Kind.croissant:
      _croissant(canvas, c, r, art);
  }
}

void _hotCup(Canvas canvas, Offset c, double r, _Art art) {
  _shadow(canvas, Rect.fromCircle(center: c.translate(r * 0.08, r * 0.12), radius: r * 1.02), r * 0.09);
  // Tatakan.
  canvas.drawCircle(c, r, _fill(const Color(0xFFF4EEE6)));
  canvas.drawCircle(
    c,
    r * 0.82,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.025
      ..color = const Color(0xFFE2D9CC),
  );
  // Sendok kecil di tatakan.
  canvas.save();
  canvas.translate(c.dx - r * 0.62, c.dy + r * 0.52);
  canvas.rotate(-0.75);
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: r * 0.55, height: r * 0.07), Radius.circular(r * 0.04)), _fill(const Color(0xFFB8BCC2)));
  canvas.drawOval(Rect.fromCenter(center: Offset(r * 0.33, 0), width: r * 0.24, height: r * 0.16), _fill(const Color(0xFFC9CDD2)));
  canvas.restore();
  // Pegangan cangkir.
  final handle = RRect.fromRectAndRadius(Rect.fromLTWH(c.dx + r * 0.5, c.dy - r * 0.1, r * 0.4, r * 0.2), Radius.circular(r * 0.1));
  _shadow(canvas, handle.outerRect.shift(Offset(r * 0.02, r * 0.04)), r * 0.03, alpha: 0.18);
  canvas.drawRRect(handle, _fill(const Color(0xFFFBF9F5)));
  // Cangkir.
  _shadow(canvas, Rect.fromCircle(center: c.translate(r * 0.03, r * 0.06), radius: r * 0.64), r * 0.05, alpha: 0.2);
  canvas.drawCircle(c, r * 0.64, _fill(const Color(0xFFFBF9F5)));
  canvas.drawCircle(
    c,
    r * 0.6,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.03
      ..color = const Color(0xFFE9E3DA),
  );
  // Isi.
  canvas.drawCircle(
    c,
    r * 0.53,
    Paint()..shader = ui.Gradient.radial(c.translate(-r * 0.12, -r * 0.15), r * 0.6, [_mix(art.drink, Colors.white, 0.18), art.drink]),
  );
  if (art.latte) {
    canvas.drawCircle(c, r * 0.53, _fill(const Color(0xFFE7CDA8)));
    canvas.drawCircle(c, r * 0.43, _fill(art.drink));
    canvas.drawPath(_heart(c.translate(0, r * 0.02), r * 0.3), _fill(const Color(0xFFF3E3CB)));
  } else if (!art.topping) {
    // Crema tipis di pinggir.
    canvas.drawCircle(
      c,
      r * 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.04
        ..color = const Color(0xFF8A5A33).withValues(alpha: 0.6),
    );
  }
  if (art.topping) {
    // Marshmallow.
    final random = math.Random(6);
    for (var i = 0; i < 6; i++) {
      final angle = i / 6 * math.pi * 2 + random.nextDouble() * 0.4;
      final distance = r * (0.12 + random.nextDouble() * 0.22);
      final at = c + Offset(math.cos(angle) * distance, math.sin(angle) * distance);
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(random.nextDouble());
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: r * 0.17, height: r * 0.17), Radius.circular(r * 0.05)), _fill(i.isEven ? const Color(0xFFFFF7F2) : const Color(0xFFF8D7DF)));
      canvas.restore();
    }
  }
  // Kilau.
  canvas.drawArc(
    Rect.fromCircle(center: c, radius: r * 0.58),
    math.pi * 1.1,
    0.9,
    false,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.03
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.55),
  );
}

void _icedGlass(Canvas canvas, Offset c, double r, _Art art) {
  final top = c.dy - r * 0.95;
  final bottom = c.dy + r * 0.95;
  final topHalf = r * 0.6;
  final bottomHalf = r * 0.46;
  _shadow(canvas, Rect.fromCenter(center: Offset(c.dx + r * 0.1, bottom + r * 0.02), width: r * 1.4, height: r * 0.25), r * 0.06, alpha: 0.32);
  final glass = Path()
    ..moveTo(c.dx - topHalf, top)
    ..lineTo(c.dx + topHalf, top)
    ..lineTo(c.dx + bottomHalf, bottom - r * 0.08)
    ..quadraticBezierTo(c.dx + bottomHalf, bottom, c.dx + bottomHalf - r * 0.08, bottom)
    ..lineTo(c.dx - bottomHalf + r * 0.08, bottom)
    ..quadraticBezierTo(c.dx - bottomHalf, bottom, c.dx - bottomHalf, bottom - r * 0.08)
    ..close();
  // Sedotan di belakang isi.
  canvas.save();
  canvas.translate(c.dx + r * 0.12, top - r * 0.05);
  canvas.rotate(0.22);
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(-r * 0.05, -r * 0.35, r * 0.1, r * 1.4), Radius.circular(r * 0.05)), _fill(art.topping ? const Color(0xFF2E7D32) : const Color(0xFF1B1B1B)));
  canvas.restore();
  canvas.drawPath(glass, _fill(Colors.white.withValues(alpha: 0.22)));
  canvas.save();
  canvas.clipPath(glass);
  final liquidTop = top + r * 0.22;
  canvas.drawRect(
    Rect.fromLTRB(c.dx - topHalf, liquidTop, c.dx + topHalf, bottom),
    Paint()..shader = ui.Gradient.linear(Offset(0, liquidTop), Offset(0, bottom), [art.drink, _mix(art.drink, art.accent ?? art.drink, 0.4), art.accent ?? art.drink], [0, 0.55, 1]),
  );
  // Es batu.
  final random = math.Random(art.drink.toARGB32());
  for (var i = 0; i < 5; i++) {
    final x = c.dx - topHalf * 0.6 + random.nextDouble() * topHalf * 1.2;
    final y = liquidTop + r * 0.05 + random.nextDouble() * r * 0.55;
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(random.nextDouble() * 0.8 - 0.4);
    final cube = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: r * 0.28, height: r * 0.26), Radius.circular(r * 0.05));
    canvas.drawRRect(cube, _fill(Colors.white.withValues(alpha: 0.38)));
    canvas.drawRRect(
      cube,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.015
        ..color = Colors.white.withValues(alpha: 0.6),
    );
    canvas.restore();
  }
  if (art.topping) {
    // Buah leci.
    for (final (dx, dy) in [(-0.2, 0.55), (0.18, 0.7), (-0.02, 0.4)]) {
      final at = Offset(c.dx + r * dx, c.dy + r * dy);
      canvas.drawCircle(at, r * 0.13, _fill(const Color(0xFFFFF4E6)));
      canvas.drawCircle(at.translate(r * 0.03, 0), r * 0.05, _fill(const Color(0xFFE9D3B8)));
    }
  }
  // Kilau kaca.
  canvas.drawRect(Rect.fromLTWH(c.dx - topHalf + r * 0.1, top, r * 0.07, bottom - top), _fill(Colors.white.withValues(alpha: 0.25)));
  canvas.restore();
  canvas.drawPath(
    glass,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.025
      ..color = Colors.white.withValues(alpha: 0.7),
  );
  canvas.drawOval(
    Rect.fromCenter(center: Offset(c.dx, top), width: topHalf * 2, height: r * 0.12),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.025
      ..color = Colors.white.withValues(alpha: 0.75),
  );
}

void _bottle(Canvas canvas, Offset c, double r, _Art art) {
  final body = RRect.fromRectAndRadius(Rect.fromCenter(center: c.translate(0, r * 0.2), width: r * 0.82, height: r * 1.45), Radius.circular(r * 0.18));
  _shadow(canvas, Rect.fromCenter(center: Offset(c.dx + r * 0.1, body.bottom), width: r * 1.1, height: r * 0.2), r * 0.06, alpha: 0.35);
  final shoulder = Path()
    ..moveTo(body.left + r * 0.05, body.top + r * 0.2)
    ..quadraticBezierTo(body.left + r * 0.02, body.top - r * 0.2, c.dx - r * 0.17, body.top - r * 0.32)
    ..lineTo(c.dx + r * 0.17, body.top - r * 0.32)
    ..quadraticBezierTo(body.right - r * 0.02, body.top - r * 0.2, body.right - r * 0.05, body.top + r * 0.2)
    ..close();
  final liquid = Paint()..shader = ui.Gradient.linear(Offset(body.left, 0), Offset(body.right, 0), [_mix(art.drink, Colors.black, 0.15), _mix(art.drink, Colors.white, 0.2), _mix(art.drink, Colors.black, 0.2)], [0, 0.4, 1]);
  canvas.drawPath(shoulder, liquid);
  canvas.drawRRect(body, liquid);
  // Leher + tutup.
  final neck = Rect.fromLTRB(c.dx - r * 0.17, body.top - r * 0.5, c.dx + r * 0.17, body.top - r * 0.3);
  canvas.drawRect(neck, _fill(_mix(art.drink, Colors.white, 0.1)));
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(c.dx - r * 0.21, body.top - r * 0.72, c.dx + r * 0.21, body.top - r * 0.48), Radius.circular(r * 0.05)), _fill(const Color(0xFF1F2A30)));
  // Label: matahari senja + dua garis tulisan.
  final label = Rect.fromLTRB(body.left, c.dy + r * 0.02, body.right, c.dy + r * 0.62);
  canvas.drawRect(label, _fill(const Color(0xFFF6EBDD)));
  final sun = Offset(c.dx, label.top + label.height * 0.55);
  canvas.save();
  canvas.clipRect(Rect.fromLTRB(label.left, label.top, label.right, sun.dy));
  canvas.drawCircle(sun, r * 0.16, _fill(const Color(0xFFE76F51)));
  canvas.restore();
  canvas.drawLine(Offset(c.dx - r * 0.25, sun.dy), Offset(c.dx + r * 0.25, sun.dy), _fill(const Color(0xFF264653))..strokeWidth = r * 0.025);
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(c.dx, sun.dy + r * 0.1), width: r * 0.46, height: r * 0.05), Radius.circular(r * 0.02)), _fill(const Color(0xFF264653)));
  // Kilau.
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(body.left + r * 0.1, body.top + r * 0.05, r * 0.07, body.height * 0.75), Radius.circular(r * 0.04)), _fill(Colors.white.withValues(alpha: 0.3)));
}

void _plate(Canvas canvas, Offset c, double r) {
  _shadow(canvas, Rect.fromCircle(center: c.translate(r * 0.08, r * 0.12), radius: r * 1.04), r * 0.09);
  canvas.drawCircle(c, r * 1.02, _fill(const Color(0xFFFBFAF7)));
  canvas.drawCircle(
    c,
    r * 0.8,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.03
      ..color = const Color(0xFFE7E2DA),
  );
}

void _friedRice(Canvas canvas, Offset c, double r, _Art art) {
  _plate(canvas, c, r);
  final rice = _blob(c.translate(-r * 0.05, r * 0.05), r * 0.62, 9);
  canvas.drawPath(rice, Paint()..shader = ui.Gradient.radial(c.translate(-r * 0.2, -r * 0.2), r * 0.8, [_mix(art.drink, Colors.white, 0.15), _mix(art.drink, Colors.black, 0.12)]));
  final random = math.Random(3);
  for (var i = 0; i < 110; i++) {
    final angle = random.nextDouble() * math.pi * 2;
    final distance = math.sqrt(random.nextDouble()) * r * 0.55;
    final at = c.translate(-r * 0.05, r * 0.05) + Offset(math.cos(angle) * distance, math.sin(angle) * distance);
    final color = switch (i % 9) {
      0 => const Color(0xFF6A994E),
      1 => const Color(0xFFD62828),
      2 || 3 => _mix(art.drink, Colors.black, 0.3),
      _ => _mix(art.drink, Colors.white, 0.35),
    };
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(random.nextDouble() * math.pi);
    canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: r * 0.07, height: r * 0.035), _fill(color));
    canvas.restore();
  }
  // Telur ceplok.
  final egg = c.translate(r * 0.22, -r * 0.2);
  canvas.drawPath(_blob(egg, r * 0.3, 4, wobble: 0.16), _fill(const Color(0xFFFFFDF8)));
  canvas.drawCircle(egg.translate(r * 0.02, r * 0.02), r * 0.12, Paint()..shader = ui.Gradient.radial(egg.translate(-r * 0.03, -r * 0.03), r * 0.14, [const Color(0xFFFFC233), const Color(0xFFF29E1F)]));
  // Timun & tomat di pinggir piring.
  for (final (angle, color, inner) in [
    (2.3, const Color(0xFF7CB342), const Color(0xFFDCEDC8)),
    (2.75, const Color(0xFF7CB342), const Color(0xFFDCEDC8)),
    (3.2, const Color(0xFFE53935), const Color(0xFFFF8A80)),
  ]) {
    final at = c + Offset(math.cos(angle) * r * 0.72, math.sin(angle) * r * 0.72);
    canvas.drawCircle(at, r * 0.13, _fill(color));
    canvas.drawCircle(at, r * 0.1, _fill(inner));
  }
  // Kerupuk.
  canvas.drawPath(_blob(c + Offset(math.cos(5.6) * r * 0.66, math.sin(5.6) * r * 0.66), r * 0.2, 12, wobble: 0.2), _fill(const Color(0xFFF6E7C1)));
}

void _croissant(Canvas canvas, Offset c, double r, _Art art) {
  _plate(canvas, c, r);
  // Bulan sabit dari beberapa ruas, digambar dari ujung ke tengah.
  const segments = 7;
  final arcCenter = c.translate(0, r * 0.55);
  final radius = r * 0.72;
  final order = [0, 6, 1, 5, 2, 4, 3];
  for (final i in order) {
    final t = i / (segments - 1);
    final angle = math.pi * (1.12 + t * 0.76);
    final at = arcCenter + Offset(math.cos(angle) * radius, math.sin(angle) * radius);
    final size = r * (0.2 + 0.24 * math.sin(t * math.pi));
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle + math.pi / 2);
    final oval = Rect.fromCenter(center: Offset.zero, width: size * 1.25, height: size * 1.9);
    _shadow(canvas, oval.shift(Offset(r * 0.02, r * 0.03)), r * 0.03, alpha: 0.2);
    canvas.drawOval(oval, Paint()..shader = ui.Gradient.radial(Offset(-size * 0.2, -size * 0.3), size * 1.2, [const Color(0xFFF2C46D), art.drink, _mix(art.drink, Colors.black, 0.25)], [0, 0.6, 1]));
    canvas.drawArc(
      oval.deflate(size * 0.12),
      math.pi * 1.15,
      math.pi * 0.7,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.025
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.35),
    );
    canvas.restore();
  }
}

Future<Uint8List> _renderArt(_Art art, int width, int height) async {
  final recorder = ui.PictureRecorder();
  _paintArt(Canvas(recorder), Size(width.toDouble(), height.toDouble()), art);
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// Tulis foto ke folder cache HP (seperti sudah pernah diunduh) dan
/// muat ke cache gambar supaya langsung tampil.
Future<Directory> _writePhotos(WidgetTester tester) async {
  final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('infois_pos_shots')))!;
  addTearDown(() => root.delete(recursive: true));
  final folder = Directory('${root.path}/${ProductPhotoStore.folderName(1, 1)}');
  await tester.runAsync(() async {
    await folder.create(recursive: true);
    for (final MapEntry(key: id, value: art) in _arts.entries) {
      final thumb = File('${folder.path}/${id}_v1_t');
      final full = File('${folder.path}/${id}_v1_f');
      await thumb.writeAsBytes(await _renderArt(art, 512, 512));
      await full.writeAsBytes(await _renderArt(art, 1200, 600));
      // Sama persis dengan Image.file(cacheWidth: …) di ProductImage.
      await _warm(ResizeImage(FileImage(thumb), width: 256));
      await _warm(ResizeImage(FileImage(full), width: 900));
    }
  });
  return root;
}

Future<void> _warm(ImageProvider provider) {
  final done = Completer<void>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener((_, __) {
    if (!done.isCompleted) {
      done.complete();
    }
  }, onError: (_, __) {
    if (!done.isCompleted) {
      done.complete();
    }
  });
  stream.addListener(listener);
  return done.future.whenComplete(() => stream.removeListener(listener));
}

// ---------------------------------------------------------------------------
// Pemindai palsu dengan pratinjau "kamera": label barcode di dalam bingkai.
// ---------------------------------------------------------------------------

class _ShotScanner implements CodeScanner {
  ValueChanged<String>? _onCode;
  final ValueNotifier<bool?> _torch = ValueNotifier<bool?>(false);

  void emit(String code) => _onCode?.call(code);

  @override
  Widget buildPreview(BuildContext context, {required ValueChanged<String> onCode, required Widget Function(BuildContext context, ScannerProblem problem) onProblem}) {
    _onCode = onCode;
    return const CustomPaint(key: Key('fake-camera'), painter: _CameraPainter());
  }

  @override
  ValueListenable<bool?> get torch => _torch;

  @override
  Future<void> toggleTorch() async => _torch.value = !(_torch.value ?? false);

  @override
  Future<void> dispose() async {}
}

class _CameraPainter extends CustomPainter {
  const _CameraPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final frameWidth = (size.width * 0.75).clamp(200.0, 360.0);
    final center = Offset(size.width / 2, size.height * 0.45);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = ui.Gradient.radial(center, size.height * 0.7, [const Color(0xFF6B5444), const Color(0xFF2A211B), const Color(0xFF120E0B)], [0, 0.55, 1]),
    );
    // Botol yang dipegang di depan kamera (agak buram).
    final bottle = RRect.fromRectAndRadius(Rect.fromCenter(center: center.translate(0, 30), width: frameWidth * 0.95, height: size.height * 0.75), const Radius.circular(60));
    canvas.drawRRect(
      bottle,
      Paint()
        ..shader = ui.Gradient.linear(bottle.outerRect.centerLeft, bottle.outerRect.centerRight, [const Color(0xFF6E4A2E), const Color(0xFFB98459), const Color(0xFF5E3D24)], [0, 0.45, 1])
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // Stiker barcode.
    final sticker = RRect.fromRectAndRadius(Rect.fromCenter(center: center.translate(0, -frameWidth * 0.08), width: frameWidth * 0.7, height: frameWidth * 0.32), const Radius.circular(6));
    canvas.drawRRect(sticker, Paint()..color = const Color(0xFFF7F3EC));
    final bars = sticker.outerRect.deflate(14);
    final barsArea = Rect.fromLTRB(bars.left, bars.top, bars.right, bars.bottom - 16);
    final pattern = <int>[];
    for (final digit in _bottleBarcode.codeUnits) {
      pattern.addAll([1 + digit % 3, 1 + (digit ~/ 3) % 2, 1 + (digit ~/ 2) % 3, 1]);
    }
    final total = pattern.fold<int>(0, (sum, width) => sum + width) + 6;
    final unit = barsArea.width / total;
    var x = barsArea.left;
    final ink = Paint()..color = const Color(0xFF111111);
    for (final (index, width) in [1, 1, ...pattern, 1, 1].indexed) {
      if (index.isEven) {
        canvas.drawRect(Rect.fromLTWH(x, barsArea.top, width * unit, barsArea.height), ink);
      }
      x += width * unit;
    }
    final digits = TextPainter(
      text: const TextSpan(text: _bottleBarcode, style: TextStyle(fontFamily: 'Poppins', fontSize: 10, height: 1.1, color: Color(0xFF111111), letterSpacing: 2)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: bars.width);
    digits.paint(canvas, Offset(bars.center.dx - digits.width / 2, bars.bottom - digits.height + 2));
    // Garis laser pemindai.
    canvas.drawRect(
      Rect.fromCenter(center: sticker.outerRect.center.translate(0, -6), width: frameWidth * 0.86, height: 2),
      Paint()
        ..color = const Color(0xFFFF5252)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _NoRationale implements PermissionGate {
  @override
  Future<bool> needsRationale(AppPermission permission) async => false;

  @override
  Future<void> markExplained(AppPermission permission) async {}
}

// ---------------------------------------------------------------------------

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final file in files) {
      loader.addFont(File(file).readAsBytes().then((bytes) => ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  final poppins = [for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/Poppins-$weight.ttf'];
  await family('Poppins', poppins);
  // Teks tanpa fontFamily memakai font tes berbentuk kotak; ganti Poppins.
  await family('FlutterTest', poppins);
  await family('Roboto', poppins);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final icons = '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  if (File(icons).existsSync()) {
    await family('MaterialIcons', [icons]);
  }
}

void main() {
  final outDir = Platform.environment['SHOTS_DIR'] ?? 'build/pos-shots';

  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
    await _loadFonts();
  });

  final boundaryKey = GlobalKey();
  const phone = (Size(1080, 2340), 2.75);
  const tablet = (Size(1920, 1200), 1.5);
  const tabletRatio2 = (Size(1920, 1200), 2.0);

  /// Beri giliran I/O sungguhan (file foto) di antara frame tes.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<_ShotScanner> pumpApp(WidgetTester tester, (Size, double) device, {bool dark = false}) async {
    final (size, ratio) = device;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    const tenant = TenantSummary(id: 1, name: 'Kopi Senja', roleLabel: 'Pemilik', menus: Menus(pos: true, ai: true, reports: true, records: true, printer: true, addCustomer: true));
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@kopisenja.example'},
        'tenants': [tenant.toJson()],
      }),
      'tenant_id': 1,
      'theme_mode': dark ? 'dark' : 'light',
      'printer_mac': '00:11:22:33:44:55',
      'printer_name': 'RPP02N',
      'printer_width': 58,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final photos = await _writePhotos(tester);
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: _menus);
      await db.upsertProducts(_products);
      await db.saveCategories(_categories);
      await db.setJson(MetaKeys.tenant, _tenant);
      await db.setJson(MetaKeys.receipt, _receipt);
      await db.setMeta(MetaKeys.numberBlocks, jsonEncode(_numberBlocks));
      await db.setMeta(MetaKeys.lastNumberSeq, '127');
      // Pesanan tersimpan (open bill) yang sedang menunggu.
      final held = HeldOrderStore(db);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      CartLine line(String key, String name, int quantity, {String? note}) => CartLine.fromProduct(key, _byName(name), quantity: '$quantity.000000', note: note);
      await held.save(
        Cart(lines: [line('a', 'Cappuccino', 2), line('b', 'Croissant Butter', 1)], orderType: OrderType.dineIn, orderLabel: 'Meja 3'),
        name: 'Meja 3',
        total: '73000.00',
        now: today.add(const Duration(hours: 10, minutes: 12)),
      );
      await held.save(
        Cart(lines: [line('a', 'Kopi Susu Botol 250 ml', 3)], orderType: OrderType.takeAway),
        name: 'Pak Budi',
        total: '75000.00',
        now: today.add(const Duration(hours: 10, minutes: 36)),
      );
      await held.save(
        Cart(lines: [line('a', 'Nasi Goreng Kampung', 2, note: 'Tidak pedas'), line('b', 'Es Teh Leci', 2)], orderType: OrderType.delivery, orderLabel: 'Antrian 12'),
        name: 'Antrian 12 · GoFood',
        total: '100000.00',
        now: today.add(const Duration(hours: 10, minutes: 48)),
      );
      return db;
    });
    ScanScreen.continuousPreference = false;
    // Getar/bunyi tidak punya plugin di tes.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    final scanner = _ShotScanner();
    await tester.pumpWidget(RepaintBoundary(
      key: boundaryKey,
      child: ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          localDbOpenerProvider.overrideWithValue((_) async => local!),
          apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(FakeServer(_handler))),
          connectivityStreamProvider.overrideWithValue(const Stream.empty()),
          printerTransportProvider.overrideWithValue(FakePrinter()),
          permissionGateProvider.overrideWithValue(_NoRationale()),
          codeScannerFactoryProvider.overrideWithValue(() => scanner),
          photoRootProvider.overrideWithValue(() async => photos),
        ],
        child: const InfoisApp(),
      ),
    ));
    await settle(tester);
    await settle(tester);
    return scanner;
  }

  Future<void> shot(WidgetTester tester, String name, double ratio) async {
    await settle(tester);
    final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$outDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await settle(tester);
  }

  /// Tunggu snackbar hilang sendiri.
  Future<void> waitSnackBar(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);
  }

  Finder gridScrollable() => find.descendant(of: find.byKey(const Key('product-grid')), matching: find.byType(Scrollable)).first;

  /// Grid & chip kategori kembali ke awal (seperti layar baru dibuka).
  Future<void> catalogToTop(WidgetTester tester) async {
    await tester.fling(gridScrollable(), const Offset(0, 3000), 3000);
    await tester.fling(find.descendant(of: find.byKey(const Key('category-chips')), matching: find.byType(Scrollable)).first, const Offset(2000, 0), 3000);
    await settle(tester);
  }

  /// Gulir grid sampai barang terlihat (grid dibangun malas).
  Future<Finder> showTile(WidgetTester tester, String name) async {
    final tile = find.byKey(_tile(name));
    if (tile.evaluate().isEmpty) {
      await tester.fling(gridScrollable(), const Offset(0, 3000), 3000);
      await settle(tester);
    }
    await tester.scrollUntilVisible(tile, 150, scrollable: gridScrollable());
    await tester.ensureVisible(tile);
    await settle(tester);
    return tile;
  }

  Future<void> tapTile(WidgetTester tester, String name) async {
    await tester.tap(await showTile(tester, name));
    await settle(tester);
  }

  /// Tekan lama barang → lembar barang: jumlah 2 + catatan cepat.
  Future<void> openItemSheet(WidgetTester tester, String name) async {
    await tester.longPress(await showTile(tester, name));
    await settle(tester);
    await tap(tester, find.byKey(const Key('item-qty-plus')));
    await tap(tester, find.widgetWithText(ActionChip, 'Sedikit gula'));
    await tap(tester, find.widgetWithText(ActionChip, 'Es sedikit'));
  }

  /// Isi pesanan contoh: Es Kopi Susu ×2 (catatan), Cappuccino, Croissant, Cokelat Panas.
  Future<void> addSampleItems(WidgetTester tester, {String last = 'Cokelat Panas'}) async {
    await openItemSheet(tester, 'Es Kopi Susu Gula Aren');
    await tap(tester, find.byKey(const Key('item-add')));
    for (final name in ['Cappuccino', 'Croissant Butter', last]) {
      await tapTile(tester, name);
    }
  }

  /// Panel pesanan: makan di tempat, meja, catatan pesanan.
  Future<void> fillOrderDetails(WidgetTester tester) async {
    await tap(tester, find.byKey(const Key('order-type-dine_in')));
    await tap(tester, find.byKey(const Key('order-label')));
    await tester.enterText(find.byKey(const Key('order-label-field')), 'Meja 7');
    await tap(tester, find.byKey(const Key('text-save')));
    await tap(tester, find.byKey(const Key('order-note')));
    await tester.enterText(find.byKey(const Key('order-note-field')), 'Croissant dihangatkan, sajikan bersamaan');
    await tap(tester, find.byKey(const Key('text-save')));
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);
  }

  Finder panelScrollable() => find.descendant(of: find.byType(PosOrderPanel), matching: find.byType(Scrollable)).first;

  Future<void> panelTo(WidgetTester tester, {required bool top}) async {
    await tester.fling(panelScrollable(), Offset(0, top ? 3000 : -3000), 3000);
    await settle(tester);
  }

  testWidgets('HP terang: alur input pesanan dari katalog sampai struk', (tester) async {
    final (_, ratio) = phone;
    final scanner = await pumpApp(tester, phone);

    // 1. Katalog: Semua.
    await shot(tester, '01-kasir', ratio);

    // 2. Kategori Kopi.
    await tap(tester, find.byKey(Key('category-cat:${_kopi.id}')));
    await shot(tester, '02-kategori-kopi', ratio);

    // 3. Lembar barang: foto besar, jumlah, catatan.
    await openItemSheet(tester, 'Es Kopi Susu Gula Aren');
    await shot(tester, '03-detail-barang', ratio);
    await tap(tester, find.byKey(const Key('item-add')));

    // 4. Beberapa barang lagi → bilah keranjang.
    await tapTile(tester, 'Cappuccino');
    await tap(tester, find.byKey(const Key('category-all')));
    await tapTile(tester, 'Croissant Butter');
    await tapTile(tester, 'Cokelat Panas');
    await catalogToTop(tester);
    await shot(tester, '04-keranjang', ratio);

    // 5. Panel pesanan: atas (jenis pesanan + barang) dan bawah (meja,
    // catatan, total).
    await tap(tester, find.byKey(const Key('open-cart')));
    await fillOrderDetails(tester);
    await panelTo(tester, top: true);
    await shot(tester, '05-panel-pesanan', ratio);
    await panelTo(tester, top: false);
    await shot(tester, '05b-panel-pesanan-rincian', ratio);
    await tester.binding.handlePopRoute();
    await settle(tester);

    // 6. Scan barcode kamera, mode scan terus.
    await tap(tester, find.byKey(const Key('scan-button')));
    await tap(tester, find.byKey(const Key('scan-continuous')));
    scanner.emit(_bottleBarcode);
    await settle(tester);
    await shot(tester, '06-scan-barcode', ratio);
    await tap(tester, find.byKey(const Key('scan-done')));
    await waitSnackBar(tester);

    // 7. Bayar tunai dengan keypad: Rp 150.000.
    await tap(tester, find.byKey(const Key('open-cart')));
    await tap(tester, find.byKey(const Key('go-pay')));
    for (final key in ['1', '5', '0', '000']) {
      await tap(tester, find.byKey(Key('key-$key')));
    }
    // Keypad digulir ke bawah saat diketuk; kembali ke atas (total terlihat).
    await tester.fling(find.byType(Scrollable).last, const Offset(0, 3000), 3000);
    await shot(tester, '07-bayar', ratio);

    // 8. Selesai.
    await tap(tester, find.byKey(const Key('pay-submit')));
    await shot(tester, '08-berhasil', ratio);

    // 9. Pesanan tersimpan.
    await tap(tester, find.byKey(const Key('new-sale')));
    await waitSnackBar(tester);
    await tap(tester, find.byKey(const Key('held-orders')));
    await shot(tester, '09-pesanan-ditahan', ratio);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HP gelap: katalog & panel pesanan', (tester) async {
    final (_, ratio) = phone;
    await pumpApp(tester, phone, dark: true);
    await shot(tester, '10-kasir-gelap', ratio);

    await addSampleItems(tester);
    await tap(tester, find.byKey(const Key('open-cart')));
    await fillOrderDetails(tester);
    await panelTo(tester, top: true);
    await shot(tester, '11-panel-pesanan-gelap', ratio);
    await tester.pumpWidget(const SizedBox());
  });

  // Tablet 10" lanskap 1920x1200 pada kerapatan umum 1,5 (1280x800 dp):
  // tata letak dua panel. Pada rasio 2 (960x600 dp) tinggi area kasir di
  // bawah 480 dp sehingga aplikasi memakai tata letak HP (lihat 12b).
  testWidgets('tablet lanskap: katalog + panel pesanan berdampingan', (tester) async {
    final (_, ratio) = tablet;
    await pumpApp(tester, tablet);
    expect(find.byKey(const Key('order-panel')), findsOneWidget, reason: 'Dua panel.');
    await addSampleItems(tester, last: 'Nasi Goreng Kampung');
    await fillOrderDetails(tester);
    await catalogToTop(tester);
    await panelTo(tester, top: true);
    await shot(tester, '12-tablet-kasir', ratio);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tablet lanskap rasio 2 (960x600 dp): tata letak HP', (tester) async {
    final (_, ratio) = tabletRatio2;
    await pumpApp(tester, tabletRatio2);
    await addSampleItems(tester, last: 'Nasi Goreng Kampung');
    await catalogToTop(tester);
    await shot(tester, '12b-tablet-kasir-rasio2', ratio);
    await tester.pumpWidget(const SizedBox());
  });
}
