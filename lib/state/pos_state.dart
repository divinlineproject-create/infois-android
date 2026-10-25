import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/money.dart';
import '../data/pos_ai_api.dart';
import '../domain/cart.dart';
import '../domain/models.dart';
import '../domain/pos_ai.dart';
import '../services/file_downloads.dart' show whatsappUri;
import '../services/pos_service.dart';
import '../services/printing/receipt_builder.dart';
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
  /// ditambah jumlahnya; barang dengan catatan menjadi baris sendiri.
  void add(Product product, {String? unit, String quantity = '1', String? note}) {
    final unitName = product.optionFor(unit).name;
    final cleaned = cleanNote(note);
    final index = cleaned != null ? -1 : state.lines.indexWhere((line) => line.product?.id == product.id && line.unit == unitName && line.note == null);
    if (index >= 0) {
      final line = state.lines[index];
      final lines = [...state.lines]..[index] = line.copyWith(quantity: Money.add([line.quantity, quantity]));
      state = state.copyWith(lines: lines);
      return;
    }
    state = state.copyWith(lines: [...state.lines, CartLine.fromProduct(PosService.newUuid(), product, unit: unitName, quantity: quantity, note: cleaned)]);
  }

  /// Hasil Input AI: setiap barang masuk lewat [add], persis seperti ketuk
  /// barang (satuan, harga grosir, gabung baris yang sama). Barang yang tidak
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
      update(key, (current) => current.copyWith(quantity: next));
    } else {
      remove(key);
    }
  }

  void remove(String key) => state = state.copyWith(lines: state.lines.where((line) => line.key != key).toList());

  void setNotaDiscount(String percent) => state = state.copyWith(notaDiscountPercent: percent);

  void setCustomer(Customer? customer) => state = customer == null ? state.copyWith(clearCustomer: true) : state.copyWith(customer: customer);

  /// Catatan pesanan; kosong = hapus.
  void setNote(String note) => state = state.copyWith(note: note);

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
  const CheckoutOutcome(this.sale, this.print);

  final Map<String, dynamic> sale;
  final PrintResult? print;
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
    final shift = await ref.read(openShiftProvider.future);
    final sale = await service.checkout(
      clientUuid: clientUuid,
      cart: ref.read(cartProvider),
      payment: payment,
      shiftClientUuid: shift?['client_uuid'] as String?,
    );
    final phone = ref.read(cartProvider).customer?.phone;
    if (phone != null && phone.isNotEmpty) {
      sale['customer_phone'] = phone;
    }
    ref.read(cartProvider.notifier).clear();
    ref.read(dataVersionProvider.notifier).state++;
    unawaited(ref.read(syncProvider.notifier).refreshPending().then((_) => ref.read(syncProvider.notifier).syncNow()));

    PrintResult? printed;
    if (autoPrint && ref.read(storageProvider).autoPrint) {
      printed = await ref.read(printerProvider.notifier).printSale(sale);
    }
    return CheckoutOutcome(sale, printed);
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

  /// Simpan keranjang sebagai pesanan tersimpan lalu kosongkan keranjang.
  Future<String> holdCurrent({String? name}) async {
    final store = await _heldStore();
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
  Future<bool> resume(HeldOrder order) async {
    final current = ref.read(cartProvider);
    final saveCurrent = !current.isEmpty && current.heldId != order.id;
    if (saveCurrent) {
      await holdCurrent();
    }
    ref.read(cartProvider.notifier).load(order.cart.copyWith(heldId: order.id));
    return saveCurrent;
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

  int _paperWidth(MasterData master) => ref.read(printerProvider).printer?.width ?? ref.read(storageProvider).printerWidth ?? master.receipt.width;

  /// Cetak tiket pesanan dapur (tanpa harga) ke printer struk.
  Future<PrintResult> printKitchenTicket(Map<String, dynamic> sale) async {
    if (ref.read(printerProvider).printer == null) {
      return PrintResult.noPrinter;
    }
    final master = await ref.read(masterDataProvider.future);
    if (master == null) {
      return PrintResult.failed;
    }
    final builder = await ref.read(receiptBuilderProvider.future);
    return ref.read(printerProvider.notifier).printBytes(builder.kitchenTicket(sale, master.receipt, width: _paperWidth(master)));
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
