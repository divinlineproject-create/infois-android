import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../domain/cart.dart';
import '../../services/pos_service.dart';
import '../../state/pos_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Tombol "Pesanan tersimpan" dengan jumlah pesanan yang menunggu.
class HeldOrdersButton extends StatelessWidget {
  const HeldOrdersButton({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => IconButton(
        key: const Key('held-orders'),
        tooltip: 'Pesanan tersimpan',
        onPressed: () => showHeldOrders(context),
        icon: Badge(
          isLabelVisible: count > 0,
          label: Text('$count'),
          child: const Icon(Icons.bookmarks_outlined),
        ),
      );
}

/// Simpan keranjang sebagai pesanan tersimpan. Kembalikan true bila tersimpan.
Future<bool> askHoldName(BuildContext context, WidgetRef ref) async {
  final cart = ref.read(cartProvider);
  if (cart.isEmpty) {
    return false;
  }
  final held = ref.read(heldOrdersProvider).valueOrNull ?? const <HeldOrder>[];
  final current = cart.heldId == null ? null : held.where((order) => order.id == cart.heldId).firstOrNull?.name;
  final controller = TextEditingController(text: current ?? HeldOrderStore.defaultName(cart, DateTime.now()));
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Simpan pesanan'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Pesanan disimpan di HP ini dan bisa dilanjutkan atau dibayar nanti.'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('hold-name'),
          controller: controller,
          autofocus: true,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Nama pesanan', hintText: 'mis. Meja 5 atau Pak Budi', counterText: ''),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(key: const Key('hold-save'), onPressed: () => Navigator.pop(context, controller.text), child: const Text('Simpan')),
      ],
    ),
  );
  if (name == null) {
    return false;
  }
  try {
    await ref.read(posActionsProvider).holdCurrent(name: name);
    return true;
  } on Exception catch (error) {
    if (context.mounted) {
      showMessage(context, plainError(error, fallback: 'Pesanan belum tersimpan. Coba lagi.'), error: true);
    }
    return false;
  }
}

Future<void> showHeldOrders(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => const FractionallySizedBox(heightFactor: 0.75, child: HeldOrdersSheet()),
    );

/// Daftar pesanan tersimpan: lanjutkan (masuk keranjang) atau hapus.
class HeldOrdersSheet extends ConsumerWidget {
  const HeldOrdersSheet({super.key});

  String _time(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final hhmm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return local.year == now.year && local.month == now.month && local.day == now.day ? hhmm : '${dateLabel(local)} $hhmm';
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, HeldOrder order) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus "${order.name}"?'),
        content: const Text('Pesanan tersimpan ini dihapus dari HP. Belum ada penjualan yang tercatat.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(key: const Key('held-delete-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(posActionsProvider).deleteHeld(order.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(heldOrdersProvider);
    final activeId = ref.watch(cartProvider.select((cart) => cart.heldId));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('Pesanan tersimpan', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      ),
      Expanded(
        child: orders.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => EmptyState(icon: Icons.error_outline, title: 'Pesanan tersimpan belum bisa dibuka', message: plainError(error, fallback: 'Coba lagi sebentar lagi.')),
          data: (items) => items.isEmpty
              ? const EmptyState(icon: Icons.bookmarks_outlined, title: 'Belum ada pesanan tersimpan', message: 'Tekan "Simpan" di keranjang untuk menyimpan pesanan yang dibayar nanti (mis. open bill per meja).')
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final order = items[index];
                    final active = order.id == activeId;
                    final type = order.cart.orderType;
                    final details = [
                      '${order.itemCount} barang',
                      if (type != null) type.label,
                      if (order.cart.customer != null && order.name != order.cart.customer!.name) order.cart.customer!.name,
                      'disimpan ${_time(order.createdAt)}',
                    ].join(' · ');
                    return ListTile(
                      key: Key('held-${order.id}'),
                      leading: CircleAvatar(
                        backgroundColor: Brand.green.withValues(alpha: 0.12),
                        child: Icon(type == OrderType.delivery ? Icons.delivery_dining_outlined : (type == OrderType.takeAway ? Icons.shopping_bag_outlined : Icons.table_restaurant_outlined), color: Brand.green),
                      ),
                      title: Text(order.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(active ? 'Sedang dibuka di keranjang · $details' : details),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(rupiah(order.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                        IconButton(key: Key('held-delete-${order.id}'), tooltip: 'Hapus', onPressed: () => _delete(context, ref, order), icon: const Icon(Icons.delete_outline)),
                      ]),
                      onTap: () async {
                        final savedCurrent = await ref.read(posActionsProvider).resume(order);
                        if (context.mounted) {
                          Navigator.pop(context);
                          if (savedCurrent) {
                            showMessage(context, 'Keranjang sebelumnya disimpan ke Pesanan tersimpan.');
                          }
                        }
                      },
                    );
                  },
                ),
        ),
      ),
    ]);
  }
}
