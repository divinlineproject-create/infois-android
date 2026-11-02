import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../data/api_client.dart';
import '../../data/ops_api.dart';
import '../../domain/models.dart';
import '../../state/ops_state.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/form_fields.dart';
import '../widgets/report_widgets.dart';
import 'catatan_screen.dart' show StatusPill, statusColor;

/// Menu "Catat": operasional harian sesuai hak akses (sama dengan web).
Future<void> showOperationsSheet(BuildContext context, WidgetRef ref) async {
  final options = await ref.read(opsOptionsProvider.future).catchError((Object _) => const OpsOptions());
  if (!context.mounted) {
    return;
  }
  final items = <(String, String, IconData, String)>[
    if (options.allows('expense_paid') || options.allows('expense_unpaid')) ('ops-expense', 'Catat biaya', Icons.receipt_outlined, '/ops/biaya/baru'),
    if (options.allows('bill')) ('ops-bill', 'Tagihan pemasok (beli barang)', Icons.inventory_outlined, '/ops/tagihan/baru'),
    if (options.allows('cash')) ('ops-cash-in', 'Uang masuk', Icons.south_west, '/ops/kas/baru/in'),
    if (options.allows('cash')) ('ops-cash-out', 'Uang keluar', Icons.north_east, '/ops/kas/baru/out'),
    if (options.allows('cash')) ('ops-transfer', 'Pindah uang antar rekening', Icons.swap_horiz, '/ops/kas/baru/transfer'),
  ];
  final lists = <(String, String, IconData, String)>[
    if (options.allows('expense_paid') || options.allows('expense_unpaid')) ('ops-list-expense', 'Daftar biaya', Icons.list_alt, '/ops/biaya'),
    if (options.allows('cash')) ('ops-list-cash', 'Daftar Kas & Bank', Icons.account_balance_wallet_outlined, '/ops/kas'),
  ];
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Catat transaksi', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
          if (items.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('Anda belum punya hak mencatat transaksi. Minta pemilik usaha memberi akses.')),
          for (final (key, label, icon, path) in items)
            ListTile(
              key: Key(key),
              leading: Icon(icon),
              title: Text(label),
              onTap: () {
                Navigator.pop(sheet);
                context.push(path);
              },
            ),
          if (lists.isNotEmpty) const Divider(),
          for (final (key, label, icon, path) in lists)
            ListTile(
              key: Key(key),
              leading: Icon(icon),
              title: Text(label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(sheet);
                context.push(path);
              },
            ),
        ]),
      ),
    ),
  );
}

/// Pesan galat untuk pengguna (ApiException sudah berbahasa Indonesia).
String _errorText(Object error) => error is ApiException ? error.message : plainError(error);

/// Kotak peringatan "terkunci" (cut off, sudah dibayar, disetujui, ...).
class LockedNotice extends StatelessWidget {
  const LockedNotice(this.reason, {super.key});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final color = warningText(context);
    return Container(
      key: const Key('ops-locked'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lock_outline, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(reason, style: const TextStyle(fontSize: 13.5, height: 1.35))),
      ]),
    );
  }
}

Future<bool> confirmOpsDelete(BuildContext context, String what) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Hapus $what?'),
        content: const Text('Jurnalnya ikut dihapus (salinannya tetap ada di Jurnal terhapus di website) dan stok/saldo kembali seperti sebelum transaksi ini. Tidak bisa dikembalikan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Batal')),
          FilledButton(key: const Key('ops-delete-confirm'), style: FilledButton.styleFrom(backgroundColor: dangerText(dialog)), onPressed: () => Navigator.pop(dialog, true), child: const Text('Hapus')),
        ],
      ),
    ) ==
    true;

// ───────────────────────────────────────────────────────────────── Biaya

class _ExpenseLine {
  _ExpenseLine({this.accountId, String? description, String? quantity, String? price})
      : description = TextEditingController(text: description ?? ''),
        quantity = TextEditingController(text: quantity ?? '1'),
        price = TextEditingController(text: price ?? '');

  int? accountId;
  final TextEditingController description;
  final TextEditingController quantity;
  final TextEditingController price;

  String get qty => Money.normalize(quantity.text.replaceAll(',', '.'), 6);
  String get amount => Money.mul(qty, rupiahDigits(price.text));

  void dispose() {
    description.dispose();
    quantity.dispose();
    price.dispose();
  }
}

/// Catat / ubah biaya: sudah dibayar (Kas/Bank Keluar) atau belum dibayar
/// (tagihan pemasok). Biaya yang sudah dicatat diubah dengan nomor tetap.
class ExpenseFormScreen extends ConsumerStatefulWidget {
  const ExpenseFormScreen({super.key, this.source, this.id});

  final String? source;
  final int? id;

