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

/// Hasil "Cetak list" ke printer produksi (dapur / bar / checker).
class ProductionResult {
  const ProductionResult({this.printed = const [], this.failed = const [], this.unrouted = const [], this.noPrinter = false});

  /// Nama printer yang sudah mencetak.
  final List<String> printed;

  /// Printer yang belum mencetak (bisa dicetak ulang).
  final List<SavedPrinter> failed;

  /// Barang yang kategorinya tidak dicetak printer mana pun.
  final List<String> unrouted;
  final bool noPrinter;

  bool get ok => !noPrinter && failed.isEmpty;

  String get failedNames => [for (final printer in failed) printer.name].join(', ');
}

class PrinterState {
  const PrinterState({
    this.printer,
    this.status = PrinterStatus.none,
    this.message,
    this.hasFailedJob = false,
    this.production = const [],
    this.productionStatus = const {},
    this.productionFailed = const {},
  });

  /// Printer kasir (struk, tagihan, laporan shift).
  final SavedPrinter? printer;
  final PrinterStatus status;
  final String? message;

  /// Ada struk yang gagal tercetak dan bisa dicetak ulang.
  final bool hasFailedJob;

  /// Printer produksi (dapur / bar / checker); kosong = list ke printer kasir.
  final List<SavedPrinter> production;

  /// Status terakhir tiap printer produksi (menurut ID).
  final Map<String, PrinterStatus> productionStatus;

  /// ID printer produksi yang list terakhirnya belum tercetak.
  final Set<String> productionFailed;

  PrinterStatus statusOf(SavedPrinter printer) =>
      printer.id == AppStorage.kasirPrinterId && printer.id == this.printer?.id ? status : (productionStatus[printer.id] ?? PrinterStatus.disconnected);

  PrinterState copyWith({
    SavedPrinter? printer,
    bool clearPrinter = false,
    PrinterStatus? status,
    String? message,
    bool clearMessage = false,
    bool? hasFailedJob,
    List<SavedPrinter>? production,
    Map<String, PrinterStatus>? productionStatus,
    Set<String>? productionFailed,
  }) =>
      PrinterState(
        printer: clearPrinter ? null : (printer ?? this.printer),
        status: status ?? this.status,
        message: clearMessage ? null : (message ?? this.message),
        hasFailedJob: hasFailedJob ?? this.hasFailedJob,
        production: production ?? this.production,
        productionStatus: productionStatus ?? this.productionStatus,
        productionFailed: productionFailed ?? this.productionFailed,
      );
}

final printerTransportProvider = Provider<PrinterTransport>((ref) => BluetoothPrinterTransport());

final networkPrinterProvider = Provider<NetworkPrinterTransport>((ref) => const SocketPrinterTransport());

final receiptBuilderProvider = FutureProvider<ReceiptBuilder>((ref) => ReceiptBuilder.create());

/// Printer kasir dan printer produksi (dapur / bar / checker), lewat
/// Bluetooth atau Wi-Fi. Bluetooth hanya satu sambungan: pekerjaan
/// Bluetooth dijalankan berurutan dan printer berpindah bila perlu.
/// Printer Wi-Fi mencetak bersamaan.
class PrinterController extends Notifier<PrinterState> {
  List<int>? _failedJob;

  /// List produksi yang belum tercetak, menurut ID printer.
  final Map<String, List<int>> _failedProduction = {};

  /// Printer Bluetooth yang sedang tersambung (satu sambungan).
  String? _connectedMac;

  /// Antrean Bluetooth: satu pekerjaan selesai dulu sebelum berikutnya.
  Future<void> _queue = Future<void>.value();

  PrinterTransport get _bluetooth => ref.read(printerTransportProvider);

  NetworkPrinterTransport get _network => ref.read(networkPrinterProvider);

  AppStorage get _storage => ref.read(storageProvider);

