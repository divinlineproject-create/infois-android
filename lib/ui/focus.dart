import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Tutup keyboard layar: lepas fokus isian yang aktif dan bersihkan riwayat
/// fokus cakupannya, sehingga isian itu tidak difokuskan ulang otomatis
/// (mis. saat lembar/dialog ditutup atau aplikasi dibuka lagi).
void dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

/// Isian teks (EditableText) yang sedang fokus.
bool textFieldFocused() => FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;

/// Navigator: setiap halaman/lembar/dialog baru melepas fokus isian di
/// bawahnya. Tanpa ini, menutup lembar barang atau kembali dari Bayar
/// memfokuskan ulang kotak cari kasir dan keyboard muncul sendiri.
class KeyboardDismissObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) {
      dismissKeyboard();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => dismissKeyboard();
}

/// Ketuk di luar isian (area kosong) menutup keyboard.
class TapToDismissKeyboard extends StatelessWidget {
  const TapToDismissKeyboard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(behavior: HitTestBehavior.translucent, onTap: dismissKeyboard, child: child);
}

/// Tab yang sedang tampil di navigasi bawah (tab tersembunyi tetap hidup di
/// IndexedStack, jadi perlu tahu apakah dirinya aktif).
class TabActive extends InheritedWidget {
  const TabActive({super.key, required this.active, required super.child});

  final bool active;

  /// Tanpa navigasi bawah (mis. tes satu layar): dianggap aktif.
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TabActive>()?.active ?? true;

  /// Seperti [of], untuk dipakai di luar build (callback) tanpa mendaftar dependensi.
  static bool read(BuildContext context) => context.getInheritedWidgetOfExactType<TabActive>()?.active ?? true;

  @override
  bool updateShouldNotify(TabActive oldWidget) => oldWidget.active != active;
}

/// Pengumpul ketikan scanner barcode (Bluetooth/USB, mode keyboard): huruf
/// yang datang beruntun cepat lalu Enter = satu kode. Jeda lebih dari
/// [maxGap] memulai kode baru (ketikan tangan tidak ikut terkumpul).
class ScannerKeyBuffer {
  ScannerKeyBuffer({this.maxGap = const Duration(milliseconds: 120), this.minLength = 3});

  final Duration maxGap;
  final int minLength;
  final StringBuffer _buffer = StringBuffer();
  Duration? _last;

  /// Kode lengkap saat Enter, selain itu null.
  String? feed(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return null;
    }
    final last = _last;
    _last = event.timeStamp;
    if (last != null && (event.timeStamp - last > maxGap || event.timeStamp < last)) {
      _buffer.clear();
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final code = _buffer.toString().trim();
      _buffer.clear();
      return code.length >= minLength ? code : null;
    }
    final character = event.character;
    if (character != null && character.length == 1 && character.codeUnitAt(0) >= 0x20) {
      _buffer.write(character);
    }
    return null;
  }
}

/// Menangkap scanner barcode berbentuk keyboard tanpa memfokuskan kotak
/// isian (keyboard layar tidak muncul). Hanya saat [active] dan tidak ada
/// isian teks yang fokus (ketikan di isian tetap masuk ke isian itu).
class HardwareScannerListener extends StatefulWidget {
  const HardwareScannerListener({super.key, required this.active, required this.onCode, required this.child});

  final bool Function() active;
  final ValueChanged<String> onCode;
  final Widget child;

  @override
  State<HardwareScannerListener> createState() => _HardwareScannerListenerState();
}

class _HardwareScannerListenerState extends State<HardwareScannerListener> {
  final _buffer = ScannerKeyBuffer();

  bool _handle(KeyEvent event) {
    if (!mounted || !widget.active() || textFieldFocused()) {
      return false;
    }
    final code = _buffer.feed(event);
    if (code == null) {
      return false;
    }
    widget.onCode(code);
    return true;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handle);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