  @override
  ConsumerState<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends ConsumerState<ExpenseFormScreen> {
  final _form = GlobalKey<FormState>();
  String _mode = 'paid';
  DateTime _date = DateTime.now();
  DateTime? _dueDate;
  int? _accountId;
  int? _supplierId;
  final _contact = TextEditingController();
  final _notes = TextEditingController();
  final _taxRate = TextEditingController();
  bool _hasTax = false;
  final List<_ExpenseLine> _lines = [_ExpenseLine()];
  OpsDocument? _document;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.id != null;

  @override
  void initState() {
    super.initState();
    if (_editing) {
      _load();
    }
  }

  @override
  void dispose() {
    _contact.dispose();
    _notes.dispose();
    _taxRate.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final result = await ref.read(opsApiProvider)!.expense(widget.source!, widget.id!);
      if (!mounted) {
        return;
      }
      if (result.redirectBillId != null) {
        context.pushReplacement('/ops/tagihan/${result.redirectBillId}');
        return;
      }
      final document = result.expense!;
      final form = document.form;
      setState(() {
        _document = document;
        _mode = form['mode']?.toString() ?? 'paid';
        _date = DateTime.tryParse(form['date']?.toString() ?? '') ?? DateTime.now();
        _dueDate = DateTime.tryParse(form['due_date']?.toString() ?? '');
        _accountId = (form['account_id'] as num?)?.toInt();
        _supplierId = (form['supplier_id'] as num?)?.toInt();
        _contact.text = form['contact_name']?.toString() ?? '';
        _notes.text = form['description']?.toString() ?? '';
        _hasTax = form['has_tax'] == true;
        _taxRate.text = form['tax_rate'] == null ? '' : Money.normalize(form['tax_rate']).replaceAll('.00', '');
        for (final line in _lines) {
          line.dispose();
        }
        _lines
          ..clear()
          ..addAll([
            for (final line in form['lines'] as List? ?? const [])
              if (line is Map)
                _ExpenseLine(
                  accountId: (line['account_id'] as num?)?.toInt(),
                  description: line['description']?.toString(),
                  quantity: qty(line['quantity']),
                  price: rupiahText(line['unit_price']),
                ),
          ]);
        if (_lines.isEmpty) {
          _lines.add(_ExpenseLine());
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String get _total => Money.add([for (final line in _lines) line.amount]);

  Future<void> _save() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    if (_lines.any((line) => line.accountId == null)) {
      setState(() => _error = 'Pilih jenis biaya di setiap baris.');
      return;
    }
    if (_mode == 'paid' && _accountId == null) {
      setState(() => _error = 'Pilih dibayar dari kas/bank mana.');
      return;
    }
    if (_mode == 'unpaid' && _supplierId == null) {
      setState(() => _error = 'Pilih pemasok/penerima yang akan dibayar nanti.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final data = {
      'mode': _mode,
      'date': isoDate(_date),
      'lines': [
        for (final line in _lines)
          {
            'account_id': line.accountId,
            if (line.description.text.trim().isNotEmpty) 'description': line.description.text.trim(),
            'quantity': line.qty,
            'unit_price': rupiahDigits(line.price.text),
            'amount': line.amount,
          },
      ],
      if (_mode == 'paid') 'account_id': _accountId,
      if (_mode == 'paid' && _contact.text.trim().isNotEmpty) 'contact_name': _contact.text.trim(),
      if (_mode == 'unpaid') 'supplier_id': _supplierId,
      if (_mode == 'unpaid' && _dueDate != null) 'due_date': isoDate(_dueDate!),
      if (_notes.text.trim().isNotEmpty) 'description': _notes.text.trim(),
      'has_tax': _hasTax,
      if (_hasTax) 'tax_rate': _taxRate.text.replaceAll(',', '.'),
    };
    try {
      final result = await ref.read(opsApiProvider)!.saveExpense(data, source: widget.source, id: widget.id);
      refreshAfterOps(ref);
      if (mounted) {
        showMessage(context, result.message ?? 'Biaya tersimpan.');
        context.pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _delete() async {
    if (!await confirmOpsDelete(context, 'biaya ${_document?.number ?? ''}')) {
      return;
    }
    try {
      await ref.read(opsApiProvider)!.deleteExpense(widget.source!, widget.id!);
      refreshAfterOps(ref);
      if (mounted) {
        showMessage(context, 'Biaya dihapus.');
        context.pop(true);
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, _errorText(error), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(opsOptionsProvider);
    final locked = _document?.lockedReason;
    final readOnly = _editing && _document != null && !_document!.canEdit;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Ubah biaya ${_document?.number ?? ''}' : 'Catat biaya'),
        actions: [
          if (_document?.canDelete ?? false) IconButton(key: const Key('ops-delete'), tooltip: 'Hapus', icon: Icon(Icons.delete_outline, color: dangerText(context)), onPressed: _delete),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : options.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text(_errorText(error))),
              data: (options) => Form(
                key: _form,
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  if (locked != null) LockedNotice(locked),
                  SegmentedButton<String>(
                    segments: [
                      if (options.allows('expense_paid') || _mode == 'paid') const ButtonSegment(value: 'paid', label: Text('Sudah dibayar'), icon: Icon(Icons.check_circle_outline)),
                      if (options.allows('expense_unpaid') || _mode == 'unpaid') const ButtonSegment(value: 'unpaid', label: Text('Bayar nanti'), icon: Icon(Icons.schedule)),
                    ],
                    selected: {_mode},
                    onSelectionChanged: _editing ? null : (value) => setState(() => _mode = value.first),
                  ),
                  if (_editing) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Sudah/belum dibayar tidak bisa diganti saat mengubah.', style: TextStyle(fontSize: 12, color: mutedText(context)))),
                  const SizedBox(height: 16),
                  DateField(label: 'Tanggal', value: _date, onChanged: (value) => setState(() => _date = value)),
                  const SizedBox(height: 16),
                  for (final (i, line) in _lines.indexed) _lineCard(context, options, i, line),
                  TextButton.icon(onPressed: () => setState(() => _lines.add(_ExpenseLine())), icon: const Icon(Icons.add), label: const Text('Tambah baris biaya')),
                  const SizedBox(height: 8),
                  if (_mode == 'paid') ...[
                    ChoiceField(key: const Key('ops-paid-from'), label: 'Dibayar dari', icon: Icons.account_balance_wallet_outlined, choices: options.cashAccounts, value: _accountId, onChanged: (choice) => setState(() => _accountId = choice?.id)),
                    const SizedBox(height: 12),
                    TextFormField(controller: _contact, decoration: const InputDecoration(labelText: 'Dibayar ke (opsional)', prefixIcon: Icon(Icons.storefront_outlined))),
                  ] else ...[
                    ChoiceField(key: const Key('ops-supplier'), label: 'Pemasok / penerima', icon: Icons.local_shipping_outlined, choices: options.suppliers, value: _supplierId, onChanged: (choice) => setState(() => _supplierId = choice?.id)),
                    const SizedBox(height: 12),
                    DateField(label: 'Jatuh tempo', value: _dueDate ?? _date.add(const Duration(days: 30)), onChanged: (value) => setState(() => _dueDate = value)),
                  ],
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Ada ${options.taxName} Masukan'),
                    value: _hasTax,
                    onChanged: (value) => setState(() {
                      _hasTax = value;
                      if (value && _taxRate.text.isEmpty) {
                        _taxRate.text = Money.normalize(options.taxRate).replaceAll('.00', '');
                      }
                    }),
                  ),
                  if (_hasTax) TextFormField(controller: _taxRate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Tarif ${options.taxName} (%)')),
                  const SizedBox(height: 12),
                  TextFormField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Keterangan (opsional)')),
                  const SizedBox(height: 16),
                  AmountRow('Total', rupiah(_total), bold: true, large: true),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, key: const Key('ops-error'), style: TextStyle(color: dangerText(context), fontWeight: FontWeight.w500))),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('ops-save'),
                    onPressed: _saving || readOnly ? null : _save,
                    child: _saving ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : Text(_editing ? 'Simpan perubahan' : 'Simpan biaya'),
                  ),
                ]),
              ),
            ),
    );
  }

  Widget _lineCard(BuildContext context, OpsOptions options, int index, _ExpenseLine line) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              Expanded(
                child: ChoiceField(
                  key: Key('ops-category-$index'),
                  label: 'Jenis biaya',
                  icon: Icons.category_outlined,
                  choices: options.expenseCategories,
                  value: line.accountId,
                  onChanged: (choice) => setState(() => line.accountId = choice?.id),
                ),
              ),
              if (_lines.length > 1)
                IconButton(
                  tooltip: 'Hapus baris',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _lines.removeAt(index).dispose();
                  }),
                ),
            ]),
            const SizedBox(height: 10),
            TextFormField(controller: line.description, decoration: const InputDecoration(labelText: 'Keterangan (mis. token listrik)')),
            const SizedBox(height: 10),
            Row(children: [
              SizedBox(
                width: 90,
                child: TextFormField(
                  controller: line.quantity,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Qty'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: RupiahField(
                  key: Key('ops-price-$index'),
                  controller: line.price,
                  label: 'Harga satuan',
                  onChanged: (_) => setState(() {}),
                  validator: (value) => Money.isPositive(rupiahDigits(value ?? '')) ? null : 'Isi jumlahnya.',
                ),
              ),
            ]),
          ]),
        ),
      );
}