  @override
  PrinterState build() {
    final storage = ref.read(storageProvider);
    final printer = storage.printer;
    if (printer != null && !printer.isWifi) {
      Future.microtask(connect);
    }
    return PrinterState(
      printer: printer,
      status: printer == null ? PrinterStatus.none : PrinterStatus.disconnected,
      production: storage.productionPrinters,
    );
  }

  Future<T> _serial<T>(Future<T> Function() job) {
    final result = _queue.then((_) => job());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Daftar printer yang sudah dipasangkan di Bluetooth HP.
  Future<List<PrinterDevice>> scan() async {
    if (!await _bluetooth.requestPermissions()) {
      throw const PrinterException('Izin Bluetooth belum diberikan. Izinkan di pengaturan aplikasi.');
    }
    if (!await _bluetooth.bluetoothOn()) {
      throw const PrinterException('Bluetooth HP mati. Nyalakan Bluetooth lalu coba lagi.');
    }
    return _bluetooth.pairedDevices();
  }

  /// Printer Wi-Fi di jaringan yang sama dengan HP ini.
  Future<List<String>> discoverWifi() => _network.discover();

  // ---------------------------------------------------------------- kasir

  Future<void> setKasir(SavedPrinter printer) async {
    final saved = printer.copyWith(id: AppStorage.kasirPrinterId);
    await _storage.setPrinter(saved);
    state = state.copyWith(printer: saved, status: PrinterStatus.disconnected, clearMessage: true);
    if (!saved.isWifi) {
      await connect();
    }
  }

  Future<void> forgetKasir() async {
    final printer = state.printer;
    if (printer != null && printer.mac == _connectedMac) {
      await _bluetooth.disconnect();
      _connectedMac = null;
    }
    await _storage.setPrinter(null);
    _failedJob = null;
    state = PrinterState(production: state.production, productionStatus: state.productionStatus, productionFailed: state.productionFailed);
  }

  /// Sambungkan printer kasir Bluetooth (Wi-Fi tidak perlu disambung dulu).
  Future<bool> connect() async {
    final printer = state.printer;
    if (printer == null) {
      return false;
    }
    if (printer.isWifi) {
      return true;
    }
    return _serial(() => _connectBluetooth(printer));
  }

  // ----------------------------------------------------------- produksi

  Future<void> _saveProduction(List<SavedPrinter> printers) async {
    await _storage.setProductionPrinters(printers);
    final ids = {for (final printer in printers) printer.id};
    _failedProduction.removeWhere((id, _) => !ids.contains(id));
    state = state.copyWith(
      production: printers,
      productionStatus: {for (final entry in state.productionStatus.entries) if (ids.contains(entry.key)) entry.key: entry.value},
      productionFailed: state.productionFailed.intersection(ids),
    );
  }

  /// Tambah satu atau beberapa printer produksi sekaligus.
  Future<void> addProduction(List<SavedPrinter> printers) => _saveProduction([
        ...state.production,
        for (final (index, printer) in printers.indexed)
          printer.copyWith(id: printer.id.isEmpty ? 'p${DateTime.now().microsecondsSinceEpoch}$index' : printer.id),
      ]);

  Future<void> updateProduction(SavedPrinter printer) =>
      _saveProduction([for (final item in state.production) item.id == printer.id ? printer : item]);

  Future<void> removeProduction(String id) async {
    final target = state.production.where((printer) => printer.id == id).firstOrNull;
    if (target != null && target.mac == _connectedMac && target.mac != state.printer?.mac) {
      await _serial(() async {
        await _bluetooth.disconnect();
        _connectedMac = null;
      });
    }
    await _saveProduction([for (final item in state.production) if (item.id != id) item]);
  }

  // -------------------------------------------------------------- kirim

  void _setStatus(SavedPrinter target, PrinterStatus status, {String? message, bool clearMessage = false}) {
    if (target.id == AppStorage.kasirPrinterId) {
      state = state.copyWith(status: status, message: message, clearMessage: clearMessage);
    } else {
      state = state.copyWith(productionStatus: {...state.productionStatus, target.id: status});
    }
  }

  /// Printer Bluetooth berbeda yang diatur di HP ini.
  int get _bluetoothCount => {
        if (state.printer != null && !state.printer!.isWifi) state.printer!.mac,
        for (final printer in state.production)
          if (!printer.isWifi) printer.mac,
      }.length;

  Future<bool> _connectBluetooth(SavedPrinter target) async {
    // Printer Bluetooth lain dengan status tersambung jadi tidak tersambung.
    void markOthers() {
      final kasir = state.printer;
      if (kasir != null && kasir.mac != target.mac && state.status == PrinterStatus.connected && !kasir.isWifi) {
        state = state.copyWith(status: PrinterStatus.disconnected);
      }
      state = state.copyWith(productionStatus: {
        for (final entry in state.productionStatus.entries)
          entry.key: entry.value == PrinterStatus.connected && state.production.any((printer) => printer.id == entry.key && !printer.isWifi && printer.mac != target.mac)
              ? PrinterStatus.disconnected
              : entry.value,
      });
    }

    try {
      final connected = await _bluetooth.isConnected();
      if (connected && (_connectedMac == target.mac || (_connectedMac == null && _bluetoothCount <= 1))) {
        _connectedMac = target.mac;
        markOthers();
        _setStatus(target, PrinterStatus.connected, clearMessage: true);
        return true;
      }
      if (connected) {
        await _bluetooth.disconnect();
      }
      _connectedMac = null;
      markOthers();
      _setStatus(target, PrinterStatus.connecting);
      final ok = await _bluetooth.connect(target.mac);
      if (ok) {
        _connectedMac = target.mac;
      }
      _setStatus(target, ok ? PrinterStatus.connected : PrinterStatus.disconnected, message: ok ? null : '${target.name} tidak tersambung.', clearMessage: ok);
      return ok;
    } on Exception {
      _connectedMac = null;
      _setStatus(target, PrinterStatus.disconnected, message: '${target.name} tidak tersambung.');
      return false;
    }
  }

  Future<bool> _writeBluetooth(SavedPrinter target, List<int> bytes) async {
    if (!await _connectBluetooth(target)) {
      return false;
    }
    _setStatus(target, PrinterStatus.printing);
    var ok = false;
    try {
      ok = await _bluetooth.write(bytes);
      if (!ok) {
        _connectedMac = null;
        if (await _connectBluetooth(target)) {
          ok = await _bluetooth.write(bytes);
        }
      }
    } on Exception {
      ok = false;
    }
    _setStatus(target, ok ? PrinterStatus.connected : PrinterStatus.disconnected, message: ok ? null : '${target.name} belum mencetak.', clearMessage: ok);
    return ok;
  }

  Future<bool> _writeWifi(SavedPrinter target, List<int> bytes) async {
    _setStatus(target, PrinterStatus.printing);
    final ok = await _network.send(target.mac, target.port, bytes);
    _setStatus(target, ok ? PrinterStatus.connected : PrinterStatus.disconnected, message: ok ? null : '${target.name} tidak terjangkau.', clearMessage: ok);
    return ok;
  }

  /// Kirim [bytes] ke [target]: Wi-Fi langsung, Bluetooth lewat antrean.
  Future<bool> send(SavedPrinter target, List<int> bytes) =>
      target.isWifi ? _writeWifi(target, bytes) : _serial(() => _writeBluetooth(target, bytes));

  /// Cetak [bytes] ke printer kasir; gagal = bisa dicetak ulang.
  Future<PrintResult> printBytes(List<int> bytes) async {
    final printer = state.printer;
    if (printer == null) {
      return PrintResult.noPrinter;
    }
    if (await send(printer, bytes)) {
      _failedJob = null;
      state = state.copyWith(status: PrinterStatus.connected, hasFailedJob: false, clearMessage: true);
      return PrintResult.printed;
    }
    _failedJob = bytes;
    state = state.copyWith(status: PrinterStatus.disconnected, hasFailedJob: true, message: 'Struk belum tercetak. Periksa printer lalu tekan Cetak ulang.');
    return PrintResult.failed;
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

  /// List pesanan ke semua printer produksi sekaligus: tiap printer hanya
  /// barang dari kategorinya (kosong = semua), printer tanpa barang
  /// dilewati. Tanpa printer produksi: satu list ke printer kasir.
  /// [categoryOf] = kategori tiap barang (ID barang → ID kategori).
  Future<ProductionResult> printProduction(Map<String, dynamic> sale, {Map<int, int?> categoryOf = const {}}) async {
    final stations = state.production;
    final targets = stations.isNotEmpty ? stations : [if (state.printer != null) state.printer!];
    if (targets.isEmpty) {
      return const ProductionResult(noPrinter: true);
    }
    final master = await ref.read(masterDataProvider.future);
    final builder = await ref.read(receiptBuilderProvider.future);
    final config = master?.receipt ?? const ReceiptConfig(companyName: '');
    final items = [for (final item in (sale['items'] as List? ?? const [])) if (!ReceiptBuilder.isCharge(item)) Map<String, dynamic>.from(item as Map)];
    int? categoryFor(Map<String, dynamic> item) {
      final productId = item['product_id'];
      return productId is int ? categoryOf[productId] : null;
    }

    final jobs = <(SavedPrinter, List<int>)>[];
    final routed = <int>{};
    for (final target in targets) {
      final lines = <Map<String, dynamic>>[];
      for (final (index, item) in items.indexed) {
        if (stations.isEmpty || target.printsCategory(categoryFor(item))) {
          lines.add(item);
          routed.add(index);
        }
      }
      if (lines.isNotEmpty) {
        jobs.add((target, builder.orderList({...sale, 'items': lines}, config, width: target.width, station: stations.isEmpty ? null : target.name)));
      }
    }
    final results = await Future.wait([for (final (target, bytes) in jobs) send(target, bytes)]);
    final failed = <SavedPrinter>[];
    final printed = <String>[];
    for (final (index, ok) in results.indexed) {
      final (target, bytes) = jobs[index];
      if (ok) {
        printed.add(target.name);
        _failedProduction.remove(target.id);
      } else {
        failed.add(target);
        _failedProduction[target.id] = bytes;
      }
    }
    state = state.copyWith(productionFailed: {..._failedProduction.keys});
    return ProductionResult(
      printed: printed,
      failed: failed,
      unrouted: [for (final (index, item) in items.indexed) if (!routed.contains(index)) item['description']?.toString() ?? ''],
    );
  }

  /// Cetak ulang list yang belum tercetak (hanya printer yang gagal).
  Future<ProductionResult> retryProduction() async {
    final all = [...state.production, if (state.printer != null) state.printer!];
    final jobs = [
      for (final entry in _failedProduction.entries)
        if (all.where((printer) => printer.id == entry.key).firstOrNull case final target?) (target, entry.value),
    ];
    final results = await Future.wait([for (final (target, bytes) in jobs) send(target, bytes)]);
    final failed = <SavedPrinter>[];
    final printed = <String>[];
    for (final (index, ok) in results.indexed) {
      final target = jobs[index].$1;
      if (ok) {
        printed.add(target.name);
        _failedProduction.remove(target.id);
      } else {
        failed.add(target);
      }
    }
    state = state.copyWith(productionFailed: {..._failedProduction.keys});
    return ProductionResult(printed: printed, failed: failed);
  }

  /// Tes cetak ke [target].
  Future<PrintResult> testPrint(SavedPrinter target) async {
    final master = await ref.read(masterDataProvider.future);
    final builder = await ref.read(receiptBuilderProvider.future);
    final receipt = master?.receipt ?? const ReceiptConfig(companyName: 'Infois');
    final ok = await send(target, builder.testPage(receipt, width: target.width, logo: master?.logoBytes, title: target.name));
    return ok ? PrintResult.printed : PrintResult.failed;
  }
}

class PrinterException implements Exception {
  const PrinterException(this.message);

  final String message;

  @override
  String toString() => message;
}

final printerProvider = NotifierProvider<PrinterController, PrinterState>(PrinterController.new);
