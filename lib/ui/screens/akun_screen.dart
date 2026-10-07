import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/format.dart';
import '../../state/printer_controller.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';

/// Akun: profil, ganti perusahaan, printer, status sinkron, keluar.
class AkunScreen extends ConsumerWidget {
  const AkunScreen({super.key});

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final workspace = ref.read(workspaceProvider).valueOrNull;
    final pending = workspace == null ? 0 : await workspace.outbox.pendingCount();
    if (!context.mounted) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keluar dari aplikasi?'),
        content: Text(
          pending > 0
              ? 'Masih ada $pending transaksi yang belum terkirim ke server. Bila keluar sekarang, transaksi itu HILANG dari HP ini. Sambungkan internet dan tunggu sinkron selesai dulu.'
              : 'Data di HP ini akan dihapus. Semua transaksi sudah tersimpan di server.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(
            style: pending > 0 ? FilledButton.styleFrom(backgroundColor: Brand.danger) : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(pending > 0 ? 'Tetap keluar' : 'Keluar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(sessionProvider.notifier).logout();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).valueOrNull;
    final sync = ref.watch(syncProvider);
    final printer = ref.watch(printerProvider);
    final master = ref.watch(masterDataProvider).valueOrNull;
    final user = session?.user;
    final tenant = session?.tenant;

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: CircleAvatar(
            radius: 26,
            backgroundColor: Brand.green.withValues(alpha: 0.12),
            child: Text((user?.name ?? '?').characters.first.toUpperCase(), style: const TextStyle(color: Brand.green, fontWeight: FontWeight.w700, fontSize: 20)),
          ),
          title: Text(user?.name ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('${user?.email ?? ''}\n${tenant?.name ?? ''} · ${tenant?.roleLabel ?? ''}'),
          isThreeLine: true,
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: Column(children: [
          if ((session?.tenants.length ?? 0) > 1)
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('Ganti perusahaan'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => ref.read(sessionProvider.notifier).selectTenant(null),
            ),
          if (master?.menus.printer ?? tenant?.menus.printer ?? false)
            ListTile(
              leading: const Icon(Icons.print_outlined),
              title: const Text('Printer struk'),
              subtitle: Text(printer.printer == null ? 'Belum diatur' : '${printer.printer!.name} · ${printer.printer!.width} mm'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/printer'),
            ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Status sinkron'),
            subtitle: Text(sync.pending > 0
                ? '${sync.pending} transaksi menunggu dikirim'
                : (sync.lastSyncAt != null || master?.lastSyncAt != null ? 'Terakhir ${dateTimeLabel((sync.lastSyncAt ?? master!.lastSyncAt!).toLocal())}' : 'Belum pernah')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sync'),
          ),
          if (master?.menus.pos ?? false)
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Riwayat nota'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/riwayat'),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Text('Kelola paket dan koin lewat website Infois.', style: TextStyle(fontSize: 13)),
      ),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        onPressed: () => _logout(context, ref),
        icon: const Icon(Icons.logout, color: Brand.danger),
        label: const Text('Keluar', style: TextStyle(color: Brand.danger)),
      ),
      const SizedBox(height: 16),
      Center(child: Text('Infois ${AppConfig.version} · Kasir ${master?.deviceCode ?? '-'}', style: TextStyle(fontSize: 12, color: Colors.grey.shade600))),
    ]);
  }
}
