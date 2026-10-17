import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/format.dart';
import '../../core/store_policy.dart';
import '../../services/file_downloads.dart';
import '../../services/pos_service.dart';
import '../../state/pos_state.dart';
import '../../state/printer_controller.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';

enum _LogoutChoice { syncFirst, logout }

/// Isi peringatan sebelum keluar: transaksi belum terkirim dan/atau pesanan
/// tersimpan (belum dibayar) yang akan hilang dari HP ini.
String logoutWarning({required int pending, int pendingElsewhere = 0, required int held, int heldElsewhere = 0, bool fromPicker = false}) {
  final parts = <String>[
    if (pending > 0)
      'Ada $pending transaksi belum terkirim ke server. Bila keluar sekarang, transaksi itu HILANG dari HP ini. '
          '${fromPicker ? 'Pilih perusahaannya lalu sinkronkan dulu supaya aman.' : 'Sambungkan internet lalu sinkronkan dulu supaya aman.'}'
          '${!fromPicker && pendingElsewhere > 0 ? ' $pendingElsewhere di antaranya ada di perusahaan lain: pilih perusahaan itu lalu sinkronkan.' : ''}',
    if (held > 0)
      'Ada $held pesanan tersimpan yang belum dibayar. Pesanan tersimpan hanya ada di HP ini dan akan HILANG bila keluar. '
          'Bayar atau catat dulu pesanannya.'
          '${!fromPicker && heldElsewhere > 0 ? ' $heldElsewhere di antaranya ada di perusahaan lain.' : ''}',
  ];
  return parts.join('\n\n');
}

/// Penjelasan "Hapus akun" (wajib Google Play): apa yang dihapus dan yang
/// tetap disimpan, lalu membuka halaman hapus akun di web Infois. Penghapusan
/// sendiri dilakukan di web (konfirmasi kata sandi / kode email).
Future<void> showDeleteAccountSheet(BuildContext context, WidgetRef ref, String url, {int pending = 0}) async {
  final open = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) {
      final muted = mutedText(sheet);
      Widget point(String text) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('•  '),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.4))),
            ]),
          );
      return SafeArea(
        child: SingleChildScrollView(
          key: const Key('delete-account-sheet'),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Hapus akun Infois', style: Theme.of(sheet).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Akun dihapus lewat halaman Hapus akun di web Infois. Masuk dengan akun ini, ketik HAPUS AKUN, lalu konfirmasi dengan kata sandi (akun Google: kode yang dikirim ke email).', style: TextStyle(fontSize: 13.5, height: 1.4)),
            const SizedBox(height: 14),
            const Text('Yang dihapus', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            point('Akun Anda dinonaktifkan dan tidak bisa dipakai masuk lagi, di web maupun di HP. Percakapan Tim AI pribadi, sesi masuk, dan perangkat Anda dihapus.'),
            point('Perusahaan milik Anda (yang Anda pegang sebagai pemilik) ditutup dan seluruh datanya dihapus permanen: transaksi, barang, pelanggan, catatan, foto nota, file, dan percakapan Tim AI.'),
            point('Dari perusahaan tempat Anda hanya anggota, Anda dikeluarkan. Data perusahaan itu tetap milik pemiliknya.'),
            point('Sisa koin Tim AI dan masa aktif perusahaan yang ditutup hangus, tanpa pengembalian dana.'),
            const SizedBox(height: 8),
            const Text('Yang tetap disimpan', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            point('Catatan tagihan dan pembayaran, sesuai kewajiban pajak dan hukum.'),
            point('Nama, email, dan nomor telepon akun dalam keadaan nonaktif, sebagai bagian dari catatan tagihan dan untuk mencegah penyalahgunaan.'),
            if (pending > 0) ...[
              const SizedBox(height: 8),
              Text('Ada $pending transaksi di HP ini yang belum terkirim. Sinkronkan dulu bila masih diperlukan, karena setelah akun dihapus transaksi itu tidak bisa dikirim lagi.',
                  key: const Key('delete-account-pending'), style: TextStyle(fontSize: 13, color: dangerText(sheet))),
            ],
            const SizedBox(height: 8),
            Text('Penghapusan tidak bisa dibatalkan.', style: TextStyle(fontSize: 13, color: muted)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('delete-account-open'),
                style: FilledButton.styleFrom(backgroundColor: dangerText(sheet)),
                onPressed: () => Navigator.pop(sheet, true),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Buka halaman Hapus akun'),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(width: double.infinity, child: TextButton(onPressed: () => Navigator.pop(sheet, false), child: const Text('Batal'))),
          ]),
        ),
      );
    },
  );
  if (open == true && context.mounted) {
    await openExternalLink(context, ref, url);
  }
}

