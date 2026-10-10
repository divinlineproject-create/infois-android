import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/outbox_store.dart';
import '../../services/printing/printer_service.dart';
import '../../state/printer_controller.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'pay_screen.dart';

/// Akun › Printer: pilih printer Bluetooth, lebar kertas, tes cetak.
class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  List<PrinterDevice>? _devices;
  bool _scanning = false;
  late int _width = ref.read(printerProvider).printer?.width ?? ref.read(masterDataProvider).valueOrNull?.receipt.width ?? 58;

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final devices = await ref.read(printerProvider.notifier).scan();
      setState(() => _devices = devices);
    } on PrinterException catch (error) {
      if (mounted) {
        showMessage(context, error.message, error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(printerProvider);
    final autoPrint = ref.watch(storageProvider).autoPrint;
    final statusLabel = switch (state.status) {
      PrinterStatus.connected => 'Tersambung',
      PrinterStatus.connecting => 'Menyambung…',
      PrinterStatus.printing => 'Mencetak…',
      PrinterStatus.disconnected => 'Tidak tersambung',
      PrinterStatus.none => 'Belum dipilih',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Printer struk')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: ListTile(
            leading: Icon(Icons.print, color: state.status == PrinterStatus.connected ? Brand.green : Colors.grey),
            title: Text(state.printer?.name ?? 'Belum ada printer'),
            subtitle: Text(state.message ?? statusLabel),
            trailing: state.printer == null ? null : IconButton(tooltip: 'Sambungkan', onPressed: () => ref.read(printerProvider.notifier).connect(), icon: const Icon(Icons.refresh)),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Lebar kertas', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [ButtonSegment(value: 58, label: Text('58 mm')), ButtonSegment(value: 80, label: Text('80 mm'))],
          selected: {_width},
          onSelectionChanged: (value) {
            setState(() => _width = value.first);
            ref.read(printerProvider.notifier).setWidth(value.first);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Cetak struk otomatis setelah bayar'),
          value: autoPrint,
          onChanged: (value) async {
            await ref.read(storageProvider).setAutoPrint(value);
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: state.printer == null
                  ? null
                  : () async {
                      final result = await ref.read(printerProvider.notifier).testPrint();
                      if (context.mounted) {
                        showMessage(context, result == PrintResult.printed ? 'Tes cetak terkirim ke printer.' : printMessage(result.name), error: result != PrintResult.printed);
                      }
                    },
              icon: const Icon(Icons.receipt_outlined),
              label: const Text('Tes cetak'),
            ),
          ),
          if (state.hasFailedJob) ...[
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(onPressed: () => ref.read(printerProvider.notifier).retryFailed(), child: const Text('Cetak ulang')),
            ),
          ],
        ]),
        const Divider(height: 32),
        Row(children: [
          const Expanded(child: Text('Pilih printer', style: TextStyle(fontWeight: FontWeight.w600))),
          TextButton.icon(onPressed: _scanning ? null : _scan, icon: const Icon(Icons.bluetooth_searching), label: Text(_scanning ? 'Mencari…' : 'Cari printer')),
        ]),
        const Text(
          'Pasangkan printer dulu di Pengaturan › Bluetooth HP (PIN biasanya 0000 atau 1234), lalu tekan Cari printer.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        if (_devices != null && _devices!.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Belum ada printer yang terpasang di HP ini.')),
        for (final device in _devices ?? const <PrinterDevice>[])
          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: Text(device.name.isEmpty ? device.mac : device.name),
            subtitle: Text(device.mac),
            trailing: state.printer?.mac == device.mac ? const Icon(Icons.check_circle, color: Brand.green) : null,
            onTap: () async {
              await ref.read(printerProvider.notifier).choose(device, _width);
              if (context.mounted) {
                showMessage(context, '${device.name} dipilih sebagai printer struk.');
              }
            },
          ),
        if (state.printer != null) ...[
          const SizedBox(height: 16),
          TextButton(onPressed: () => ref.read(printerProvider.notifier).forget(), child: const Text('Lupakan printer ini')),
        ],
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
