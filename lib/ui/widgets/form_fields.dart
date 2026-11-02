import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../data/ops_api.dart';
import '../theme.dart';

/// Ketik nominal Rupiah: hanya angka, titik ribuan otomatis ("150.000").
class RupiahInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '').replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final text = digits.isEmpty ? '' : rupiah(digits, symbol: false);
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

/// "150.000" → "150000" (kosong → "0").
String rupiahDigits(String text) {
  final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
  return digits.isEmpty ? '0' : digits;
}

/// Isi awal isian Rupiah dari angka server ("150000.00" → "150.000").
String rupiahText(Object? value) {
  final whole = (value?.toString() ?? '').split('.').first.replaceAll(RegExp(r'[^0-9]'), '');
  return whole.isEmpty || whole == '0' ? '' : rupiah(whole, symbol: false);
}

class RupiahField extends StatelessWidget {
  const RupiahField({super.key, required this.controller, required this.label, this.onChanged, this.validator, this.helper});

  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onChanged;
  final FormFieldValidator<String>? validator;
  final String? helper;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [RupiahInputFormatter()],
        decoration: InputDecoration(labelText: label, prefixText: 'Rp ', helperText: helper),
        validator: validator,
        onChanged: onChanged,
      );
}

/// Pilihan dari daftar (jenis biaya, akun, pemasok) lewat lembar bawah
/// dengan kotak cari.
class ChoiceField extends StatelessWidget {
  const ChoiceField({super.key, required this.label, required this.choices, required this.value, required this.onChanged, this.icon, this.errorText, this.allowNew = false});

  final String label;
  final List<OpsChoice> choices;
  final int? value;
  final ValueChanged<OpsChoice?> onChanged;
  final IconData? icon;
  final String? errorText;

  /// Boleh mengetik nama baru (dikembalikan sebagai OpsChoice dengan id 0).
  final bool allowNew;

  @override
  Widget build(BuildContext context) {
    final selected = choices.where((choice) => choice.id == value).firstOrNull;
    return InkWell(
      onTap: () async {
        final picked = await pickChoice(context, title: label, choices: choices, allowNew: allowNew);
        if (picked != null) {
          onChanged(picked);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, prefixIcon: icon == null ? null : Icon(icon), suffixIcon: const Icon(Icons.arrow_drop_down), errorText: errorText),
        isEmpty: selected == null,
        child: Text(selected?.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

Future<OpsChoice?> pickChoice(BuildContext context, {required String title, required List<OpsChoice> choices, bool allowNew = false}) => showModalBottomSheet<OpsChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ChoiceSheet(title: title, choices: choices, allowNew: allowNew),
    );

class _ChoiceSheet extends StatefulWidget {
  const _ChoiceSheet({required this.title, required this.choices, required this.allowNew});

  final String title;
  final List<OpsChoice> choices;
  final bool allowNew;

  @override
  State<_ChoiceSheet> createState() => _ChoiceSheetState();
}

class _ChoiceSheetState extends State<_ChoiceSheet> {
  String _query = '';

  /// Pilihan dengan judul kelompok (mis. "Sering dipakai", "Biaya usaha").
  List<Widget> _grouped(BuildContext context, List<OpsChoice> shown) {
    final widgets = <Widget>[];
    String? group;
    for (final choice in shown) {
      if (choice.group != null && choice.group != group) {
        group = choice.group;
        widgets.add(Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(group!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: mutedText(context)))));
      }
      widgets.add(ListTile(title: Text(choice.name), onTap: () => Navigator.pop(context, choice)));
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final shown = [for (final choice in widget.choices) if (query.isEmpty || choice.name.toLowerCase().contains(query)) choice];
    final exact = widget.choices.any((choice) => choice.name.toLowerCase() == query);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: widget.choices.length > 8,
            decoration: InputDecoration(hintText: 'Cari ${widget.title.toLowerCase()}', prefixIcon: const Icon(Icons.search)),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: ListView(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom + 16), children: [
            if (widget.allowNew && query.isNotEmpty && !exact)
              ListTile(
                key: const Key('choice-new'),
                leading: const Icon(Icons.add),
                title: Text('Tambah "${_query.trim()}"'),
                onTap: () => Navigator.pop(context, OpsChoice(id: 0, name: _query.trim())),
              ),
            ..._grouped(context, shown),
            if (shown.isEmpty && !(widget.allowNew && query.isNotEmpty)) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Tidak ada yang cocok.'))),
          ]),
        ),
      ]),
    );
  }
}

/// Tanggal dokumen (ketuk → kalender).
class DateField extends StatelessWidget {
  const DateField({super.key, required this.label, required this.value, required this.onChanged, this.firstDate});

  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final DateTime? firstDate;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          final picked = await showDatePicker(context: context, initialDate: value, firstDate: firstDate ?? DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365)));
          if (picked != null) {
            onChanged(picked);
          }
        },
        child: InputDecorator(decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.event_outlined)), child: Text(dateLabel(value))),
      );
}