// ──────────────────────────────────────────────────────── Tagihan pemasok

class _BillLine {
  _BillLine({this.productId, this.accountId, String? description, String? quantity, String? price, this.unit, this.unitFactor = '1'})
      : description = TextEditingController(text: description ?? ''),
        quantity = TextEditingController(text: quantity ?? '1'),
        price = TextEditingController(text: price ?? '');

  int? productId;
  int? accountId;
  String? unit;
  String unitFactor;
  final TextEditingController description;
  final TextEditingController quantity;
  final TextEditingController price;

  bool get isProduct => productId != null;
  String get qty => Money.normalize(quantity.text.replaceAll(',', '.'), 6);
  String get amount => Money.mul(qty, rupiahDigits(price.text));

  void dispose() {
    description.dispose();
    quantity.dispose();
    price.dispose();
  }
}

/// Catat / ubah tagihan pemasok: barang stok (masuk Persediaan) dan biaya
/// lain (ongkos kirim, dll.); bisa langsung dibayar.
class BillFormScreen extends ConsumerStatefulWidget {
  const BillFormScreen({super.key, this.id});

  final int? id;

  @override
  ConsumerState<BillFormScreen> createState() => _BillFormScreenState();
}

class _BillFormScreenState extends ConsumerState<BillFormScreen> {
  final _form = GlobalKey<FormState>();
  OpsChoice? _supplier;
  DateTime _date = DateTime.now();
  int _dueDays = 0;
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  final List<_BillLine> _lines = [];
  bool _payNow = false;
  int? _payAccountId;
  OpsDocument? _document;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.id != null;

