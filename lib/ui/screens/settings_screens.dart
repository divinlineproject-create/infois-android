import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../data/app_storage.dart';
import '../../data/outbox_store.dart';
import '../../domain/models.dart';
import '../../services/permission_gate.dart';
import '../../services/printing/printer_service.dart';
import '../../state/pos_state.dart';
import '../../state/printer_controller.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Akun › Pengaturan kasir: fitur rumah makan (untuk semua kasir, hanya
/// yang boleh mengelola perusahaan), printer kasir, dan printer produksi
/// (dapur / bar / checker) di perangkat ini, lewat Bluetooth atau Wi-Fi.
class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  bool _savingDining = false;

  /// Simpan fitur rumah makan / kafe ke server (online saja). Gagal = nilai
  /// lama tetap, dengan pesan biasa.
  Future<void> _saveDining(bool value) async {
    setState(() => _savingDining = true);
    try {
      await ref.read(posActionsProvider).saveDining(value);
    } on ApiException catch (error) {
      if (mounted) {
        showMessage(context, error.offline ? 'Butuh internet untuk mengubah ini.' : error.message, error: true);
      }
    } catch (_) {
      if (mounted) {
        showMessage(context, 'Belum tersimpan. Coba lagi.', error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _savingDining = false);
      }
    }
  }

  Future<void> _add({required bool kasir}) async {
    final added = await showModalBottomSheet<List<SavedPrinter>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AddPrinterSheet(multiple: !kasir),
    );
    if (added == null || added.isEmpty || !mounted) {
      return;
    }
    final printers = ref.read(printerProvider.notifier);
    if (kasir) {
      await printers.setKasir(added.first);
      return;
    }
    final existing = ref.read(printerProvider).production.length;
    await printers.addProduction([
      for (final (index, printer) in added.indexed) printer.copyWith(name: added.length == 1 && existing == 0 ? 'Dapur' : 'Printer ${existing + index + 1}'),
    ]);
    // Satu printer baru: langsung beri nama & kategori.
    if (added.length == 1 && mounted) {
      await _edit(ref.read(printerProvider).production.last, kasir: false);
    }
  }

  Future<void> _edit(SavedPrinter printer, {required bool kasir}) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => EditPrinterSheet(printer: printer, kasir: kasir),
      );

  Future<void> _test(SavedPrinter printer) async {
    final result = await ref.read(printerProvider.notifier).testPrint(printer);
    if (mounted) {
      showMessage(context, result == PrintResult.printed ? 'Tes cetak terkirim.' : '${printer.name} belum mencetak. Periksa printer.', error: result != PrintResult.printed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(printerProvider);
    final storage = ref.watch(storageProvider);
    final master = ref.watch(masterDataProvider).valueOrNull;
    final canManage = master?.menus.posSettings ?? false;
    final categories = ref.watch(productCategoriesProvider).valueOrNull ?? const <ProductCategory>[];
    final kasir = state.printer;

    String categoriesLabel(SavedPrinter printer) {
      if (printer.categoryIds.isEmpty) {
        return 'Semua kategori';
      }
      final names = [for (final category in categories) if (printer.categoryIds.contains(category.id)) category.name];
      return names.isEmpty ? '${printer.categoryIds.length} kategori' : names.join(', ');
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan kasir')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        if (canManage)
          SwitchListTile(
            key: const Key('pos-settings-dining'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Fitur rumah makan / kafe'),
            subtitle: Text(_savingDining ? 'Menyimpan…' : 'Meja, jenis pesanan, nomor antrian'),
            value: master!.tenant.posDining,
            onChanged: _savingDining ? null : _saveDining,
          ),
        const _SectionTitle('Printer kasir', key: Key('printer-title-kasir')),
        if (kasir == null)
          _AddButton(buttonKey: const Key('printer-add-kasir'), label: 'Tambah printer kasir', onPressed: () => _add(kasir: true))
        else
          _PrinterTile(
            key: const Key('printer-kasir'),
            printer: kasir,
            status: state.status,
            subtitle: '${kasir.width} mm',
            failed: state.hasFailedJob,
            onTap: () => _edit(kasir, kasir: true),
            onTest: () => _test(kasir),
          ),
        if (state.hasFailedJob)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: () => ref.read(printerProvider.notifier).retryFailed(), icon: const Icon(Icons.replay), label: const Text('Cetak ulang struk')),
          ),
        SwitchListTile(
          key: const Key('printer-auto-kasir'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Cetak struk setelah bayar'),
          value: storage.autoPrint,
          onChanged: (value) async {
            await storage.setAutoPrint(value);
            setState(() {});
          },
        ),
        const _SectionTitle('Printer dapur / bar', key: Key('printer-title-dapur')),
        for (final printer in state.production)
          _PrinterTile(
            key: Key('printer-production-${printer.id}'),
            printer: printer,
            status: state.statusOf(printer),
            subtitle: categoriesLabel(printer),
            failed: state.productionFailed.contains(printer.id),
            onTap: () => _edit(printer, kasir: false),
            onTest: () => _test(printer),
          ),
        _AddButton(buttonKey: const Key('printer-add-production'), label: 'Tambah printer', onPressed: () => _add(kasir: false)),
        SwitchListTile(
          key: const Key('printer-auto-dapur'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Cetak list setelah bayar'),
          subtitle: state.production.isEmpty ? const Text('Tanpa printer dapur: ke printer kasir') : null,
          value: storage.autoPrintKitchen,
          onChanged: (value) async {
            await storage.setAutoPrintKitchen(value);
            setState(() {});
          },
        ),
      ]),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      );
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.buttonKey, required this.label, required this.onPressed});

  final Key buttonKey;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(key: buttonKey, onPressed: onPressed, icon: const Icon(Icons.add), label: Text(label)),
      );
}

