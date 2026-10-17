import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';

/// Warna brand Infois (Brand Guideline v1.0, sama dengan web). Warna datar,
/// tanpa gradasi.
class Brand {
  Brand._();

  /// Hijau Infois (warna utama).
  static const green = Color(0xFF0A7F3E);
  static const greenDark = Color(0xFF07632D);

  /// Tinta: teks utama.
  static const ink = Color(0xFF0F1A14);

  /// Hijau netral: latar halaman, garis tipis, garis tegas.
  static const surface = Color(0xFFF3F7F4);
  static const line = Color(0xFFE4ECE7);
  static const lineStrong = Color(0xFFD3DFD7);

  /// Nota: aksen kuning, dipakai seperlunya (penanda, bukan teks di latar putih).
  static const nota = Color(0xFFFFB020);

  static const amber = Color(0xFFB45309);
  static const danger = Color(0xFFB91C1C);

  /// Mode gelap (guideline): hijau terang + permukaan hijau sangat gelap.
  static const greenOnDark = Color(0xFF4BD98A);
  static const darkCanvas = Color(0xFF08110C);
  static const darkSurface = Color(0xFF101A14);
}

/// Skala jarak (4/8/12/16/24) dan sudut, dipakai seluruh layar.
class Space {
  Space._();

  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
}

class Radii {
  Radii._();

  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
}

