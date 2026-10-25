import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../domain/models.dart';
import '../../state/pos_state.dart';
import '../../state/sync_controller.dart';
import '../../services/permission_gate.dart';
import '../../state/workspace.dart';
import '../focus.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/pos_categories.dart';
import '../widgets/pos_product_tile.dart';
import 'cart_sheet.dart';
import 'pos_held_orders.dart';
import 'pos_item_sheet.dart';
import 'pos_ai_sheet.dart';
import 'pos_order_panel.dart';
import 'scan_screen.dart';
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
  List<Product>? _lastFound;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() => setState(() {
        _search.clear();
        _query = '';
      });

  /// Cari selalu di semua kategori: mulai mengetik = kembali ke "Semua".
  void _onSearch(String value) => setState(() {
        _query = value;
        if (value.trim().isNotEmpty) {
          _category = 'all';
        }
      });

  void _addProduct(Product product) {
    // Barang diketuk: keyboard cari ditutup supaya grid terlihat.
    dismissKeyboard();
    HapticFeedback.selectionClick();
    ref.read(cartProvider.notifier).add(product);
  }

  /// Scanner barcode (Bluetooth/USB) mengetik kode lalu Enter: cocok persis
  /// dengan barcode/SKU → masuk pesanan.
  Future<void> _submitSearch(String value) async {
    final text = value.trim();
    if (text.isEmpty) {
      return;
    }
    final found = await ref.read(posActionsProvider).addByCode(text);
    final product = found.product;
    if (!mounted) {
      return;
    }
    if (found.isInactive) {
      HapticFeedback.heavyImpact();
      showMessage(context, inactiveCodeMessage, error: true);
      return;
    }
    if (product == null) {
      return;
    }
    HapticFeedback.mediumImpact();
    _clearSearch();
    showMessage(context, '${product.name} masuk pesanan.');
  }

  /// Scanner keyboard (Bluetooth/USB) saat kotak cari TIDAK fokus: kode
  /// ditangkap tanpa memunculkan keyboard layar.
  bool _scannerActive() => mounted && TabActive.read(context) && (ModalRoute.of(context)?.isCurrent ?? true);

  Future<void> _onHardwareCode(String code) async {
    final found = await ref.read(posActionsProvider).addByCode(code);
    final product = found.product;
    if (!mounted) {
      return;
    }
    if (product == null) {
      HapticFeedback.heavyImpact();
      showMessage(context, found.isInactive ? inactiveCodeMessage : 'Kode "$code" tidak ada di katalog HP ini.', error: true);
      return;
    }
    HapticFeedback.mediumImpact();
    showMessage(context, '${product.name} masuk pesanan.');
  }

  /// Scan dengan kamera: jelaskan izin kamera dulu (sekali), lalu buka layar scan.
  Future<void> _scanWithCamera() async {
    FocusScope.of(context).unfocus();
    if (!await explainPermission(context, ref, AppPermission.camera) || !mounted) {
      return;
    }
    final outcome = await openScanScreen(context);
    if (!mounted || outcome == null || outcome.added == 0) {
      return;
    }
    showMessage(context, outcome.added == 1 ? '${outcome.last!.name} masuk pesanan.' : '${outcome.added} barang masuk pesanan.');
  }

  /// Input AI (online saja): pesanan diketik/diucapkan/difoto langsung ke keranjang.
  void _openAiInput() {
    dismissKeyboard();
    showPosAiSheet(context);
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
    return HardwareScannerListener(active: _scannerActive, onCode: _onHardwareCode, child: LayoutBuilder(builder: (context, constraints) {
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
      final scheme = Theme.of(context).colorScheme;
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: catalog),
        SizedBox(
          width: panelWidth,
          child: DecoratedBox(
            decoration: BoxDecoration(color: scheme.surface, border: Border(left: BorderSide(color: scheme.outlineVariant))),
            child: Padding(padding: const EdgeInsets.only(top: Space.s), child: PosOrderPanel(key: const Key('order-panel'), onPay: _goPay)),
          ),
        ),
      ]);
    }));
  }

  Widget _toolbar(bool twoPane) {
    final held = ref.watch(heldOrdersProvider).valueOrNull?.length ?? 0;
    final online = ref.watch(syncProvider.select((state) => state.connection == ConnectionStatus.online));
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.s, Space.xs),
      child: Row(children: [
        Expanded(
          child: TextField(
            key: const Key('kasir-search'),
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Cari barang, barcode, SKU',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_query.isNotEmpty) IconButton(tooltip: 'Hapus', icon: const Icon(Icons.close), onPressed: _clearSearch),
                IconButton(
                  key: const Key('scan-button'),
                  tooltip: 'Scan barcode dengan kamera',
                  onPressed: _scanWithCamera,
                  icon: Icon(Icons.qr_code_scanner, color: Theme.of(context).colorScheme.primary),
                ),
                // Input AI butuh internet: tombol disembunyikan saat offline.
                if (online)
                  IconButton(
                    key: const Key('ai-input-button'),
                    tooltip: 'Input AI: ketik, ucapkan, atau foto pesanan',
                    onPressed: _openAiInput,
                    icon: Icon(Icons.auto_awesome, color: Theme.of(context).colorScheme.primary),
                  ),
              ]),
            ),
            onChanged: _onSearch,
            onSubmitted: _submitSearch,
            onTapOutside: (_) => dismissKeyboard(),
          ),
        ),
        if (!twoPane) HeldOrdersButton(count: held),
        IconButton(tooltip: 'Riwayat nota', onPressed: () => context.push('/riwayat'), icon: const Icon(Icons.history)),
      ]),
    );
  }

  Widget _grid(bool twoPane) {
    final all = ref.watch(productSearchProvider('')).valueOrNull ?? const <Product>[];
    final known = ref.watch(productCategoriesProvider).valueOrNull ?? const <ProductCategory>[];
    final products = ref.watch(productSearchProvider(_query));
    final cart = ref.watch(cartProvider);
    final categories = posCategories(all, known);
    final category = categories.firstWhere((item) => item.key == _category, orElse: () => PosCategory.all);

    return Column(children: [
      PosCategoryChips(categories: categories, selected: category.key, onSelected: (key) => setState(() => _category = key)),
      Expanded(child: Builder(builder: (context) {
        // Hasil cari sebelumnya tetap tampil selama hasil baru dimuat (tanpa kedip).
        if (products.hasValue) {
          _lastFound = products.value;
        }
        final found = products.valueOrNull ?? _lastFound;
        if (found == null) {
          return products.hasError
              ? EmptyState(icon: Icons.error_outline, title: 'Katalog belum bisa dibuka', message: plainError(products.error, fallback: 'Tutup lalu buka lagi aplikasinya, atau tekan Sinkron sekarang.'))
              : const PosGridSkeleton();
        }
        final items = found.where(category.matches).toList();
        if (items.isEmpty) {
          final empty = _query.isEmpty && category.key == 'all';
          return EmptyState(
            icon: empty ? Icons.inventory_2_outlined : Icons.search_off,
            title: empty ? 'Katalog kosong' : 'Barang tidak ditemukan',
            message: empty ? 'Tambahkan barang di website (Barang & Gudang › Katalog).' : (_query.isNotEmpty ? 'Coba kata lain, atau scan barcode-nya.' : null),
          );
        }
        return GridView.builder(
          key: const Key('product-grid'),
          padding: EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, twoPane ? Space.l : Space.s),
          gridDelegate: posGridDelegate,
          itemCount: items.length,
          itemBuilder: (context, index) {
            final product = items[index];
            return PosProductTile(
              product: product,
              inCart: cart.quantityOf(product.id),
              onTap: () => _addProduct(product),
              onLongPress: () {
                HapticFeedback.lightImpact();
                showPosItemSheet(context, product);
              },
            );
          },
        );
      })),
    ]);
  }
}

