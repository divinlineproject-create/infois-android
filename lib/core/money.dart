import 'bcmath.dart';

/// Port langsung dari `App\Support\Money` (backoffice). Semua nilai uang
/// dan qty disimpan sebagai string desimal, bukan double.
class Money {
  Money._();

  static String normalize(Object? value, [int scale = 2]) {
    if (value == null) {
      return zero(scale);
    }
    var text = value is double ? value.toStringAsFixed(scale + 2) : value.toString().trim();
    if (text.isEmpty || !isNumericString(text)) {
      return zero(scale);
    }
    if (text.startsWith('+')) {
      text = text.substring(1);
    }
    return round(text, scale);
  }

  /// Bulatkan setengah menjauhi nol, persis `Money::round`.
  static String round(String value, [int scale = 2]) {
    final offset = '0.${'0' * scale}5';
    return value.trim().startsWith('-') ? bcsub(value, offset, scale) : bcadd(value, offset, scale);
  }

  static String zero([int scale = 2]) => bcadd('0', '0', scale);

  static String add(List<Object?> values) {
    var sum = '0';
    for (final value in values) {
      sum = bcadd(sum, normalize(value, 4), 4);
    }
    return normalize(sum);
  }

  static String sub(Object? left, Object? right) => normalize(bcsub(normalize(left, 4), normalize(right, 4), 4));

  static String mul(Object? left, Object? right, [int scale = 2]) => round(bcmul(normalize(left, 6), normalize(right, 6), 8), scale);

  static String percent(Object? amount, Object? rate) =>
      round(bcdiv(bcmul(normalize(amount, 6), normalize(rate, 6), 8), '100', 8));

  static int compare(Object? left, Object? right) => bccomp(normalize(left), normalize(right), 2);

  static bool isZero(Object? value) => compare(value, '0') == 0;

  static bool isPositive(Object? value) => compare(value, '0') > 0;

  static String max(Object? left, Object? right) => compare(left, right) >= 0 ? normalize(left) : normalize(right);

  static String min(Object? left, Object? right) => compare(left, right) <= 0 ? normalize(left) : normalize(right);
}
