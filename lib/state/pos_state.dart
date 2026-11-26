import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/money.dart';
import '../data/outbox_store.dart';
import '../data/pos_ai_api.dart';
import '../data/qris_api.dart';
import '../domain/cart.dart';
import '../domain/models.dart';
import '../domain/pos_ai.dart';
import '../domain/qris.dart';
import '../services/file_downloads.dart' show whatsappUri;
import '../services/pos_service.dart';
import '../services/printing/receipt_builder.dart';
import '../services/sync_engine.dart' show MetaKeys;
import 'printer_controller.dart';
import 'session.dart';
import 'sync_controller.dart';
import 'workspace.dart';

/// Keranjang kasir aktif.
class CartController extends Notifier<Cart> {
  @override
  Cart build() {
    ref.watch(workspaceProvider.select((value) => value.valueOrNull?.tenant.id));
    return const Cart();
  }

  /// Tambah barang. Barang yang sama (satuan sama, tanpa catatan) cukup
  /// ditambah jumlahnya; barang dengan catatan menjadi baris sendiri. Harga
  /// bertingkat mengikuti jumlah dan level pelanggan keranjang.
  void add(Product product, {String? unit, String quantity = '1', String? note}) {
    final unitName = product.optionFor(unit).name;
    final cleaned = cleanNote(note);
    final levelId = state.levelId;
    final index = cleaned != null ? -1 : state.lines.indexWhere((line) => line.product?.id == product.id && line.unit == unitName && line.note == null);
    if (index >= 0) {
      final line = state.lines[index];
      final lines = [...state.lines]..[index] = line.copyWith(quantity: Money.add([line.quantity, quantity]), levelId: levelId);
      state = state.copyWith(lines: lines);
      return;
    }
    state = state.copyWith(lines: [...state.lines, CartLine.fromProduct(PosService.newUuid(), product, unit: unitName, quantity: quantity, note: cleaned, levelId: levelId)]);
  }

  /// Hasil Input AI: setiap barang masuk lewat [add], persis seperti ketuk
  /// barang (satuan, harga bertingkat & level pelanggan, gabung baris yang sama). Barang yang tidak
  /// ada / tidak aktif di katalog HP ini menjadi "tidak ditemukan"; saran
  /// hanya barang aktif. Sama dengan `applyAiInput` kasir web.
  PosAiApplied applyAi(PosAiResult result, Map<int, Product> products) {
    Product? sellable(int id) {
      final product = products[id];
      return product != null && product.isActive ? product : null;
    }

    final added = <PosAiAdded>[];
    final unmatched = [...result.unmatched];
    for (final item in result.items) {
      final product = sellable(item.productId);
      if (product == null) {
        unmatched.add(PosAiUnmatched(said: item.said.isEmpty ? item.name : item.said, quantity: item.quantity, unit: item.unit, note: item.note));
        continue;
      }
      add(product, unit: item.unit, quantity: item.quantity, note: item.note);
      added.add(PosAiAdded(name: product.name, quantity: item.quantity, unit: product.optionFor(item.unit).name));
    }
    return PosAiApplied(
      added: added,
      unmatched: [for (final row in unmatched) row.copyWith(suggestions: row.suggestions.where((suggestion) => sellable(suggestion.id) != null).toList())],
    );
  }

  /// Saran "tidak ditemukan" yang diketuk kasir: jumlah & catatan dari
  /// pesanan, satuan bila barang punya satuan itu.
  PosAiAdded addAiSuggestion(Product product, PosAiUnmatched row) {
    add(product, unit: row.unit, quantity: row.quantity, note: row.note);
    return PosAiAdded(name: product.name, quantity: row.quantity, unit: product.optionFor(row.unit).name);
  }

  void update(String key, CartLine Function(CartLine line) change) {
    state = state.copyWith(lines: [for (final line in state.lines) line.key == key ? change(line) : line]);
  }

