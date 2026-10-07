import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../domain/models.dart';
import '../services/sync_engine.dart';
import 'session.dart';
import 'workspace.dart';

enum ConnectionStatus { checking, online, offline }

class SyncState {
  const SyncState({
    this.connection = ConnectionStatus.checking,
    this.syncing = false,
    this.pending = 0,
    this.lastSyncAt,
    this.message,
    this.mustUpdate = false,
  });

  final ConnectionStatus connection;
  final bool syncing;

  /// Transaksi di outbox yang belum terkirim.
  final int pending;
  final DateTime? lastSyncAt;

  /// Pesan singkat hasil sinkron terakhir (galat atau info).
  final String? message;

  /// Versi aplikasi di bawah versi minimum server.
  final bool mustUpdate;

  SyncState copyWith({ConnectionStatus? connection, bool? syncing, int? pending, DateTime? lastSyncAt, String? message, bool clearMessage = false, bool? mustUpdate}) => SyncState(
        connection: connection ?? this.connection,
        syncing: syncing ?? this.syncing,
        pending: pending ?? this.pending,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        message: clearMessage ? null : (message ?? this.message),
        mustUpdate: mustUpdate ?? this.mustUpdate,
      );
}

/// Sumber perubahan jaringan (diganti di tes).
final connectivityStreamProvider = Provider<Stream<List<ConnectivityResult>>>((ref) => Connectivity().onConnectivityChanged);

/// Status Online / Offline / Menyinkron dan pemicu sinkron: saat aplikasi
/// dibuka, saat kembali online, setelah penjualan, tiap 15 menit, dan manual.
class SyncController extends Notifier<SyncState> {
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _timer;
  Timer? _retry;
  bool _running = false;
  bool _again = false;

  static const Duration interval = Duration(minutes: 15);

  @override
  SyncState build() {
    ref.onDispose(() {
      _connectivity?.cancel();
      _timer?.cancel();
      _retry?.cancel();
    });
    ref.listen(workspaceProvider, (previous, next) {
      if (next.valueOrNull != null && previous?.valueOrNull != next.valueOrNull) {
        _start();
      }
    }, fireImmediately: true);
    return const SyncState();
  }

  Workspace? get _workspace => ref.read(workspaceProvider).valueOrNull;

  void _start() {
    _connectivity?.cancel();
    _connectivity = ref.read(connectivityStreamProvider).listen((results) {
      if (results.every((result) => result == ConnectivityResult.none)) {
        state = state.copyWith(connection: ConnectionStatus.offline);
      } else {
        unawaited(syncNow());
      }
    });
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(syncNow()));
    unawaited(refreshPending());
    unawaited(syncNow());
  }

  Future<void> refreshPending() async {
    final workspace = _workspace;
    if (workspace == null) {
      return;
    }
    final pending = await workspace.outbox.pendingCount();
    workspace.pendingCache = pending;
    state = state.copyWith(pending: pending);
  }

  /// Cek internet (ping 5 detik), kirim outbox, lalu tarik data master.
  Future<void> syncNow({bool forceFull = false}) async {
    final workspace = _workspace;
    if (workspace == null) {
      return;
    }
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        await _cycle(workspace, forceFull: forceFull);
      } while (_again);
    } finally {
      _running = false;
    }
  }

  Future<void> _cycle(Workspace workspace, {bool forceFull = false}) async {
    final ping = await workspace.engine.ping();
    if (!ping.ok) {
      state = state.copyWith(connection: ConnectionStatus.offline, syncing: false);
      await refreshPending();
      return;
    }
    state = state.copyWith(connection: ConnectionStatus.online, syncing: true, mustUpdate: ping.mustUpdate, clearMessage: true);
    try {
      final summary = await workspace.engine.run(forceFull: forceFull);
      final menus = await workspace.local.getJson(MetaKeys.menus);
      if (menus != null) {
        await ref.read(sessionProvider.notifier).updateMenus(workspace.tenant.id, Menus.fromJson(menus));
      }
      String? message;
      if (summary.failed) {
        message = summary.error;
        _scheduleRetry(workspace);
      } else if (summary.review > 0) {
        message = '${summary.review} penjualan perlu ditinjau pemilik.';
      } else if (summary.rejected > 0) {
        message = '${summary.rejected} transaksi ditolak server. Lihat Akun › Status sinkron.';
      }
      state = state.copyWith(syncing: false, lastSyncAt: summary.failed ? null : DateTime.now(), message: message, clearMessage: message == null);
    } on ApiException catch (error) {
      if (error.unauthenticated) {
        await ref.read(sessionProvider.notifier).expire();
        return;
      }
      state = state.copyWith(syncing: false, connection: error.offline ? ConnectionStatus.offline : ConnectionStatus.online, message: error.message);
      if (error.code == 'perangkat_dicabut' || error.code == 'langganan_tidak_aktif' || error.code == 'bukan_anggota') {
        await ref.read(sessionProvider.notifier).refreshMe();
      } else {
        _scheduleRetry(workspace);
      }
    } finally {
      ref.read(dataVersionProvider.notifier).state++;
      await refreshPending();
    }
  }

  /// Coba lagi dengan jeda bertambah bila masih ada yang menunggu.
  void _scheduleRetry(Workspace workspace) {
    _retry?.cancel();
    workspace.outbox.pending(limit: 1).then((items) {
      if (items.isEmpty) {
        return;
      }
      final delay = Duration(seconds: (5 * (1 << items.first.attempts.clamp(0, 6))).clamp(5, 300));
      _retry = Timer(delay, () => unawaited(syncNow()));
    });
  }
}

final syncProvider = NotifierProvider<SyncController, SyncState>(SyncController.new);
