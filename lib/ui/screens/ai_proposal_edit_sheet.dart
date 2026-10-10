import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/ai_models.dart';
import '../../domain/models.dart';
import '../theme.dart';

/// Lembar "Ubah" usulan: hanya isian di `editable_fields` yang ditampilkan,
/// sama dengan formulir web. Mengembalikan `edits` untuk approve, atau null
/// bila dibatalkan.
Future<Map<String, dynamic>?> showProposalEditSheet(BuildContext context, AiProposal proposal, {List<CashAccount> accounts = const []}) =>
    showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => _ProposalEditSheet(proposal: proposal, accounts: accounts),
    );

class _ProposalEditSheet extends StatefulWidget {
  const _ProposalEditSheet({required this.proposal, required this.accounts});

  final AiProposal proposal;
  final List<CashAccount> accounts;

  @override
  State<_ProposalEditSheet> createState() => _ProposalEditSheetState();
}

class _ProposalEditSheetState extends State<_ProposalEditSheet> {
  final _form = GlobalKey<FormState>();
  final Map<String, TextEditingController> _text = {};
  final List<Map<String, dynamic>> _items = [];
  final List<Map<String, TextEditingController>> _itemText = [];
  DateTime? _date;
  DateTime? _deliveryDate;
  bool _paid = false;
  String? _paymentMethod;
  int? _cashAccountId;

  AiProposal get proposal => widget.proposal;
  Map<String, dynamic> get payload => proposal.payload;
  bool has(String field) => proposal.editableFields.contains(field);

  String get _initialContact => (proposal.preview['contact']?.toString() ?? payload['customer_name']?.toString() ?? payload['supplier_name']?.toString() ?? '').trim();

  @override
  void initState() {
    super.initState();
    _text['contact'] = TextEditingController(text: _initialContact);
    _text['amount'] = TextEditingController(text: payload['amount'] == null ? '' : rupiah(payload['amount'], symbol: false));
    _text['description'] = TextEditingController(text: payload['description']?.toString() ?? '');
    _date = DateTime.tryParse(payload['date']?.toString() ?? '');
    _deliveryDate = DateTime.tryParse(payload['delivery_date']?.toString() ?? '');
    _paid = payload['paid'] == true || payload['paid'] == 1 || payload['paid'] == '1';
    _paymentMethod = payload['payment_method']?.toString();
    _cashAccountId = payload['cash_account_id'] is int ? payload['cash_account_id'] as int : int.tryParse(payload['cash_account_id']?.toString() ?? '');
    final rows = has('lines') ? payload['lines'] : payload['items'];
    for (final row in (rows as List? ?? const [])) {
      if (row is! Map) {
        continue;
      }
      final item = Map<String, dynamic>.from(row);
      _items.add(item);
      _itemText.add({
        'quantity': TextEditingController(text: qty(item['quantity'] ?? item['opening_stock'] ?? '0')),
        'unit_price': TextEditingController(text: item['unit_price'] == null ? '' : rupiah(item['unit_price'], symbol: false)),
        'name': TextEditingController(text: item['name']?.toString() ?? ''),
        'sale_price': TextEditingController(text: item['sale_price'] == null ? '' : rupiah(item['sale_price'], symbol: false)),
        'cost_price': TextEditingController(text: item['cost_price'] == null ? '' : rupiah(item['cost_price'], symbol: false)),
        'opening_stock': TextEditingController(text: item['opening_stock'] == null ? '' : qty(item['opening_stock'])),
      });
    }
  }

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    for (final row in _itemText) {
      for (final controller in row.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _pickDate({bool delivery = false}) async {
    final picked = await showDatePicker(context: context, initialDate: (delivery ? _deliveryDate : _date) ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365)));
    if (picked != null) {
      setState(() => delivery ? _deliveryDate = picked : _date = picked);
    }
  }

  /// Harga/jumlah uang: angka, tidak boleh negatif.
  String? _requiredMoney(String? value) {
    final parsed = value == null ? null : parseMoneyInput(value);
    if (parsed == null) {
      return 'Isi angka';
    }
    return parsed.startsWith('-') ? 'Tidak boleh minus' : null;
  }

  /// Banyaknya barang: angka lebih dari nol (server menolak 0 setelah dikirim).
  String? _requiredQty(String? value) {
    final parsed = value == null ? null : parseQuantityInput(value);
    if (parsed == null) {
      return 'Isi jumlah';
    }
    return (double.tryParse(parsed) ?? 0) <= 0 ? 'Harus lebih dari nol' : null;
  }

