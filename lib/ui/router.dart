import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/session.dart';
import 'screens/history_screen.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/pay_screen.dart';
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
      GoRoute(path: '/printer', builder: (_, __) => const PrinterSettingsScreen()),
      GoRoute(path: '/sync', builder: (_, __) => const SyncStatusScreen()),
      GoRoute(path: '/tutup-kasir', builder: (_, __) => const ShiftCloseScreen()),
    ],
  );
});
