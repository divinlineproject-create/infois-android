import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../data/outbox_store.dart';
import '../../services/permission_gate.dart';
import '../../services/printing/printer_service.dart';
import '../../state/pos_state.dart';
import '../../state/printer_controller.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Akun › Pengaturan kasir: pengaturan untuk semua kasir usaha ini (hanya
/// yang boleh mengelola perusahaan, `menus.pos_settings`), lalu printer di
/// perangkat ini (printer Bluetooth, lebar kertas, tes cetak).
class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  bool _scanning = false;
  bool _savingDining = false;

  /// Simpan fitur rumah makan / kafe ke server (online saja). Gagal = nilai
  /// lama tetap, dengan pesan biasa.
  Future<void> _saveDining(bool value) async {
    setState(() => _savingDining = true);
    try {
      final dining = await ref.read(posActionsProvider).saveDining(value);
      if (mounted) {
        showMessage(context, dining ? 'Fitur rumah makan / kafe dinyalakan untuk semua kasir.' : 'Fitur rumah makan / kafe dimatikan untuk semua kasir.');
      }
    } on ApiException catch (error) {
      if (mounted) {
        showMessage(context, error.offline ? 'Butuh internet untuk mengubah pengaturan ini. Sambungkan internet lalu coba lagi.' : error.message, error: true);
      }
    } catch (_) {
      if (mounted) {
        showMessage(context, 'Pengaturan belum tersimpan. Coba lagi.', error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _savingDining = false);
      }
    }
  }

  /// Pilih printer Bluetooth yang sudah dipasangkan untuk [role].
  Future<void> _choose(PrinterRole role) async {
    // Jelaskan dulu kenapa izin Bluetooth (Perangkat sekitar) diminta.
    if (!await explainPermission(context, ref, AppPermission.bluetoothPrinter) || !mounted) {
      return;
    }
    setState(() => _scanning = true);
    List<PrinterDevice> devices;
    try {
      devices = await ref.read(printerProvider.notifier).scan();
    } on PrinterException catch (error) {
      if (mounted) {
        showMessage(context, error.message, error: true);
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
    if (!mounted) {
      return;
    }
    final state = ref.read(printerProvider);
    final current = role == PrinterRole.dapur ? state.kitchen : state.printer;
    final device = await showModalBottomSheet<PrinterDevice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(role == PrinterRole.dapur ? 'Pilih printer dapur' : 'Pilih printer kasir', style: Theme.of(sheet).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Pasangkan printer dulu di Pengaturan › Bluetooth HP (PIN biasanya 0000 atau 1234).', style: TextStyle(fontSize: 13)),
          ),
          if (devices.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Belum ada printer yang terpasang di HP ini.')),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final device in devices)
                ListTile(
                  key: Key('printer-device-${device.mac}'),
                  leading: const Icon(Icons.bluetooth),
                  title: Text(device.name.isEmpty ? device.mac : device.name),
                  subtitle: Text(device.mac),
                  trailing: current?.mac == device.mac ? const Icon(Icons.check_circle, color: Brand.green) : null,
                  onTap: () => Navigator.pop(sheet, device),
                ),
            ]),
          ),
        ]),
      ),
    );
    if (device == null || !mounted) {
      return;
    }
    final width = current?.width ?? ref.read(masterDataProvider).valueOrNull?.receipt.width ?? 58;
    await ref.read(printerProvider.notifier).choose(device, width, role: role);
    if (mounted) {
      showMessage(context, '${device.name} dipilih sebagai ${role == PrinterRole.dapur ? 'printer dapur' : 'printer kasir'}.');
    }
  }

  Future<void> _test(PrinterRole role) async {
    final result = await ref.read(printerProvider.notifier).testPrint(role: role);
    if (!mounted) {
      return;
    }
    final name = role == PrinterRole.dapur ? 'Printer dapur' : 'Printer kasir';
    showMessage(
      context,
      switch (result) {
        PrintResult.printed => 'Tes cetak terkirim ke ${name.toLowerCase()}.',
        PrintResult.noPrinter => '$name belum dipilih.',
        PrintResult.failed => '$name belum tersambung. Pastikan printer menyala dan dekat.',
      },
      error: result != PrintResult.printed,
    );
  }

  static String _statusLabel(PrinterStatus status) => switch (status) {
        PrinterStatus.connected => 'Tersambung',
        PrinterStatus.connecting => 'Menyambung…',
        PrinterStatus.printing => 'Mencetak…',
        PrinterStatus.disconnected => 'Tidak tersambung',
        PrinterStatus.none => 'Belum dipilih',
      };

  /// Satu printer (kasir / dapur): status, lebar kertas, cetak otomatis, tes cetak, pilih / lupakan.
  List<Widget> _section(BuildContext context, PrinterState state, PrinterRole role) {
    final kitchen = role == PrinterRole.dapur;
    final printer = kitchen ? state.kitchen : state.printer;
    final status = kitchen ? state.kitchenStatus : state.status;
    final message = kitchen ? state.kitchenMessage : state.message;
    final storage = ref.watch(storageProvider);
    final width = printer?.width ?? ref.read(masterDataProvider).valueOrNull?.receipt.width ?? 58;
    final key = kitchen ? 'dapur' : 'kasir';
    return [
      Text(kitchen ? 'Printer dapur' : 'Printer kasir', key: Key('printer-title-$key'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      const SizedBox(height: 2),
      Text(
        kitchen ? 'Untuk Cetak list (dapur / bar / gudang). Opsional: tanpa printer dapur, list dicetak di printer kasir.' : 'Untuk struk, tagihan, laporan tutup kasir, dan tes cetak.',
        style: TextStyle(fontSize: 13, color: mutedText(context)),
      ),
      const SizedBox(height: 8),
      Card(
        child: ListTile(
          key: Key('printer-status-$key'),
          leading: Icon(Icons.print, color: status == PrinterStatus.connected ? Brand.green : Colors.grey),
          title: Text(printer?.name ?? (kitchen ? 'Belum ada printer dapur' : 'Belum ada printer')),
          subtitle: Text(message ?? (printer == null && kitchen ? 'List dicetak di printer kasir' : _statusLabel(status))),
          trailing: printer == null ? null : IconButton(tooltip: 'Sambungkan', onPressed: () => ref.read(printerProvider.notifier).connect(role: role), icon: const Icon(Icons.refresh)),
        ),
      ),
      if (printer != null) ...[
        const SizedBox(height: 12),
        const Text('Lebar kertas', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          key: Key('printer-width-$key'),
          segments: const [ButtonSegment(value: 58, label: Text('58 mm')), ButtonSegment(value: 80, label: Text('80 mm'))],
          selected: {width},
          onSelectionChanged: (value) async {
            await ref.read(printerProvider.notifier).setWidth(value.first, role: role);
            setState(() {});
          },
        ),
      ],
      SwitchListTile(
        key: Key('printer-auto-$key'),
        contentPadding: EdgeInsets.zero,
        title: Text(kitchen ? 'Cetak list ke dapur otomatis setelah bayar' : 'Cetak struk otomatis setelah bayar'),
        value: kitchen ? storage.autoPrintKitchen : storage.autoPrint,
        onChanged: (value) async {
          await (kitchen ? storage.setAutoPrintKitchen(value) : storage.setAutoPrint(value));
          setState(() {});
        },
      ),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          key: Key('printer-choose-$key'),
          onPressed: _scanning ? null : () => _choose(role),
          icon: const Icon(Icons.bluetooth_searching),
          label: Text(_scanning ? 'Mencari…' : (printer == null ? 'Pilih printer' : 'Ganti printer')),
        ),
        if (printer != null)
          FilledButton.icon(key: Key('printer-test-$key'), onPressed: () => _test(role), icon: const Icon(Icons.receipt_outlined), label: const Text('Tes cetak')),
        if (!kitchen && state.hasFailedJob) OutlinedButton(onPressed: () => ref.read(printerProvider.notifier).retryFailed(), child: const Text('Cetak ulang')),
        if (printer != null)
          TextButton(key: Key('printer-forget-$key'), onPressed: () => ref.read(printerProvider.notifier).forget(role: role), child: const Text('Lupakan printer ini')),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(printerProvider);
    final master = ref.watch(masterDataProvider).valueOrNull;
    final canManage = master?.menus.posSettings ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan kasir')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (canManage) ...[
          const Text('Untuk semua kasir di usaha ini', key: Key('pos-settings-shared'), style: TextStyle(fontWeight: FontWeight.w600)),
          SwitchListTile(
            key: const Key('pos-settings-dining'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Fitur rumah makan / kafe (jenis pesanan, meja/antrian)'),
            subtitle: _savingDining ? const Text('Menyimpan…') : null,
            value: master!.tenant.posDining,
            onChanged: _savingDining ? null : _saveDining,
          ),
          const Divider(height: 24),
          const Text('Printer di perangkat ini', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
        ],
        ..._section(context, state, PrinterRole.kasir),
        const Divider(height: 32),
        ..._section(context, state, PrinterRole.dapur),
      ]),
    );
  }
}

