import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../domain/models.dart';
import '../../state/pos_state.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../widgets/common.dart';
import '../widgets/pos_categories.dart';
import '../widgets/pos_product_tile.dart';
import 'cart_sheet.dart';
import 'pos_held_orders.dart';
import 'pos_item_sheet.dart';
import 'pos_order_panel.dart';
import 'shift_screens.dart';

/// Lebar minimal untuk tata letak dua panel (katalog kiri, pesanan kanan).
const double posTwoPaneWidth = 720;

/// Dua panel butuh tinggi juga: HP miring / layar terbelah (mis. 780×360 dp)
/// tetap memakai tata letak HP supaya katalog tidak tergencet.
const double posTwoPaneMinHeight = 480;

bool posUseTwoPane(BoxConstraints constraints) => constraints.maxWidth >= posTwoPaneWidth && constraints.maxHeight >= posTwoPaneMinHeight;

/// Layar kasir (POS): kelompok barang, cari/scan, grid barang, keranjang.
/// HP tegak: grid + bilah keranjang di bawah. Tablet/lanskap: dua panel.
class KasirScreen extends ConsumerStatefulWidget {
  const KasirScreen({super.key});

  @override
  ConsumerState<KasirScreen> createState() => _KasirScreenState();
}

class _KasirScreenState extends ConsumerState<KasirScreen> {
  final _search = TextEditingController();
  String _query = '';
  String _category = 'all';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() => setState(() {
        _search.clear();
        _query = '';
      });

  /// Kode barang (scanner barcode mengetik kode lalu Enter): cocok persis → masuk pesanan.
  Future<bool> _addByCode(String code) async {
    final text = code.trim();
    if (text.isEmpty) {
      return false;
    }
    final workspace = await ref.read(workspaceProvider.future);
    final product = await workspace?.local.productBySku(text);
    if (!mounted) {
      return false;
    }
    if (product == null) {
      return false;
    }
    ref.read(cartProvider.notifier).add(product);
    showMessage(context, '${product.name} masuk pesanan.');
    return true;
  }

