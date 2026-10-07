import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_storage.dart';
import '../domain/models.dart';
import '../services/printing/printer_service.dart';
import '../services/printing/receipt_builder.dart';
import 'session.dart';
import 'workspace.dart';

enum PrinterStatus { none, disconnected, connecting, connected, printing }

enum PrintResult { printed, noPrinter, failed }

class PrinterState {
  const PrinterState({this.printer, this.status = PrinterStatus.none, this.message, this.hasFailedJob = false});

  final SavedPrinter? printer;
  final PrinterStatus status;
  final String? message;

  /// Ada struk yang gagal tercetak dan bisa dicetak ulang.
  final bool hasFailedJob;

  PrinterState copyWith({SavedPrinter? printer, bool clearPrinter = false, PrinterStatus? status, String? message, bool clearMessage = false, bool? hasFailedJob}) => PrinterState(
        printer: clearPrinter ? null : (printer ?? this.printer),
        status: status ?? this.status,
        message: clearMessage ? null : (message ?? this.message),
        hasFailedJob: hasFailedJob ?? this.hasFailedJob,
      );
}

final printerTransportProvider = Provider<PrinterTransport>((ref) => BluetoothPrinterTransport());

final receiptBuilderProvider = FutureProvider<ReceiptBuilder>((ref) => ReceiptBuilder.create());

/// Printer struk default: pilih dari perangkat terpasang, lebar 58/80 mm,
/// tes cetak, sambung ulang otomatis, dan cetak ulang struk yang gagal.
class PrinterController extends Notifier<PrinterState> {
  List<int>? _failedJob;

  PrinterTransport get _transport => ref.read(printerTransportProvider);

  AppStorage get _storage => ref.read(storageProvider);

  @override
  PrinterState build() {
    final printer = ref.read(storageProvider).printer;
    if (printer != null) {
      Future.microtask(connect);
    }
    return PrinterState(printer: printer, status: printer == null ? PrinterStatus.none : PrinterStatus.disconnected);
  }

  /// Daftar printer yang sudah dipasangkan di Bluetooth HP.
  Future<List<PrinterDevice>> scan() async {
    if (!await _transport.requestPermissions()) {
      throw const PrinterException('Izin Bluetooth belum diberikan. Izinkan di pengaturan aplikasi.');
    }
    if (!await _transport.bluetoothOn()) {
      throw const PrinterException('Bluetooth HP mati. Nyalakan Bluetooth lalu coba lagi.');
    }
    return _transport.pairedDevices();
  }

  Future<void> choose(PrinterDevice device, int width) async {
    final printer = SavedPrinter(mac: device.mac, name: device.name, width: width);
    await _storage.setPrinter(printer);
    state = state.copyWith(printer: printer, status: PrinterStatus.disconnected, clearMessage: true);
    await connect();
  }

  Future<void> setWidth(int width) async {
    final printer = state.printer;
    await _storage.setPrinterWidth(width);
    if (printer != null) {
      final updated = SavedPrinter(mac: printer.mac, name: printer.name, width: width);
      await _storage.setPrinter(updated);
      state = state.copyWith(printer: updated);
    }
  }

  Future<void> forget() async {
    await _transport.disconnect();
    await _storage.setPrinter(null);
    state = const PrinterState();
  }

  Future<bool> connect() async {
    final printer = state.printer;
    if (printer == null) {
      return false;
    }
    try {
      if (await _transport.isConnected()) {
        state = state.copyWith(status: PrinterStatus.connected, clearMessage: true);
        return true;
      }
      state = state.copyWith(status: PrinterStatus.connecting);
      final ok = await _transport.connect(printer.mac);
      state = state.copyWith(
        status: ok ? PrinterStatus.connected : PrinterStatus.disconnected,
        message: ok ? null : 'Printer ${printer.name} tidak tersambung. Pastikan printer menyala dan dekat.',
        clearMessage: ok,
      );
      return ok;
    } on Exception {
      state = state.copyWith(status: PrinterStatus.disconnected, message: 'Printer tidak tersambung.');
      return false;
    }
  }

  Future<PrintResult> printBytes(List<int> bytes) async {
    if (state.printer == null) {
      return PrintResult.noPrinter;
    }
    if (!await connect()) {
      _remember(bytes);
      return PrintResult.failed;
    }
    state = state.copyWith(status: PrinterStatus.printing);
    var ok = false;
    try {
      ok = await _transport.write(bytes);
      if (!ok && await connect()) {
        ok = await _transport.write(bytes);
      }
    } on Exception {
      ok = false;
    }
    if (ok) {
      _failedJob = null;
      state = state.copyWith(status: PrinterStatus.connected, hasFailedJob: false, clearMessage: true);
      return PrintResult.printed;
    }
    _remember(bytes);
    return PrintResult.failed;
  }

  void _remember(List<int> bytes) {
    _failedJob = bytes;
    state = state.copyWith(
      status: PrinterStatus.disconnected,
      hasFailedJob: true,
      message: 'Struk belum tercetak. Periksa printer (menyala, kertas, Bluetooth) lalu tekan Cetak ulang.',
    );
  }

  Future<PrintResult> retryFailed() async {
    final job = _failedJob;
    return job == null ? PrintResult.printed : printBytes(job);
  }

  int _width(MasterData master) => state.printer?.width ?? _storage.printerWidth ?? master.receipt.width;

  Future<PrintResult> printSale(Map<String, dynamic> sale, {bool reprint = false}) async {
    if (state.printer == null) {
      return PrintResult.noPrinter;
    }
    final master = await ref.read(masterDataProvider.future);
    if (master == null) {
      return PrintResult.failed;
    }
    final builder = await ref.read(receiptBuilderProvider.future);
    return printBytes(builder.sale(sale, master.receipt, width: _width(master), logo: master.logoBytes, reprint: reprint));
  }

  Future<PrintResult> printShiftReport(Map<String, dynamic> report) async {
    final master = await ref.read(masterDataProvider.future);
    if (master == null || state.printer == null) {
      return PrintResult.noPrinter;
    }
    final builder = await ref.read(receiptBuilderProvider.future);
    return printBytes(builder.shiftReport(report, master.receipt, width: _width(master)));
  }

  Future<PrintResult> testPrint() async {
    final master = await ref.read(masterDataProvider.future);
    final builder = await ref.read(receiptBuilderProvider.future);
    final receipt = master?.receipt ?? const ReceiptConfig(companyName: 'Infois');
    return printBytes(builder.testPage(receipt, width: state.printer?.width ?? 58, logo: master?.logoBytes));
  }
}

class PrinterException implements Exception {
  const PrinterException(this.message);

  final String message;

  @override
  String toString() => message;
}

final printerProvider = NotifierProvider<PrinterController, PrinterState>(PrinterController.new);