  @override
  void initState() {
    super.initState();
    if (_editing) {
      _load();
    }
  }

  @override
  void dispose() {
    _reference.dispose();
    _notes.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final document = await ref.read(opsApiProvider)!.bill(widget.id!);
      final form = document.form;
      final date = DateTime.tryParse(form['date']?.toString() ?? '') ?? DateTime.now();
      final due = DateTime.tryParse(form['due_date']?.toString() ?? '');
      if (!mounted) {
        return;
      }
      setState(() {
        _document = document;
        _supplier = form['supplier_id'] == null ? null : OpsChoice(id: (form['supplier_id'] as num).toInt(), name: form['supplier_name']?.toString() ?? '-');
        _date = date;
        _dueDays = due == null ? 0 : due.difference(date).inDays;
        _reference.text = form['supplier_reference']?.toString() ?? '';
        _notes.text = form['notes']?.toString() ?? '';
        _lines.addAll([
          for (final item in form['items'] as List? ?? const [])
            if (item is Map)
              _BillLine(
                productId: (item['product_id'] as num?)?.toInt(),
                accountId: (item['account_id'] as num?)?.toInt(),
                description: item['description']?.toString(),
                quantity: qty(item['quantity']),
                price: rupiahText(item['unit_price']),
                unit: item['unit']?.toString(),
                unitFactor: item['unit_factor']?.toString() ?? '1',
              ),
        ]);
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String get _total => Money.add([for (final line in _lines) line.amount]);

  Future<void> _addProduct() async {
    final products = (await ref.read(workspaceProvider.future))?.local;
    if (products == null || !mounted) {
      return;
    }
    final list = [for (final product in await products.products(query: '')) if (product.trackInventory && product.isActive) product];
    if (!mounted) {
      return;
    }
    final picked = await pickChoice(context, title: 'Barang stok', choices: [for (final product in list) OpsChoice(id: product.id, name: product.name, group: product.categoryName)]);
    if (picked == null) {
      return;
    }
    final product = list.firstWhere((item) => item.id == picked.id);
    setState(() => _lines.add(_BillLine(productId: product.id, description: product.name, unit: product.unit)));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    if (_supplier == null) {
      setState(() => _error = 'Pilih pemasok atau ketik nama pemasok baru.');
      return;
    }
    if (_lines.isEmpty) {
      setState(() => _error = 'Tambahkan minimal satu barang atau biaya.');
      return;
    }
    if (_lines.any((line) => !line.isProduct && line.accountId == null)) {
      setState(() => _error = 'Pilih jenis biaya di setiap baris biaya.');
      return;
    }
    if (_payNow && _payAccountId == null) {
      setState(() => _error = 'Pilih dibayar dari kas/bank mana.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final data = {
      if (_supplier!.id > 0) 'supplier_id': _supplier!.id else 'supplier_name': _supplier!.name,
      'date': isoDate(_date),
      'due_days': _dueDays,
      if (_reference.text.trim().isNotEmpty) 'supplier_reference': _reference.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      'items': [
        for (final line in _lines)
          {
            if (line.isProduct) 'product_id': line.productId else 'account_id': line.accountId,
            'description': line.description.text.trim(),
            'quantity': line.qty,
            if (line.unit != null) 'unit': line.unit,
            if (line.isProduct) 'unit_factor': line.unitFactor,
            'unit_price': rupiahDigits(line.price.text),
          },
      ],
      if (_payNow && !_editing) 'paid': {'account_id': _payAccountId},
    };
    try {
      final result = await ref.read(opsApiProvider)!.saveBill(data, id: widget.id);
      refreshAfterOps(ref);
      if (mounted) {
        showMessage(context, result.message ?? 'Tagihan tersimpan.');
        context.pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _delete() async {
    if (!await confirmOpsDelete(context, 'tagihan ${_document?.number ?? ''}')) {
      return;
    }
    try {
      await ref.read(opsApiProvider)!.deleteBill(widget.id!);
      refreshAfterOps(ref);
      if (mounted) {
        showMessage(context, 'Tagihan dihapus.');
        context.pop(true);
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, _errorText(error), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(opsOptionsProvider);
    final readOnly = _editing && _document != null && !_document!.canEdit;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Ubah tagihan ${_document?.number ?? ''}' : 'Tagihan pemasok'),
        actions: [
          if (_document?.canDelete ?? false) IconButton(key: const Key('ops-delete'), tooltip: 'Hapus', icon: Icon(Icons.delete_outline, color: dangerText(context)), onPressed: _delete),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : options.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text(_errorText(error))),
              data: (options) => Form(
                key: _form,
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  if (_document?.lockedReason != null) LockedNotice(_document!.lockedReason!),
                  ChoiceField(
                    key: const Key('ops-bill-supplier'),
                    label: 'Pemasok',
                    icon: Icons.local_shipping_outlined,
                    choices: [...options.suppliers, if (_supplier != null && !options.suppliers.any((item) => item.id == _supplier!.id)) _supplier!],
                    value: _supplier?.id,
                    allowNew: options.allows('add_supplier'),
                    onChanged: (choice) => setState(() => _supplier = choice),
                  ),
                  const SizedBox(height: 12),
                  DateField(label: 'Tanggal tagihan', value: _date, onChanged: (value) => setState(() => _date = value)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text('Jatuh tempo:', style: TextStyle(color: mutedText(context))),
                    for (final days in const [0, 7, 14, 30])
                      ChoiceChip(label: Text(days == 0 ? 'Hari ini' : '$days hari'), selected: _dueDays == days, onSelected: (_) => setState(() => _dueDays = days)),
                  ]),
                  const SizedBox(height: 12),
                  TextFormField(controller: _reference, decoration: const InputDecoration(labelText: 'No. nota pemasok (opsional)')),
                  const SizedBox(height: 16),
                  for (final (i, line) in _lines.indexed) _lineCard(context, options, i, line),
                  Wrap(spacing: 8, children: [
                    OutlinedButton.icon(key: const Key('ops-bill-add-product'), onPressed: _addProduct, icon: const Icon(Icons.add_shopping_cart), label: const Text('Barang stok')),
                    OutlinedButton.icon(key: const Key('ops-bill-add-cost'), onPressed: () => setState(() => _lines.add(_BillLine(quantity: '1'))), icon: const Icon(Icons.add), label: const Text('Biaya lain')),
                  ]),
                  const SizedBox(height: 12),
                  TextFormField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Catatan (opsional)')),
                  if (!_editing && options.allows('pay_bill')) ...[
                    const SizedBox(height: 8),
                    SwitchListTile(
                      key: const Key('ops-bill-pay-now'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Langsung dibayar lunas'),
                      value: _payNow,
                      onChanged: (value) => setState(() => _payNow = value),
                    ),
                    if (_payNow) ChoiceField(label: 'Dibayar dari', icon: Icons.account_balance_wallet_outlined, choices: options.cashAccounts, value: _payAccountId, onChanged: (choice) => setState(() => _payAccountId = choice?.id)),
                  ],
                  const SizedBox(height: 16),
                  AmountRow('Total', rupiah(_total), bold: true, large: true),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, key: const Key('ops-error'), style: TextStyle(color: dangerText(context), fontWeight: FontWeight.w500))),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('ops-save'),
                    onPressed: _saving || readOnly ? null : _save,
                    child: _saving ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : Text(_editing ? 'Simpan perubahan' : 'Simpan tagihan'),
                  ),
                ]),
              ),
            ),
    );
  }

  Widget _lineCard(BuildContext context, OpsOptions options, int index, _BillLine line) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: line.isProduct
                    ? Text(line.description.text, style: const TextStyle(fontWeight: FontWeight.w600))
                    : ChoiceField(label: 'Jenis biaya', icon: Icons.category_outlined, choices: options.expenseCategories, value: line.accountId, onChanged: (choice) => setState(() => line.accountId = choice?.id)),
              ),
              IconButton(tooltip: 'Hapus baris', icon: const Icon(Icons.close), onPressed: () => setState(() => _lines.removeAt(index).dispose())),
            ]),
            if (!line.isProduct) ...[
              const SizedBox(height: 10),
              TextFormField(controller: line.description, decoration: const InputDecoration(labelText: 'Keterangan (mis. ongkos kirim)')),
            ],
            const SizedBox(height: 10),
            Row(children: [
              SizedBox(
                width: 100,
                child: TextFormField(
                  key: Key('ops-bill-qty-$index'),
                  controller: line.quantity,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Qty', suffixText: line.unit),
                  onChanged: (_) => setState(() {}),
                  validator: (value) => Money.isPositive((value ?? '').replaceAll(',', '.')) ? null : 'Isi qty.',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: RupiahField(key: Key('ops-bill-price-$index'), controller: line.price, label: 'Harga satuan', onChanged: (_) => setState(() {}))),
            ]),
            Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.only(top: 6), child: Text(rupiah(line.amount), style: const TextStyle(fontWeight: FontWeight.w600)))),
          ]),
        ),
      );
}

