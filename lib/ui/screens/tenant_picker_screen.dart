import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';

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

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).valueOrNull;
    final tenants = session?.tenants ?? const <TenantSummary>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pilih perusahaan'),
        actions: [
          TextButton(onPressed: () => ref.read(sessionProvider.notifier).logout(), child: const Text('Keluar')),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(sessionProvider.notifier).refreshMe(),
        child: tenants.isEmpty
            ? ListView(children: const [
                SizedBox(height: 120),
                EmptyState(icon: Icons.storefront_outlined, title: 'Belum ada perusahaan', message: 'Minta pemilik usaha menambahkan Anda sebagai anggota tim di website Infois.'),
              ])
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: tenants.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final tenant = tenants[index];
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      leading: CircleAvatar(
                        backgroundColor: Brand.green.withValues(alpha: 0.12),
                        child: Text(tenant.name.isEmpty ? '?' : tenant.name[0].toUpperCase(), style: const TextStyle(color: Brand.green, fontWeight: FontWeight.w700)),
                      ),
                      title: Text(tenant.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(tenant.active ? (tenant.roleLabel ?? 'Anggota') : 'Langganan tidak aktif · kelola lewat website', style: TextStyle(color: tenant.active ? null : Brand.amber)),
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