/// Status sinkron: koneksi, antrean, transaksi yang ditolak/perlu ditinjau.
class SyncStatusScreen extends ConsumerWidget {
  const SyncStatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final problems = ref.watch(outboxProblemsProvider).valueOrNull ?? const <OutboxItem>[];
    final master = ref.watch(masterDataProvider).valueOrNull;
    final lastSync = sync.lastSyncAt ?? master?.lastSyncAt;
    return Scaffold(
      appBar: AppBar(title: const Text('Status sinkron')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Align(alignment: Alignment.centerLeft, child: SyncStatusBadge()),
        const SizedBox(height: 16),
        AmountRow('Menunggu dikirim', '${sync.pending} transaksi', bold: true),
        AmountRow('Terakhir sinkron', lastSync == null ? 'Belum pernah' : dateTimeLabel(lastSync.toLocal())),
        AmountRow('Barang di HP', '${master?.productCount ?? 0}'),
        if (sync.message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(sync.message!, style: const TextStyle(color: Brand.amber))),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: sync.syncing ? null : () => ref.read(syncProvider.notifier).syncNow(),
          icon: const Icon(Icons.sync),
          label: const Text('Sinkron sekarang'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: sync.syncing ? null : () => ref.read(syncProvider.notifier).syncNow(forceFull: true),
          child: const Text('Unduh ulang semua data'),
        ),
        if (problems.isNotEmpty) ...[
          const Divider(height: 32),
          const Text('Perlu perhatian', style: TextStyle(fontWeight: FontWeight.w600)),
          for (final item in problems)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(item.status == OutboxStatus.review ? Icons.visibility_outlined : Icons.block, color: item.status == OutboxStatus.review ? Brand.amber : Brand.danger),
              title: Text('${_typeLabel(item.type)} ${item.data['number'] ?? ''}'),
              subtitle: Text(item.lastError ?? (item.status == OutboxStatus.review ? 'Diterima, menunggu ditinjau pemilik di web.' : 'Ditolak server.')),
              trailing: item.status == OutboxStatus.rejected
                  ? TextButton(
                      onPressed: () async {
                        final workspace = ref.read(workspaceProvider).valueOrNull;
                        if (workspace != null && workspace.usable) {
                          await workspace.outbox.retry(item.clientUuid);
                        }
                        ref.read(dataVersionProvider.notifier).state++;
                        await ref.read(syncProvider.notifier).syncNow();
                      },
                      child: const Text('Kirim ulang'),
                    )
                  : null,
            ),
        ],
      ]),
    );
  }

  static String _typeLabel(String type) => switch (type) {
        'sale' => 'Penjualan',
        'customer' => 'Pelanggan baru',
        'shift_open' => 'Buka kasir',
        'shift_close' => 'Tutup kasir',
        _ => type,
      };
}
