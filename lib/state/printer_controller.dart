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

/// Peran printer: kasir (struk, tagihan, laporan shift) atau dapur ("Cetak
/// list"; kosong = list ke printer kasir).
enum PrinterRole { kasir, dapur }

class PrinterState {
  const PrinterState({
    this.printer,
    this.status = PrinterStatus.none,
    this.message,
    this.hasFailedJob = false,
    this.kitchen,
    this.kitchenStatus = PrinterStatus.none,
    this.kitchenMessage,
  });

  /// Printer kasir.
  final SavedPrinter? printer;
  final PrinterStatus status;
  final String? message;

  /// Ada struk yang gagal tercetak dan bisa dicetak ulang.
  final bool hasFailedJob;

  /// Printer dapur (opsional).
  final SavedPrinter? kitchen;
  final PrinterStatus kitchenStatus;
  final String? kitchenMessage;

  /// Printer yang dipakai untuk [role]: list tanpa printer dapur → printer kasir.
  SavedPrinter? printerFor(PrinterRole role) => role == PrinterRole.dapur ? (kitchen ?? printer) : printer;

  /// Printer dapur sendiri (bukan printer kasir) yang dipakai untuk [role].
  bool usesKitchen(PrinterRole role) => role == PrinterRole.dapur && kitchen != null;

  PrinterState copyWith({
    SavedPrinter? printer,
    bool clearPrinter = false,
    PrinterStatus? status,
    String? message,
    bool clearMessage = false,
    bool? hasFailedJob,
    SavedPrinter? kitchen,
    bool clearKitchen = false,
    PrinterStatus? kitchenStatus,
    String? kitchenMessage,
    bool clearKitchenMessage = false,
  }) =>
      PrinterState(
        printer: clearPrinter ? null : (printer ?? this.printer),
        status: status ?? this.status,
        message: clearMessage ? null : (message ?? this.message),
        hasFailedJob: hasFailedJob ?? this.hasFailedJob,
        kitchen: clearKitchen ? null : (kitchen ?? this.kitchen),
        kitchenStatus: kitchenStatus ?? this.kitchenStatus,
        kitchenMessage: clearKitchenMessage ? null : (kitchenMessage ?? this.kitchenMessage),
      );
}

/// Pesan bila printer dapur gagal (printer kasir tetap mencetak).
const kitchenPrinterFailedMessage = 'Printer dapur belum tersambung. Pastikan printer dapur menyala dan dekat, lalu cetak list lagi.';

final printerTransportProvider = Provider<PrinterTransport>((ref) => BluetoothPrinterTransport());

final receiptBuilderProvider = FutureProvider<ReceiptBuilder>((ref) => ReceiptBuilder.create());

/// Printer kasir & printer dapur: pilih dari perangkat terpasang, lebar
/// 58/80 mm per printer, tes cetak, sambung ulang otomatis, dan cetak ulang
/// struk yang gagal. Bluetooth hanya satu sambungan: pekerjaan cetak
/// dijalankan berurutan dan printer berpindah bila perlu.
class PrinterController extends Notifier<PrinterState> {
  List<int>? _failedJob;

  /// Printer yang sedang tersambung lewat Bluetooth (satu sambungan).
  String? _connectedMac;

  /// Antrean cetak: satu pekerjaan selesai dulu sebelum berikutnya.
  Future<void> _queue = Future<void>.value();

  PrinterTransport get _transport => ref.read(printerTransportProvider);

  AppStorage get _storage => ref.read(storageProvider);

  @override
  PrinterState build() {
    final storage = ref.read(storageProvider);
    final printer = storage.printer;
    final kitchen = storage.kitchenPrinter;
    if (printer != null) {
      Future.microtask(connect);
    }
    return PrinterState(
      printer: printer,
      status: printer == null ? PrinterStatus.none : PrinterStatus.disconnected,
      kitchen: kitchen,
      kitchenStatus: kitchen == null ? PrinterStatus.none : PrinterStatus.disconnected,
    );
  }

