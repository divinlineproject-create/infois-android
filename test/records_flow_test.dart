import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/app.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/state/printer_controller.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/state/workspace.dart';
import 'package:infois/ui/screens/catatan_screen.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Tab Catatan: daftar penjualan berkursor + cari, rincian dengan barang,
/// cetak ulang struk dari server, bagian sesuai hak akses, offline.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('id_ID');
    await preloadEscPosProfile();
  });

  const ownerPermissions = ['ViewAny:Invoice', 'View:Invoice', 'ViewAny:Bill', 'ViewAny:JournalEntry', 'ViewAny:Account', 'ViewAny:ProductService', 'ViewAny:Customer', 'ViewAny:Supplier', 'void-invoice', 'view-reports'];
  const owner = TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Pemilik', menus: Menus(pos: true, shift: true, reports: true, records: true, stock: true, cashJournal: true, voidSale: true), permissions: ownerPermissions);
  const kasirPermissions = ['ViewAny:Invoice', 'View:Invoice', 'ViewAny:Customer', 'ViewAny:ProductService', 'ViewAny:JournalEntry', 'ViewAny:Account'];
  const kasir = TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Kasir', menus: Menus(pos: true, shift: true, records: true, stock: true), permissions: kasirPermissions);

  Future<(FakePrinter, Map<String, dynamic>)> pumpApp(WidgetTester tester, {required FakeServer server, TenantSummary tenant = owner, Map<String, dynamic>? menus, bool withPrinter = false}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final menuJson = menus ?? tenant.menus.toJson();
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [tenant.toJson()],
      }),
      'tenant_id': 1,
      if (withPrinter) ...{'printer_mac': '00:11:22:33:44:55', 'printer_name': 'RPP02N', 'printer_width': 58},
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes', 'device_uid': 'hp-tes'});
    final storage = await AppStorage.load();
    final local = await tester.runAsync(() async {
      final db = await memoryDb();
      await seedMaster(db, menus: menuJson);
      return db;
    });
    final printer = FakePrinter();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localDbOpenerProvider.overrideWithValue((_) async => local!),
        apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(server)),
        connectivityStreamProvider.overrideWithValue(const Stream.empty()),
        printerTransportProvider.overrideWithValue(printer),
      ],
      child: const InfoisApp(),
    ));
    await settle(tester);
    return (printer, menuJson);
  }

  late List<String> clipboard;
  setUp(() => clipboard = mockClipboard());

  Future<void> openCatatan(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(NavigationDestination, 'Catatan'));
    await settle(tester);
  }

  testWidgets('penjualan: daftar berhalaman saat digulir dan pencarian menyaring', (tester) async {
    final server = FakeServer(recordsHandler());
    await pumpApp(tester, server: server);
    expect(server.requests.where((request) => request.path.startsWith('records/')), isEmpty, reason: 'Belum dibuka: belum memanggil server.');

    await openCatatan(tester);
    final first = server.requests.where((request) => request.path == 'records/sales').toList();
    expect(first, hasLength(1));
    expect(first.single.queryParameters.containsKey('cursor'), isFalse);
    expect(find.byKey(const Key('sale-1365')), findsOneWidget);
    expect(find.text('POS-K22/000002'), findsOneWidget);
    expect(find.text('Lunas'), findsWidgets);
    expect(find.byKey(const Key('section-sales')), findsOneWidget);
    expect(find.byKey(const Key('section-purchases')), findsOneWidget);
    expect(find.byKey(const Key('section-suppliers')), findsOneWidget);

    // Gulir ke bawah: halaman berikutnya diminta dengan kursor.
    await tester.fling(find.byType(ListView).last, const Offset(0, -4000), 3000);
    await settle(tester);
    await tester.fling(find.byType(ListView).last, const Offset(0, -4000), 3000);
    await settle(tester);
    final paged = server.requests.where((request) => request.path == 'records/sales' && request.queryParameters['cursor'] != null).toList();
    expect(paged, isNotEmpty, reason: 'Gulir ke bawah memuat halaman berikutnya.');
    expect(paged.first.queryParameters['cursor'], 'c-sales-2');
    // Daftar dibangun malas: baris terakhir halaman kedua terlihat di bawah.
    expect(find.byKey(const Key('sale-1291')), findsOneWidget, reason: 'Baris halaman kedua ikut tampil.');

    // Cari: permintaan baru dengan q setelah jeda ketik.
    await tester.enterText(find.byKey(const Key('search-sales')), 'budi');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    final searched = server.requests.where((request) => request.path == 'records/sales' && request.queryParameters['q'] == 'budi').toList();
    expect(searched, hasLength(1));
    expect(find.byKey(const Key('sale-1365')), findsNothing);
    expect(find.byKey(const Key('sale-9')), findsOneWidget);
    expect(find.text('INV/2026/10/0009'), findsOneWidget);

    // Chip status menambah filter.
    await tester.tap(find.byKey(const Key('filter-sales-1')));
    await settle(tester);
    expect(server.requests.where((request) => request.path == 'records/sales' && request.queryParameters['status'] == 'outstanding' && request.queryParameters['q'] == 'budi'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rincian penjualan: barang, pembayaran, cetak ulang struk dari server', (tester) async {
    final server = FakeServer(recordsHandler());
    final (printer, _) = await pumpApp(tester, server: server, withPrinter: true);
    await openCatatan(tester);
    await tester.tap(find.byKey(const Key('sale-1365')));
    await settle(tester);

    expect(server.requests.where((request) => request.path == 'records/sales/1365'), hasLength(1));
    expect(find.byKey(const Key('sale-number')), findsOneWidget);
    expect(find.text('Americano'), findsOneWidget);
    expect(find.textContaining('1 gelas × Rp 26.000'), findsOneWidget);
    expect(find.text('Rp 26.000'), findsWidgets);
    expect(find.text('Tunai · Kas Outlet'), findsOneWidget);
    await scrollTo(tester, find.text('Retur barang dilakukan lewat website Infois.'));
    expect(find.byKey(const Key('void-sale')), findsNothing, reason: 'Sudah dibayar: tidak bisa dibatalkan (can.void false).');

    await tapVisible(tester, find.byKey(const Key('reprint')));
    await settle(tester);
    expect(server.requests.where((request) => request.path == 'records/sales/1365/receipt'), hasLength(1));
    expect(printer.printed, hasLength(1), reason: 'Struk dicetak dari data /receipt.');
    final text = String.fromCharCodes(printer.printed.single.where((byte) => byte >= 32 && byte < 127));
    expect(text, contains('POS-K22/000002'));
    expect(text, contains('Americano'));
    expect(text, contains('CETAK ULANG'));
    expect(find.text('Struk tercetak.'), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('whatsapp')));
    await settle(tester);
    expect(find.textContaining('Pesan struk disalin'), findsOneWidget);
    expect(clipboard.single, contains('POS-K22/000002'));
    expect(clipboard.single, contains('Total: Rp 26.000'));
    expect(clipboard.single, contains('http://tes/verify/uuid-1365'), reason: 'Tautan cek keaslian ikut dikirim.');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('batalkan penjualan: alasan dikirim dan status berubah', (tester) async {
    final server = FakeServer(recordsHandler());
    await pumpApp(tester, server: server);
    await openCatatan(tester);
    await tester.tap(find.byKey(const Key('sale-1366')));
    await settle(tester);
    expect(find.text('Terbit'), findsOneWidget);
    await scrollTo(tester, find.byKey(const Key('void-sale')));
    await tapVisible(tester, find.byKey(const Key('void-sale')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('void-reason')), 'Salah input');
    await tester.tap(find.byKey(const Key('void-confirm')));
    await settle(tester);
    final call = server.requests.where((request) => request.path == 'records/sales/1366/void').single;
    expect(call.method, 'POST');
    expect(jsonDecode(call.data is String ? call.data as String : jsonEncode(call.data))['reason'], 'Salah input');
    expect(find.text('Penjualan dibatalkan'), findsOneWidget);
    expect(find.text('Dibatalkan'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kasir: hanya bagian yang boleh dilihat, tanpa Pembelian & Pemasok', (tester) async {
    final server = FakeServer(recordsHandler(menus: kasir.menus.toJson()));
    await pumpApp(tester, server: server, tenant: kasir);
    await openCatatan(tester);
    expect(find.byKey(const Key('section-sales')), findsOneWidget);
    expect(find.byKey(const Key('section-payments')), findsOneWidget);
    expect(find.byKey(const Key('section-stock')), findsOneWidget);
    expect(find.byKey(const Key('section-customers')), findsOneWidget);
    expect(find.byKey(const Key('section-cash')), findsNothing, reason: 'Saldo kas/bank butuh hak laporan atau catat kas (web: Buku Besar).');
    expect(find.byKey(const Key('section-purchases')), findsNothing);
    expect(find.byKey(const Key('section-suppliers')), findsNothing);
    expect(server.requests.where((request) => request.path == 'records/purchases'), isEmpty);

    // Pembayaran: hanya chip "Uang masuk" (tanpa hak tagihan pemasok).
    await tapVisible(tester, find.byKey(const Key('section-payments')));
    await settle(tester);
    expect(find.text('Uang masuk'), findsOneWidget);
    expect(find.text('Uang keluar'), findsNothing);
    expect(find.byKey(const Key('payment-in-2235')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('daftar pendek bisa ditarik untuk memuat ulang', (tester) async {
    final server = FakeServer(recordsHandler());
    await pumpApp(tester, server: server);
    await openCatatan(tester);
    await tapVisible(tester, find.byKey(const Key('section-customers')));
    await settle(tester);
    expect(find.text('Belum ada pelanggan'), findsOneWidget);
    final before = server.requests.where((request) => request.path == 'records/customers').length;

    await tester.fling(find.text('Belum ada pelanggan'), const Offset(0, 400), 1200);
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(server.requests.where((request) => request.path == 'records/customers').length, before + 1, reason: 'Tarik ke bawah di daftar kosong memuat ulang.');

    await tester.tap(find.byKey(const Key('records-reload')));
    await settle(tester);
    expect(server.requests.where((request) => request.path == 'records/customers').length, before + 2, reason: 'Tombol Muat ulang di daftar kosong.');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('daftar panjang hanya membangun baris yang terlihat', (tester) async {
    final base = recordsHandler();
    final server = FakeServer((options, body) {
      if (options.path == 'records/sales' && options.queryParameters['cursor'] == null) {
        // Di bawah 50 KB: jawaban lebih besar di-decode Dio di isolate, yang tidak jalan di tes widget.
        return {'data': [for (var i = 0; i < 60; i++) saleJson(5000 - i)], 'next_cursor': null};
      }
      return base(options, body);
    });
    await pumpApp(tester, server: server);
    await openCatatan(tester);
    expect(find.byKey(const Key('sale-5000')), findsOneWidget);
    expect(find.byType(SaleListTile).evaluate().length, lessThan(30), reason: '60 nota dimuat, tapi hanya yang di layar yang dibangun.');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hak akses berubah: tiap chip tetap membuka bagiannya sendiri', (tester) async {
    // Sesi lama tanpa daftar permission: bagian mengikuti menu dari sinkron.
    const tenant = TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Admin', menus: Menus(pos: true, shift: true, records: true, stock: true));
    var menus = <String, dynamic>{'pos': true, 'shift': true, 'records': true, 'stock': true};
    final base = recordsHandler();
    final server = FakeServer((options, body) {
      final response = base(options, body);
      if (options.path == 'sync/pull' && response != null) {
        return {...response, 'menus': menus};
      }
      return response;
    });
    await pumpApp(tester, server: server, tenant: tenant, menus: menus);
    await openCatatan(tester);
    expect(find.byKey(const Key('section-cash')), findsNothing);
    await tapVisible(tester, find.byKey(const Key('section-stock')));
    await settle(tester);
    expect(find.text('Cari nama atau SKU barang'), findsOneWidget);

    // Pemilik memberi hak catat kas di web; sinkron membawa menu baru dan
    // "Kas & Bank" muncul di posisi yang tadinya milik Stok.
    menus = {...menus, 'cash_journal': true};
    final container = ProviderScope.containerOf(tester.element(find.byType(CatatanScreen)));
    unawaited(container.read(syncProvider.notifier).syncNow());
    await settle(tester);
    await tapVisible(tester, find.byKey(const Key('section-cash')));
    await settle(tester);
    expect(find.text('Cari keterangan, nomor, atau referensi'), findsOneWidget, reason: 'Chip Kas & Bank membuka Kas & Bank, bukan isi Stok yang tersimpan di posisi itu.');
    expect(find.text('Cari nama atau SKU barang'), findsNothing);
    await tapVisible(tester, find.byKey(const Key('section-stock')));
    await settle(tester);
    expect(find.text('Cari nama atau SKU barang'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tanpa hak catatan sama sekali: tab Catatan tidak tampil', (tester) async {
    final server = FakeServer(recordsHandler(menus: {'pos': true, 'shift': true}));
    await pumpApp(tester, server: server, tenant: const TenantSummary(id: 1, name: 'Warung Tes', roleLabel: 'Staff', menus: Menus(pos: true, shift: true), permissions: ['issue-invoice']), menus: {'pos': true, 'shift': true});
    expect(find.widgetWithText(NavigationDestination, 'Catatan'), findsNothing);
    expect(server.requests.where((request) => request.path.startsWith('records/')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offline: Catatan menjelaskan butuh internet', (tester) async {
    await pumpApp(tester, server: offlineServer());
    await openCatatan(tester);
    expect(find.text('Catatan butuh internet'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Server palsu: ping + sinkron minimal dan endpoint Catatan (API.md › 8).
Map<String, dynamic>? Function(RequestOptions options, Map<String, dynamic>? body) recordsHandler({Map<String, dynamic>? menus}) {
  var voided = false;
  return (options, body) {
    final path = options.path;
    final query = options.queryParameters;
    switch (path) {
      case 'ping':
        return {'ok': true, 'min_app_version': '1.0.0'};
      case 'sync/pull':
        return {
          'cursor': 'c1',
          'full': true,
          'tenant': {'id': 1, 'name': 'Warung Tes', 'prices_include_tax': false, 'sales_tax_name': 'PPN', 'sales_tax_rate': '11.00'},
          'receipt': {'width': 58, 'company': {'name': 'Warung Tes'}},
          'device': {'id': 3, 'code': 'K1', 'name': 'HP Tes'},
          'menus': menus ?? {'pos': true, 'shift': true, 'reports': true, 'records': true, 'stock': true, 'cash_journal': true, 'void_sale': true, 'printer': true},
          'products': {'items': [], 'ids': [1, 2]},
          'customers': {'items': [], 'ids': [7]},
          'accounts': {'items': [], 'ids': [], 'default_cash_id': null, 'default_transfer_id': null},
          'warehouses': {'items': [], 'ids': []},
          'number_blocks': [],
          'open_shift': null,
        };
      case 'sync/push':
        return {'results': []};
      case 'records/sales':
        if (query['q'] == 'budi') {
          return {'data': [saleJson(9, number: 'INV/2026/10/0009', customer: 'Pak Budi', status: query['status'] == 'outstanding' ? 'issued' : 'paid')], 'next_cursor': null};
        }
        if (query['cursor'] == 'c-sales-2') {
          return {'data': [for (var i = 0; i < 10; i++) saleJson(1300 - i)], 'next_cursor': null};
        }
        return {
          'data': [saleJson(1365), saleJson(1366, status: 'issued', paid: '0.00'), for (var i = 0; i < 23; i++) saleJson(1340 - i)],
          'next_cursor': 'c-sales-2',
        };
      case 'records/sales/1365':
        return {'sale': saleDetailJson(1365)};
      case 'records/sales/1366':
        return {'sale': saleDetailJson(1366, status: voided ? 'void' : 'issued', paid: '0.00', canVoid: !voided)};
      case 'records/sales/1366/void':
        voided = true;
        return {'sale': saleDetailJson(1366, status: 'void', paid: '0.00', canVoid: false), 'message': 'Penjualan dibatalkan'};
      case 'records/sales/1365/receipt':
        return {
          'sale': {
            'id': 1365,
            'client_uuid': '15eafd03-1',
            'number': 'POS-K22/000002',
            'status': 'paid',
            'source': 'pos',
            'date': '2026-10-09',
            'created_at': '2026-10-09T14:57:18+07:00',
            'customer_id': 29,
            'customer_name': 'Pelanggan Umum',
            'notes': null,
            'items': [
              {'product_id': 68, 'description': 'Americano', 'quantity': '1.000000', 'unit': 'gelas', 'unit_price': '26000.00', 'discount_percent': '0.00', 'tax_rate': '0.00', 'discount_amount': '0.00', 'line_total': '26000.00'},
            ],
            'payments': [
              {'client_uuid': 'p-1', 'method': 'cash', 'amount': '26000.00', 'tendered': null, 'account_id': 127, 'date': '2026-10-09'},
            ],
            'subtotal': '26000.00',
            'discount_total': '0.00',
            'tax_total': '0.00',
            'total': '26000.00',
            'paid': '26000.00',
            'change': '0.00',
            'cashier': 'Rani',
            'tax_name': 'PPN',
            'prices_include_tax': false,
            'verification_url': 'http://tes/verify/15eafd03-1',
          },
          'reprint': true,
        };
      case 'records/payments':
        return {'data': [paymentJson()], 'next_cursor': null};
      case 'records/purchases':
        return {'data': [], 'next_cursor': null};
      case 'records/cash':
        return {'data': [], 'next_cursor': null, 'period': {'from': '2026-09-10', 'to': '2026-10-09'}, 'accounts': [], 'totals': {'in': '0.00', 'out': '0.00', 'opening': '0.00', 'closing': '0.00'}};
      case 'records/stock':
        return {'data': [], 'next_cursor': null, 'low_count': 0};
      case 'records/customers':
      case 'records/suppliers':
        return {'data': [], 'next_cursor': null};
    }
    return {'_status': 404, 'message': 'Tidak ditemukan: $path', 'code': 'tidak_ditemukan'};
  };
}

Map<String, dynamic> saleJson(int id, {String number = '', String customer = 'Pelanggan Umum', String status = 'paid', String paid = '26000.00'}) => {
      'id': id,
      'number': number.isEmpty ? (id == 1365 ? 'POS-K22/000002' : 'POS-K22/${id.toString().padLeft(6, '0')}') : number,
      'client_uuid': 'uuid-$id',
      'date': '2026-10-09',
      'due_date': '2026-10-09',
      'status': status,
      'status_label': switch (status) {
        'paid' => 'Lunas',
        'issued' => 'Terbit',
        'void' => 'Dibatalkan',
        _ => status,
      },
      'source': 'pos',
      'customer': {'id': 29, 'name': customer, 'phone': null},
      'currency': 'IDR',
      'total': '26000.00',
      'amount_paid': paid,
      'balance_due': status == 'void' ? '0.00' : (26000 - double.parse(paid)).toStringAsFixed(2),
      'items_count': 1,
      'cashier': 'Rani',
      'device': {'id': 22, 'code': 'K22', 'name': 'HP Kasir 1'},
      'pos_shift_id': 4,
      'has_attachments': false,
      'issued_at': '2026-10-09T14:57:18+07:00',
      'created_at': '2026-10-09T14:57:18+07:00',
      'updated_at': '2026-10-09T14:57:20+07:00',
    };

Map<String, dynamic> saleDetailJson(int id, {String status = 'paid', String paid = '26000.00', bool canVoid = false}) => {
      ...saleJson(id, status: status, paid: paid),
      'is_opening': false,
      'prices_include_tax': false,
      'tax_name': 'PPN',
      'subtotal': '26000.00',
      'discount_total': '0.00',
      'tax_total': '0.00',
      'notes': null,
      'terms': null,
      'warehouse': {'id': 6, 'code': 'GR', 'name': 'Gudang Roastery'},
      'items': [
        {'id': 14071, 'product_id': 68, 'sku': 'MNU-AMR', 'description': 'Americano', 'quantity': '1.000000', 'unit': 'gelas', 'unit_price': '26000.00', 'discount_percent': '0.00', 'tax_rate': '0.00', 'discount_amount': '0.00', 'net_amount': '26000.00', 'tax_amount': '0.00', 'line_total': '26000.00'},
      ],
      'payments': status == 'paid' ? [paymentJson()] : [],
      'credit_notes': [],
      'verification': {'url': 'http://tes/verify/uuid-$id', 'status': status == 'void' ? 'void' : 'valid'},
      'void_reason': status == 'void' ? 'Salah input' : null,
      'voided_at': status == 'void' ? '2026-10-09T16:00:00+07:00' : null,
      'attachments': [],
      'links': {'receipt': 'http://tes/api/v1/records/sales/$id/receipt', 'pdf': 'http://tes/api/v1/records/sales/$id/pdf'},
      'can': {'void': canVoid, 'return': false},
    };

Map<String, dynamic> paymentJson() => {
      'id': 2235,
      'kind': 'in',
      'date': '2026-10-09',
      'amount': '26000.00',
      'base_amount': '26000.00',
      'currency': 'IDR',
      'method': 'cash',
      'method_label': 'Tunai',
      'via': 'payment',
      'reference': 'Kasir HP K22',
      'account': {'id': 127, 'code': '1-1100', 'name': 'Kas Outlet'},
      'document': {'type': 'sale', 'id': 1365, 'number': 'POS-K22/000002', 'status': 'paid'},
      'party': {'type': 'customer', 'id': 29, 'name': 'Pelanggan Umum'},
      'withholding_amount': '0.00',
      'has_attachments': false,
      'created_at': '2026-10-09T14:57:19+07:00',
    };

/// Gulir daftar layar teratas sampai [finder] terbangun dan terlihat.
Future<void> scrollTo(WidgetTester tester, Finder finder) => tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).last);

/// Gulir sampai terlihat, gambar ulang, lalu ketuk.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

/// Pump beberapa frame (tanpa pumpAndSettle karena indikator berputar).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
