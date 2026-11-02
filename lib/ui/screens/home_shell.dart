import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../domain/models.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../focus.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'ai_home_screen.dart';
import 'akun_screen.dart';
import 'catatan_screen.dart';
import 'kasir_screen.dart';
import 'laporan_screen.dart';

/// Layar miring yang cukup lebar: navigasi pindah ke bilah samping kiri.
bool useSideNavigation(Size size) => size.width > size.height && size.width >= 720;

/// Layar miring yang pendek (tablet 7–8" miring, layar terbelah): tata
/// letak padat (bilah atas satu baris, kasir lebih rapat).
bool isShortLandscape(Size size) => size.width > size.height && size.height < 640;

class _Tab {
  const _Tab(this.key, this.label, this.icon, this.selectedIcon, this.builder);

  final String key;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() builder;
}

/// Navigasi: Kasir · Tim AI · Laporan · Catatan · Akun. Menu tampil sesuai
/// hak akses role di web. Tegak: bilah bawah. Miring (tablet kasir): bilah
/// samping kiri dan bilah atas yang pendek, supaya tinggi layar untuk isi.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  String? _selected;
  bool _updateDismissed = false;

  List<_Tab> _tabs(Menus menus) => [
        if (menus.pos) _Tab('kasir', 'Kasir', Icons.point_of_sale_outlined, Icons.point_of_sale, () => const KasirScreen()),
        if (menus.ai) _Tab('ai', 'Tim AI', Icons.auto_awesome_outlined, Icons.auto_awesome, () => const AiHomeScreen()),
        if (menus.reports) _Tab('laporan', 'Laporan', Icons.insights_outlined, Icons.insights, () => const LaporanScreen()),
        if (menus.records) _Tab('catatan', 'Catatan', Icons.receipt_long_outlined, Icons.receipt_long, () => const CatatanScreen()),
        _Tab('akun', 'Akun', Icons.person_outline, Icons.person, () => const AkunScreen()),
      ];

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).valueOrNull;
    final tenant = session?.tenant;
    final master = ref.watch(masterDataProvider).valueOrNull;
    final sync = ref.watch(syncProvider);
    final menus = master?.menus ?? tenant?.menus ?? const Menus();
    final tabs = _tabs(menus);
    final index = tabs.indexWhere((tab) => tab.key == _selected).clamp(0, tabs.length - 1);

    // Tab Tim AI punya bilah atas sendiri (Riwayat · judul · Percakapan baru)
    // seperti aplikasi chat; status sinkron pindah ke laci Riwayat.
    final aiTab = tabs[index].key == 'ai';
    final maintenance = ref.watch(maintenanceProvider);
    final updateBanner = sync.mustUpdate && !_updateDismissed;
    final anyBanner = updateBanner || maintenance != null;
    // Tanpa bilah aplikasi (tab Tim AI) spanduk pertama tidak boleh di bawah status bar.
    final bannerTop = aiTab ? EdgeInsetsDirectional.only(start: 16, top: 24 + MediaQuery.paddingOf(context).top) : null;
    final size = MediaQuery.sizeOf(context);
    final side = tabs.length >= 2 && useSideNavigation(size);
    final short = isShortLandscape(size);
    final cashierLine = master?.deviceCode == null ? null : 'Kasir ${master!.deviceCode} · ${session?.user?.name ?? ''}';
    void select(int value) {
      dismissKeyboard();
      if (value != index) {
        HapticFeedback.selectionClick();
      }
      setState(() => _selected = tabs[value].key);
    }

    return Scaffold(
      appBar: aiTab
          ? null
          : AppBar(
              titleSpacing: 16,
              toolbarHeight: short ? 48 : null,
              title: short
                  // Miring & pendek: satu baris supaya tinggi layar untuk isi.
                  ? Text([tenant?.name ?? AppConfig.name, if (cashierLine != null) cashierLine].join(' · '), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tenant?.name ?? AppConfig.name, overflow: TextOverflow.ellipsis),
                      if (cashierLine != null) Text(cashierLine, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: mutedText(context))),
                    ]),
              actions: [
                if (ref.read(storageProvider).pinLock)
                  IconButton(
                    key: const Key('shell-lock'),
                    tooltip: 'Kunci / ganti pengguna',
                    icon: const Icon(Icons.lock_outline),
                    onPressed: () => ref.read(sessionProvider.notifier).lock(),
                  ),
                Padding(padding: const EdgeInsets.only(right: 12), child: SyncStatusBadge(onTap: () => context.push('/sync'))),
              ],
            ),
      body: _WithSideNavigation(
        tabs: side ? tabs : null,
        index: index,
        onSelected: select,
        child: Column(children: [
          if (updateBanner)
            MaterialBanner(
              padding: bannerTop,
              content: const Text('Versi aplikasi ini sudah lama. Perbarui aplikasi Infois supaya data tetap tersimpan dengan benar.'),
              actions: [TextButton(onPressed: () => setState(() => _updateDismissed = true), child: const Text('Nanti'))],
            ),
          // Aplikasi HP dimatikan sementara oleh admin Infois (503
          // kanal_pemeliharaan): tetap masuk, transaksi tetap di antrean HP.
          if (maintenance != null)
            Material(
              key: const Key('maintenance-banner'),
              color: warningText(context).withValues(alpha: 0.1),
              child: SafeArea(
                top: aiTab && !updateBanner,
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.construction_rounded, size: 20, color: warningText(context)),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Aplikasi sedang pemeliharaan', style: TextStyle(fontWeight: FontWeight.w700))),
                      TextButton(
                        key: const Key('maintenance-retry'),
                        onPressed: sync.syncing ? null : () => ref.read(syncProvider.notifier).syncNow(),
                        child: const Text('Coba lagi'),
                      ),
                    ]),
                    Text(maintenance, key: const Key('maintenance-message'), maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.35)),
                    if (sync.pending > 0) ...[
                      const SizedBox(height: 4),
                      Text('${sync.pending} transaksi aman tersimpan di HP dan terkirim otomatis setelah selesai.', key: const Key('maintenance-pending'), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ],
                  ]),
                ),
              ),
            ),
          // Laporan & Catatan baru memanggil server saat tab-nya pertama dibuka.
          Expanded(child: MediaQuery(
            // Spanduk sudah memakai ruang status bar. Keyboard sudah dikurangi
            // Scaffold ini dari tinggi isi tab: Scaffold di dalam tab (Tim AI,
            // Laporan, Catatan) tidak boleh menguranginya sekali lagi.
            data: MediaQuery.of(context).removePadding(removeTop: aiTab && anyBanner).removeViewInsets(removeBottom: true),
            // Tab tersembunyi tetap hidup tetapi tidak boleh memegang fokus:
            // isian di tab lain (mis. kotak tulis Tim AI) tidak memunculkan
            // keyboard di atas tab yang sedang dibuka.
            child: IndexedStack(index: index, children: [
              for (final (i, tab) in tabs.indexed)
                ExcludeFocus(
                  excluding: i != index,
                  child: TabActive(active: i == index, child: LazyTab(key: ValueKey(tab.key), active: i == index, builder: tab.builder)),
                ),
            ]),
          )),
        ]),
      ),
      bottomNavigationBar: tabs.length < 2 || side
          ? null
          : DecoratedBox(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
              child: NavigationBar(
                selectedIndex: index,
                onDestinationSelected: select,
                destinations: [for (final tab in tabs) NavigationDestination(key: Key('nav-${tab.key}'), icon: Icon(tab.icon), selectedIcon: Icon(tab.selectedIcon), label: tab.label)],
              ),
            ),
    );
  }
}

