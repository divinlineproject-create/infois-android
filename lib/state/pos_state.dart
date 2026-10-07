import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/money.dart';
import '../domain/cart.dart';
import '../domain/models.dart';
import '../services/pos_service.dart';
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

  /// Tambah barang; barang yang sama (satuan sama) cukup ditambah 1.
  void add(Product product, {String? unit}) {
    final unitName = product.optionFor(unit).name;
    final index = state.lines.indexWhere((line) => line.product?.id == product.id && line.unit == unitName);
    if (index >= 0) {
      final line = state.lines[index];
      final lines = [...state.lines]..[index] = line.copyWith(quantity: Money.add([line.quantity, '1']));
      state = state.copyWith(lines: lines);
      return;
    }
    state = state.copyWith(lines: [...state.lines, CartLine.fromProduct(PosService.newUuid(), product, unit: unitName)]);
  }

  void update(String key, CartLine Function(CartLine line) change) {
    state = state.copyWith(lines: [for (final line in state.lines) line.key == key ? change(line) : line]);
  }

  void remove(String key) => state = state.copyWith(lines: state.lines.where((line) => line.key != key).toList());

  void setNotaDiscount(String percent) => state = state.copyWith(notaDiscountPercent: percent);

  void setCustomer(Customer? customer) => state = customer == null ? state.copyWith(clearCustomer: true) : state.copyWith(customer: customer);

  void setNote(String note) => state = state.copyWith(note: note);

  void clear() => state = const Cart();
}

final cartProvider = NotifierProvider<CartController, Cart>(CartController.new);

final posServiceProvider = FutureProvider<PosService?>((ref) async {
  final workspace = await ref.watch(workspaceProvider.future);
  final master = await ref.watch(masterDataProvider.future);
  if (workspace == null || master == null) {
    return null;
  }
  return PosService(local: workspace.local, user: workspace.user, master: master);
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
    ref.read(cartProvider.notifier).clear();
    ref.read(dataVersionProvider.notifier).state++;
    unawaited(ref.read(syncProvider.notifier).refreshPending().then((_) => ref.read(syncProvider.notifier).syncNow()));

    PrintResult? printed;
    if (autoPrint && ref.read(storageProvider).autoPrint) {
      printed = await ref.read(printerProvider.notifier).printSale(sale);
    }
    return CheckoutOutcome(sale, printed);
  }
}

final posActionsProvider = Provider<PosActions>(PosActions.new);
