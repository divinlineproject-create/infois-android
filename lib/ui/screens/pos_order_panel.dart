import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/cart.dart';
import '../../state/pos_state.dart';
import '../../state/printer_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/product_image.dart';
import 'cart_sheet.dart';
import 'customer_picker.dart';
import 'pay_screen.dart' show draftPrintMessage, showProductionResult;
import 'pos_held_orders.dart';
import 'pos_item_sheet.dart';

/// Panel pesanan: baris barang (qty, catatan, geser untuk hapus), jenis
/// pesanan, meja/antrian, pelanggan, catatan pesanan, diskon nota, rincian
/// total, Simpan pesanan, dan Bayar. Dipakai di lembar keranjang (HP) dan
/// panel kanan (tablet/lanskap).
class PosOrderPanel extends ConsumerWidget {
  const PosOrderPanel({super.key, required this.onPay, this.onClose, this.dense = false});

  /// Lanjut ke layar Bayar.
  final VoidCallback onPay;

  /// Tutup lembar keranjang (null di panel tablet).
  final VoidCallback? onClose;

  /// Layar miring yang pendek: judul & tombol lebih rendah.
  final bool dense;

  Future<void> _confirmClear(BuildContext context, WidgetRef ref, Cart cart) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kosongkan pesanan?'),
        content: Text(cart.heldId == null ? 'Semua barang di keranjang dihapus.' : 'Pesanan tersimpan ini juga ikut dihapus.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(key: const Key('clear-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('Kosongkan')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(posActionsProvider).discardCart();
      onClose?.call();
    }
  }

  Future<void> _hold(BuildContext context, WidgetRef ref) async {
    final held = await askHoldName(context, ref);
    // Tanpa snackbar: menutupi bilah keranjang. Badge "Pesanan tersimpan" bertambah.
    if (held && context.mounted) {
      onClose?.call();
    }
  }

  /// Cetak tagihan / list pesanan sebelum dibayar (tidak dicatat).
  Future<void> _printDraft(BuildContext context, WidgetRef ref, {required bool bill, String? title}) async {
    HapticFeedback.selectionClick();
    final actions = ref.read(posActionsProvider);
    if (!bill) {
      final result = await actions.printDraftList(title: title);
      if (context.mounted) {
        showProductionResult(context, ref, result);
      }
      return;
    }
    final result = await actions.printDraftBill(title: title);
    if (context.mounted) {
      showMessage(context, draftPrintMessage(result, 'Tagihan'), error: result != PrintResult.printed);
    }
  }

  /// Meja: pilih dari daftar meja (Pengaturan Kasir web) atau "Tanpa meja";
  /// tanpa daftar = isian bebas.
  Future<void> _editLabel(BuildContext context, WidgetRef ref, Cart cart, List<String> tables) async {
    final Future<String?> asked = tables.isEmpty
        ? askText(
            context,
            title: 'Meja',
            initial: cart.orderLabel,
            hint: 'mis. Meja 5',
            helper: 'Atur daftar meja di web: Pengaturan Kasir.',
            maxLength: 40,
            fieldKey: const Key('order-label-field'),
            suggestions: const ['Meja '],
          )
        : pickTable(context, tables, cart.orderLabel);
    final value = await asked;
    if (value != null) {
      ref.read(cartProvider.notifier).setOrderLabel(value);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final master = ref.watch(masterDataProvider).valueOrNull;
    final inclusive = master?.tenant.pricesIncludeTax ?? false;
    // Fitur rumah makan / kafe (jenis pesanan, meja/antrian); mati untuk toko eceran.
    final dining = master?.tenant.posDining ?? true;
    final tables = master?.tenant.posTables ?? const <String>[];
    final totals = cart.totals(pricesIncludeTax: inclusive);
    final notifier = ref.read(cartProvider.notifier);
    final held = ref.watch(heldOrdersProvider).valueOrNull ?? const [];
    final heldName = cart.heldId == null ? null : held.where((order) => order.id == cart.heldId).firstOrNull?.name;
    final scheme = Theme.of(context).colorScheme;

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.l, Space.xs, Space.s, Space.s),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('Pesanan', style: (dense ? Theme.of(context).textTheme.titleMedium : Theme.of(context).textTheme.titleLarge)?.copyWith(fontWeight: FontWeight.w700)),
                if (dining && cart.queueNumber != null && !cart.isEmpty) ...[
                  const SizedBox(width: Space.s),
                  Flexible(child: Text('Antrian ${cart.queueNumber}', key: const Key('order-queue'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary))),
                ],
              ]),
              if (heldName != null)
                Text('Pesanan tersimpan: $heldName', key: const Key('held-active'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: mutedText(context)))
              else if (!cart.isEmpty)
                Text('${cart.itemCount} barang · ${qty(cart.totalQuantity)} item', style: TextStyle(fontSize: 12.5, color: mutedText(context))),
            ]),
          ),
          HeldOrdersButton(count: held.length),
          if (!cart.isEmpty)
            IconButton(
              key: const Key('clear-cart'),
              tooltip: 'Kosongkan',
              onPressed: () => _confirmClear(context, ref, cart),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ]),
      ),
      Expanded(
        child: cart.isEmpty
            ? const EmptyState(
                icon: Icons.shopping_basket_outlined,
                title: 'Belum ada pesanan',
                message: 'Ketuk barang untuk menambah.',
              )
            : ListView(padding: const EdgeInsets.symmetric(horizontal: Space.l), children: [
                if (dining) ...[
                  _OrderTypeSelector(cart: cart),
                  const SizedBox(height: Space.s),
                ],
                for (final line in cart.lines) _LineRow(line: line, amounts: cart.amountsFor(line, pricesIncludeTax: inclusive), levelId: cart.levelId),
                const SizedBox(height: Space.s),
                _OptionGroup(children: [
                  if (dining)
                    _OptionTile(
                      key: const Key('order-label'),
                      icon: Icons.table_restaurant_outlined,
                      title: cart.orderLabel ?? 'Pilih meja',
                      highlight: cart.orderLabel != null,
                      onTap: () => _editLabel(context, ref, cart, tables),
                    ),
                  _OptionTile(
                    key: const Key('order-customer'),
                    icon: Icons.person_outline,
                    title: cart.customer?.nameWithLevel ?? 'Pelanggan umum',
                    onTap: () async {
                      final customer = await pickCustomer(context, ref);
                      if (customer != null) {
                        notifier.setCustomer(customer.isWalkIn ? null : customer);
                      }
                    },
                  ),
                  // Hanya bila barang dikirim (Pesan antar / ada ongkos kirim).
                  if (cart.needsDelivery(dining: dining))
                    _OptionTile(
                      key: const Key('order-delivery'),
                      icon: Icons.local_shipping_outlined,
                      title: cart.deliveryAddress ?? 'Alamat pengiriman',
                      highlight: cart.deliveryAddress != null,
                      onTap: () async {
                        final value = await askText(
                          context,
                          title: 'Alamat pengiriman',
                          initial: cart.deliveryAddress ?? cleanNote(cart.customer?.address, 500),
                          hint: 'Jalan, nomor, kelurahan, patokan',
                          maxLength: 500,
                          fieldKey: const Key('delivery-address-field'),
                          multiline: true,
                        );
                        if (value != null) {
                          notifier.setDeliveryAddress(value);
                        }
                      },
                    ),
                  _OptionTile(
                    key: const Key('order-note'),
                    icon: Icons.edit_note,
                    title: cart.note ?? 'Catatan pesanan',
                    highlight: cart.note != null,
                    italic: true,
                    onTap: () async {
                      final value = await askText(context, title: 'Catatan pesanan', initial: cart.note, hint: orderNoteHint, maxLength: 500, fieldKey: const Key('order-note-field'));
                      if (value != null) {
                        notifier.setNote(value);
                      }
                    },
                  ),
                  _OptionTile(
                    key: const Key('order-discount'),
                    icon: Icons.local_offer_outlined,
                    title: Money.isPositive(cart.notaDiscountPercent) ? 'Diskon nota ${percentLabel(cart.notaDiscountPercent)}%' : 'Diskon nota',
                    highlight: Money.isPositive(cart.notaDiscountPercent),
                    onTap: () async {
                      final value = await askPercent(context, 'Diskon nota (%)', cart.notaDiscountPercent);
                      if (value != null) {
                        notifier.setNotaDiscount(value);
                      }
                    },
                  ),
                  _OptionTile(
                    key: const Key('order-charges'),
                    icon: Icons.add_circle_outline,
                    title: 'Biaya tambahan',
                    highlight: cart.charges.isNotEmpty,
                    onTap: () async {
                      final charge = await askCharge(context);
                      if (charge != null) {
                        notifier.addCharge(charge.$1, charge.$2);
                      }
                    },
                  ),
                ]),
                if (cart.charges.isNotEmpty) ...[
                  const SizedBox(height: Space.s),
                  for (final charge in cart.charges)
                    Padding(
                      key: Key('charge-${charge.key}'),
                      padding: const EdgeInsets.only(left: Space.m),
                      child: Row(children: [
                        Expanded(child: Text(charge.name, style: const TextStyle(fontWeight: FontWeight.w500))),
                        Text(rupiah(charge.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                        IconButton(
                          key: Key('charge-remove-${charge.key}'),
                          tooltip: 'Hapus ${charge.name}',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => notifier.removeCharge(charge.key),
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ]),
                    ),
                ],
                const SizedBox(height: Space.m),
                // Cetak sebelum dibayar: tagihan (bayar nanti / bon) dan list pesanan.
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('cart-print-bill'),
                      onPressed: () => _printDraft(context, ref, bill: true, title: heldName),
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: const Text('Cetak tagihan'),
                    ),
                  ),
                  const SizedBox(width: Space.s),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('cart-print-list'),
                      onPressed: () => _printDraft(context, ref, bill: false, title: heldName),
                      icon: const Icon(Icons.list_alt_outlined),
                      label: const Text('Cetak list'),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.m),
                Container(
                  key: const Key('order-totals'),
                  padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m),
                  decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(Radii.l)),
                  child: Column(children: [
                    // Subtotal barang saja; biaya tambahan sebaris masing-masing (tidak kena diskon nota).
                    AmountRow('Subtotal (${qty(cart.totalQuantity)} item)', rupiah(Money.sub(totals.subtotal, cart.chargesTotal))),
                    if (Money.isPositive(totals.discountTotal)) AmountRow('Diskon', '-${rupiah(totals.discountTotal)}'),
                    for (final charge in cart.charges) AmountRow(charge.name, rupiah(charge.amount)),
                    if (Money.isPositive(totals.taxTotal)) AmountRow('${master?.tenant.salesTaxName ?? 'PPN'}${inclusive ? ' (termasuk)' : ''}', rupiah(totals.taxTotal)),
                    const Padding(padding: EdgeInsets.symmetric(vertical: Space.s), child: Divider()),
                    AmountRow('Total', rupiah(totals.total), bold: true, large: true),
                  ]),
                ),
                const SizedBox(height: Space.l),
              ]),
      ),
      DecoratedBox(
        decoration: BoxDecoration(color: scheme.surface, border: Border(top: BorderSide(color: scheme.outlineVariant))),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(Space.l, dense ? Space.s : Space.m, Space.l, dense ? Space.s : Space.m),
            child: Row(children: [
              OutlinedButton.icon(
                key: const Key('hold-order'),
                onPressed: cart.isEmpty ? null : () => _hold(context, ref),
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Simpan'),
                style: OutlinedButton.styleFrom(minimumSize: Size(0, dense ? 48 : 56)),
              ),
              const SizedBox(width: Space.m),
              Expanded(
                child: FilledButton(
                  key: const Key('go-pay'),
                  onPressed: cart.isEmpty || !Money.isPositive(totals.total)
                      ? null
                      : () {
                          HapticFeedback.mediumImpact();
                          onPay();
                        },
                  style: FilledButton.styleFrom(minimumSize: Size.fromHeight(dense ? 48 : 56), textStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 17, fontWeight: FontWeight.w700)),
                  child: FittedBox(fit: BoxFit.scaleDown, child: Text('Bayar ${rupiah(totals.total)}')),
                ),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// Contoh isian catatan pesanan (netral, untuk semua jenis usaha).
const orderNoteHint = 'mis. dikirim sore, nota dipisah';

/// Jenis pesanan: tiga tombol sejajar; ketuk yang terpilih lagi = batal pilih.
class _OrderTypeSelector extends ConsumerWidget {
  const _OrderTypeSelector({required this.cart});

  final Cart cart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(cartProvider.notifier);
    return Row(children: [
      for (final (index, type) in OrderType.values.indexed) ...[
        if (index > 0) const SizedBox(width: Space.s),
        Expanded(
          child: Semantics(
            selected: cart.orderType == type,
            button: true,
            child: Material(
              color: cart.orderType == type ? scheme.primary : scheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.m),
                side: BorderSide(color: cart.orderType == type ? scheme.primary : scheme.outline),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: Key('order-type-${type.code}'),
                onTap: () {
                  HapticFeedback.selectionClick();
                  notifier.setOrderType(type);
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: Space.xs),
                      child: Text(
                        type.label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        style: TextStyle(fontSize: 12.5, height: 1.2, fontWeight: FontWeight.w600, color: cart.orderType == type ? scheme.onPrimary : scheme.onSurface),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ]);
  }
}

/// Kelompok pilihan pesanan dalam satu kartu bergaris tipis.
class _OptionGroup extends StatelessWidget {
  const _OptionGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(Radii.l)),
        child: Column(children: [
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const Divider(indent: 52),
            child,
          ],
        ]),
      );
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({super.key, required this.icon, required this.title, required this.onTap, this.highlight = false, this.italic = false});

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool highlight;
  final bool italic;

  @override
  Widget build(BuildContext context) {
    final color = highlight ? (italic ? noteColor(context) : Theme.of(context).colorScheme.primary) : null;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: Space.m, right: Space.s),
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.l)),
      leading: Icon(icon, color: color),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: highlight ? FontWeight.w600 : FontWeight.w500, fontStyle: highlight && italic ? FontStyle.italic : null, fontSize: 14.5)),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// Satu baris pesanan: foto kecil, nama, satuan × harga, diskon, catatan,