// ─────────────────────────────────────────────────────────── Kas & Bank

class _CashLine {
  _CashLine({this.accountId, String? description, String? amount})
      : description = TextEditingController(text: description ?? ''),
        amount = TextEditingController(text: amount ?? '');

  int? accountId;
  final TextEditingController description;
  final TextEditingController amount;

  void dispose() {
    description.dispose();
    amount.dispose();
  }
}

String cashTypeLabel(String type) => switch (type) {
      'in' => 'Uang masuk',
      'out' => 'Uang keluar',
      _ => 'Pindah uang antar rekening',
    };

/// Catat / ubah uang masuk, uang keluar, atau pindah uang antar rekening.
class CashFormScreen extends ConsumerStatefulWidget {
  const CashFormScreen({super.key, required this.type, this.id});

  final String type;
  final int? id;

  @override
  ConsumerState<CashFormScreen> createState() => _CashFormScreenState();
}

class _CashFormScreenState extends ConsumerState<CashFormScreen> {
  final _form = GlobalKey<FormState>();
  late String _type = widget.type;
  DateTime _date = DateTime.now();
  int? _accountId;
  int? _toAccountId;
  final _amount = TextEditingController();
  final _fee = TextEditingController();
  final _contact = TextEditingController();
  final _notes = TextEditingController();
  final List<_CashLine> _lines = [_CashLine()];
  OpsDocument? _document;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.id != null;
  bool get _transfer => _type == 'transfer';