  /// Tambah/kurangi qty satu baris; di bawah 1 baris dihapus.
  void step(String key, int delta) {
    final line = state.lines.where((line) => line.key == key).firstOrNull;
    if (line == null) {
      return;
    }
    final next = Money.add([line.quantity, '$delta']);
    if (Money.isPositive(next)) {
      update(key, (current) => current.copyWith(quantity: next, levelId: state.levelId));
    } else {
      remove(key);
    }
  }

  void remove(String key) => state = state.copyWith(lines: state.lines.where((line) => line.key != key).toList());

  void setNotaDiscount(String percent) => state = state.copyWith(notaDiscountPercent: percent);

  /// Tambah biaya tambahan nota (ongkos kirim, ...): nama maks. 60 huruf.
  void addCharge(String name, String amount) {
    final cleaned = cleanNote(name, 60);
    if (cleaned == null) {
      return;
    }
    state = state.copyWith(charges: [...state.charges, CartCharge(key: PosService.newUuid(), name: cleaned, amount: Money.normalize(amount))]);
  }

  void removeCharge(String key) => state = state.copyWith(charges: state.charges.where((charge) => charge.key != key).toList());

  /// Pilih/ganti/hapus pelanggan; harga otomatis semua baris dihitung ulang
  /// dengan level pelanggan itu (harga manual tetap).
  void setCustomer(Customer? customer) => state = state.withCustomer(customer);

  /// Catatan pesanan; kosong = hapus.
  void setNote(String note) => state = state.copyWith(note: note);

  /// Nomor antrian pesanan ini (diberi sekali, lihat [PosActions.ensureQueueNumber]).
  void setQueueNumber(String number) => state = state.copyWith(queueNumber: number);

  /// Alamat pengiriman (maks. 500 huruf); kosong = hapus.
  void setDeliveryAddress(String address) => state = state.copyWith(deliveryAddress: address);

  void setLineNote(String key, String note) => update(key, (line) => line.copyWith(note: note));

  /// Pilih jenis pesanan; pilih yang sama lagi = batal pilih.
  void setOrderType(OrderType? type) =>
      state = type == null || type == state.orderType ? state.copyWith(clearOrderType: true) : state.copyWith(orderType: type);

  /// Meja / antrian; kosong = hapus.
  void setOrderLabel(String label) => state = state.copyWith(orderLabel: label);

  /// Ganti seluruh keranjang (melanjutkan pesanan tersimpan).
  void load(Cart cart) => state = cart;

  void clear() => state = const Cart();
}

final cartProvider = NotifierProvider<CartController, Cart>(CartController.new);

/// Klien QRIS kasir untuk perusahaan aktif (null bila belum ada perusahaan).
final qrisApiProvider = Provider<QrisApi?>((ref) {
  final workspace = ref.watch(workspaceProvider).valueOrNull;
  return workspace == null ? null : QrisApi(workspace.api);
});

/// Klien Input AI kasir untuk perusahaan aktif (null bila belum ada perusahaan).
final posAiApiProvider = Provider<PosAiApi?>((ref) {
  final workspace = ref.watch(workspaceProvider).valueOrNull;
  return workspace == null ? null : PosAiApi(workspace.api);
});

final posServiceProvider = FutureProvider<PosService?>((ref) async {
  final workspace = await ref.watch(workspaceProvider.future);
  final master = await ref.watch(masterDataProvider.future);
  if (workspace == null || master == null) {
    return null;
  }
  return PosService(local: workspace.local, user: workspace.user, master: master);
});

/// Daftar pesanan tersimpan di HP ini (open bill).
final heldOrdersProvider = FutureProvider<List<HeldOrder>>((ref) async {
  ref.watch(dataVersionProvider);
  final workspace = await ref.watch(workspaceProvider.future);
  return workspace == null ? const [] : HeldOrderStore(workspace.local).all();
});