/// stepper qty. Geser ke kiri untuk menghapus; ketuk untuk mengubah semua isian.
class _LineRow extends ConsumerWidget {
  const _LineRow({required this.line, required this.amounts, this.levelId});

  final CartLine line;
  final LineAmounts amounts;

  /// Level pelanggan keranjang (keterangan "harga grosir" / "harga Reseller").
  final int? levelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(cartProvider.notifier);
    final discount = amounts.discountPercent;
    final product = line.product;
    final priceLabel = line.priceLabel(levelId);
    return Dismissible(
      key: ValueKey('line-${line.key}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: Space.l),
        decoration: BoxDecoration(color: Brand.danger.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(Radii.m)),
        child: Icon(Icons.delete_outline, color: dangerText(context)),
      ),
      onDismissed: (_) {
        HapticFeedback.lightImpact();
        notifier.remove(line.key);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.s),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.s),
            child: SizedBox(
              width: 44,
              height: 44,
              child: product != null ? ProductImage(product: product, initialsSize: 14) : ProductPlaceholder(name: line.description, fontSize: 14),
            ),
          ),
          const SizedBox(width: Space.m),
          Expanded(
            child: InkWell(
              key: Key('line-tap-${line.key}'),
              borderRadius: BorderRadius.circular(Radii.s),
              onTap: () => showLineEditor(context, ref, line),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(line.description, style: const TextStyle(fontWeight: FontWeight.w600, height: 1.25)),
                Text(
                  '${line.unitLabel} × ${rupiah(line.unitPrice)}${priceLabel != null ? ' · $priceLabel' : ''}${Money.isPositive(discount) ? ' · diskon ${percentLabel(discount)}%' : ''}',
                  key: Key('line-price-${line.key}'),
                  style: TextStyle(fontSize: 12.5, color: mutedText(context)),
                ),
                if (line.note != null) PosNoteText(line.note!),
                const SizedBox(height: 2),
                Text(rupiah(amounts.lineTotal), style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
              ]),
            ),
          ),
          const SizedBox(width: Space.s),
          _Stepper(line: line, onStep: (delta) => notifier.step(line.key, delta), onEdit: () => showLineEditor(context, ref, line)),
        ]),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.line, required this.onStep, required this.onEdit});

  final CartLine line;
  final ValueChanged<int> onStep;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(color: scheme.surfaceContainer, border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(24)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          key: Key('minus-${line.key}'),
          tooltip: 'Kurangi',
          visualDensity: VisualDensity.compact,
          onPressed: () {
            HapticFeedback.selectionClick();
            onStep(-1);
          },
          icon: Icon(Money.compare(line.quantity, '1') <= 0 ? Icons.delete_outline : Icons.remove, size: 20),
        ),
        GestureDetector(
          onTap: onEdit,
          child: SizedBox(width: 32, child: Text(qty(line.quantity), key: Key('qty-${line.key}'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
        ),
        IconButton(
          key: Key('plus-${line.key}'),
          tooltip: 'Tambah',
          visualDensity: VisualDensity.compact,
          color: scheme.primary,
          onPressed: () {
            HapticFeedback.selectionClick();
            onStep(1);
          },
          icon: const Icon(Icons.add, size: 20),
        ),
      ]),
    );
  }
}

