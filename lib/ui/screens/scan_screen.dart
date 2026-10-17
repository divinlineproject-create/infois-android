import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../../core/format.dart';
import '../../domain/models.dart';
import '../../services/code_scanner.dart';
import '../../state/pos_state.dart';
import '../theme.dart';
import '../widgets/product_image.dart';

/// Hasil layar scan: jumlah barang yang ditambahkan dan barang terakhir.
class ScanOutcome {
  const ScanOutcome(this.added, this.last);

  final int added;
  final Product? last;
}


/// Buka layar scan barcode kamera. Izin kamera sudah dijelaskan sebelumnya
/// (lihat KasirScreen); jendela izin sistem muncul saat kamera mulai.
Future<ScanOutcome?> openScanScreen(BuildContext context) => Navigator.of(context).push<ScanOutcome>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const ScanScreen()),
    );

/// Scan barcode dengan kamera HP: kode dicocokkan ke barcode lalu SKU, barang
/// langsung masuk pesanan (getar + bunyi singkat). "Scan terus" membiarkan
/// kamera tetap terbuka untuk beberapa barang, dengan barang terakhir dan
/// penghitung. Kode yang tidak dikenal ditampilkan apa adanya.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  /// Mode "Scan terus" diingat selama aplikasi terbuka.
  static bool continuousPreference = false;

  /// Kode yang sama dianggap barang baru setelah hilang dari kamera selama ini.
  static const Duration repeatGap = Duration(milliseconds: 1200);

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  late final CodeScanner _scanner = ref.read(codeScannerFactoryProvider)();
  bool _continuous = ScanScreen.continuousPreference;
  bool _busy = false;
  bool _closing = false;
  int _added = 0;
  Product? _last;
  String? _notFound;
  String? _seenCode;
  DateTime _seenAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing) {
      return;
    }
    _closing = true;
    Navigator.of(context).pop(ScanOutcome(_added, _last));
  }

  /// Satu pembacaan kamera. Kode yang masih terlihat (dibaca lagi dalam
  /// [ScanScreen.repeatGap]) diabaikan supaya satu barang tidak masuk dua kali.
  void _onCode(String code) {
    final now = DateTime.now();
    final repeated = code == _seenCode && now.difference(_seenAt) < ScanScreen.repeatGap;
    _seenCode = code;
    _seenAt = now;
    if (repeated || _busy || _closing) {
      return;
    }
    _handle(code);
  }

  Future<void> _handle(String code) async {
    _busy = true;
    try {
      final product = await ref.read(posActionsProvider).addByCode(code);
      if (!mounted) {
        return;
      }
      if (product == null) {
        HapticFeedback.heavyImpact();
        setState(() => _notFound = code);
        return;
      }
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.click);
      setState(() {
        _added++;
        _last = product;
        _notFound = null;
      });
      if (!_continuous) {
        _close();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _typeCode() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Ketik kode barang'),
        content: TextField(
          key: const Key('scan-code'),
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.qr_code_2), hintText: 'Barcode atau SKU'),
          onSubmitted: (value) => Navigator.pop(dialog, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Batal')),
          FilledButton(key: const Key('scan-add'), onPressed: () => Navigator.pop(dialog, controller.text), child: const Text('Tambah')),
        ],
      ),
    );
    // Pengendali tidak di-dispose di sini: dialog masih beranimasi keluar.
    if (code != null && code.trim().isNotEmpty && mounted) {
      await _handle(code.trim());
    }
  }

  Widget _problem(BuildContext context, ScannerProblem problem) {
    final (title, message) = switch (problem) {
      ScannerProblem.permissionDenied => ('Kamera belum diizinkan', 'Izinkan kamera untuk Infois POS di Pengaturan HP, atau ketik kode barangnya.'),
      ScannerProblem.unsupported => ('Kamera tidak tersedia', 'HP ini tidak bisa memakai kamera untuk scan. Ketik kode barangnya.'),
      ScannerProblem.other => ('Kamera belum bisa dibuka', 'Tutup lalu buka lagi layar scan, atau ketik kode barangnya.'),
    };
    return ColoredBox(
      key: Key('scan-problem-${problem.name}'),
      color: Brand.darkCanvas,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography_outlined, size: 48, color: Colors.white70),
            const SizedBox(height: Space.l),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: Space.s),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, height: 1.4)),
            if (problem == ScannerProblem.permissionDenied) ...[
              const SizedBox(height: Space.l),
              OutlinedButton.icon(
                key: const Key('scan-open-settings'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54)),
                onPressed: () => openAppSettings(),
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Buka Pengaturan'),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(children: [
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            _scanner.buildPreview(context, onCode: _onCode, onProblem: _problem),
            const IgnorePointer(child: _ScanFrame()),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.xs),
                child: Row(children: [
                  _RoundButton(key: const Key('scan-close'), icon: Icons.close, tooltip: 'Tutup', onPressed: _close),
                  const Expanded(
                    child: Text('Scan barcode', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                  ),
                  ValueListenableBuilder<bool?>(
                    valueListenable: _scanner.torch,
                    builder: (context, on, _) => _RoundButton(
                      key: const Key('scan-torch'),
                      icon: on == true ? Icons.flashlight_on : Icons.flashlight_off_outlined,
                      tooltip: on == true ? 'Matikan senter' : 'Nyalakan senter',
                      active: on == true,
                      onPressed: on == null ? null : _scanner.toggleTorch,
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ),
        Material(
          color: scheme.surface,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _status(context),
                const SizedBox(height: Space.s),
                SwitchListTile(
                  key: const Key('scan-continuous'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Scan terus', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Kamera tetap terbuka untuk beberapa barang', style: TextStyle(fontSize: 12.5)),
                  value: _continuous,
                  onChanged: (value) => setState(() => _continuous = ScanScreen.continuousPreference = value),
                ),
                const SizedBox(height: Space.xs),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('scan-type'),
                      onPressed: _typeCode,
                      icon: const Icon(Icons.keyboard_outlined),
                      label: const Text('Ketik kode'),
                    ),
                  ),
                  const SizedBox(width: Space.m),
                  Expanded(
                    child: FilledButton(
                      key: const Key('scan-done'),
                      onPressed: _close,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: const Text('Selesai'),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _status(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget child;
    if (_notFound != null) {
      child = Container(
        key: const Key('scan-not-found'),
        padding: const EdgeInsets.all(Space.m),
        decoration: BoxDecoration(color: dangerText(context).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(Radii.m)),
        child: Row(children: [
          Icon(Icons.search_off, color: dangerText(context)),
          const SizedBox(width: Space.m),
          Expanded(
            child: Text.rich(TextSpan(children: [
              const TextSpan(text: 'Kode '),
              TextSpan(text: _notFound, style: const TextStyle(fontWeight: FontWeight.w700)),
              const TextSpan(text: ' tidak ada di katalog HP ini. Cek barcode/SKU barang di web, lalu sinkron.'),
            ]), style: TextStyle(color: dangerText(context), fontSize: 13.5)),
          ),
        ]),
      );
    } else if (_last != null) {
      child = Container(
        key: const Key('scan-last'),
        padding: const EdgeInsets.all(Space.s),
        decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(Radii.m)),
        child: Row(children: [
          ClipRRect(borderRadius: BorderRadius.circular(Radii.s), child: SizedBox(width: 48, height: 48, child: ProductImage(product: _last!, initialsSize: 16))),
          const SizedBox(width: Space.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_last!.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer)),
              Text('${rupiah(_last!.price)} · masuk pesanan', style: TextStyle(fontSize: 12.5, color: scheme.onPrimaryContainer)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.xs),
            decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(Radii.l)),
            child: Text('$_added', key: const Key('scan-count'), style: TextStyle(color: scheme.onPrimary, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
    } else {
      child = Padding(
        key: const Key('scan-hint'),
        padding: const EdgeInsets.symmetric(vertical: Space.s),
        child: Row(children: [
          Icon(Icons.center_focus_weak, color: mutedText(context)),
          const SizedBox(width: Space.m),
          Expanded(child: Text('Arahkan kamera ke barcode barang. Barang langsung masuk pesanan.', style: TextStyle(color: mutedText(context)))),
        ]),
      );
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: KeyedSubtree(key: ValueKey('${_notFound ?? ''}|$_added'), child: child));
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.tooltip, required this.onPressed, this.active = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: active ? Brand.nota : Colors.black.withValues(alpha: 0.45),
          foregroundColor: active ? Brand.ink : Colors.white,
          disabledBackgroundColor: Colors.black.withValues(alpha: 0.3),
          disabledForegroundColor: Colors.white38,
          minimumSize: const Size(48, 48),
        ),
        icon: Icon(icon),
      );
}

/// Bingkai area scan: luar bingkai digelapkan, sudut bingkai putih.
class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _FramePainter());
}

class _FramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final width = (size.width * 0.75).clamp(200.0, 360.0);
    final height = width * 0.62;
    final rect = Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.45), width: width, height: height);
    final frame = RRect.fromRectAndRadius(rect, const Radius.circular(Radii.l));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(frame)),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawRRect(frame, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
