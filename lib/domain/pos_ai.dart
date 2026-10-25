// Input AI kasir: pesanan diketik, diucapkan, atau difoto diubah server
// menjadi barang kasir yang langsung masuk keranjang (API.md › POST
// pos/ai-input). Online saja; memakai koin perusahaan.

import '../core/money.dart';

/// Cara input.
enum PosAiMode {
  text('text', 'Ketik'),
  voice('voice', 'Suara'),
  photo('photo', 'Foto');

  const PosAiMode(this.code, this.label);

  final String code;
  final String label;
}

/// Satu barang yang dipilih AI (barang aktif kasir, satuan persis katalog).
class PosAiItem {
  const PosAiItem({required this.productId, required this.name, required this.quantity, required this.unit, this.note, this.said = ''});

  factory PosAiItem.fromJson(Map<String, dynamic> json) => PosAiItem(
        productId: (json['product_id'] as num).toInt(),
        name: json['name']?.toString() ?? '',
        quantity: Money.normalize(json['quantity'], 6),
        unit: json['unit']?.toString(),
        note: json['note']?.toString(),
        said: json['said']?.toString() ?? '',
      );

  final int productId;
  final String name;
  final String quantity;
  final String? unit;
  final String? note;
  final String said;
}

/// Saran barang untuk baris "tidak ditemukan".
class PosAiSuggestion {
  const PosAiSuggestion({required this.id, required this.name});

  factory PosAiSuggestion.fromJson(Map<String, dynamic> json) => PosAiSuggestion(id: (json['id'] as num).toInt(), name: json['name']?.toString() ?? '');

  final int id;
  final String name;
}

/// Pesanan yang tidak cocok dengan barang kasir: tidak dimasukkan.
class PosAiUnmatched {
  const PosAiUnmatched({required this.said, this.quantity = '1.000000', this.unit, this.note, this.suggestions = const []});

  factory PosAiUnmatched.fromJson(Map<String, dynamic> json) => PosAiUnmatched(
        said: json['said']?.toString() ?? '',
        quantity: Money.normalize(json['quantity'] ?? '1', 6),
        unit: json['unit']?.toString(),
        note: json['note']?.toString(),
        suggestions: [for (final item in (json['suggestions'] as List? ?? const [])) PosAiSuggestion.fromJson(Map<String, dynamic>.from(item as Map))],
      );

  final String said;
  final String quantity;
  final String? unit;
  final String? note;
  final List<PosAiSuggestion> suggestions;

  PosAiUnmatched copyWith({List<PosAiSuggestion>? suggestions}) =>
      PosAiUnmatched(said: said, quantity: quantity, unit: unit, note: note, suggestions: suggestions ?? this.suggestions);
}

/// Jawaban server.
class PosAiResult {
  const PosAiResult({this.items = const [], this.unmatched = const [], this.heard, this.message, this.coinsUsed = '0', this.coinsLeft = ''});

  factory PosAiResult.fromJson(Map<String, dynamic> json) => PosAiResult(
        items: [for (final item in (json['items'] as List? ?? const [])) PosAiItem.fromJson(Map<String, dynamic>.from(item as Map))],
        unmatched: [for (final item in (json['unmatched'] as List? ?? const [])) PosAiUnmatched.fromJson(Map<String, dynamic>.from(item as Map))],
        heard: json['heard']?.toString(),
        message: json['message']?.toString(),
        coinsUsed: json['coins_used_label']?.toString() ?? '0',
        coinsLeft: json['coins_left']?.toString() ?? '',
      );

  final List<PosAiItem> items;
  final List<PosAiUnmatched> unmatched;

  /// Transkrip suara / baris yang terbaca dari foto (bila ada).
  final String? heard;

  /// Pesan untuk kasir (mis. suara tidak terdengar jelas).
  final String? message;

  /// Koin yang terpakai & sisa, sudah diformat ("0,3", "49,7").
  final String coinsUsed;
  final String coinsLeft;
}

/// Barang yang sudah masuk keranjang dari Input AI (untuk ringkasan).
class PosAiAdded {
  const PosAiAdded({required this.name, required this.quantity, required this.unit});

  final String name;
  final String quantity;
  final String unit;
}

/// Hasil memasukkan jawaban server ke keranjang.
class PosAiApplied {
  const PosAiApplied({required this.added, required this.unmatched});

  final List<PosAiAdded> added;
  final List<PosAiUnmatched> unmatched;
}