  Future<T> _serial<T>(Future<T> Function() job) {
    final result = _queue.then((_) => job());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
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

  Future<void> choose(PrinterDevice device, int width, {PrinterRole role = PrinterRole.kasir}) async {
    final printer = SavedPrinter(mac: device.mac, name: device.name, width: width);
    if (role == PrinterRole.dapur) {
      await _storage.setKitchenPrinter(printer);
      state = state.copyWith(kitchen: printer, kitchenStatus: PrinterStatus.disconnected, clearKitchenMessage: true);
      return;
    }
    await _storage.setPrinter(printer);
    state = state.copyWith(printer: printer, status: PrinterStatus.disconnected, clearMessage: true);
    await connect();
  }

  Future<void> setWidth(int width, {PrinterRole role = PrinterRole.kasir}) async {
    if (role == PrinterRole.dapur) {
      final kitchen = state.kitchen;
      if (kitchen != null) {
        final updated = SavedPrinter(mac: kitchen.mac, name: kitchen.name, width: width);
        await _storage.setKitchenPrinter(updated);
        state = state.copyWith(kitchen: updated);
      }
      return;
    }
    final printer = state.printer;
    await _storage.setPrinterWidth(width);
    if (printer != null) {
      final updated = SavedPrinter(mac: printer.mac, name: printer.name, width: width);
      await _storage.setPrinter(updated);
      state = state.copyWith(printer: updated);
    }
  }

  Future<void> forget({PrinterRole role = PrinterRole.kasir}) async {
    final target = role == PrinterRole.dapur ? state.kitchen : state.printer;
    if (target != null && target.mac == _connectedMac) {
      await _transport.disconnect();
      _connectedMac = null;
    }
    if (role == PrinterRole.dapur) {
      await _storage.setKitchenPrinter(null);
      state = state.copyWith(clearKitchen: true, kitchenStatus: PrinterStatus.none, clearKitchenMessage: true);
      return;
    }
    await _storage.setPrinter(null);
    state = PrinterState(kitchen: state.kitchen, kitchenStatus: state.kitchenStatus);
  }

  /// Sambungkan printer [role] (printer lain diputus dulu).
  Future<bool> connect({PrinterRole role = PrinterRole.kasir}) => _serial(() => _connect(role));

  void _setStatus(PrinterRole role, PrinterStatus status, {String? message, bool clearMessage = false}) {
    state = state.usesKitchen(role)
        ? state.copyWith(kitchenStatus: status, kitchenMessage: message, clearKitchenMessage: clearMessage)
        : state.copyWith(status: status, message: message, clearMessage: clearMessage);
  }

  Future<bool> _connect(PrinterRole role) async {
    final target = state.printerFor(role);
    if (target == null) {
      return false;
    }
    // Printer lain (kasir/dapur) yang tersambung jadi tidak tersambung.
    void markOtherDisconnected() {
      final kitchen = state.kitchen;
      if (kitchen == null || kitchen.mac == state.printer?.mac) {
        return;
      }
      if (state.usesKitchen(role)) {
        if (state.printer != null && state.status == PrinterStatus.connected) {
          state = state.copyWith(status: PrinterStatus.disconnected);
        }
      } else if (state.kitchenStatus == PrinterStatus.connected) {
        state = state.copyWith(kitchenStatus: PrinterStatus.disconnected);
      }
    }

    try {
      final twoPrinters = state.kitchen != null && state.printer != null && state.kitchen!.mac != state.printer!.mac;
      final connected = await _transport.isConnected();
      if (connected && (_connectedMac == target.mac || (_connectedMac == null && !twoPrinters))) {
        _connectedMac = target.mac;
        markOtherDisconnected();
        _setStatus(role, PrinterStatus.connected, clearMessage: true);
        return true;
      }
      if (connected) {
        await _transport.disconnect();
      }
      _connectedMac = null;
      markOtherDisconnected();
      _setStatus(role, PrinterStatus.connecting);
      final ok = await _transport.connect(target.mac);
      if (ok) {
        _connectedMac = target.mac;
      }
      _setStatus(
        role,
        ok ? PrinterStatus.connected : PrinterStatus.disconnected,
        message: ok ? null : (state.usesKitchen(role) ? kitchenPrinterFailedMessage : 'Printer ${target.name} tidak tersambung. Pastikan printer menyala dan dekat.'),
        clearMessage: ok,
      );
      return ok;
    } on Exception {
      _connectedMac = null;
      _setStatus(role, PrinterStatus.disconnected, message: state.usesKitchen(role) ? kitchenPrinterFailedMessage : 'Printer tidak tersambung.');
      return false;
    }
  }

  /// Cetak [bytes] ke printer [role] (berurutan dengan pekerjaan lain).
  Future<PrintResult> printBytes(List<int> bytes, {PrinterRole role = PrinterRole.kasir}) => _serial(() => _print(bytes, role));

  Future<PrintResult> _print(List<int> bytes, PrinterRole role) async {
    if (state.printerFor(role) == null) {
      return PrintResult.noPrinter;
    }
    final kitchen = state.usesKitchen(role);
    if (!await _connect(role)) {
      if (kitchen) {
        _setStatus(role, PrinterStatus.disconnected, message: kitchenPrinterFailedMessage);
      } else {
        _remember(bytes);
      }
      return PrintResult.failed;
    }
    _setStatus(role, PrinterStatus.printing);
    var ok = false;
    try {
      ok = await _transport.write(bytes);
      if (!ok) {
        _connectedMac = null;
        if (await _connect(role)) {
          ok = await _transport.write(bytes);
        }
      }
    } on Exception {
      ok = false;
    }
    if (ok) {
      if (kitchen) {
        _setStatus(role, PrinterStatus.connected, clearMessage: true);
      } else {
        _failedJob = null;
        state = state.copyWith(status: PrinterStatus.connected, hasFailedJob: false, clearMessage: true);
      }
      return PrintResult.printed;
    }
    if (kitchen) {
      _setStatus(role, PrinterStatus.disconnected, message: kitchenPrinterFailedMessage);
    } else {
      _remember(bytes);
    }
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

  /// Lebar kertas printer [role].
  int widthFor(PrinterRole role, MasterData master) => state.printerFor(role)?.width ?? _storage.printerWidth ?? master.receipt.width;

  int _width(MasterData master) => widthFor(PrinterRole.kasir, master);

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

  /// Tagihan sebelum dibayar (lihat `ReceiptBuilder.bill`).
  Future<PrintResult> printBill(Map<String, dynamic> draft) async {
    if (state.printer == null) {
      return PrintResult.noPrinter;
    }
    final master = await ref.read(masterDataProvider.future);
    if (master == null) {
      return PrintResult.failed;
    }
    final builder = await ref.read(receiptBuilderProvider.future);
    return printBytes(builder.bill(draft, master.receipt, width: _width(master), logo: master.logoBytes));
  }

  Future<PrintResult> printShiftReport(Map<String, dynamic> report) async {
    final master = await ref.read(masterDataProvider.future);
    if (master == null || state.printer == null) {
      return PrintResult.noPrinter;
    }
    final builder = await ref.read(receiptBuilderProvider.future);
    return printBytes(builder.shiftReport(report, master.receipt, width: _width(master)));
  }

  /// Tes cetak ke printer [role].
  Future<PrintResult> testPrint({PrinterRole role = PrinterRole.kasir}) async {
    final target = role == PrinterRole.dapur ? state.kitchen : state.printer;
    if (target == null) {
      return PrintResult.noPrinter;
    }
    final master = await ref.read(masterDataProvider.future);
    final builder = await ref.read(receiptBuilderProvider.future);
    final receipt = master?.receipt ?? const ReceiptConfig(companyName: 'Infois');
    return printBytes(builder.testPage(receipt, width: target.width, logo: master?.logoBytes, title: role == PrinterRole.dapur ? 'Printer dapur' : 'Printer kasir'), role: role);
  }
}

class PrinterException implements Exception {
  const PrinterException(this.message);

  final String message;

  @override
  String toString() => message;
}

final printerProvider = NotifierProvider<PrinterController, PrinterState>(PrinterController.new);
