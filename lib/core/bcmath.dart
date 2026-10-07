/// Aritmatika desimal string yang meniru PHP bcmath (dipotong ke arah nol,
/// tanpa floating point). Dipakai supaya hitungan keranjang di HP sama
/// persis dengan `App\Support\Money` dan `InvoiceCalculator` di server.
library;

class _Dec {
  const _Dec(this.value, this.scale);

  /// Nilai tanpa koma: angka sebenarnya = value / 10^scale.
  final BigInt value;
  final int scale;

  static final RegExp _pattern = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$');

  static _Dec parse(String input) {
    final match = _pattern.firstMatch(input.trim());
    if (match == null) {
      return _Dec(BigInt.zero, 0);
    }
    final sign = match.group(1) == '-' ? -1 : 1;
    final whole = match.group(2) ?? '';
    final fraction = match.group(3) ?? '';
    final digits = '${whole.isEmpty ? '0' : whole}$fraction';
    final value = BigInt.parse(digits) * BigInt.from(sign);
    return _Dec(value, fraction.length);
  }

  _Dec rescale(int target) {
    if (target == scale) {
      return this;
    }
    if (target > scale) {
      return _Dec(value * BigInt.from(10).pow(target - scale), target);
    }
    // Potong ke arah nol (perilaku bcmath).
    return _Dec(value ~/ BigInt.from(10).pow(scale - target), target);
  }

  @override
  String toString() {
    final negative = value.isNegative;
    var digits = value.abs().toString();
    if (scale == 0) {
      return value == BigInt.zero ? '0' : '${negative ? '-' : ''}$digits';
    }
    if (digits.length <= scale) {
      digits = digits.padLeft(scale + 1, '0');
    }
    final whole = digits.substring(0, digits.length - scale);
    final fraction = digits.substring(digits.length - scale);
    final isZero = value == BigInt.zero;
    return '${negative && !isZero ? '-' : ''}$whole.$fraction';
  }
}

/// Hasil a + b dipotong ke [scale] angka di belakang koma.
String bcadd(String a, String b, int scale) {
  final left = _Dec.parse(a);
  final right = _Dec.parse(b);
  final common = left.scale > right.scale ? left.scale : right.scale;
  final sum = _Dec(left.rescale(common).value + right.rescale(common).value, common);
  return sum.rescale(scale).toString();
}

/// Hasil a − b dipotong ke [scale] angka di belakang koma.
String bcsub(String a, String b, int scale) {
  final right = _Dec.parse(b);
  return bcadd(a, _Dec(-right.value, right.scale).toString(), scale);
}

/// Hasil a × b dipotong ke [scale] angka di belakang koma.
String bcmul(String a, String b, int scale) {
  final left = _Dec.parse(a);
  final right = _Dec.parse(b);
  final product = _Dec(left.value * right.value, left.scale + right.scale);
  return product.rescale(scale).toString();
}

/// Hasil a ÷ b dipotong ke [scale] angka di belakang koma.
String bcdiv(String a, String b, int scale) {
  final left = _Dec.parse(a);
  final right = _Dec.parse(b);
  if (right.value == BigInt.zero) {
    throw ArgumentError('Pembagian dengan nol');
  }
  // (l / 10^ls) / (r / 10^rs) × 10^scale = l × 10^(rs + scale) / (r × 10^ls)
  final numerator = left.value * BigInt.from(10).pow(right.scale + scale);
  final denominator = right.value * BigInt.from(10).pow(left.scale);
  return _Dec(numerator ~/ denominator, scale).toString();
}

/// Bandingkan a dan b sampai [scale] angka di belakang koma: -1, 0, atau 1.
int bccomp(String a, String b, int scale) {
  final left = _Dec.parse(a).rescale(scale);
  final right = _Dec.parse(b).rescale(scale);
  return left.value.compareTo(right.value).sign;
}

/// Apakah string berupa angka desimal biasa (tanpa notasi eksponen).
bool isNumericString(String value) {
  final trimmed = value.trim();
  return trimmed.isNotEmpty && trimmed != '-' && trimmed != '+' && trimmed != '.' && _Dec._pattern.hasMatch(trimmed);
}