/// Cara membuka tautan WhatsApp (diganti di tes).
final linkLauncherProvider = Provider<Future<bool> Function(Uri uri)>((ref) {
  return (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
});

/// Hasil bayar: penjualan tersimpan + status cetak.
class CheckoutOutcome {
  const CheckoutOutcome(this.sale, this.print, {this.kitchen});

  final Map<String, dynamic> sale;

  /// Struk otomatis ke printer kasir (null = tidak dicetak otomatis).
  final PrintResult? print;

  /// List otomatis ke printer produksi (null = tidak dicetak otomatis).
  final ProductionResult? kitchen;
}

/// Alur bayar: simpan ke HP → kosongkan keranjang → cetak otomatis →
/// sinkron di latar (bila online).
class PosActions {
  PosActions(this.ref);

  final Ref ref;

  Future<CheckoutOutcome> checkout({required String clientUuid, required PaymentInput payment, bool autoPrint = true}) async {
    final service = await ref.read(posServiceProvider.future);
    if (service == null) {
      throw const CheckoutException('Data kasir belum siap. Tunggu sinkron selesai.');
    }
    await ensureQueueNumber(service);
    final shift = await ref.read(openShiftProvider.future);
    final saved = await service.checkout(
      clientUuid: clientUuid,
      cart: ref.read(cartProvider),
      payment: payment,
      shiftClientUuid: shift?['client_uuid'] as String?,
    );
    var sale = saved;
    if (payment.mode == PayMode.qris) {
      // QRIS (online): langsung dikirim. Ditolak server = keranjang & QR yang
      // sudah dibayar tetap, kasir bisa mencoba lagi.
      sale = await _pushQrisSale(clientUuid) ?? saved;
    }
    final phone = ref.read(cartProvider).customer?.phone;
    if (phone != null && phone.isNotEmpty) {
      sale['customer_phone'] = phone;
    }
    ref.read(cartProvider.notifier).clear();
    ref.read(dataVersionProvider.notifier).state++;
    if (payment.mode != PayMode.qris) {
      unawaited(ref.read(syncProvider.notifier).refreshPending().then((_) => ref.read(syncProvider.notifier).syncNow()));
    }

    // Struk ke printer kasir, lalu list ke printer produksi (gagal di satu
    // printer tidak menahan yang lain).
    PrintResult? printed;
    if (autoPrint && ref.read(storageProvider).autoPrint) {
      printed = await ref.read(printerProvider.notifier).printSale(sale);
    }
    ProductionResult? kitchen;
    if (autoPrint && ref.read(storageProvider).autoPrintKitchen) {
      kitchen = await printOrderList(sale);
    }
    return CheckoutOutcome(sale, printed, kitchen: kitchen);
  }

  /// Kirim penjualan QRIS [clientUuid] sekarang (paling lama [qrisPushWait]).
  /// Ditolak → [CheckoutException] dengan pesan server (penjualan yang sama
  /// dikirim ulang saat dicoba lagi). Offline / lambat: tetap di antrean.
  /// Kembalikan data struk terbaru (nomor final dari server).
  Future<Map<String, dynamic>?> _pushQrisSale(String clientUuid) async {
    final workspace = await ref.read(workspaceProvider.future);
    if (workspace == null || !workspace.usable) {
      return null;
    }
    final outbox = OutboxStore(workspace.local);
    if ((await outbox.find(clientUuid))?.status == OutboxStatus.rejected) {
      await outbox.retry(clientUuid);
    }
    final sync = ref.read(syncProvider.notifier);
    await sync.refreshPending();
    try {
      await sync.syncNow().timeout(qrisPushWait);
    } on TimeoutException {
      // Server lambat: penjualan tetap di antrean dan terkirim nanti.
    }
    final item = await outbox.find(clientUuid);
    if (item?.status == OutboxStatus.rejected) {
      ref.read(dataVersionProvider.notifier).state++;
      throw CheckoutException(item?.lastError ?? 'Penjualan QRIS ditolak server. Coba lagi.');
    }
    return workspace.local.sale(clientUuid);
  }

  /// Batas tunggu kirim penjualan QRIS sebelum lanjut ke struk.
  static const Duration qrisPushWait = Duration(seconds: 15);

  /// Cetak tagihan + QR QRIS yang belum dibayar ("Cetak QR"), bila
  /// `tenant.qris.print_on_bill`. Tidak dicatat.
  Future<PrintResult> printQrisBill(QrisPayment qris) async {
    if (ref.read(printerProvider).printer == null) {
      return PrintResult.noPrinter;
    }
    final cart = ref.read(cartProvider);
    final store = await _heldStore();
    final title = cart.heldId == null ? null : (await store?.find(cart.heldId!))?.name;
    final draft = await _draft(title);
    if (draft == null || qris.qrContent == null) {
      return PrintResult.failed;
    }
    return ref.read(printerProvider.notifier).printBill({
      ...draft,
      'qris': {'content': qris.qrContent, 'amount': qris.amount},
    });
  }

  /// Barang untuk kode hasil scan kamera / scanner / ketik: barcode dulu,
  /// lalu SKU; barang nonaktif tidak dijual (lihat [LocalDb.lookupCode]).
  Future<CodeLookup> lookupCode(String code) async {
    final workspace = await ref.read(workspaceProvider.future);
    if (workspace == null || !workspace.usable) {
      return CodeLookup.none;
    }
    return workspace.local.lookupCode(code);
  }

  /// Tambahkan barang aktif dengan kode [code] ke pesanan. Kode yang tidak
  /// ada atau hanya cocok dengan barang nonaktif tidak menambah apa pun.
  Future<CodeLookup> addByCode(String code) async {
    final found = await lookupCode(code);
    final product = found.product;
    if (product != null) {
      ref.read(cartProvider.notifier).add(product);
    }
    return found;
  }

  /// Kirim pesanan ke Input AI lalu masukkan hasilnya ke keranjang.
  Future<(PosAiResult, PosAiApplied)> aiInput(PosAiMode mode, {String? text, String? path, String? name, int? seconds}) async {
    final api = ref.read(posAiApiProvider);
    final workspace = await ref.read(workspaceProvider.future);
    if (api == null || workspace == null || !workspace.usable) {
      throw const CheckoutException('Data kasir belum siap.');
    }
    final result = await api.send(mode, text: text, path: path, name: name, seconds: seconds);
    final products = await workspace.local.productsByIds([
      for (final item in result.items) item.productId,
      for (final row in result.unmatched)
        for (final suggestion in row.suggestions) suggestion.id,
    ]);
    return (result, ref.read(cartProvider.notifier).applyAi(result, products));
  }

  /// Barang aktif dengan id [id] di katalog HP, atau null.
  Future<Product?> activeProduct(int id) async {
    final workspace = await ref.read(workspaceProvider.future);
    final product = workspace == null ? null : (await workspace.local.productsByIds([id]))[id];
    return product != null && product.isActive ? product : null;
  }

  Future<HeldOrderStore?> _heldStore() async {
    final workspace = await ref.read(workspaceProvider.future);
    return workspace == null ? null : HeldOrderStore(workspace.local);
  }

  /// Rumah makan / kafe: beri nomor antrian ke pesanan yang belum punya
  /// (barang pertama masuk keranjang; juga Simpan, Cetak list, atau bayar).
  Future<void> ensureQueueNumber([PosService? known]) async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty || cart.queueNumber != null) {
      return;
    }
    final service = known ?? await ref.read(posServiceProvider.future);
    if (service == null || !service.master.tenant.posDining) {
      return;
    }
    final number = await service.nextQueueNumber();
    // Keranjang bisa berubah selama menunggu (dikosongkan / pesanan lain dibuka).
    final now = ref.read(cartProvider);
    if (now.isEmpty || now.queueNumber != null) {
      return;
    }
    ref.read(cartProvider.notifier).setQueueNumber(number);
  }

  /// Simpan keranjang sebagai pesanan tersimpan lalu kosongkan keranjang.
  Future<String> holdCurrent({String? name}) async {
    final store = await _heldStore();
    if (store != null) {
      await ensureQueueNumber();
    }
    final cart = ref.read(cartProvider);
    if (store == null) {
      throw const CheckoutException('Data kasir belum siap.');
    }
    final master = await ref.read(masterDataProvider.future);
    final total = cart.totals(pricesIncludeTax: master?.tenant.pricesIncludeTax ?? false).total;
    final id = await store.save(cart, name: name ?? '', total: total);
    ref.read(cartProvider.notifier).clear();
    ref.read(dataVersionProvider.notifier).state++;
    return id;
  }

  /// Buka pesanan tersimpan di keranjang. Keranjang yang sedang terisi
  /// disimpan dulu supaya tidak hilang (kembalikan true bila begitu).
  /// Pelanggan diambil ulang dari data HP (level bisa berubah) dan harga
  /// otomatis dihitung ulang dengan katalog terbaru; harga manual tetap.
  Future<bool> resume(HeldOrder order) async {
    final current = ref.read(cartProvider);
    final saveCurrent = !current.isEmpty && current.heldId != order.id;
    if (saveCurrent) {
      await holdCurrent();
    }
    ref.read(cartProvider.notifier).load(await _refreshed(order.cart.copyWith(heldId: order.id)));
    return saveCurrent;
  }

  Future<Cart> _refreshed(Cart cart) async {
    final workspace = await ref.read(workspaceProvider.future);
    if (workspace == null) {
      return cart;
    }
    try {
      final customer = cart.customer == null ? null : await workspace.local.customerFor(cart.customer!);
      final catalog = await workspace.local.productsByIds([
        for (final line in cart.lines)
          if (line.product != null) line.product!.id,
      ]);
      return cart.reopened(customer: customer, catalog: catalog);
    } on Exception {
      // Data HP belum bisa dibaca: pesanan tetap dibuka apa adanya.
      return cart;
    }
  }

  Future<void> deleteHeld(String id) async {
    final store = await _heldStore();
    await store?.delete(id);
    if (ref.read(cartProvider).heldId == id) {
      ref.read(cartProvider.notifier).clear();
    }
    ref.read(dataVersionProvider.notifier).state++;
  }

  /// Kosongkan keranjang; pesanan tersimpan yang sedang dibuka ikut dihapus.
  Future<void> discardCart() async {
    final heldId = ref.read(cartProvider).heldId;
    ref.read(cartProvider.notifier).clear();
    if (heldId != null) {
      await deleteHeld(heldId);
    }
  }

  /// Cetak list pesanan (tanpa harga, tanpa biaya tambahan) ke semua
  /// printer produksi sesuai kategori barangnya (tanpa printer produksi:
  /// printer kasir): dapur, bar, checker, atau menyiapkan barang.
  Future<ProductionResult> printOrderList(Map<String, dynamic> sale) async {
    final state = ref.read(printerProvider);
    if (state.production.isEmpty && state.printer == null) {
      return const ProductionResult(noPrinter: true);
    }
    final workspace = await ref.read(workspaceProvider.future);
    final ids = {
      for (final item in (sale['items'] as List? ?? const []))
        if (item is Map && item['product_id'] is int) item['product_id'] as int,
    };
    final products = workspace == null || ids.isEmpty ? const <int, Product>{} : await workspace.local.productsByIds(ids.toList());
    return ref.read(printerProvider.notifier).printProduction(sale, categoryOf: {for (final entry in products.entries) entry.key: entry.value.categoryId});
  }

  /// Data cetak keranjang sebelum dibayar; [title] = nama pesanan tersimpan.
  Future<Map<String, dynamic>?> _draft(String? title) async {
    final service = await ref.read(posServiceProvider.future);
    final cart = ref.read(cartProvider);
    return service == null || cart.isEmpty ? null : service.draft(cart, title: title);
  }

  /// Cetak tagihan keranjang sebelum dibayar (pelanggan minta nota dulu,
  /// bayar nanti / bon). Tidak dicatat dan tidak dikirim ke server.
  Future<PrintResult> printDraftBill({String? title}) async {
    if (ref.read(printerProvider).printer == null) {
      return PrintResult.noPrinter;
    }
    final draft = await _draft(title);
    return draft == null ? PrintResult.failed : ref.read(printerProvider.notifier).printBill(draft);
  }

  /// Cetak list pesanan keranjang sebelum dibayar. Tidak dicatat.
  Future<ProductionResult> printDraftList({String? title}) async {
    final state = ref.read(printerProvider);
    if (state.production.isEmpty && state.printer == null) {
      return const ProductionResult(noPrinter: true);
    }
    await ensureQueueNumber();
    final draft = await _draft(title);
    return draft == null ? const ProductionResult() : printOrderList(draft);
  }

  /// Tutup kasir: simpan di HP, lalu kirim ke server sebentar (bila online,
  /// paling lama [wait]) supaya uang awal & setoran otomatis yang dicatat
  /// server (`cash_transfers`) ikut tampil dan tercetak. Offline: laporan
  /// tanpa data itu.
  Future<Map<String, dynamic>> closeShift(Map<String, dynamic> shift, String counted, {Duration wait = const Duration(seconds: 8), String? notes}) async {
    final service = await ref.read(posServiceProvider.future);
    if (service == null) {
      throw const CheckoutException('Data kasir belum siap.');
    }
    final report = await service.closeShift(shift, counted, notes: notes);
    ref.read(dataVersionProvider.notifier).state++;
    final sync = ref.read(syncProvider.notifier);
    await sync.refreshPending();
    try {
      await sync.syncNow().timeout(wait);
    } on TimeoutException {
      // Server lambat: laporan tanpa data pindah uang (tampil saat sinkron selesai).
    }
    final transfers = await shiftTransfers(shift['client_uuid'] as String);
    return {...report, if (transfers != null) 'cash_transfers': transfers.toJson()};
  }

  /// `cash_transfers` shift [clientUuid] dari jawaban server yang tersimpan di HP.
  Future<ShiftCashTransfers?> shiftTransfers(String clientUuid) async {
    final workspace = await ref.read(workspaceProvider.future);
    if (workspace == null || !workspace.usable) {
      return null;
    }
    final stored = await workspace.local.shift(clientUuid);
    final server = stored?['server'];
    return server is Map ? ShiftCashTransfers.fromJson(server['cash_transfers']) : null;
  }

  /// Pengaturan kasir untuk semua kasir di usaha ini: fitur rumah makan /
  /// kafe (`PUT /pos/settings`, online saja; hanya `menus.pos_settings`).
  /// Berhasil = pengaturan di HP langsung diganti (tanpa menunggu sinkron).
  Future<bool> saveDining(bool value) async {
    final workspace = await ref.read(workspaceProvider.future);
    if (workspace == null || !workspace.usable) {
      throw const CheckoutException('Data kasir belum siap.');
    }
    final result = await workspace.api.put('pos/settings', data: {'dining': value});
    final settings = result['settings'];
    final dining = settings is Map && settings['dining'] is bool ? settings['dining'] as bool : value;
    final tenant = await workspace.local.getJson(MetaKeys.tenant);
    await workspace.local.setJson(MetaKeys.tenant, {'id': workspace.tenant.id, 'name': workspace.tenant.name, ...?tenant, 'pos_dining': dining});
    ref.read(dataVersionProvider.notifier).state++;
    return dining;
  }

  /// Teks struk untuk WhatsApp / disalin.
  Future<String> receiptText(Map<String, dynamic> sale) async {
    final master = await ref.read(masterDataProvider.future);
    return ReceiptBuilder.plainText(sale, master?.receipt ?? const ReceiptConfig());
  }

  /// Buka WhatsApp dengan teks struk (aturan nomor sama dengan Catatan:
  /// [whatsappUri]). False bila WhatsApp tidak bisa dibuka.
  Future<bool> sendWhatsApp(Map<String, dynamic> sale, {String? phone}) async {
    final text = await receiptText(sale);
    try {
      return await ref.read(linkLauncherProvider)(whatsappUri(text, phone: phone ?? sale['customer_phone']?.toString()));
    } on Exception {
      return false;
    }
  }
}

final posActionsProvider = Provider<PosActions>(PosActions.new);
