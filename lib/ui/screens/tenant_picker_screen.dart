import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'akun_screen.dart' show logoutWarning;
import 'login_screen.dart' show AccessNoticeCard;

/// Pilih perusahaan (user bisa anggota beberapa perusahaan).
class TenantPickerScreen extends ConsumerStatefulWidget {
  const TenantPickerScreen({super.key});

  @override
  ConsumerState<TenantPickerScreen> createState() => _TenantPickerScreenState();
}

class _TenantPickerScreenState extends ConsumerState<TenantPickerScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(sessionProvider.notifier).refreshMe());
  }

  /// Dialog Keluar sedang disiapkan / tampil: ketukan kedua diabaikan.
  bool _asking = false;

  /// Keluar dari Pilih perusahaan: peringatkan bila masih ada transaksi
  /// belum terkirim atau pesanan tersimpan (belum dibayar) di salah satu
  /// perusahaan (data HP ikut dihapus).
  Future<void> _logout() async {
    if (_asking) {
      return;
    }
    _asking = true;
    bool? ok;
    try {
      final userId = ref.read(sessionProvider).valueOrNull?.user?.id;
      var pending = 0;
      var held = 0;
      if (userId != null) {
        try {
          pending = await SessionController.unsentElsewhere(userId);
        } catch (_) {
          pending = 0;
        }
        try {
          held = await SessionController.heldElsewhere(userId);
        } catch (_) {
          held = 0;
        }
      }
      if (!mounted) {
        return;
      }
      final warn = pending > 0 || held > 0;
      ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('logout-dialog'),
          title: Text(pending > 0 ? 'Transaksi belum terkirim' : (held > 0 ? 'Pesanan tersimpan belum dibayar' : 'Keluar dari aplikasi?')),
          content: Text(warn ? logoutWarning(pending: pending, held: held, fromPicker: true) : 'Data di HP ini akan dihapus.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
            warn
                ? TextButton(key: const Key('logout-anyway'), style: TextButton.styleFrom(foregroundColor: dangerText(context)), onPressed: () => Navigator.pop(context, true), child: const Text('Tetap keluar'))
                : FilledButton(key: const Key('logout-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('Keluar')),
          ],
        ),
      );
    } finally {
      _asking = false;
    }
    if (ok == true && mounted) {
      await ref.read(sessionProvider.notifier).logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).valueOrNull;
    final tenants = session?.tenants ?? const <TenantSummary>[];
    final notice = session?.notice;
    final noticeCard = notice == null ? null : AccessNoticeCard(notice: notice, onClose: () => ref.read(sessionProvider.notifier).clearNotice());
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pilih perusahaan'),
        actions: [
          TextButton(key: const Key('picker-logout'), onPressed: _logout, child: const Text('Keluar')),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(sessionProvider.notifier).refreshMe(),
        child: tenants.isEmpty
            ? ListView(padding: const EdgeInsets.all(16), children: [
                if (noticeCard != null) noticeCard,
                const SizedBox(height: 80),
                const EmptyState(
                  icon: Icons.storefront_outlined,
                  title: 'Belum ada perusahaan',
                  message: 'Aplikasi HP bisa dipakai perusahaan dengan paket berbayar yang aktif. Minta pemilik usaha menambahkan Anda sebagai anggota tim, atau kelola paket lewat website Infois.',
                ),
              ])
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: tenants.length + (noticeCard == null ? 0 : 1),
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  if (noticeCard != null) {
                    if (index == 0) {
                      return noticeCard;
                    }
                    index--;
                  }
                  final tenant = tenants[index];
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
                        child: Text(tenant.name.isEmpty ? '?' : tenant.name[0].toUpperCase(), style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
                      ),
                      title: Text(tenant.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(tenant.active ? (tenant.roleLabel ?? 'Anggota') : 'Langganan tidak aktif · kelola lewat website', style: TextStyle(color: tenant.active ? null : warningText(context))),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        if (!tenant.active) {
                          showMessage(context, 'Langganan ${tenant.name} sedang tidak aktif. Pemilik dapat mengelola paket lewat website Infois.', error: true);
                          return;
                        }
                        ref.read(sessionProvider.notifier).selectTenant(tenant.id);
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }
}
