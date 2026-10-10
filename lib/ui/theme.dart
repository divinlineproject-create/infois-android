import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';

/// Warna brand Infois (sama dengan web).
class Brand {
  Brand._();

  static const green = Color(0xFF0A7F3E);
  static const greenDark = Color(0xFF07632D);
  static const ink = Color(0xFF0F1A14);
  static const surface = Color(0xFFF3F7F4);
  static const amber = Color(0xFFB45309);
  static const danger = Color(0xFFB91C1C);
}

/// Warna teks sekunder (keterangan kecil) yang tetap terbaca di mode gelap;
/// `Colors.grey.shade700` hampir hilang di atas kartu gelap.
Color mutedText(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

/// Teks peringatan (kuning) yang tetap kontras: amber-700 di mode terang,
/// amber-300 di mode gelap (amber-700 di atas kartu gelap hanya 3,3:1).
Color warningText(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFCD34D) : Brand.amber;

/// Teks galat (merah) yang tetap kontras: red-700 terang, red-300 gelap.
Color dangerText(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFCA5A5) : Brand.danger;

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.green,
    brightness: brightness,
    primary: dark ? const Color(0xFF4CC283) : Brand.green,
    surface: dark ? const Color(0xFF121A15) : Colors.white,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Poppins', brightness: brightness);

  return base.copyWith(
    scaffoldBackgroundColor: dark ? const Color(0xFF0B110D) : Brand.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF121A15) : Colors.white,
      foregroundColor: dark ? Colors.white : Brand.ink,
      elevation: 0,
      scrolledUnderElevation: 1,
      titleTextStyle: TextStyle(fontFamily: 'Poppins', fontSize: 18, fontWeight: FontWeight.w600, color: dark ? Colors.white : Brand.ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 52),
        textStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 15, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF1A241E) : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF16201A) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: dark ? const Color(0xFF26342B) : const Color(0xFFE2EAE5))),
      margin: EdgeInsets.zero,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontFamily: 'Poppins', fontSize: 12, fontWeight: FontWeight.w500)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Pilihan tampilan di Akun › Tampilan, tersimpan di HP.
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => switch (ref.watch(storageProvider).themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(storageProvider).setThemeMode(mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

/// Label pilihan tampilan.
String themeModeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => 'Ikuti sistem',
      ThemeMode.light => 'Terang',
      ThemeMode.dark => 'Gelap',
    };
