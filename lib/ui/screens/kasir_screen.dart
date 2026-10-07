import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../state/pos_state.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'cart_sheet.dart';
import 'shift_screens.dart';

/// Layar kasir: cari & pilih barang, keranjang, lalu bayar.
class KasirScreen extends ConsumerStatefulWidget {
  const KasirScreen({super.key});

  @override
  ConsumerState<KasirScreen> createState() => _KasirScreenState();
}

class _KasirScreenState extends ConsumerState<KasirScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _pickUnit(Product product) async {
    final options = product.unitOptions();
    if (options.length < 2) {
      ref.read(cartProvider.notifier).add(product);
      return;
    }
    final unit = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Pilih satuan ${product.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final option in options)
            ListTile(
              title: Text(option.name),
              subtitle: Money.compare(option.factor, '1') == 0 ? null : Text('Isi ${qty(option.factor)} ${product.unit}'),
              trailing: Text(rupiah(option.price), style: const TextStyle(fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(context, option.name),
            ),
        ]),
      ),
    );
    if (unit != null) {
      ref.read(cartProvider.notifier).add(product, unit: unit);
    }
  }

  @override
  Widget build(BuildContext context) {
    final master = ref.watch(masterDataProvider);
    final products = ref.watch(productSearchProvider(_query));
    final cart = ref.watch(cartProvider);
    final sync = ref.watch(syncProvider);
    final shift = ref.watch(openShiftProvider).valueOrNull;
    final data = master.valueOrNull;
    final inclusive = data?.tenant.pricesIncludeTax ?? false;

    if (data != null && !data.hasData) {
      return EmptyState(
        icon: sync.connection == ConnectionStatus.offline ? Icons.cloud_off_outlined : Icons.downloading_outlined,
        title: sync.connection == ConnectionStatus.offline ? 'Belum ada data barang' : 'Mengunduh data barang…',
        message: sync.connection == ConnectionStatus.offline ? 'Sambungkan internet sekali untuk mengunduh katalog. Setelah itu kasir bisa dipakai offline.' : null,
        action: sync.syncing ? const CircularProgressIndicator() : OutlinedButton(onPressed: () => ref.read(syncProvider.notifier).syncNow(), child: const Text('Coba lagi')),
      );
    }

    return Column(children: [
      if (data?.menus.shift ?? false) ShiftBar(shift: shift),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              key: const Key('kasir-search'),
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Cari barang atau kode',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Hapus',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                        }),
                      ),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(tooltip: 'Riwayat nota', onPressed: () => context.push('/riwayat'), icon: const Icon(Icons.history)),
        ]),
      ),
      Expanded(
        child: products.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => EmptyState(icon: Icons.error_outline, title: 'Katalog belum bisa dibuka', message: '$error'),
          data: (items) => items.isEmpty
              ? EmptyState(icon: Icons.inventory_2_outlined, title: _query.isEmpty ? 'Katalog kosong' : 'Barang tidak ditemukan', message: _query.isEmpty ? 'Tambahkan barang di website (Barang & Gudang › Katalog).' : null)
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, mainAxisExtent: 128, crossAxisSpacing: 10, mainAxisSpacing: 10),
                  itemCount: items.length,
                  itemBuilder: (context, index) => _ProductCard(
                    product: items[index],
                    inCart: cart.lines.where((line) => line.product?.id == items[index].id).fold('0', (sum, line) => Money.add([sum, line.quantity])),
                    onTap: () => ref.read(cartProvider.notifier).add(items[index]),
                    onLongPress: () => _pickUnit(items[index]),
                  ),
                ),
        ),
      ),
      if (!cart.isEmpty) _CartBar(count: cart.itemCount, total: cart.totals(pricesIncludeTax: inclusive).total, onOpen: () => showCartSheet(context)),
    ]);
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, required this.inCart, required this.onTap, required this.onLongPress});

  final Product product;
  final String inCart;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final stock = product.stockQuantity;
    final empty = product.trackInventory && stock != null && !Money.isPositive(stock);
    final stockLabel = product.trackInventory && stock != null
        ? (empty ? 'Stok habis' : 'Stok ${qty(stock)} ${product.unit}')
        : (product.hasComposition ? 'Pakai resep' : null);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('product-${product.id}'),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, height: 1.25))),
              if (Money.isPositive(inCart))
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Brand.green, borderRadius: BorderRadius.circular(12)),
                  child: Text(qty(inCart), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                ),
            ]),
            const Spacer(),
            Text(rupiah(product.price), style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.green, fontSize: 15)),
            if (stockLabel != null)
              Text(stockLabel, style: TextStyle(fontSize: 12, color: empty ? Brand.amber : Colors.grey.shade600)),
            if (product.units.isNotEmpty || product.tiers.isNotEmpty)
              Text(product.tiers.isNotEmpty ? 'Ada harga grosir' : 'Tekan lama: pilih satuan', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ]),
        ),
      ),
    );
  }
}

class _CartBar extends StatelessWidget {
  const _CartBar({required this.count, required this.total, required this.onOpen});

  final int count;
  final String total;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: FilledButton(
            key: const Key('open-cart'),
            onPressed: onOpen,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: Row(children: [
              const Icon(Icons.shopping_basket_outlined),
              const SizedBox(width: 10),
              Expanded(child: Text('$count barang', overflow: TextOverflow.ellipsis)),
              Flexible(
                child: FittedBox(fit: BoxFit.scaleDown, child: Text(rupiah(total), style: const TextStyle(fontWeight: FontWeight.w700))),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        ),
      );
}