/// Akun: profil, ganti perusahaan, printer, status sinkron, tampilan,
/// Pusat Bantuan, kebijakan privasi, hapus akun, keluar.
class AkunScreen extends ConsumerStatefulWidget {
  const AkunScreen({super.key});

  @override
  ConsumerState<AkunScreen> createState() => _AkunScreenState();
}

class _AkunScreenState extends ConsumerState<AkunScreen> {
  bool _loggingOut = false;

  /// Dialog Keluar sedang disiapkan / tampil: ketukan kedua diabaikan.
  bool _asking = false;

  /// Jumlah transaksi yang belum terkirim. Database yang sedang ditutup /
  /// tertutup tidak boleh membuat tombol Keluar diam: pakai angka terakhir.
  Future<int> _pendingCount() async {
    final fallback = ref.read(syncProvider).pending;
    final workspace = ref.read(workspaceProvider).valueOrNull;
    if (workspace == null || !workspace.usable) {
      return fallback;
    }
    try {
      return await workspace.outbox.pendingCount();
    } catch (_) {
      return fallback;
    }
  }

  /// Jumlah pesanan tersimpan (belum dibayar) di perusahaan ini.
  Future<int> _heldCount() async {
    final fallback = ref.read(heldOrdersProvider).valueOrNull?.length ?? 0;
    final workspace = ref.read(workspaceProvider).valueOrNull;
    if (workspace == null || !workspace.usable) {
      return fallback;
    }
    try {
      return await HeldOrderStore(workspace.local).count();
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _logout() async {
    if (_loggingOut || _asking) {
      return;
    }
    _asking = true;
    final _LogoutChoice? choice;
    try {
      choice = await _askLogout();
    } finally {
      _asking = false;
    }
    if (!mounted || choice == null) {
      return;
    }
    if (choice == _LogoutChoice.syncFirst) {
      await _syncThenAskAgain();
      return;
    }
    setState(() => _loggingOut = true);
    try {
      await ref.read(sessionProvider.notifier).logout();
    } finally {
      if (mounted) {
        setState(() => _loggingOut = false);
      }
    }
  }

  Future<_LogoutChoice?> _askLogout() async {
    final current = await _pendingCount();
    final heldHere = await _heldCount();
    final session = ref.read(sessionProvider).valueOrNull;
    var elsewhere = 0;
    var heldElsewhere = 0;
    if (session?.user != null) {
      try {
        elsewhere = await SessionController.unsentElsewhere(session!.user!.id, exceptTenantId: session.tenantId);
      } catch (_) {
        elsewhere = 0;
      }
      try {
        heldElsewhere = await SessionController.heldElsewhere(session!.user!.id, exceptTenantId: session.tenantId);
      } catch (_) {
        heldElsewhere = 0;
      }
    }
    final pending = current + elsewhere;
    final held = heldHere + heldElsewhere;
    if (!mounted) {
      return null;
    }
    return showDialog<_LogoutChoice>(
      context: context,
      builder: (context) => pending > 0 || held > 0
          ? AlertDialog(
              key: const Key('logout-dialog'),
              title: Text(pending > 0 ? 'Transaksi belum terkirim' : 'Pesanan tersimpan belum dibayar'),
              content: Text(logoutWarning(pending: pending, pendingElsewhere: elsewhere, held: held, heldElsewhere: heldElsewhere)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
                TextButton(
                  key: const Key('logout-anyway'),
                  style: TextButton.styleFrom(foregroundColor: dangerText(context)),
                  onPressed: () => Navigator.pop(context, _LogoutChoice.logout),
                  child: const Text('Tetap keluar'),
                ),
                if (pending > 0)
                  FilledButton(key: const Key('logout-sync-first'), onPressed: () => Navigator.pop(context, _LogoutChoice.syncFirst), child: const Text('Sinkron dulu')),
              ],
            )
          : AlertDialog(
              key: const Key('logout-dialog'),
              title: const Text('Keluar dari aplikasi?'),
              content: const Text('Data di HP ini akan dihapus. Semua transaksi sudah tersimpan di server.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
                FilledButton(key: const Key('logout-confirm'), onPressed: () => Navigator.pop(context, _LogoutChoice.logout), child: const Text('Keluar')),
              ],
            ),
    );
  }

  Future<void> _syncThenAskAgain() async {
    showMessage(context, 'Menyinkronkan transaksi…');
    await ref.read(syncProvider.notifier).syncNow();
    // Sinkron yang sudah berjalan sebelumnya: tunggu sampai selesai.
    for (var i = 0; i < 600 && mounted && ref.read(syncProvider).syncing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (!mounted) {
      return;
    }
    final sync = ref.read(syncProvider);
    final pending = await _pendingCount();
    if (!mounted) {
      return;
    }
    if (pending == 0) {
      showMessage(context, 'Semua transaksi sudah terkirim.');
      await _logout();
      return;
    }
    showMessage(
      context,
      sync.connection == ConnectionStatus.offline ? 'Masih offline: $pending transaksi belum terkirim. Sambungkan internet lalu coba lagi.' : '$pending transaksi belum terkirim. ${sync.message ?? 'Coba lagi sebentar lagi.'}',
      error: true,
    );
  }

  Future<void> _chooseTheme() async {
    final current = ref.read(themeModeProvider);
    final chosen = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Tampilan'),
        children: [
          for (final mode in ThemeMode.values)
            ListTile(
              key: Key('theme-${mode.name}'),
              leading: Icon(mode == current ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: mode == current ? Theme.of(context).colorScheme.primary : null),
              title: Text(themeModeLabel(mode)),
              subtitle: mode == ThemeMode.system ? const Text('Terang atau gelap mengikuti pengaturan HP') : null,
              onTap: () => Navigator.pop(context, mode),
            ),
        ],
      ),
    );
    if (chosen != null) {
      await ref.read(themeModeProvider.notifier).set(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).valueOrNull;
    final sync = ref.watch(syncProvider);
    final printer = ref.watch(printerProvider);
    final master = ref.watch(masterDataProvider).valueOrNull;
    final themeMode = ref.watch(themeModeProvider);
    final user = session?.user;
    final tenant = session?.tenant;

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: CircleAvatar(
            radius: 26,
            backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
            child: Text((user?.name ?? '?').characters.first.toUpperCase(), style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700, fontSize: 20)),
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
          ListTile(
            key: const Key('akun-theme'),
            leading: const Icon(Icons.dark_mode_outlined),
            title: const Text('Tampilan'),
            subtitle: Text(themeModeLabel(themeMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _chooseTheme,
          ),
        ]),
      ),
      const SizedBox(height: 12),
      // Kebijakan Google Play: tidak ada tautan ke web untuk paket/koin. Web
      // hanya disebut sebagai tempat pengaturan lengkap (tanpa tautan).
      Card(
        child: Column(children: [
          ListTile(
            key: const Key('akun-help'),
            leading: const Icon(Icons.help_outline),
            title: const Text('Pusat Bantuan'),
            subtitle: const Text('Panduan memakai Infois, langkah demi langkah'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/bantuan'),
          ),
          ListTile(
            key: const Key('akun-web-info'),
            leading: const Icon(Icons.computer_outlined),
            title: const Text('Infois versi web'),
            subtitle: Text('Laporan lengkap, pengaturan, dan tim ada di ${session == null ? 'dashboard.infois.ai' : Uri.parse(session.serverUrl.trim()).host}.'),
          ),
          ListTile(
            key: const Key('akun-privacy'),
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Kebijakan privasi'),
            trailing: const Icon(Icons.open_in_new, size: 20),
            onTap: () => openExternalLink(context, ref, privacyPolicyUrl),
          ),
          ListTile(
            key: const Key('akun-terms'),
            leading: const Icon(Icons.description_outlined),
            title: const Text('Syarat & ketentuan'),
            trailing: const Icon(Icons.open_in_new, size: 20),
            onTap: () => openExternalLink(context, ref, termsUrl),
          ),
          ListTile(
            key: const Key('akun-delete-account'),
            leading: Icon(Icons.person_remove_outlined, color: dangerText(context)),
            title: Text('Hapus akun', style: TextStyle(color: dangerText(context))),
            subtitle: const Text('Hapus akun Infois dan data Anda'),
            trailing: const Icon(Icons.chevron_right),
            onTap: session == null ? null : () => showDeleteAccountSheet(context, ref, session.webUrl(deleteAccountPath), pending: sync.pending),
          ),
        ]),
      ),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        key: const Key('akun-logout'),
        onPressed: _loggingOut ? null : _logout,
        icon: _loggingOut ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.logout, color: dangerText(context)),
        label: Text(_loggingOut ? 'Keluar…' : 'Keluar', style: TextStyle(color: dangerText(context))),
      ),
      const SizedBox(height: 16),
      Center(child: Text('Infois ${AppConfig.version} · Kasir ${master?.deviceCode ?? '-'}', style: TextStyle(fontSize: 12, color: mutedText(context)))),
    ]);
  }
}
