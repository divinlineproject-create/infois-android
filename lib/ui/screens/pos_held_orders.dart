import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../domain/cart.dart';
import '../../services/pos_service.dart';
import '../../state/pos_state.dart';
import '../../state/workspace.dart';
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
  if (ref.read(cartProvider).isEmpty) {
    return false;
  }
  // Nama bawaan = nomor pesanan (rumah makan), jadi pastikan sudah ada.
  await ref.read(posActionsProvider).ensureQueueNumber();
  if (!context.mounted) {
    return false;
  }
  final cart = ref.read(cartProvider);
  final held = ref.read(heldOrdersProvider).valueOrNull ?? const <HeldOrder>[];
  final current = cart.heldId == null ? null : held.where((order) => order.id == cart.heldId).firstOrNull?.name;
  // Nama buatan otomatis ikut meja & pelanggan terbaru; nama ketikan kasir tetap.
  final controller = TextEditingController(text: current != null && !HeldOrderStore.isAutoName(current, cart) ? current : HeldOrderStore.defaultName(cart, DateTime.now()));
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Simpan pesanan'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          key: const Key('hold-name'),
          controller: controller,
          autofocus: true,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Nama pesanan', hintText: 'mis. 000001-Meja 5-Pak Budi', counterText: ''),
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

/// Daftar pesanan tersimpan: lanjutkan (masuk keranjang) atau hapus. Lebih
/// dari 5 pesanan (restoran dengan banyak meja): kotak cari nomor, meja, atau
/// nama pelanggan.
class HeldOrdersSheet extends ConsumerStatefulWidget {
  const HeldOrdersSheet({super.key});

  @override
  ConsumerState<HeldOrdersSheet> createState() => _HeldOrdersSheetState();
}

class _HeldOrdersSheetState extends ConsumerState<HeldOrdersSheet> {
  String _query = '';

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
        content: const Text('Pesanan ini belum dibayar dan akan dihapus.'),
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
  Widget build(BuildContext context) {
    final orders = ref.watch(heldOrdersProvider);
    final activeId = ref.watch(cartProvider.select((cart) => cart.heldId));
    final dining = ref.watch(masterDataProvider).valueOrNull?.tenant.posDining ?? true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('Pesanan tersimpan', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      ),
      if ((orders.valueOrNull?.length ?? 0) > 5)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            key: const Key('held-search'),
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Cari nomor, meja, atau nama', isDense: true),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
      Expanded(
        child: orders.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => EmptyState(icon: Icons.error_outline, title: 'Pesanan tersimpan belum bisa dibuka', message: plainError(error, fallback: 'Coba lagi sebentar lagi.')),
          data: (all) {
            final items = [for (final order in all) if (HeldOrderStore.matches(order, _query)) order];
            return all.isEmpty
              ? EmptyState(
                  icon: Icons.bookmarks_outlined,
                  title: 'Belum ada pesanan tersimpan',
                  message: 'Tekan Simpan di keranjang untuk bayar nanti.',
                )
              : items.isEmpty
              ? const EmptyState(icon: Icons.search_off, title: 'Pesanan tidak ditemukan', message: 'Coba nomor pesanan, nama meja, atau nama pelanggan.')
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final order = items[index];
                    final active = order.id == activeId;
                    final type = dining ? order.cart.orderType : null;
                    final customer = order.cart.customer;
                    final queue = dining ? order.cart.queueNumber : null;
                    // Satu baris: jenis pesanan sudah terlihat dari ikonnya.
                    final details = [
                      if (queue != null && !order.name.startsWith(queue)) 'Antrian $queue',
                      '${order.itemCount} barang',
                      // Pelanggan "{nama} · {level}"; nama pesanan sudah memuat nama pelanggan: levelnya saja.
                      if (customer != null && !customer.isWalkIn && !order.name.contains(customer.name)) customer.nameWithLevel,
                      if (customer != null && order.name.contains(customer.name) && customer.level != null) customer.level!,
                      _time(order.createdAt),
                    ].join(' · ');
                    return ListTile(
                      key: Key('held-${order.id}'),
                      leading: CircleAvatar(
                        backgroundColor: Brand.green.withValues(alpha: 0.12),
                        child: Icon(
                          !dining
                              ? Icons.receipt_long_outlined
                              : (type == OrderType.delivery ? Icons.delivery_dining_outlined : (type == OrderType.takeAway ? Icons.shopping_bag_outlined : Icons.table_restaurant_outlined)),
                          color: Brand.green,
                        ),
                      ),
                      title: Text(order.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(active ? 'Dibuka · $details' : details, key: Key('held-details-${order.id}'), maxLines: 1, overflow: TextOverflow.ellipsis),
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
                );
          },
        ),
      ),
    ]);
  }
}
