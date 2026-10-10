import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../state/pos_state.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../widgets/common.dart';

/// Pilih pelanggan dari data HP, atau tambah pelanggan baru (bisa offline).
Future<Customer?> pickCustomer(BuildContext context, WidgetRef ref) => showModalBottomSheet<Customer>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => const FractionallySizedBox(heightFactor: 0.85, child: _CustomerPicker()),
    );

class _CustomerPicker extends ConsumerStatefulWidget {
  const _CustomerPicker();

  @override
  ConsumerState<_CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends ConsumerState<_CustomerPicker> {
  String _query = '';

  Future<void> _addNew() async {
    final name = TextEditingController(text: _query);
    final phone = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pelanggan baru'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nama')),
          const SizedBox(height: 12),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'No. HP (opsional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, name.text.trim().isNotEmpty), child: const Text('Simpan')),
        ],
      ),
    );
    if (created != true) {
      return;
    }
    final service = await ref.read(posServiceProvider.future);
    if (service == null) {
      return;
    }
    final customer = await service.addCustomer(name: name.text, phone: phone.text);
    ref.read(dataVersionProvider.notifier).state++;
    await ref.read(syncProvider.notifier).refreshPending();
    if (mounted) {
      Navigator.pop(context, customer);
    }
  }

  @override
  Widget build(BuildContext context) {
    final customers = ref.watch(customerSearchProvider(_query));
    final canAdd = ref.watch(masterDataProvider).valueOrNull?.menus.addCustomer ?? false;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Cari nama atau no. HP', prefixIcon: Icon(Icons.search), isDense: true),
          onChanged: (value) => setState(() => _query = value),
        ),
      ),
      if (canAdd)
        ListTile(leading: const Icon(Icons.person_add_alt_1_outlined), title: const Text('Tambah pelanggan baru'), onTap: _addNew),
      ListTile(
        leading: const Icon(Icons.storefront_outlined),
        title: const Text('Pelanggan umum'),
        subtitle: const Text('Pembeli langsung, bayar lunas'),
        onTap: () => Navigator.pop(context, const Customer(name: 'Pelanggan Umum', isWalkIn: true)),
      ),
      const Divider(height: 1),
      Expanded(
        child: customers.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text(plainError(error, fallback: 'Daftar pelanggan belum bisa dibuka. Coba lagi.'))),
          data: (items) {
            final list = items.where((customer) => !customer.isWalkIn).toList();
            return list.isEmpty
                ? const EmptyState(icon: Icons.people_outline, title: 'Pelanggan tidak ditemukan')
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final customer = list[index];
                      return ListTile(
                        title: Text(customer.name),
                        subtitle: Text([customer.phone, if (customer.pending) 'belum terkirim'].whereType<String>().where((text) => text.isNotEmpty).join(' · ')),
                        onTap: () => Navigator.pop(context, customer),
                      );
                    },
                  );
          },
        ),
      ),
    ]);
  }
}