/// Dialog "Biaya tambahan": nama (dengan saran) + nominal. Kembalikan
/// (nama, nominal) atau null bila dibatalkan.
Future<(String, String)?> askCharge(BuildContext context) async {
  final name = TextEditingController();
  final amount = TextEditingController();
  String? error;
  final result = await showDialog<(String, String)>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void submit() {
          final value = parseMoneyInput(amount.text);
          if (name.text.trim().isEmpty) {
            setState(() => error = 'Isi nama biaya, mis. Ongkos kirim.');
          } else if (value == null || !Money.isPositive(value)) {
            setState(() => error = 'Isi nominal biaya.');
          } else {
            Navigator.pop(context, (name.text.trim(), value));
          }
        }

        return AlertDialog(
          title: const Text('Biaya tambahan'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                key: const Key('charge-name'),
                controller: name,
                autofocus: true,
                maxLength: 60,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nama biaya', hintText: 'mis. Ongkos kirim', counterText: ''),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final suggestion in CartCharge.suggestions)
                  ActionChip(
                    label: Text(suggestion),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() {
                      name.text = suggestion;
                      error = null;
                    }),
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(
                key: const Key('charge-amount'),
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Nominal', prefixText: 'Rp ', hintText: '0'),
                onSubmitted: (_) => submit(),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, key: const Key('charge-error'), style: TextStyle(color: dangerText(context))),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
            FilledButton(key: const Key('charge-save'), onPressed: submit, child: const Text('Tambah')),
          ],
        );
      },
    ),
  );
  return result;
}

