import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../widgets/common.dart';
import 'ai_home_screen.dart';
import 'akun_screen.dart';
import 'kasir_screen.dart';

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
        if (menus.reports)
          _Tab('laporan', 'Laporan', Icons.insights_outlined, Icons.insights, () => const ComingSoon(title: 'Laporan', message: 'Ringkasan omzet, barang terlaris, dan laporan per kasir segera hadir.')),
        if (menus.records)
          _Tab('catatan', 'Catatan', Icons.receipt_long_outlined, Icons.receipt_long, () => const ComingSoon(title: 'Catatan', message: 'Daftar penjualan, pembayaran, stok, dan piutang segera hadir. Riwayat nota kasir ada di menu Kasir.')),
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

    return Scaffold(
      appBar: AppBar(
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
        if (sync.mustUpdate && !_updateDismissed)
          MaterialBanner(
            content: const Text('Versi aplikasi ini sudah lama. Perbarui aplikasi Infois supaya data tetap tersimpan dengan benar.'),
            actions: [TextButton(onPressed: () => setState(() => _updateDismissed = true), child: const Text('Nanti'))],
          ),
        Expanded(child: IndexedStack(index: index, children: [for (final tab in tabs) tab.builder()])),
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