/// Bilah keranjang tetap di bawah (HP): jumlah barang + total, ketuk untuk
/// membuka. Muncul dengan geser halus saat barang pertama masuk.
class _CartBarSlot extends ConsumerWidget {
  const _CartBarSlot({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final Widget bar;
    if (cart.isEmpty) {
      bar = const SizedBox(key: ValueKey('cart-empty'), width: double.infinity);
    } else {
      final scheme = Theme.of(context).colorScheme;
      final inclusive = ref.watch(masterDataProvider).valueOrNull?.tenant.pricesIncludeTax ?? false;
      final total = cart.totals(pricesIncludeTax: inclusive).total;
      final details = [
        if (cart.orderType != null) cart.orderType!.label,
        if (cart.orderLabel != null) cart.orderLabel!,
        if (cart.customer != null) cart.customer!.name,
      ].join(' · ');
      bar = SafeArea(
        key: const ValueKey('cart-bar'),
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, Space.xs, Space.l, Space.m),
          child: FilledButton(
            key: const Key('open-cart'),
            onPressed: () {
              HapticFeedback.selectionClick();
              onOpen();
            },
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64), padding: const EdgeInsets.symmetric(horizontal: Space.l), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.l))),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: scheme.onPrimary.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(Radii.m)),
                alignment: Alignment.center,
                child: Badge(
                  label: Text(qty(cart.totalQuantity)),
                  // Kontras di mode terang & gelap: warna teks tombol di atas warna tombol.
                  backgroundColor: scheme.onPrimary,
                  textColor: scheme.primary,
                  child: const Icon(Icons.shopping_basket_outlined),
                ),
              ),
              const SizedBox(width: Space.m),
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${cart.itemCount} barang', overflow: TextOverflow.ellipsis),
                  Text(details.isEmpty ? 'Lihat pesanan' : details, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
                ]),
              ),
              const SizedBox(width: Space.s),
              Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(rupiah(total), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)))),
              const SizedBox(width: Space.xs),
              const Icon(Icons.keyboard_arrow_up_rounded),
            ]),
          ),
        ),
      );
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: bar,
    );
  }
}
