import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/ui/theme.dart';

/// Brand Guideline v1.0: warna datar Infois dan kontras WCAG AA (≥ 4,5:1
/// untuk teks biasa) di mode terang dan gelap.
void main() {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  test('token brand: hijau Infois terang, #4BD98A + permukaan #08110C/#101A14 gelap', () {
    final light = buildTheme(Brightness.light);
    final dark = buildTheme(Brightness.dark);
    expect(light.colorScheme.primary, const Color(0xFF0A7F3E));
    expect(light.colorScheme.onSurface, const Color(0xFF0F1A14));
    expect(light.scaffoldBackgroundColor, const Color(0xFFF3F7F4));
    expect(light.colorScheme.tertiary, const Color(0xFFFFB020));
    expect(dark.colorScheme.primary, const Color(0xFF4BD98A));
    expect(dark.scaffoldBackgroundColor, const Color(0xFF08110C));
    expect(dark.colorScheme.surface, const Color(0xFF101A14));
  });

  for (final brightness in Brightness.values) {
    test('kontras AA: ${brightness.name}', () {
      final scheme = buildTheme(brightness).colorScheme;
      final canvas = buildTheme(brightness).scaffoldBackgroundColor;
      final pairs = <String, (Color, Color)>{
        'teks di permukaan': (scheme.onSurface, scheme.surface),
        'teks di latar': (scheme.onSurface, canvas),
        'teks sekunder di permukaan': (scheme.onSurfaceVariant, scheme.surface),
        'teks sekunder di latar': (scheme.onSurfaceVariant, canvas),
        'tombol utama': (scheme.onPrimary, scheme.primary),
        'harga (hijau) di kartu': (scheme.primary, scheme.surface),
        'kotak total': (scheme.onPrimaryContainer, scheme.primaryContainer),
        'label stok menipis (Nota)': (Brand.ink, Brand.nota),
        'label habis': (Colors.white, Brand.danger),
      };
      for (final MapEntry(key: name, value: (fg, bg)) in pairs.entries) {
        expect(contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '$name (${brightness.name})');
      }
    });
  }
}
