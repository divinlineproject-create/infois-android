import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/reports_api.dart';
import '../domain/report_models.dart';
import 'session.dart';
import 'workspace.dart';

/// Klien Laporan untuk perusahaan aktif (null bila belum ada perusahaan).
final reportsApiProvider = Provider<ReportsApi?>((ref) {
  final workspace = ref.watch(workspaceProvider).valueOrNull;
  return workspace == null ? null : ReportsApi(workspace.api);
});

/// Periode yang dipilih di tab Laporan; dipakai semua layar rincian dan
/// bertahan selama aplikasi dibuka (kembali ke Bulan ini saat ganti perusahaan).
final reportPeriodProvider = StateProvider<ReportPeriodChoice>((ref) {
  ref.watch(reportsApiProvider);
  return ReportPeriodChoice.bulanIni;
});

/// Token HP sudah tidak berlaku (401): keluar seperti yang dilakukan sinkron.
void _expireIfUnauthenticated(Ref ref, ApiException error) {
  if (error.unauthenticated) {
    unawaited(ref.read(sessionProvider.notifier).expire());
  }
}

Future<T?> _guard<T>(Ref ref, ReportsApi? api, Future<T> Function(ReportsApi api) request) async {
  if (api == null) {
    return null;
  }
  try {
    return await request(api);
  } on ApiException catch (error) {
    _expireIfUnauthenticated(ref, error);
    rethrow;
  }
}

/// Ubin beranda Laporan (hari ini, kemarin, bulan ini, kas, piutang, stok).
final reportOverviewProvider = FutureProvider<ReportOverview?>((ref) => _guard(ref, ref.watch(reportsApiProvider), (api) => api.overview()));

/// Ringkasan penjualan untuk periode yang dipilih (grafik + metode bayar).
final salesSummaryProvider = FutureProvider<SalesSummary?>((ref) {
  final period = ref.watch(reportPeriodProvider);
  return _guard(ref, ref.watch(reportsApiProvider), (api) => api.salesSummary(period));
});

/// Penjualan per jam (24 baris) untuk periode yang dipilih.
final hourlyReportProvider = FutureProvider.autoDispose<RankedReport?>((ref) {
  final period = ref.watch(reportPeriodProvider);
  return _guard(ref, ref.watch(reportsApiProvider), (api) => api.ranked('by-hour', period));
});

final profitLossProvider = FutureProvider.autoDispose<ProfitLossReport?>((ref) {
  final period = ref.watch(reportPeriodProvider);
  return _guard(ref, ref.watch(reportsApiProvider), (api) => api.profitLoss(period));
});

final cashFlowProvider = FutureProvider.autoDispose<CashFlowReport?>((ref) {
  final period = ref.watch(reportPeriodProvider);
  return _guard(ref, ref.watch(reportsApiProvider), (api) => api.cashFlow(period));
});

/// Rincian satu shift (ringkasan dihitung ulang + nota).
final shiftDetailProvider = FutureProvider.autoDispose.family<ShiftDetail?, int>((ref, id) => _guard(ref, ref.watch(reportsApiProvider), (api) => api.shift(id)));

/// Daftar peringkat yang dimuat per halaman.
class RankedState {
  const RankedState({required this.report, this.rows = const [], this.loadingMore = false, this.loadMoreError});

  final RankedReport report;

  /// Semua baris yang sudah dimuat (gabungan halaman).
  final List<RankRow> rows;
  final bool loadingMore;

  /// Pesan bila halaman berikutnya gagal dimuat (tombol Coba lagi di kaki daftar).
  final String? loadMoreError;

  bool get hasMore => report.nextCursor != null;

  RankedState copyWith({RankedReport? report, List<RankRow>? rows, bool? loadingMore, String? loadMoreError, bool clearError = false}) => RankedState(
        report: report ?? this.report,
        rows: rows ?? this.rows,
        loadingMore: loadingMore ?? this.loadingMore,
        loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
      );
}

/// Pesan untuk halaman berikutnya yang gagal dimuat.
String _loadMoreMessage(Object error) => error is ApiException ? error.message : 'Data dari server belum bisa dibaca.';

/// Laporan peringkat (`by-product`, `by-customer`, `by-cashier`, `by-device`)
/// untuk periode yang dipilih; halaman berikutnya lewat [loadMore].
class RankedReportController extends AutoDisposeFamilyAsyncNotifier<RankedState, String> {
  static const int pageSize = 20;

  /// Naik setiap kali daftar dimuat ulang (periode berubah / tarik ulang);
  /// halaman lanjutan dari muatan lama dibuang.
  int _generation = 0;

  @override
  Future<RankedState> build(String arg) async {
    _generation++;
    final api = ref.watch(reportsApiProvider);
    final period = ref.watch(reportPeriodProvider);
    if (api == null) {
      return RankedState(report: RankedReport(period: ReportPeriod(preset: period.preset, from: '', to: '', label: period.label), totals: const SalesTotals()));
    }
    try {
      final report = await api.ranked(arg, period, limit: pageSize);
      return RankedState(report: report, rows: report.rows);
    } on ApiException catch (error) {
      _expireIfUnauthenticated(ref, error);
      rethrow;
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => build(arg));
  }

