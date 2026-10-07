import 'models.dart';

class OfflineNumber {
  const OfflineNumber(this.number, this.sequence);

  final String number;
  final int sequence;
}

/// Nomor nota offline dari jatah nomor perangkat (mis. POS-K1/000123).
/// Nomor urut terakhir yang dipakai disimpan di HP, sehingga nomor tidak
/// pernah dipakai dua kali walau belum tersinkron.
class NumberAllocator {
  NumberAllocator._();

  /// Nomor berikutnya setelah [lastUsed], atau null bila jatah habis.
  static OfflineNumber? next(List<NumberBlock> blocks, int lastUsed, DateTime date) {
    final sorted = [...blocks]..sort((a, b) => a.start.compareTo(b.start));
    for (final block in sorted) {
      if (block.end <= lastUsed) {
        continue;
      }
      final sequence = lastUsed >= block.start ? lastUsed + 1 : block.start;
      return OfflineNumber(render(block.format, date, sequence), sequence);
    }
    return null;
  }

  /// Sisa nomor yang belum dipakai di semua jatah.
  static int remaining(List<NumberBlock> blocks, int lastUsed) {
    var total = 0;
    for (final block in blocks) {
      if (block.end > lastUsed) {
        total += block.end - (lastUsed >= block.start ? lastUsed : block.start - 1);
      }
    }
    return total;
  }

  /// Sama dengan `DocumentNumberGenerator::format()` di server.
  static String render(String format, DateTime date, int sequence) {
    String two(int value) => value.toString().padLeft(2, '0');
    final withDate = format
        .replaceAll('{YYYY}', date.year.toString())
        .replaceAll('{YY}', two(date.year % 100))
        .replaceAll('{MM}', two(date.month))
        .replaceAll('{DD}', two(date.day));
    return withDate.replaceAllMapped(RegExp(r'\{SEQ(?::(\d+))?\}'), (match) {
      final width = int.tryParse(match.group(1) ?? '') ?? 4;
      return sequence.toString().padLeft(width, '0');
    });
  }
}