/// Satu printer: nama, kategori / cara sambung, status, tes cetak.
class _PrinterTile extends StatelessWidget {
  const _PrinterTile({super.key, required this.printer, required this.status, required this.subtitle, required this.onTap, required this.onTest, this.failed = false});

  final SavedPrinter printer;
  final PrinterStatus status;
  final String subtitle;
  final bool failed;
  final VoidCallback onTap;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final color = failed ? Brand.danger : (status == PrinterStatus.connected ? Brand.green : mutedText(context));
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(printer.isWifi ? Icons.wifi : Icons.bluetooth, color: color),
        title: Text(printer.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(failed ? 'Belum mencetak' : subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: failed ? const TextStyle(color: Brand.danger) : null),
        trailing: status == PrinterStatus.printing || status == PrinterStatus.connecting
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(key: Key('printer-test-${printer.id}'), tooltip: 'Tes cetak', onPressed: onTest, icon: const Icon(Icons.print_outlined)),
      ),
    );
  }
}

/// Tambah printer: Bluetooth (yang sudah dipasangkan di HP) atau Wi-Fi
/// (cari di jaringan, bisa pilih beberapa sekaligus, atau ketik IP).
class AddPrinterSheet extends ConsumerStatefulWidget {
  const AddPrinterSheet({super.key, this.multiple = true});

  /// Printer produksi: boleh beberapa sekaligus. Printer kasir: satu.
  final bool multiple;

  @override
  ConsumerState<AddPrinterSheet> createState() => _AddPrinterSheetState();
}