  /// Halaman berikutnya. Setelah gagal, hanya dicoba lagi lewat tombol
  /// ([retry]) supaya gulir tidak mengulang permintaan terus-menerus.
  Future<void> loadMore({bool retry = false}) async {
    final api = ref.read(reportsApiProvider);
    final current = state.valueOrNull;
    if (api == null || current == null || !current.hasMore || current.loadingMore || state.isLoading || (current.loadMoreError != null && !retry)) {
      return;
    }
    final generation = _generation;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await api.ranked(arg, ref.read(reportPeriodProvider), limit: pageSize, cursor: current.report.nextCursor);
      if (generation == _generation) {
        state = AsyncData(RankedState(report: page, rows: [...current.rows, ...page.rows]));
      }
    } catch (error) {
      if (error is ApiException) {
        _expireIfUnauthenticated(ref, error);
      }
      if (generation == _generation) {
        state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: _loadMoreMessage(error)));
      }
    }
  }
}

final rankedReportProvider = AsyncNotifierProvider.autoDispose.family<RankedReportController, RankedState, String>(RankedReportController.new);

class AgingState {
  const AgingState({required this.report, this.rows = const [], this.loadingMore = false, this.loadMoreError});

  final AgingReport report;
  final List<AgingRow> rows;
  final bool loadingMore;
  final String? loadMoreError;

  bool get hasMore => report.nextCursor != null;

  AgingState copyWith({AgingReport? report, List<AgingRow>? rows, bool? loadingMore, String? loadMoreError, bool clearError = false}) => AgingState(
        report: report ?? this.report,
        rows: rows ?? this.rows,
        loadingMore: loadingMore ?? this.loadingMore,
        loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
      );
}

/// Umur piutang (`receivables`) / hutang (`payables`) per hari ini.
class AgingReportController extends AutoDisposeFamilyAsyncNotifier<AgingState, String> {
  static const int pageSize = 20;

  int _generation = 0;

  @override
  Future<AgingState> build(String arg) async {
    _generation++;
    final api = ref.watch(reportsApiProvider);
    if (api == null) {
      return const AgingState(report: AgingReport(asOf: ''));
    }
    try {
      final report = await api.aging(arg, limit: pageSize);
      return AgingState(report: report, rows: report.rows);
    } on ApiException catch (error) {
      _expireIfUnauthenticated(ref, error);
      rethrow;
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => build(arg));
  }

  Future<void> loadMore({bool retry = false}) async {
    final api = ref.read(reportsApiProvider);
    final current = state.valueOrNull;
    if (api == null || current == null || !current.hasMore || current.loadingMore || state.isLoading || (current.loadMoreError != null && !retry)) {
      return;
    }
    final generation = _generation;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await api.aging(arg, limit: pageSize, cursor: current.report.nextCursor);
      if (generation == _generation) {
        state = AsyncData(AgingState(report: page, rows: [...current.rows, ...page.rows]));
      }
    } catch (error) {
      if (error is ApiException) {
        _expireIfUnauthenticated(ref, error);
      }
      if (generation == _generation) {
        state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: _loadMoreMessage(error)));
      }
    }
  }
}

final agingReportProvider = AsyncNotifierProvider.autoDispose.family<AgingReportController, AgingState, String>(AgingReportController.new);

class ShiftsState {
  const ShiftsState({this.items = const [], this.nextCursor, this.loadingMore = false, this.loadMoreError});

  final List<ShiftReport> items;
  final String? nextCursor;
  final bool loadingMore;
  final String? loadMoreError;

  bool get hasMore => nextCursor != null;

  ShiftsState copyWith({List<ShiftReport>? items, String? nextCursor, bool clearCursor = false, bool? loadingMore, String? loadMoreError, bool clearError = false}) => ShiftsState(
        items: items ?? this.items,
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
        loadingMore: loadingMore ?? this.loadingMore,
        loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
      );
}

/// Shift kasir yang sudah ditutup, terbaru dulu, disaring periode yang dipilih.
class ShiftsController extends AutoDisposeAsyncNotifier<ShiftsState> {
  int _generation = 0;

  @override
  Future<ShiftsState> build() async {
    _generation++;
    final api = ref.watch(reportsApiProvider);
    final period = ref.watch(reportPeriodProvider);
    if (api == null) {
      return const ShiftsState();
    }
    try {
      final page = await api.shifts(period: period);
      return ShiftsState(items: page.items, nextCursor: page.nextCursor);
    } on ApiException catch (error) {
      _expireIfUnauthenticated(ref, error);
      rethrow;
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }

  Future<void> loadMore({bool retry = false}) async {
    final api = ref.read(reportsApiProvider);
    final current = state.valueOrNull;
    if (api == null || current == null || !current.hasMore || current.loadingMore || state.isLoading || (current.loadMoreError != null && !retry)) {
      return;
    }
    final generation = _generation;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await api.shifts(period: ref.read(reportPeriodProvider), cursor: current.nextCursor);
      if (generation != _generation) {
        return;
      }
      final known = {for (final item in current.items) item.id};
      state = AsyncData(ShiftsState(items: [...current.items, ...page.items.where((item) => !known.contains(item.id))], nextCursor: page.nextCursor));
    } catch (error) {
      if (error is ApiException) {
        _expireIfUnauthenticated(ref, error);
      }
      if (generation == _generation) {
        state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: _loadMoreMessage(error)));
      }
    }
  }
}

final shiftsProvider = AsyncNotifierProvider.autoDispose<ShiftsController, ShiftsState>(ShiftsController.new);
