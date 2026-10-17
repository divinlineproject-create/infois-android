import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart' show printCapabilities;
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show BuildContext, ColoredBox, Key, ValueChanged, Widget;
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/services/code_scanner.dart';
import 'package:infois/services/printing/printer_service.dart';
import 'package:infois/services/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Server palsu untuk tes: setiap request dijawab oleh [handler].
/// Bila [handler] mengembalikan null, request dianggap gagal jaringan.
class FakeServer implements HttpClientAdapter {
  FakeServer(this.handler);

  final Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    Map<String, dynamic>? body;
    if (options.data is Map) {
      body = Map<String, dynamic>.from(options.data as Map);
    } else if (options.data is String && (options.data as String).isNotEmpty) {
      body = Map<String, dynamic>.from(jsonDecode(options.data as String) as Map);
    }
    final response = handler(options, body);
    if (response == null) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    final status = response.remove('_status') as int? ?? 200;
    return ResponseBody.fromString(jsonEncode(response), status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// Server palsu yang bisa menahan request tertentu sampai [Completer]-nya
/// diselesaikan tes (meniru jawaban server yang lambat).
class GatedServer extends FakeServer {
  GatedServer(super.handler);

  final List<(bool Function(RequestOptions options), Completer<void>)> _gates = [];

  /// Tahan request yang cocok sampai [gate] selesai.
  void hold(bool Function(RequestOptions options) matches, Completer<void> gate) => _gates.add((matches, gate));

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    for (final (matches, gate) in _gates) {
      if (matches(options)) {
        await gate.future;
      }
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}

ApiClient fakeApi(FakeServer server, {int tenantId = 1}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://tes/api/v1/'));
  dio.httpClientAdapter = server;
  return ApiClient(baseUrl: 'http://tes', token: 'token', tenantId: tenantId, dio: dio);
}

/// Server yang selalu offline.
FakeServer offlineServer() => FakeServer((_, __) => null);

Future<LocalDb> memoryDb() async {
  sqfliteFfiInit();
  return LocalDb.open(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
}

const kopi = Product(id: 1, name: 'Kopi susu', unit: 'gelas', price: '18000.00', taxRate: '0.00');
const roti = Product(id: 2, name: 'Roti bakar', unit: 'pcs', price: '15000.00', taxRate: '11.00', trackInventory: true, stockQuantity: '5.000000');

/// Isi database HP seperti setelah sinkron pertama.
Future<void> seedMaster(LocalDb local, {bool pricesIncludeTax = false, bool withBlock = true, Map<String, dynamic>? menus}) async {
  await local.upsertProducts([kopi, roti]);
  await local.upsertCustomers([const Customer(id: 7, name: 'Bu Ani', phone: '0812')]);
  await local.setJson(MetaKeys.tenant, {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': pricesIncludeTax, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'});
  await local.setJson(MetaKeys.receipt, {'width': 58, 'company': {'name': 'Warung Tes', 'address': 'Jl. Contoh 1'}, 'footer_text': 'Terima kasih', 'show_qr': true, 'verify_base_url': 'http://tes/verify'});
  await local.setJson(MetaKeys.accounts, {
    'items': [
      {'id': 11, 'code': '1-1100', 'name': 'Kas', 'kind': 'cash'},
      {'id': 12, 'code': '1-1200', 'name': 'Bank BCA', 'kind': 'bank'},
    ],
    'default_cash_id': 11,
    'default_transfer_id': 12,
  });
  await local.setJson(MetaKeys.device, {'id': 3, 'code': 'K1', 'name': 'HP Tes'});
  await local.setJson(MetaKeys.menus, menus ?? {'pos': true, 'shift': true, 'add_customer': true, 'printer': true, 'ai': true, 'reports': true, 'records': true});
  await local.setMeta(MetaKeys.lastSyncAt, DateTime(2026, 10, 7).toIso8601String());
  if (withBlock) {
    await local.setMeta(MetaKeys.numberBlocks, jsonEncode([
      {'id': 1, 'format': 'POS-K1/{SEQ:6}', 'start': 1, 'end': 3},
    ]));
  }
}

/// Printer palsu yang menyimpan byte yang dicetak.
class FakePrinter implements PrinterTransport {
  final List<List<int>> printed = [];
  bool connected = false;

  @override
  Future<bool> bluetoothOn() async => true;

  @override
  Future<bool> connect(String mac) async => connected = true;

  @override
  Future<void> disconnect() async => connected = false;

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<List<PrinterDevice>> pairedDevices() async => const [PrinterDevice(name: 'RPP02N', mac: '00:11:22:33:44:55')];

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> write(List<int> bytes) async {
    printed.add(bytes);
    return true;
  }
}

/// Muat profil printer ESC/POS langsung dari file paket (tes tidak memakai
/// asset bundle aplikasi).
Future<void> preloadEscPosProfile() async {
  if (printCapabilities.isNotEmpty) {
    return;
  }
  final config = File('.dart_tool/package_config.json');
  final packages = (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
  final package = packages.cast<Map>().firstWhere((entry) => entry['name'] == 'esc_pos_utils_plus');
  var rootUri = package['rootUri'] as String;
  rootUri = rootUri.endsWith('/') ? rootUri : '$rootUri/';
  final root = config.absolute.uri.resolve(rootUri);
  final file = File.fromUri(root.resolve('${package['packageUri']}resources/capabilities.json'));
  printCapabilities = Map.from(jsonDecode(file.readAsStringSync()) as Map);
}

/// Papan klip palsu: tanpa ini `Clipboard.setData` tidak pernah selesai di
/// tes widget (tidak ada plugin). Mengembalikan daftar teks yang disalin.
List<String> mockClipboard() {
  final copied = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'].toString());
    }
    return null;
  });
  return copied;
}

/// Pemindai kamera palsu: tes memanggil [emit] seolah kamera membaca kode.
class FakeCodeScanner implements CodeScanner {
  ValueChanged<String>? _onCode;
  final ValueNotifier<bool?> _torch = ValueNotifier<bool?>(false);
  ScannerProblem? problem;
  bool disposed = false;
  int torchToggles = 0;

  void emit(String code) => _onCode?.call(code);

  @override
  Widget buildPreview(BuildContext context, {required ValueChanged<String> onCode, required Widget Function(BuildContext context, ScannerProblem problem) onProblem}) {
    _onCode = onCode;
    return problem == null ? const ColoredBox(key: Key('fake-camera'), color: Color(0xFF000000)) : onProblem(context, problem!);
  }

  @override
  ValueListenable<bool?> get torch => _torch;

  @override
  Future<void> toggleTorch() async {
    torchToggles++;
    _torch.value = !(_torch.value ?? false);
  }

  @override
  Future<void> dispose() async => disposed = true;
}
