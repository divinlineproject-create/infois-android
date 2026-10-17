import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Ubah teks nominal dengan tombol keypad: angka, "000", hapus satu, kosongkan.
/// Teks hanya berisi digit (rupiah tanpa desimal), maksimal 13 digit.
String applyKeypad(String current, String key) {
  switch (key) {
    case 'back':
      return current.isEmpty ? current : current.substring(0, current.length - 1);
    case 'clear':
      return '';
    default:
      final next = (current == '0' ? '' : current) + key;
      final trimmed = next.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      return trimmed.length > 13 ? current : trimmed;
  }
}

/// Keypad angka besar untuk uang tunai (seperti mesin kasir).
class PosKeypad extends StatelessWidget {
  const PosKeypad({super.key, required this.onKey});

  final ValueChanged<String> onKey;

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['000', '0', 'back'],
  ];

  void _press(String key) {
    HapticFeedback.selectionClick();
    onKey(key);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      for (final row in _rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            for (final (index, key) in row.indexed) ...[
              if (index > 0) const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: key == 'back'
                      ? GestureDetector(
                          onLongPress: () => _press('clear'),
                          child: FilledButton.tonal(
                            key: const Key('key-back'),
                            onPressed: () => _press('back'),
                            style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                            child: const Icon(Icons.backspace_outlined, semanticLabel: 'Hapus'),
                          ),
                        )
                      : OutlinedButton(
                          key: Key('key-$key'),
                          onPressed: () => _press(key),
                          style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: scheme.onSurface, backgroundColor: scheme.surface),
                          child: Text(key, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                        ),
                ),
              ),
            ],
          ]),
        ),
    ]);
  }
}