class _AddPrinterSheetState extends ConsumerState<AddPrinterSheet> {
  PrinterLink _link = PrinterLink.bluetooth;
  List<PrinterDevice>? _devices;
  List<String>? _found;
  String? _error;
  bool _busy = false;
  final Set<String> _selected = {};
  final _ip = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadBluetooth);
  }

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }

  Future<void> _loadBluetooth() async {
    if (!await explainPermission(context, ref, AppPermission.bluetoothPrinter) || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final devices = await ref.read(printerProvider.notifier).scan();
      if (mounted) {
        setState(() => _devices = devices);
      }
    } on PrinterException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _searchWifi() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final found = await ref.read(printerProvider.notifier).discoverWifi();
      if (mounted) {
        setState(() {
          _found = found;
          if (found.isEmpty) {
            _error = 'Tidak ada printer Wi-Fi ditemukan. Pastikan HP dan printer di Wi-Fi yang sama, atau ketik IP-nya.';
          }
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _error = 'Pencarian gagal. Ketik IP printer.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _toggle(String key) => setState(() {
        if (!widget.multiple) {
          _selected
            ..clear()
            ..add(key);
        } else if (!_selected.remove(key)) {
          _selected.add(key);
        }
      });

  void _done() {
    final width = ref.read(masterDataProvider).valueOrNull?.receipt.width ?? 58;
    final printers = <SavedPrinter>[];
    if (_link == PrinterLink.bluetooth) {
      for (final device in _devices ?? const <PrinterDevice>[]) {
        if (_selected.contains(device.mac)) {
          printers.add(SavedPrinter(mac: device.mac, name: device.name.isEmpty ? device.mac : device.name, width: width));
        }
      }
    } else {
      final typed = _ip.text.trim();
      final hosts = {..._selected.where((host) => host.contains('.')), if (_validIp(typed)) typed};
      for (final host in widget.multiple ? hosts : hosts.take(1)) {
        printers.add(SavedPrinter(mac: host, name: 'Printer $host', width: width, link: PrinterLink.wifi));
      }
    }
    Navigator.pop(context, printers);
  }

  static bool _validIp(String value) {
    final parts = value.split('.');
    return parts.length == 4 && parts.every((part) => (int.tryParse(part) ?? -1) >= 0 && (int.tryParse(part) ?? 256) <= 255);
  }

  /// Alamat printer yang sudah diatur di HP ini (tidak ditawarkan lagi).
  Set<String> get _known {
    final state = ref.read(printerProvider);
    return {if (state.printer != null) state.printer!.mac, for (final printer in state.production) printer.mac};
  }

  @override
  Widget build(BuildContext context) {
    final count = _link == PrinterLink.bluetooth ? _selected.where((key) => !key.contains('.') || key.contains(':')).length : _selected.length + (_validIp(_ip.text.trim()) && !_selected.contains(_ip.text.trim()) ? 1 : 0);
    final options = _link == PrinterLink.bluetooth
        ? [for (final device in _devices ?? const <PrinterDevice>[]) (device.mac, device.name.isEmpty ? device.mac : device.name, device.mac)]
        : [
            for (final host in _found ?? const <String>[])
              if (!_known.contains(host)) (host, host, host),
          ];
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Tambah printer', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        SegmentedButton<PrinterLink>(
          key: const Key('printer-link'),
          segments: const [
            ButtonSegment(value: PrinterLink.bluetooth, icon: Icon(Icons.bluetooth), label: Text('Bluetooth')),
            ButtonSegment(value: PrinterLink.wifi, icon: Icon(Icons.wifi), label: Text('Wi-Fi')),
          ],
          selected: {_link},
          onSelectionChanged: (value) => setState(() {
            _link = value.first;
            _selected.clear();
            _error = null;
          }),
        ),
        const SizedBox(height: 8),
        if (_link == PrinterLink.wifi) ...[
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('printer-ip'),
                controller: _ip,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'IP printer', hintText: '192.168.1.50'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(key: const Key('printer-wifi-search'), onPressed: _busy ? null : _searchWifi, icon: const Icon(Icons.search), label: const Text('Cari')),
          ]),
          const SizedBox(height: 8),
        ],
        if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_error!, style: TextStyle(color: warningText(context)))),
        if (_link == PrinterLink.bluetooth && !_busy && _devices != null && _devices!.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Pasangkan printer dulu di Bluetooth HP.')),
        Flexible(
          child: ListView(shrinkWrap: true, children: [
            for (final (key, title, subtitle) in options)
              widget.multiple
                  ? CheckboxListTile(
                      key: Key('printer-option-$key'),
                      contentPadding: EdgeInsets.zero,
                      value: _selected.contains(key),
                      title: Text(title),
                      subtitle: title == subtitle ? null : Text(subtitle),
                      onChanged: (_) => _toggle(key),
                    )
                  : RadioListTile<String>(
                      key: Key('printer-option-$key'),
                      contentPadding: EdgeInsets.zero,
                      value: key,
                      groupValue: _selected.firstOrNull,
                      title: Text(title),
                      subtitle: title == subtitle ? null : Text(subtitle),
                      onChanged: (_) => _toggle(key),
                    ),
          ]),
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('printer-add-done'),
          onPressed: count == 0 ? null : _done,
          child: Text(widget.multiple && count > 1 ? 'Tambah $count printer' : 'Tambah'),
        ),
      ]),
    );
  }
}