  @override
  void initState() {
    super.initState();
    if (_editing) {
      _load();
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _fee.dispose();
    _contact.dispose();
    _notes.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final document = await ref.read(opsApiProvider)!.cashTransaction(widget.id!);
      final form = document.form;
      if (!mounted) {
        return;
      }
      setState(() {
        _document = document;
        _type = form['type']?.toString() ?? widget.type;
        _date = DateTime.tryParse(form['date']?.toString() ?? '') ?? DateTime.now();
        _accountId = (form['account_id'] as num?)?.toInt();
        _toAccountId = (form['to_account_id'] as num?)?.toInt();
        _contact.text = form['contact']?.toString() ?? '';
        _notes.text = form['description']?.toString() ?? '';
        _amount.text = rupiahText(form['total']);
        _fee.text = rupiahText(form['fee_amount']);
        for (final line in _lines) {
          line.dispose();
        }
        _lines
          ..clear()
          ..addAll([
            for (final line in form['lines'] as List? ?? const [])
              if (line is Map) _CashLine(accountId: (line['account_id'] as num?)?.toInt(), description: line['description']?.toString(), amount: rupiahText(line['amount'])),
          ]);
        if (_lines.isEmpty) {
          _lines.add(_CashLine());
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String get _total => _transfer ? Money.normalize(rupiahDigits(_amount.text)) : Money.add([for (final line in _lines) rupiahDigits(line.amount.text)]);

  Future<void> _save() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    if (_accountId == null || (_transfer && _toAccountId == null)) {
      setState(() => _error = _transfer ? 'Pilih rekening asal dan tujuan.' : 'Pilih kas/bank-nya.');
      return;
    }
    if (!_transfer && _lines.any((line) => line.accountId == null)) {
      setState(() => _error = 'Pilih akun di setiap baris.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final data = {
      'type': _type,
      'date': isoDate(_date),
      'account_id': _accountId,
      if (_transfer) ...{
        'to_account_id': _toAccountId,
        'amount': rupiahDigits(_amount.text),
        if (Money.isPositive(rupiahDigits(_fee.text))) 'fee_amount': rupiahDigits(_fee.text),
      } else
        'lines': [
          for (final line in _lines) {'account_id': line.accountId, 'amount': rupiahDigits(line.amount.text), if (line.description.text.trim().isNotEmpty) 'description': line.description.text.trim()},
        ],
      if (!_transfer && _contact.text.trim().isNotEmpty) 'contact_name': _contact.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'description': _notes.text.trim(),
    };
    try {
      final result = await ref.read(opsApiProvider)!.saveCash(data, id: widget.id);
      refreshAfterOps(ref);
      if (mounted) {
        showMessage(context, result.message ?? 'Tersimpan.');
        context.pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(opsOptionsProvider);
    final readOnly = _editing && _document != null && !_document!.canEdit;
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Ubah ${cashTypeLabel(_type).toLowerCase()}' : cashTypeLabel(_type))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : options.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text(_errorText(error))),
              data: (options) => Form(
                key: _form,
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  if (_document?.lockedReason != null) LockedNotice(_document!.lockedReason!),
                  DateField(label: 'Tanggal', value: _date, onChanged: (value) => setState(() => _date = value)),
                  const SizedBox(height: 12),
                  ChoiceField(
                    key: const Key('ops-cash-account'),
                    label: _transfer ? 'Dari rekening' : (_type == 'in' ? 'Masuk ke' : 'Keluar dari'),
                    icon: Icons.account_balance_wallet_outlined,
                    choices: options.cashAccounts,
                    value: _accountId,
                    onChanged: (choice) => setState(() => _accountId = choice?.id),
                  ),
                  const SizedBox(height: 12),
                  if (_transfer) ...[
                    ChoiceField(key: const Key('ops-cash-to'), label: 'Ke rekening', icon: Icons.account_balance_outlined, choices: options.cashAccounts, value: _toAccountId, onChanged: (choice) => setState(() => _toAccountId = choice?.id)),
                    const SizedBox(height: 12),
                    RupiahField(key: const Key('ops-cash-amount'), controller: _amount, label: 'Jumlah dipindah', onChanged: (_) => setState(() {}), validator: (value) => Money.isPositive(rupiahDigits(value ?? '')) ? null : 'Isi jumlahnya.'),
                    const SizedBox(height: 12),
                    RupiahField(controller: _fee, label: 'Biaya transfer (opsional)'),
                  ] else ...[
                    for (final (i, line) in _lines.indexed)
                      Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(children: [
                            Row(children: [
                              Expanded(
                                child: ChoiceField(
                                  key: Key('ops-cash-line-$i'),
                                  label: _type == 'in' ? 'Uang masuk dari' : 'Untuk',
                                  icon: Icons.category_outlined,
                                  choices: _type == 'in' ? options.incomeAccounts : options.spendingAccounts,
                                  value: line.accountId,
                                  onChanged: (choice) => setState(() => line.accountId = choice?.id),
                                ),
                              ),
                              if (_lines.length > 1) IconButton(tooltip: 'Hapus baris', icon: const Icon(Icons.close), onPressed: () => setState(() => _lines.removeAt(i).dispose())),
                            ]),
                            const SizedBox(height: 10),
                            RupiahField(key: Key('ops-cash-line-amount-$i'), controller: line.amount, label: 'Jumlah', onChanged: (_) => setState(() {}), validator: (value) => Money.isPositive(rupiahDigits(value ?? '')) ? null : 'Isi jumlahnya.'),
                            const SizedBox(height: 10),
                            TextFormField(controller: line.description, decoration: const InputDecoration(labelText: 'Keterangan (opsional)')),
                          ]),
                        ),
                      ),
                    TextButton.icon(onPressed: () => setState(() => _lines.add(_CashLine())), icon: const Icon(Icons.add), label: const Text('Tambah baris')),
                    TextFormField(controller: _contact, decoration: InputDecoration(labelText: _type == 'in' ? 'Dari siapa (opsional)' : 'Kepada siapa (opsional)')),
                  ],
                  const SizedBox(height: 12),
                  TextFormField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Keterangan transaksi (opsional)')),
                  const SizedBox(height: 16),
                  AmountRow('Total', rupiah(_total), bold: true, large: true),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, key: const Key('ops-error'), style: TextStyle(color: dangerText(context), fontWeight: FontWeight.w500))),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('ops-save'),
                    onPressed: _saving || readOnly ? null : _save,
                    child: _saving ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : Text(_editing ? 'Simpan perubahan' : 'Simpan'),
                  ),
                ]),
              ),
            ),
    );
  }
}