/// Warna teks sekunder (keterangan kecil) yang tetap terbaca di mode gelap;
/// `Colors.grey.shade700` hampir hilang di atas kartu gelap.
Color mutedText(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

/// Teks peringatan (kuning) yang tetap kontras: amber-700 di mode terang,
/// amber-300 di mode gelap (amber-700 di atas kartu gelap hanya 3,3:1).
Color warningText(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFCD34D) : Brand.amber;

/// Teks galat (merah) yang tetap kontras: red-700 terang, red-300 gelap.
Color dangerText(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFCA5A5) : Brand.danger;

/// Warna khusus Tim AI (gaya aplikasi chat: kotak tulis melayang, bubble
/// pengguna lembut, jawaban tanpa bubble). Terang dan gelap.
class AiColors {
  AiColors._();

  static bool _dark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

  /// Latar layar percakapan (sedikit lebih hangat dari kartu).
  static Color canvas(BuildContext context) => _dark(context) ? Brand.darkCanvas : const Color(0xFFF6F8F6);

  /// Isi kotak tulis pesan.
  static Color composerFill(BuildContext context) => _dark(context) ? Theme.of(context).colorScheme.surfaceContainerHigh : Colors.white;

  /// Garis tepi halus (kotak tulis, kartu usulan, kartu file).
  static Color border(BuildContext context) => _dark(context) ? const Color(0xFF2A3830) : const Color(0xFFDCE5DF);

  /// Bubble pesan pengguna.
  static Color userBubble(BuildContext context) => _dark(context) ? Theme.of(context).colorScheme.surfaceContainerHighest : const Color(0xFFE5EEE8);

  /// Kartu usulan / file di dalam jawaban.
  static Color card(BuildContext context) => _dark(context) ? Brand.darkSurface : Colors.white;

  /// Latar kode & kepala tabel di jawaban.
  static Color codeFill(BuildContext context) => _dark(context) ? const Color(0xFF1C2821) : const Color(0xFFEFF3F0);

  /// Bayangan lembut kotak tulis (mode gelap tanpa bayangan).
  static List<BoxShadow> composerShadow(BuildContext context) =>
      _dark(context) ? const [] : [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 18, offset: const Offset(0, 4))];
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final ink = dark ? const Color(0xFFE8F0EA) : Brand.ink;
  final muted = dark ? const Color(0xFFA3B5AA) : const Color(0xFF4A5A50);
  final line = dark ? const Color(0xFF22312A) : Brand.line;
  final lineStrong = dark ? const Color(0xFF2E4036) : Brand.lineStrong;
  final surface = dark ? Brand.darkSurface : Colors.white;
  final canvas = dark ? Brand.darkCanvas : Brand.surface;
  final primary = dark ? Brand.greenOnDark : Brand.green;
  final onPrimary = dark ? Brand.darkCanvas : Colors.white;

  final scheme = ColorScheme.fromSeed(seedColor: Brand.green, brightness: brightness).copyWith(
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: dark ? const Color(0xFF133D27) : const Color(0xFFDDF3E5),
    onPrimaryContainer: dark ? const Color(0xFFB8F5D2) : const Color(0xFF05391B),
    secondary: dark ? const Color(0xFF9FD9B6) : const Color(0xFF2F6B4A),
    onSecondary: dark ? Brand.darkCanvas : Colors.white,
    secondaryContainer: dark ? const Color(0xFF1D2B23) : const Color(0xFFE4ECE7),
    onSecondaryContainer: ink,
    tertiary: Brand.nota,
    onTertiary: Brand.ink,
    surface: surface,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerLowest: dark ? const Color(0xFF050B08) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF0C1510) : const Color(0xFFF8FBF9),
    surfaceContainer: dark ? const Color(0xFF131E17) : Brand.surface,
    surfaceContainerHigh: dark ? const Color(0xFF16221B) : const Color(0xFFEDF3EF),
    surfaceContainerHighest: dark ? const Color(0xFF1D2B23) : Brand.line,
    surfaceTint: Colors.transparent,
    outline: lineStrong,
    outlineVariant: line,
    error: dark ? const Color(0xFFFCA5A5) : Brand.danger,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Poppins', brightness: brightness);
  final text = base.textTheme.apply(bodyColor: ink, displayColor: ink).copyWith(
        titleLarge: base.textTheme.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w600, color: ink, height: 1.25),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: ink),
        titleSmall: base.textTheme.titleSmall?.copyWith(fontSize: 14, fontWeight: FontWeight.w600, color: ink),
        labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      );
  const pill = StadiumBorder();
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.m));

  return base.copyWith(
    scaffoldBackgroundColor: canvas,
    canvasColor: canvas,
    textTheme: text,
    dividerColor: line,
    dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: Border(bottom: BorderSide(color: line)),
      titleTextStyle: TextStyle(fontFamily: 'Poppins', fontSize: 18, fontWeight: FontWeight.w600, color: ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: Space.xl),
        textStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: ink,
        side: BorderSide(color: lineStrong),
        textStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 15, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 44), textStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 14.5, fontWeight: FontWeight.w600), shape: rounded),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(44, 44))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF16221B) : Colors.white,
      hintStyle: TextStyle(color: muted),
      prefixIconColor: muted,
      suffixIconColor: muted,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.m), borderSide: BorderSide(color: lineStrong)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.m), borderSide: BorderSide(color: lineStrong)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.m), borderSide: BorderSide(color: primary, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.l), side: BorderSide(color: line)),
      margin: EdgeInsets.zero,
    ),
    chipTheme: ChipThemeData(
      shape: pill,
      side: WidgetStateBorderSide.resolveWith((states) => BorderSide(color: states.contains(WidgetState.selected) ? primary : lineStrong)),
      color: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? primary : surface),
      labelStyle: TextStyle(
        fontFamily: 'Poppins',
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
        color: WidgetStateColor.resolveWith((states) => states.contains(WidgetState.selected) ? onPrimary : ink),
      ),
      checkmarkColor: onPrimary,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: pill,
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(color: states.contains(WidgetState.selected) ? scheme.onPrimaryContainer : muted, size: 24)),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontFamily: 'Poppins',
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? ink : muted,
          )),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      modalBackgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: lineStrong,
      dragHandleSize: const Size(40, 4),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
      titleTextStyle: TextStyle(fontFamily: 'Poppins', fontSize: 18, fontWeight: FontWeight.w600, color: ink),
    ),
    listTileTheme: ListTileThemeData(iconColor: muted, minVerticalPadding: Space.s, shape: rounded),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: primary, linearTrackColor: line, circularTrackColor: Colors.transparent),
    badgeTheme: BadgeThemeData(backgroundColor: primary, textColor: onPrimary),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF1D2B23) : Brand.ink,
      contentTextStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 14, color: Colors.white),
      actionTextColor: Brand.greenOnDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.m)),
    ),
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
