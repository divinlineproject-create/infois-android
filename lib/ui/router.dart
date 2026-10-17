import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/session.dart';
import '../domain/record_models.dart';
import '../state/records_state.dart';
import 'screens/ai_chat_screen.dart';
import 'screens/catatan_screen.dart';
import 'screens/help_screens.dart';
import 'screens/history_screen.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/pay_screen.dart';
import 'screens/record_detail_screens.dart';
import 'screens/report_screens.dart';
import 'screens/settings_screens.dart';
import 'screens/shift_screens.dart';
import 'screens/tenant_picker_screen.dart';
import 'widgets/common.dart';

/// Memberi tahu router saat sesi berubah (login, pilih perusahaan, keluar).
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen(sessionProvider, (_, __) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _SessionListenable(ref);
  ref.onDispose(listenable.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: listenable,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final location = state.matchedLocation;
      if (session.isLoading && !session.hasValue) {
        return location == '/mulai' ? null : '/mulai';
      }
      final value = session.valueOrNull;
      if (value == null || !value.loggedIn) {
        return location == '/masuk' ? null : '/masuk';
      }
      if (value.tenant == null) {
        return location == '/perusahaan' ? null : '/perusahaan';
      }
      if (location == '/masuk' || location == '/perusahaan' || location == '/mulai') {
        return '/';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/mulai', builder: (_, __) => const Scaffold(body: Center(child: BrandMark(size: 72)))),
      GoRoute(path: '/masuk', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/perusahaan', builder: (_, __) => const TenantPickerScreen()),
      GoRoute(path: '/', builder: (_, __) => const HomeShell()),
      GoRoute(path: '/bayar', builder: (_, __) => const PayScreen()),
      GoRoute(
        path: '/selesai',
        builder: (_, state) {
          final extra = Map<String, dynamic>.from(state.extra as Map? ?? const {});
          return SaleDoneScreen(sale: Map<String, dynamic>.from(extra['sale'] as Map? ?? const {}), printResult: extra['print'] as String?);
        },
      ),
      GoRoute(path: '/riwayat', builder: (_, __) => const HistoryScreen()),
      GoRoute(
        path: '/ai/percakapan',
        builder: (_, state) => AiChatScreen(conversationId: int.tryParse(state.uri.queryParameters['id'] ?? ''), initialText: state.extra is String ? state.extra as String : null),
      ),
      // Pusat Bantuan (isi platform, cukup login).
      GoRoute(path: '/bantuan', builder: (_, __) => const HelpHomeScreen()),
      GoRoute(path: '/bantuan/kategori/:slug', builder: (_, state) => HelpCategoryScreen(slug: state.pathParameters['slug'] ?? '')),
      GoRoute(path: '/bantuan/artikel/:slug', builder: (_, state) => HelpArticleScreen(slug: state.pathParameters['slug'] ?? '')),
      GoRoute(path: '/printer', builder: (_, __) => const PrinterSettingsScreen()),
      GoRoute(path: '/sync', builder: (_, __) => const SyncStatusScreen()),
      GoRoute(path: '/tutup-kasir', builder: (_, __) => const ShiftCloseScreen()),
      // Laporan (periode dipilih di tab Laporan, ikut ke semua rincian).
      GoRoute(path: '/laporan/ringkasan', builder: (_, __) => const SalesSummaryScreen()),
      GoRoute(path: '/laporan/peringkat/:kind', builder: (_, state) => RankedReportScreen(kind: state.pathParameters['kind'] ?? 'by-product')),
      GoRoute(path: '/laporan/per-jam', builder: (_, __) => const HourlyReportScreen()),
      GoRoute(path: '/laporan/umur/:kind', builder: (_, state) => AgingReportScreen(kind: state.pathParameters['kind'] ?? 'receivables')),
      GoRoute(path: '/laporan/laba-rugi', builder: (_, __) => const ProfitLossScreen()),
      GoRoute(path: '/laporan/arus-kas', builder: (_, __) => const CashFlowScreen()),
      GoRoute(path: '/laporan/shift', builder: (_, __) => const ShiftsScreen()),
      GoRoute(path: '/laporan/shift/:id', builder: (_, state) => ShiftDetailScreen(id: int.tryParse(state.pathParameters['id'] ?? '') ?? 0)),
      // Catatan: rincian dokumen dan bagian sebagai layar sendiri.
      GoRoute(
        path: '/catatan/bagian/:section',
        builder: (_, state) => RecordSectionScreen(
          section: RecordSection.values.firstWhere((section) => section.name == state.pathParameters['section'], orElse: () => RecordSection.sales),
          initialParams: state.uri.queryParameters,
        ),
      ),
      GoRoute(path: '/catatan/penjualan/:id', builder: (_, state) => SaleDetailScreen(id: int.tryParse(state.pathParameters['id'] ?? '') ?? 0)),
      GoRoute(path: '/catatan/pembayaran/:kind/:id', builder: (_, state) => PaymentDetailScreen(kind: state.pathParameters['kind'] ?? 'in', id: int.tryParse(state.pathParameters['id'] ?? '') ?? 0)),
      GoRoute(path: '/catatan/pembelian/:id', builder: (_, state) => PurchaseDetailScreen(id: int.tryParse(state.pathParameters['id'] ?? '') ?? 0)),
      GoRoute(path: '/catatan/pelanggan/:id', builder: (_, state) => CustomerDetailScreen(id: int.tryParse(state.pathParameters['id'] ?? '') ?? 0)),
      GoRoute(path: '/catatan/pemasok/:id', builder: (_, state) => SupplierDetailScreen(id: int.tryParse(state.pathParameters['id'] ?? '') ?? 0)),
      GoRoute(path: '/catatan/stok/:id', builder: (_, state) => StockItemScreen(productId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0, item: state.extra is StockLevel ? state.extra as StockLevel : null)),
      GoRoute(
        path: '/catatan/lampiran',
        builder: (_, state) => AttachmentScreen(attachment: state.extra is RecordAttachment ? state.extra as RecordAttachment : const RecordAttachment(index: 0, name: 'Lampiran')),
      ),
    ],
  );
});
