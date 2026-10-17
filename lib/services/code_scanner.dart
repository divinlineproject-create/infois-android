import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Galat kamera yang dipahami layar scan.
enum ScannerProblem { permissionDenied, unsupported, other }

/// Pemindai barcode kamera di balik antarmuka, supaya tes tidak butuh kamera
/// (lihat FakeCodeScanner di test/support). Gambar kamera hanya diproses di
/// HP (ML Kit di dalam aplikasi); tidak disimpan dan tidak dikirim.
abstract class CodeScanner {
  /// Pratinjau kamera yang memanggil [onCode] untuk setiap kode yang
  /// terbaca, dan [onProblem] bila kamera tidak bisa dipakai.
  Widget buildPreview(BuildContext context, {required ValueChanged<String> onCode, required Widget Function(BuildContext context, ScannerProblem problem) onProblem});

  /// Senter menyala (null = HP tanpa senter / belum diketahui).
  ValueListenable<bool?> get torch;

  Future<void> toggleTorch();

  Future<void> dispose();
}

/// Pembuat pemindai baru untuk setiap layar scan (diganti di tes).
final codeScannerFactoryProvider = Provider<CodeScanner Function()>((ref) => MobileCodeScanner.new);

/// Pemindai dengan paket mobile_scanner (CameraX + ML Kit yang dibundel).
class MobileCodeScanner implements CodeScanner {
  MobileCodeScanner()
      : _controller = MobileScannerController(
          // Kode yang sama boleh terbaca berkali-kali (dua barang sejenis);
          // layar scan sendiri yang menahan pembacaan beruntun.
          detectionSpeed: DetectionSpeed.normal,
          formats: const [
            BarcodeFormat.ean13,
            BarcodeFormat.ean8,
            BarcodeFormat.upcA,
            BarcodeFormat.upcE,
            BarcodeFormat.code128,
            BarcodeFormat.code39,
            BarcodeFormat.code93,
            BarcodeFormat.itf,
            BarcodeFormat.codabar,
            BarcodeFormat.qrCode,
            BarcodeFormat.dataMatrix,
          ],
        ) {
    _controller.addListener(_syncTorch);
  }

  final MobileScannerController _controller;
  final ValueNotifier<bool?> _torch = ValueNotifier<bool?>(null);

  void _syncTorch() {
    _torch.value = switch (_controller.value.torchState) {
      TorchState.on => true,
      TorchState.off || TorchState.auto => false,
      TorchState.unavailable => null,
    };
  }

  @override
  ValueListenable<bool?> get torch => _torch;

  @override
  Future<void> toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } catch (_) {
      // Senter tidak tersedia: tombol tetap diam.
    }
  }

  @override
  Widget buildPreview(BuildContext context, {required ValueChanged<String> onCode, required Widget Function(BuildContext context, ScannerProblem problem) onProblem}) => MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          for (final barcode in capture.barcodes) {
            final value = barcode.rawValue?.trim();
            if (value != null && value.isNotEmpty) {
              onCode(value);
              return;
            }
          }
        },
        errorBuilder: (context, error) => onProblem(context, switch (error.errorCode) {
          MobileScannerErrorCode.permissionDenied => ScannerProblem.permissionDenied,
          MobileScannerErrorCode.unsupported => ScannerProblem.unsupported,
          _ => ScannerProblem.other,
        }),
      );

  @override
  Future<void> dispose() async {
    _controller.removeListener(_syncTorch);
    _torch.dispose();
    await _controller.dispose();
  }
}