/// Ubah printer: nama, kategori (printer produksi), lebar kertas, hapus.
class EditPrinterSheet extends ConsumerStatefulWidget {
  const EditPrinterSheet({super.key, required this.printer, required this.kasir});

  final SavedPrinter printer;
  final bool kasir;

  @override
  ConsumerState<EditPrinterSheet> createState() => _EditPrinterSheetState();
}

class _EditPrinterSheetState extends ConsumerState<EditPrinterSheet> {
  late final _name = TextEditingController(text: widget.printer.name);
  late int _width = widget.printer.width;
  late final Set<int> _categories = {...widget.printer.categoryIds};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  SavedPrinter get _edited => widget.printer.copyWith(
        name: _name.text.trim().isEmpty ? widget.printer.name : _name.text.trim(),
        width: _width,
        categoryIds: _categories.toList()..sort(),
      );

  Future<void> _save() async {
    final printers = ref.read(printerProvider.notifier);
    await (widget.kasir ? printers.setKasir(_edited) : printers.updateProduction(_edited));
    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _remove() async {
    final printers = ref.read(printerProvider.notifier);
    await (widget.kasir ? printers.forgetKasir() : printers.removeProduction(widget.printer.id));
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(productCategoriesProvider).valueOrNull ?? const <ProductCategory>[];
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: const Key('printer-name'),
            controller: _name,
            maxLength: 24,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: 'Nama printer', hintText: widget.kasir ? 'Kasir' : 'mis. Dapur, Bar, Checker', counterText: '', helperText: widget.printer.linkLabel),
          ),
          if (!widget.kasir) ...[
            const SizedBox(height: 16),
            const Text('Kategori yang dicetak', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilterChip(
                key: const Key('printer-category-all'),
                label: const Text('Semua'),
                selected: _categories.isEmpty,
                onSelected: (_) => setState(_categories.clear),
              ),
              for (final category in categories)
                FilterChip(
                  key: Key('printer-category-${category.id}'),
                  label: Text(category.name),
                  selected: _categories.contains(category.id),
                  onSelected: (selected) => setState(() => selected ? _categories.add(category.id) : _categories.remove(category.id)),
                ),
            ]),
          ],
          const SizedBox(height: 16),
          SegmentedButton<int>(
            key: const Key('printer-width'),
            segments: const [ButtonSegment(value: 58, label: Text('58 mm')), ButtonSegment(value: 80, label: Text('80 mm'))],
            selected: {_width},
            onSelectionChanged: (value) => setState(() => _width = value.first),
          ),
          const SizedBox(height: 16),
          Row(children: [
            TextButton(key: const Key('printer-remove'), onPressed: _remove, style: TextButton.styleFrom(foregroundColor: Brand.danger), child: const Text('Hapus')),
            const Spacer(),
            OutlinedButton(
              key: const Key('printer-test'),
              onPressed: () async {
                final result = await ref.read(printerProvider.notifier).testPrint(_edited);
                if (context.mounted) {
                  showMessage(context, result == PrintResult.printed ? 'Tes cetak terkirim.' : 'Belum mencetak. Periksa printer.', error: result != PrintResult.printed);
                }
              },
              child: const Text('Tes cetak'),
            ),
            const SizedBox(width: 8),
            FilledButton(key: const Key('printer-save'), onPressed: _save, child: const Text('Simpan')),
          ]),
        ]),
      ),
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