  Future<void> _scan() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Scan kode barang'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Arahkan scanner barcode ke barang, atau ketik kode barangnya.'),
          const SizedBox(height: 12),
          TextField(
            key: const Key('scan-code'),
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.qr_code_scanner), hintText: 'Kode barang'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup')),
          FilledButton(key: const Key('scan-add'), onPressed: () => Navigator.pop(context, controller.text), child: const Text('Tambah')),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) {
      return;
    }
    if (!await _addByCode(code) && mounted) {
      showMessage(context, 'Kode "${code.trim()}" tidak ada di katalog HP ini.', error: true);
    }
  }

  Future<void> _submitSearch(String value) async {
    if (await _addByCode(value)) {
      _clearSearch();
    }
  }

  void _openCart() => showCartSheet(context);

  void _goPay() => context.push('/bayar');

  @override
  Widget build(BuildContext context) {
    final master = ref.watch(masterDataProvider);
    final sync = ref.watch(syncProvider);
    final data = master.valueOrNull;

    if (data != null && !data.hasData) {
      final offline = sync.connection == ConnectionStatus.offline;
      final failed = !sync.syncing && sync.message != null;
      return EmptyState(
        icon: offline ? Icons.cloud_off_outlined : (failed ? Icons.error_outline : Icons.downloading_outlined),
        title: offline ? 'Belum ada data barang' : (failed ? 'Data barang belum bisa diunduh' : 'Mengunduh data barang…'),
        message: offline
            ? 'Sambungkan internet sekali untuk mengunduh katalog. Setelah itu kasir bisa dipakai offline.'
            : (failed ? sync.message : null),
        action: sync.syncing ? const CircularProgressIndicator() : OutlinedButton(onPressed: () => ref.read(syncProvider.notifier).syncNow(), child: const Text('Coba lagi')),
      );
    }

    final shift = ref.watch(openShiftProvider).valueOrNull;
    return LayoutBuilder(builder: (context, constraints) {
      final twoPane = posUseTwoPane(constraints);
      final catalog = Column(children: [
        if (data?.menus.shift ?? false) ShiftBar(shift: shift),
        _toolbar(twoPane),
        Expanded(child: _grid(twoPane)),
        if (!twoPane) _CartBarSlot(onOpen: _openCart),
      ]);
      if (!twoPane) {
        return catalog;
      }
      final panelWidth = (constraints.maxWidth * 0.4).clamp(340.0, 440.0);
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: catalog),
        const VerticalDivider(width: 1),
        SizedBox(
          width: panelWidth,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            child: Padding(padding: const EdgeInsets.only(top: 8), child: PosOrderPanel(key: const Key('order-panel'), onPay: _goPay)),
          ),
        ),
      ]);
    });
  }

  Widget _toolbar(bool twoPane) {
    final held = ref.watch(heldOrdersProvider).valueOrNull?.length ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
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
              suffixIcon: _query.isEmpty ? null : IconButton(tooltip: 'Hapus', icon: const Icon(Icons.close), onPressed: _clearSearch),
            ),
            onChanged: (value) => setState(() => _query = value),
            onSubmitted: _submitSearch,
          ),
        ),
        IconButton(key: const Key('scan-button'), tooltip: 'Scan kode barang', onPressed: _scan, icon: const Icon(Icons.qr_code_scanner)),
        if (!twoPane) HeldOrdersButton(count: held),
        IconButton(tooltip: 'Riwayat nota', onPressed: () => context.push('/riwayat'), icon: const Icon(Icons.history)),
      ]),
    );
  }

  Widget _grid(bool twoPane) {
    final all = ref.watch(productSearchProvider('')).valueOrNull ?? const <Product>[];
    final products = ref.watch(productSearchProvider(_query));
    final cart = ref.watch(cartProvider);
    final categories = posCategories(all);
    final category = categories.firstWhere((item) => item.key == _category, orElse: () => PosCategory.all);

    return Column(children: [
      PosCategoryChips(categories: categories, selected: category.key, onSelected: (key) => setState(() => _category = key)),
      Expanded(
        child: products.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => EmptyState(icon: Icons.error_outline, title: 'Katalog belum bisa dibuka', message: plainError(error, fallback: 'Tutup lalu buka lagi aplikasinya, atau tekan Sinkron sekarang.')),
          data: (found) {
            final items = found.where(category.matches).toList();
            if (items.isEmpty) {
              return EmptyState(
                icon: Icons.inventory_2_outlined,
                title: _query.isEmpty && category.key == 'all' ? 'Katalog kosong' : 'Barang tidak ditemukan',
                message: _query.isEmpty && category.key == 'all' ? 'Tambahkan barang di website (Barang & Gudang › Katalog).' : null,
              );
            }
            return GridView.builder(
              padding: EdgeInsets.fromLTRB(16, 8, 16, twoPane ? 16 : 8),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 168, mainAxisExtent: 158, crossAxisSpacing: 10, mainAxisSpacing: 10),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final product = items[index];
                return PosProductTile(
                  product: product,
                  inCart: cart.quantityOf(product.id),
                  onTap: () => ref.read(cartProvider.notifier).add(product),
                  onLongPress: () => showPosItemSheet(context, product),
                );
              },
            );
          },
        ),
      ),
    ]);
  }
}

/// Bilah keranjang tetap di bawah (HP): jumlah barang + total, ketuk untuk membuka.
class _CartBarSlot extends ConsumerWidget {
  const _CartBarSlot({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    if (cart.isEmpty) {
      return const SizedBox.shrink();
    }
    final inclusive = ref.watch(masterDataProvider).valueOrNull?.tenant.pricesIncludeTax ?? false;
    final total = cart.totals(pricesIncludeTax: inclusive).total;
    final details = [
      if (cart.orderType != null) cart.orderType!.label,
      if (cart.orderLabel != null) cart.orderLabel!,
      if (cart.customer != null) cart.customer!.name,
    ].join(' · ');
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: FilledButton(
          key: const Key('open-cart'),
          onPressed: onOpen,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(60), padding: const EdgeInsets.symmetric(horizontal: 16)),
          child: Row(children: [
            Badge(
              label: Text(qty(cart.totalQuantity)),
              // Kontras di mode terang & gelap: warna teks tombol di atas warna tombol.
              backgroundColor: Theme.of(context).colorScheme.onPrimary,
              textColor: Theme.of(context).colorScheme.primary,
              child: const Icon(Icons.shopping_basket_outlined),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${cart.itemCount} barang', overflow: TextOverflow.ellipsis),
                if (details.isNotEmpty) Text(details, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
              ]),
            ),
            Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(rupiah(total), style: const TextStyle(fontWeight: FontWeight.w700)))),
            const Icon(Icons.expand_less),
          ]),
        ),
      ),
    );
  }
}