  String? _requiredContact(String? value) => value == null || value.trim().isEmpty ? 'Isi nama' : null;

  String? _requiredAccount(int? value) => _paid && value == null ? 'Pilih akun kas/bank' : null;

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) {
      return;
    }
    final edits = <String, dynamic>{};
    final contact = _text['contact']!.text.trim();
    // Nama kontak hanya dikirim bila diisi dan berubah (kosong = pakai yang ada).
    if (has('contact') && contact.isNotEmpty && contact != _initialContact) {
      edits['contact'] = contact;
    }
    if (has('date') && _date != null) {
      edits['date'] = isoDate(_date!);
    }
    if (has('delivery_date') && _deliveryDate != null) {
      edits['delivery_date'] = isoDate(_deliveryDate!);
    }
    if (has('amount')) {
      edits['amount'] = parseMoneyInput(_text['amount']!.text);
    }
    if (has('description')) {
      edits['description'] = _text['description']!.text.trim();
    }
    if (has('paid')) {
      edits['paid'] = _paid ? '1' : '0';
    }
    if (has('payment_method')) {
      edits['payment_method'] = _paid ? (_paymentMethod ?? 'cash') : null;
    }
    if (has('cash_account_id')) {
      edits['cash_account_id'] = _paid ? _cashAccountId : null;
    }
    if (has('items')) {
      edits['items'] = [
        for (var i = 0; i < _items.length; i++)
          proposal.type == 'products'
              ? {
                  ..._items[i],
                  'name': _itemText[i]['name']!.text.trim(),
                  'sale_price': parseMoneyInput(_itemText[i]['sale_price']!.text) ?? _items[i]['sale_price'],
                  'cost_price': parseMoneyInput(_itemText[i]['cost_price']!.text) ?? _items[i]['cost_price'],
                  'opening_stock': parseQuantityInput(_itemText[i]['opening_stock']!.text) ?? _items[i]['opening_stock'],
                }
              : {
                  'product_id': _items[i]['product_id'],
                  'description': _items[i]['description'],
                  'quantity': parseQuantityInput(_itemText[i]['quantity']!.text),
                  'unit': _items[i]['unit'],
                  'unit_price': parseMoneyInput(_itemText[i]['unit_price']!.text),
                  'discount_percent': Money.normalize(_items[i]['discount_percent'] ?? '0'),
                  'tax_rate': Money.normalize(_items[i]['tax_rate'] ?? '0'),
                  if (_items[i]['account_id'] != null) 'account_id': _items[i]['account_id'],
                },
      ];
    }
    if (has('lines')) {
      edits['lines'] = [
        for (var i = 0; i < _items.length; i++) {'sales_order_item_id': _items[i]['sales_order_item_id'], 'quantity': parseQuantityInput(_itemText[i]['quantity']!.text)},
      ];
    }
    Navigator.pop(context, edits);
  }

  @override
  Widget build(BuildContext context) {
    final isSale = proposal.type == 'sale' || proposal.type == 'sales_order';
    final isProducts = proposal.type == 'products';
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Form(
        key: _form,
        child: ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.edit_outlined, size: 20, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Ubah usulan', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(proposal.title, style: TextStyle(fontSize: 13, color: mutedText(context))),
              ]),
            ),
          ]),
          const SizedBox(height: 20),
          if (has('contact')) ...[
            TextFormField(key: const Key('edit-contact'), controller: _text['contact'], validator: _requiredContact, decoration: InputDecoration(labelText: proposal.type == 'purchase' ? 'Pemasok' : 'Pelanggan')),
            const SizedBox(height: 12),
          ],
          if (has('date')) ...[
            _DateField(label: 'Tanggal', value: _date, onTap: () => _pickDate()),
            const SizedBox(height: 12),
          ],
          if (has('delivery_date')) ...[
            _DateField(label: 'Tanggal kirim', value: _deliveryDate, onTap: () => _pickDate(delivery: true)),
            const SizedBox(height: 12),
          ],
          if (has('description')) ...[
            TextFormField(controller: _text['description'], decoration: const InputDecoration(labelText: 'Keterangan')),
            const SizedBox(height: 12),
          ],
          if (has('amount')) ...[
            TextFormField(key: const Key('edit-amount'), controller: _text['amount'], keyboardType: TextInputType.number, validator: _requiredMoney, decoration: const InputDecoration(labelText: 'Jumlah', prefixText: 'Rp ')),
            const SizedBox(height: 12),
          ],
          if (has('items') || has('lines')) ...[
            Text(isProducts ? 'Barang' : 'Rincian', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (var i = 0; i < _items.length; i++) ...[
              Container(
                decoration: BoxDecoration(color: AiColors.card(context), borderRadius: BorderRadius.circular(16), border: Border.all(color: AiColors.border(context))),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (isProducts)
                      TextFormField(controller: _itemText[i]['name'], decoration: const InputDecoration(labelText: 'Nama barang', isDense: true), validator: (value) => value == null || value.trim().isEmpty ? 'Isi nama' : null)
                    else
                      Text(_items[i]['description']?.toString() ?? '-', style: const TextStyle(fontWeight: FontWeight.w500)),
                    const SizedBox(height: 10),
                    if (isProducts)
                      Row(children: [
                        Expanded(child: TextFormField(controller: _itemText[i]['sale_price'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Harga jual', prefixText: 'Rp ', isDense: true))),
                        const SizedBox(width: 8),
                        Expanded(child: TextFormField(controller: _itemText[i]['cost_price'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Harga beli', prefixText: 'Rp ', isDense: true))),
                        const SizedBox(width: 8),
                        Expanded(child: TextFormField(controller: _itemText[i]['opening_stock'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Stok awal', isDense: true))),
                      ])
                    else
                      Row(children: [
                        Expanded(
                          child: TextFormField(
                            key: Key('edit-qty-$i'),
                            controller: _itemText[i]['quantity'],
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            validator: _requiredQty,
                            decoration: InputDecoration(labelText: 'Jumlah', suffixText: _items[i]['unit']?.toString(), isDense: true),
                          ),
                        ),
                        if (has('items')) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              key: Key('edit-price-$i'),
                              controller: _itemText[i]['unit_price'],
                              keyboardType: TextInputType.number,
                              validator: _requiredMoney,
                              decoration: const InputDecoration(labelText: 'Harga satuan', prefixText: 'Rp ', isDense: true),
                            ),
                          ),
                        ],
                      ]),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 4),
          ],
          if (has('paid')) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(isSale ? 'Sudah dibayar' : 'Sudah dibayar ke pemasok'),
              subtitle: Text(_paid ? 'Uang masuk/keluar dicatat sekarang' : (isSale ? 'Belum dibayar, ditagih nanti' : 'Dibayar nanti'), style: const TextStyle(fontSize: 12)),
              value: _paid,
              onChanged: (value) => setState(() => _paid = value),
            ),
            if (_paid) ...[
              if (has('payment_method'))
                DropdownButtonFormField<String>(
                  value: _paymentMethod ?? 'cash',
                  decoration: const InputDecoration(labelText: 'Cara bayar'),
                  items: [
                    const DropdownMenuItem(value: 'cash', child: Text('Tunai')),
                    const DropdownMenuItem(value: 'transfer', child: Text('Transfer')),
                    if (isSale) const DropdownMenuItem(value: 'qris', child: Text('QRIS')),
                  ],
                  onChanged: (value) => setState(() => _paymentMethod = value),
                ),
              if (has('cash_account_id') && widget.accounts.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: const Key('edit-account'),
                  value: widget.accounts.any((account) => account.id == _cashAccountId) ? _cashAccountId : null,
                  validator: _requiredAccount,
                  decoration: const InputDecoration(labelText: 'Akun kas / bank'),
                  items: [for (final account in widget.accounts) DropdownMenuItem(value: account.id, child: Text(account.name))],
                  onChanged: (value) => setState(() => _cashAccountId = value),
                ),
              ],
            ],
            const SizedBox(height: 12),
          ],
          if (has('cash_account_id') && !has('paid') && widget.accounts.isNotEmpty) ...[
            DropdownButtonFormField<int>(
              value: widget.accounts.any((account) => account.id == _cashAccountId) ? _cashAccountId : null,
              decoration: const InputDecoration(labelText: 'Akun kas / bank'),
              items: [for (final account in widget.accounts) DropdownMenuItem(value: account.id, child: Text(account.name))],
              onChanged: (value) => setState(() => _cashAccountId = value),
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('edit-save'),
            style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26))),
            onPressed: _save,
            icon: const Icon(Icons.check_rounded),
            label: const Text('Simpan & setujui'),
          ),
          const SizedBox(height: 8),
          TextButton(style: TextButton.styleFrom(minimumSize: const Size(0, 48)), onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        ]),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onTap});

  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18)),
          child: Text(value == null ? 'Pilih tanggal' : dateLabel(value!)),
        ),
      );
}
