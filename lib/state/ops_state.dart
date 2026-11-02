import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ops_api.dart';
import 'records_state.dart';
import 'workspace.dart';

/// Klien Operasional untuk perusahaan aktif (null bila belum ada perusahaan).
final opsApiProvider = Provider<OpsApi?>((ref) {
  final workspace = ref.watch(workspaceProvider).valueOrNull;
  return workspace == null ? null : OpsApi(workspace.api);
});

/// Pilihan form + hak Operasional (jenis biaya, akun, pemasok).
final opsOptionsProvider = FutureProvider.autoDispose<OpsOptions>((ref) async {
  final api = ref.watch(opsApiProvider);
  if (api == null) {
    return const OpsOptions();
  }
  return api.options();
});

/// Setelah dokumen dicatat/diubah/dihapus: muat ulang daftar & rincian Catatan.
void refreshAfterOps(WidgetRef ref) {
  ref.invalidate(purchasesListProvider);
  ref.invalidate(cashListProvider);
  ref.invalidate(paymentsListProvider);
  ref.invalidate(salesListProvider);
  ref.invalidate(purchaseDetailProvider);
  ref.invalidate(saleDetailProvider);
  ref.read(opsListVersionProvider.notifier).state++;
}

/// Naik setiap ada perubahan dari layar Operasional (daftar biaya / kas dimuat ulang).
final opsListVersionProvider = StateProvider<int>((ref) => 0);