/// Isi tab dengan bilah navigasi samping di kiri (layar miring), atau isi
/// saja bila [tabs] null (navigasi di bawah).
class _WithSideNavigation extends StatelessWidget {
  const _WithSideNavigation({required this.tabs, required this.index, required this.onSelected, required this.child});

  final List<_Tab>? tabs;
  final int index;
  final ValueChanged<int> onSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tabs = this.tabs;
    if (tabs == null) {
      return child;
    }
    final scheme = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DecoratedBox(
        key: const Key('side-navigation'),
        decoration: BoxDecoration(color: scheme.surface, border: Border(right: BorderSide(color: scheme.outlineVariant))),
        child: SafeArea(
          right: false,
          top: false,
          child: SizedBox(
            width: 84,
            // Layar sangat pendek: daftar menu bisa digulir, tidak meluap.
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                for (final (i, tab) in tabs.indexed)
                  Semantics(
                    selected: i == index,
                    button: true,
                    label: tab.label,
                    excludeSemantics: true,
                    child: InkWell(
                      key: Key('nav-${tab.key}'),
                      onTap: () => onSelected(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 56,
                            height: 32,
                            decoration: BoxDecoration(color: i == index ? scheme.secondaryContainer : Colors.transparent, borderRadius: BorderRadius.circular(16)),
                            child: Icon(i == index ? tab.selectedIcon : tab.icon, color: i == index ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tab.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontWeight: i == index ? FontWeight.w700 : FontWeight.w500, color: i == index ? scheme.onSurface : scheme.onSurfaceVariant),
                          ),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
      Expanded(child: child),
    ]);
  }
}

class ComingSoon extends StatelessWidget {
  const ComingSoon({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => EmptyState(icon: Icons.hourglass_empty_rounded, title: '$title · Segera hadir', message: message);
}