/// Pilih meja dari daftar meja usaha. Kembalikan nama meja, '' untuk
/// "Tanpa meja", atau null bila ditutup.
Future<String?> pickTable(BuildContext context, List<String> tables, String? current) => showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.s),
              child: Text('Meja', style: Theme.of(sheet).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                ListTile(
                  key: const Key('table-none'),
                  leading: Icon(current == null ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  title: const Text('Tanpa meja'),
                  onTap: () => Navigator.pop(sheet, ''),
                ),
                for (final table in tables)
                  ListTile(
                    key: Key('table-$table'),
                    leading: Icon(table == current ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: table == current ? Theme.of(sheet).colorScheme.primary : null),
                    title: Text(table, style: TextStyle(fontWeight: table == current ? FontWeight.w700 : FontWeight.w500)),
                    onTap: () => Navigator.pop(sheet, table),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );

/// Dialog isian teks satu baris. Kembalikan teks (boleh kosong = hapus) atau
/// null bila dibatalkan.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String? initial,
  String? hint,
  int maxLength = 200,
  Key? fieldKey,
  List<String> suggestions = const [],
  bool multiline = false,
  String? helper,
}) async {
  final controller = TextEditingController(text: initial ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          key: fieldKey,
          controller: controller,
          autofocus: true,
          maxLength: maxLength,
          minLines: multiline ? 2 : 1,
          maxLines: multiline ? 4 : 1,
          keyboardType: multiline ? TextInputType.multiline : TextInputType.text,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: hint, counterText: '', helperText: helper, helperMaxLines: 2),
          onSubmitted: multiline ? null : (value) => Navigator.pop(context, value),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            for (final suggestion in suggestions)
              ActionChip(
                label: Text(suggestion.trim()),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  controller.text = suggestion;
                  controller.selection = TextSelection.collapsed(offset: suggestion.length);
                },
              ),
          ]),
        ],
      ]),
      actions: [
        if ((initial ?? '').isNotEmpty) TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Hapus')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(key: const Key('text-save'), onPressed: () => Navigator.pop(context, controller.text), child: const Text('Simpan')),
      ],
    ),
  );
  return result?.trim();
}
