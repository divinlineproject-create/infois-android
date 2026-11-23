import 'dart:convert';
import 'dart:typed_data';

import '../core/money.dart';

/// Satu QR QRIS dinamis dari server (`/pos/qris`): dibuat untuk total nota,
/// statusnya ditanyakan sampai dibayar. [qrContent] & [qrImage] hanya ada
/// selama `pending`.
class QrisPayment {
  const QrisPayment({
    required this.id,
    required this.status,
    required this.amount,
    this.statusLabel,
    this.qrContent,
    this.qrImage,
    this.expiresAt,
    this.paidAt,
    this.issuer,
    this.reference,
    this.invoiceId,
  });

  factory QrisPayment.fromJson(Map<String, dynamic> json) => QrisPayment(
        id: (json['id'] as num).toInt(),
        status: json['status']?.toString() ?? 'pending',
        statusLabel: _blank(json['status_label']),
        amount: Money.normalize(json['amount']),
        qrContent: _blank(json['qr_content']),
        qrImage: _blank(json['qr_image']),
        expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
        paidAt: DateTime.tryParse(json['paid_at']?.toString() ?? ''),
        issuer: _blank(json['issuer']),
        reference: _blank(json['reference']),
        invoiceId: json['invoice_id'] is num ? (json['invoice_id'] as num).toInt() : null,
      );

  final int id;

  /// `pending` | `paid` | `expired` | `failed` | `canceled`.
  final String status;
  final String? statusLabel;
  final String amount;
  final String? qrContent;

  /// `data:image/png;base64,…`.
  final String? qrImage;
  final DateTime? expiresAt;
  final DateTime? paidAt;

  /// Bank / e-wallet pembayar (mis. "GoPay").
  final String? issuer;
  final String? reference;
  final int? invoiceId;

  bool get isPending => status == 'pending';
  bool get isPaid => status == 'paid';

  /// Kedaluwarsa / gagal / dibatalkan: perlu QR baru.
  bool get isOver => status == 'expired' || status == 'failed' || status == 'canceled';

  /// Gambar PNG dari [qrImage] (data URI base64), atau null.
  Uint8List? get imageBytes {
    final image = qrImage;
    if (image == null) {
      return null;
    }
    final comma = image.indexOf(',');
    try {
      return base64Decode(comma >= 0 ? image.substring(comma + 1) : image);
    } on FormatException {
      return null;
    }
  }

  /// Jawaban status terbaru; QR (isi & gambar) lama tetap dipakai bila tidak dikirim ulang.
  QrisPayment merge(QrisPayment next) => QrisPayment(
        id: next.id,
        status: next.status,
        statusLabel: next.statusLabel ?? statusLabel,
        amount: next.amount,
        qrContent: next.qrContent ?? qrContent,
        qrImage: next.qrImage ?? qrImage,
        expiresAt: next.expiresAt ?? expiresAt,
        paidAt: next.paidAt ?? paidAt,
        issuer: next.issuer ?? issuer,
        reference: next.reference ?? reference,
        invoiceId: next.invoiceId ?? invoiceId,
      );

  static String? _blank(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}
