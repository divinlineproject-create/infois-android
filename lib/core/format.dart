import 'package:intl/intl.dart';

import 'bcmath.dart';
import 'money.dart';

/// Format angka gaya Indonesia, sama dengan `Money::format` di web:
/// "Rp 1.500.000" atau "Rp 1.500.000,50".
String rupiah(Object? value, {bool symbol = true}) {
  final normalized = Money.normalize(value);
  final negative = normalized.startsWith('-');
  final parts = normalized.replaceFirst('-', '').split('.');
  final integer = _thousands(parts[0]);
  final decimals = parts.length > 1 && parts[1] != '00' ? ',${parts[1]}' : '';
  return '${negative ? '-' : ''}${symbol ? 'Rp ' : ''}$integer$decimals';
}

/// Qty tanpa nol di belakang: "1,5", "2", "0,333333".
String qty(Object? value) {
  final normalized = Money.normalize(value, 6);
  final negative = normalized.startsWith('-');
  final parts = normalized.replaceFirst('-', '').split('.');
  final fraction = parts.length > 1 ? parts[1].replaceFirst(RegExp(r'0+$'), '') : '';
  return '${negative ? '-' : ''}${_thousands(parts[0])}${fraction.isEmpty ? '' : ',$fraction'}';
}

/// Persen tanpa nol di belakang: "10", "12,5".
String percentLabel(Object? value) {
  final normalized = Money.normalize(value);
  final parts = normalized.split('.');
  final fraction = parts[1].replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? parts[0] : '${parts[0]},$fraction';
}

String _thousands(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write('.');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Baca input qty dari kasir ("1,5" / "1.5") menjadi string desimal 6 angka.
/// Kembalikan null bila bukan angka.
String? parseQuantityInput(String input) {
  final text = input.trim().replaceAll(' ', '').replaceAll(',', '.');
  if (text.isEmpty || !isNumericString(text) || '.'.allMatches(text).length > 1) {
    return null;
  }
  return Money.normalize(text, 6);
}

/// Baca input nominal rupiah: titik ribuan diabaikan, koma = desimal.
String? parseMoneyInput(String input) {
  final text = input.trim().replaceAll(' ', '').replaceAll('Rp', '').replaceAll('.', '').replaceAll(',', '.');
  if (text.isEmpty || !isNumericString(text)) {
    return null;
  }
  return Money.normalize(text);
}

String dateLabel(DateTime value) => DateFormat('d MMM yyyy', 'id_ID').format(value);

String dateTimeLabel(DateTime value) => DateFormat('d MMM yyyy HH:mm', 'id_ID').format(value);

String receiptDateTime(DateTime value) => DateFormat('dd/MM/yyyy HH:mm', 'id_ID').format(value);

String isoDate(DateTime value) => DateFormat('yyyy-MM-dd').format(value);
