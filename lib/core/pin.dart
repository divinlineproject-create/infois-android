import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PIN 6 angka aplikasi (tablet kasir bersama). Aturannya sama dengan server
/// (MobilePin): 6 angka, bukan angka sama semua / berurutan.
class PinCode {
  static const length = 6;

  /// Salah berturut-turut saat offline sebelum harus dicek ke server.
  static const offlineAttempts = 5;

  static final _digits = RegExp(r'^\d{6}$');

  /// Alasan PIN ditolak, atau null bila boleh dipakai.
  static String? invalidReason(String pin) {
    if (!_digits.hasMatch(pin)) {
      return 'PIN harus $length angka.';
    }
    if (pin.split('').toSet().length == 1 || '0123456789'.contains(pin) || '9876543210'.contains(pin)) {
      return 'PIN terlalu mudah ditebak (angka sama semua atau berurutan). Pilih kombinasi lain.';
    }
    return null;
  }

  static const _rounds = 20000;

  /// Pencocok PIN untuk disimpan di HP: `garam:hash` (SHA-256 berulang).
  static String verifier(String pin, {String? salt}) {
    final useSalt = salt ?? base64UrlEncode(List<int>.generate(16, (_) => Random.secure().nextInt(256)));
    return '$useSalt:${_hash(pin, useSalt)}';
  }

  static bool matches(String pin, String? verifier) {
    if (verifier == null) {
      return false;
    }
    final parts = verifier.split(':');
    return parts.length == 2 && parts[1] == _hash(pin, parts[0]);
  }

  static String _hash(String pin, String salt) {
    var digest = sha256.convert(utf8.encode('$salt|$pin')).bytes;
    for (var i = 0; i < _rounds; i++) {
      digest = sha256.convert([...digest, ...utf8.encode(salt)]).bytes;
    }
    return base64UrlEncode(digest);
  }
}