/// Rincian transaksi Kas & Bank dengan tombol Ubah / Hapus.
class CashDetailScreen extends ConsumerStatefulWidget {
  const CashDetailScreen({super.key, required this.id});

  final int id;

  @override
  ConsumerState<CashDetailScreen> createState() => _CashDetailScreenState();
}

class _CashDetailScreenState extends ConsumerState<CashDetailScreen> {
  late Future<OpsDocument> _future = ref.read(opsApiProvider)!.cashTransaction(widget.id);

  void _reload() => setState(() => _future = ref.read(opsApiProvider)!.cashTransaction(widget.id));

  Future<void> _delete(OpsDocument document) async {
    if (!await confirmOpsDelete(context, 'transaksi ${document.number ?? ''}')) {
      return;
    }
    try {
      await ref.read(opsApiProvider)!.deleteCash(widget.id);
      refreshAfterOps(ref);
      if (mounted) {
        showMessage(context, 'Transaksi dihapus.');
        context.pop(true);
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, _errorText(error), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kas & Bank')),
      body: FutureBuilder<OpsDocument>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_errorText(snapshot.error!))));
          }
          final document = snapshot.data;
          if (document == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final raw = document.raw;
          final type = raw['type']?.toString() ?? 'out';
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (document.lockedReason != null) LockedNotice(document.lockedReason!),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(document.number ?? 'Draf', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                    StatusPill(document.status == 'posted' ? 'Tercatat' : (document.status == 'void' ? 'Batal' : 'Draf'), color: statusColor(context, document.status ?? '')),
                  ]),
                  const SizedBox(height: 8),
                  Text('${cashTypeLabel(type)} · ${dateFromIso(raw['date']?.toString() ?? '')}'),
                  Text(type == 'transfer' ? '${raw['account']} → ${raw['to_account']}' : '${raw['account'] ?? ''}${(raw['contact'] ?? '').toString().isEmpty ? '' : ' · ${raw['contact']}'}', style: TextStyle(color: mutedText(context))),
                  if ((raw['description'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(raw['description'].toString())),
                  const Divider(height: 24),
                  for (final line in raw['lines'] as List? ?? const [])
                    if (line is Map) AmountRow('${line['account'] ?? '-'}${(line['description'] ?? '').toString().isEmpty ? '' : ' · ${line['description']}'}', rupiah(line['amount'])),
                  AmountRow('Total', rupiah(document.total), bold: true, large: true),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            if (document.canEdit)
              FilledButton.icon(
                key: const Key('ops-cash-edit'),
                onPressed: () async {
                  final changed = await context.push<bool>('/ops/kas/${widget.id}/ubah?type=$type');
                  if (changed == true) {
                    _reload();
                  }
                },
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Ubah'),
              ),
            if (document.canDelete) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('ops-cash-delete'),
                onPressed: () => _delete(document),
                icon: Icon(Icons.delete_outline, color: dangerText(context)),
                label: Text('Hapus', style: TextStyle(color: dangerText(context))),
              ),
            ],
          ]);
        },
      ),
    );
  }
}

/// Daftar biaya (ketuk untuk mengubah) atau daftar Kas & Bank (ketuk untuk rincian).
class OpsListScreen extends ConsumerStatefulWidget {
  const OpsListScreen({super.key, required this.kind});

  /// `biaya` atau `kas`.
  final String kind;

  @override
  ConsumerState<OpsListScreen> createState() => _OpsListScreenState();
}

class _OpsListScreenState extends ConsumerState<OpsListScreen> {
  final List<Map<String, dynamic>> _items = [];
  String? _next;
  bool _loading = false;
  String? _error;
  String _query = '';
  String? _type;

