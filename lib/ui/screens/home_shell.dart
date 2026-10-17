import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'ai_home_screen.dart';
import 'akun_screen.dart';
import 'catatan_screen.dart';
import 'kasir_screen.dart';
import 'laporan_screen.dart';

class _Tab {
  const _Tab(this.key, this.label, this.icon, this.selectedIcon, this.builder);

  final String key;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() builder;
}

/// Navigasi bawah: Kasir · Tim AI · Laporan · Catatan · Akun. Menu tampil
/// sesuai hak akses role di web.
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
    return Scaffold(
      appBar: aiTab
          ? null
          : AppBar(
              titleSpacing: 16,
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tenant?.name ?? 'Infois', overflow: TextOverflow.ellipsis),
                if (master?.deviceCode != null)
                  Text('Kasir ${master!.deviceCode} · ${session?.user?.name ?? ''}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
              ]),
              actions: [
                Padding(padding: const EdgeInsets.only(right: 12), child: SyncStatusBadge(onTap: () => context.push('/sync'))),
              ],
            ),
      body: Column(children: [
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
          child: IndexedStack(index: index, children: [for (final (i, tab) in tabs.indexed) LazyTab(key: ValueKey(tab.key), active: i == index, builder: tab.builder)]),
        )),
      ]),
      bottomNavigationBar: tabs.length < 2
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (value) => setState(() => _selected = tabs[value].key),
              destinations: [for (final tab in tabs) NavigationDestination(icon: Icon(tab.icon), selectedIcon: Icon(tab.selectedIcon), label: tab.label)],
            ),
    );
  }
}

class ComingSoon extends StatelessWidget {
  const ComingSoon({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => EmptyState(icon: Icons.hourglass_empty_rounded, title: '$title · Segera hadir', message: message);
}