  bool get _expenses => widget.kind == 'biaya';

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    final api = ref.read(opsApiProvider);
    if (api == null || _loading) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = _expenses ? await api.expenses(q: _query, cursor: reset ? null : _next) : await api.cashTransactions(type: _type, q: _query, cursor: reset ? null : _next);
      if (!mounted) {
        return;
      }
      setState(() {
        if (reset) {
          _items.clear();
        }
        _items.addAll(page.items);
        _next = page.next;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(Map<String, dynamic> item) async {
    final path = _expenses ? '/ops/biaya/${item['source']}/${item['id']}' : '/ops/kas/${item['id']}';
    final changed = await context.push<bool>(path);
    if (changed == true) {
      _load(reset: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(opsListVersionProvider, (_, __) => _load(reset: true));
    return Scaffold(
      appBar: AppBar(title: Text(_expenses ? 'Daftar biaya' : 'Daftar Kas & Bank')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('ops-list-add'),
        onPressed: () async {
          await context.push<bool>(_expenses ? '/ops/biaya/baru' : '/ops/kas/baru/${_type ?? 'out'}');
          _load(reset: true);
        },
        icon: const Icon(Icons.add),
        label: Text(_expenses ? 'Catat biaya' : 'Catat'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Cari nomor / keterangan', prefixIcon: Icon(Icons.search)),
            onSubmitted: (value) {
              _query = value;
              _load(reset: true);
            },
          ),
        ),
        if (!_expenses)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              for (final (value, label) in const [(null, 'Semua'), ('in', 'Masuk'), ('out', 'Keluar'), ('transfer', 'Pindah')]) ...[
                ChoiceChip(
                  label: Text(label),
                  selected: _type == value,
                  onSelected: (_) {
                    setState(() => _type = value);
                    _load(reset: true);
                  },
                ),
                const SizedBox(width: 8),
              ],
            ]),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: _items.length + 1,
              itemBuilder: (context, index) {
                if (index == _items.length) {
                  if (_error != null) {
                    return Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center));
                  }
                  if (_loading) {
                    return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
                  }
                  if (_items.isEmpty) {
                    return const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Belum ada catatan.')));
                  }
                  return _next == null ? const SizedBox.shrink() : TextButton(onPressed: _load, child: const Text('Muat lagi'));
                }
                final item = _items[index];
                final title = _expenses ? (item['category'] ?? item['description'] ?? '-').toString() : cashTypeLabel(item['type']?.toString() ?? 'out');
                final subtitle = [
                  item['number'] ?? 'Draf',
                  dateFromIso(item['date']?.toString() ?? ''),
                  if ((item['description'] ?? '').toString().isNotEmpty && !_expenses) item['description'],
                  if ((item['contact'] ?? '').toString().isNotEmpty) item['contact'],
                ].join(' · ');
                return ListTile(
                  key: Key('ops-row-$index'),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Text(rupiah(item['amount'] ?? item['total']), style: const TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () => _open(item),
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}

/// Catat pembayaran: bayar tagihan pemasok atau terima dari pelanggan.
/// Mengembalikan true bila tersimpan.
Future<bool> showPaymentSheet(BuildContext context, WidgetRef ref, {required String title, required String balance, required Future<OpsResult> Function(Map<String, dynamic> data) submit}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PaymentSheet(title: title, balance: balance, submit: submit),
  );
  if (saved == true) {
    refreshAfterOps(ref);
  }
  return saved == true;
}

class _PaymentSheet extends ConsumerStatefulWidget {
  const _PaymentSheet({required this.title, required this.balance, required this.submit});

  final String title;
  final String balance;
  final Future<OpsResult> Function(Map<String, dynamic> data) submit;

  @override
  ConsumerState<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<_PaymentSheet> {
  late final _amount = TextEditingController(text: rupiahText(widget.balance));
  DateTime _date = DateTime.now();
  int? _accountId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_accountId == null) {
      setState(() => _error = 'Pilih kas/bank-nya.');
      return;
    }
    if (!Money.isPositive(rupiahDigits(_amount.text))) {
      setState(() => _error = 'Isi jumlah pembayaran.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.submit({'date': isoDate(_date), 'amount': rupiahDigits(_amount.text), 'account_id': _accountId, 'method': 'cash'});
      if (mounted) {
        Navigator.pop(context, true);
        showMessage(context, Money.isPositive(result.balanceDue ?? '0') ? 'Pembayaran tercatat. Sisa ${rupiah(result.balanceDue)}.' : 'Pembayaran tercatat. Sudah lunas.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(opsOptionsProvider).valueOrNull ?? const OpsOptions();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        Text('Sisa ${rupiah(widget.balance)}', style: TextStyle(color: mutedText(context))),
        const SizedBox(height: 16),
        RupiahField(key: const Key('ops-pay-amount'), controller: _amount, label: 'Jumlah'),
        const SizedBox(height: 12),
        ChoiceField(key: const Key('ops-pay-account'), label: 'Kas / bank', icon: Icons.account_balance_wallet_outlined, choices: options.cashAccounts, value: _accountId, onChanged: (choice) => setState(() => _accountId = choice?.id)),
        const SizedBox(height: 12),
        DateField(label: 'Tanggal bayar', value: _date, onChanged: (value) => setState(() => _date = value)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, key: const Key('ops-pay-error'), style: TextStyle(color: dangerText(context)))),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('ops-pay-save'),
          onPressed: _saving ? null : _save,
          child: _saving ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Simpan pembayaran'),
        ),
      ]),
    );
  }
}

/// Produk tersimpan di HP (dipakai tes untuk memastikan hanya barang stok).
bool billProductAllowed(Product product) => product.trackInventory && product.isActive;
