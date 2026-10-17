import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' show DatabaseException;

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
    this.maintenance,
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

  /// Pesan pemeliharaan dari server (503 `kanal_pemeliharaan`), atau null.
  final String? maintenance;

  SyncState copyWith({ConnectionStatus? connection, bool? syncing, int? pending, DateTime? lastSyncAt, String? message, bool clearMessage = false, bool? mustUpdate, String? maintenance, bool clearMaintenance = false}) => SyncState(
        connection: connection ?? this.connection,
        syncing: syncing ?? this.syncing,
        pending: pending ?? this.pending,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        message: clearMessage ? null : (message ?? this.message),
        mustUpdate: mustUpdate ?? this.mustUpdate,
        maintenance: clearMaintenance ? null : (maintenance ?? this.maintenance),
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

  /// Coba lagi saat pemeliharaan (server: Retry-After 300 detik).
  static const Duration maintenanceRetry = Duration(minutes: 5);

  @override
  SyncState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _stop();
    });
    ref.listen(workspaceProvider, (previous, next) {
      final workspace = next.valueOrNull;
      if (next is AsyncData<Workspace?> && workspace == null) {
        // Keluar / belum memilih perusahaan: hentikan pemicu sinkron.
        _stop();
        if (previous != null) {
          state = const SyncState();
        }
      } else if (workspace != null && previous?.valueOrNull != workspace) {
        _start();
      }
    }, fireImmediately: true);
    return const SyncState();
  }

  /// Controller sudah dilepas (aplikasi ditutup / tes selesai): pekerjaan
  /// async yang masih berjalan berhenti tanpa menyentuh ref/state.
  bool _disposed = false;

  /// Workspace yang siap dipakai (bukan yang sedang ditutup).
  Workspace? get _workspace => _disposed ? null : readyWorkspace(ref);

  void _stop() {
    _connectivity?.cancel();
    _connectivity = null;
    _timer?.cancel();
    _timer = null;
    _retry?.cancel();
    _retry = null;
  }

  void _start() {
    _connectivity?.cancel();
    _connectivity = ref.read(connectivityStreamProvider).listen((results) {
      if (results.every((result) => result == ConnectivityResult.none)) {
        state = state.copyWith(connection: ConnectionStatus.offline);
      } else {
        _autoSync();
      }
    });
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _autoSync());
    unawaited(refreshPending());
    unawaited(syncNow());
  }

  Future<void> refreshPending() async {
    final workspace = _workspace;
    if (workspace == null) {
      return;
    }
    try {
      final pending = await workspace.local.hold(() => workspace.outbox.pendingCount());
      workspace.pendingCache = pending;
      if (!_disposed) {
        state = state.copyWith(pending: pending);
      }
    } on DatabaseException catch (error) {
      _recoverClosed(workspace, error);
    }
  }

  /// Cek internet (ping 5 detik), kirim outbox, lalu tarik data master.
  Future<void> syncNow({bool forceFull = false}) async {
    final workspace = _workspace;
    if (workspace == null) {
      if (!_disposed) {
        _reopenIfClosed();
      }
      return;
    }
    _heartbeat(workspace);
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        final current = _workspace;
        if (current == null) {
          break;
        }
        // Database tetap terbuka selama satu siklus, walau perusahaan diganti
        // atau pengguna keluar di tengah jalan.
        await current.local.hold(() => _cycle(current, forceFull: forceFull));
      } while (_again);
    } finally {
      _running = false;
    }
  }

  /// Pemicu otomatis (tiap 15 menit, kembali online, coba ulang) hanya saat
  /// aplikasi tampil. Di belakang layar sinkron latar (WorkManager) yang
  /// bekerja, sehingga tidak ada dua penulis di file database yang sama
  /// (`database is locked`). Saat aplikasi dibuka lagi, sinkron jalan
  /// (lihat InfoisApp.didChangeAppLifecycleState).
  void _autoSync() {
    if (autoSyncAllowed(_lifecycleState())) {
      unawaited(syncNow());
    }
  }

  static AppLifecycleState? _lifecycleState() {
    try {
      return WidgetsBinding.instance.lifecycleState;
    } catch (_) {
      return null;
    }
  }

  /// Boleh sinkron otomatis pada status aplikasi ini (null = belum diketahui
  /// / tes tanpa binding).
  static bool autoSyncAllowed(AppLifecycleState? state) => state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  /// Aplikasi tampil dan menyinkron sendiri: sinkron latar menunggu.
  static void _heartbeat(Workspace workspace) {
    try {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(workspace.storage.markForeground(true).catchError((Object _) {}));
      }
    } catch (_) {
      // Tanpa binding Flutter (tes unit): tidak perlu tanda.
    }
  }

  /// Database workspace aktif tertutup dari luar (bukan karena diganti):
  /// buka ulang lewat workspace baru. Sinkron jalan lagi saat siap.
  void _reopenIfClosed() {
    final value = ref.read(workspaceProvider);
    final workspace = value is AsyncData<Workspace?> ? value.value : null;
    if (workspace != null && !workspace.disposed && !workspace.local.isOpen) {
      _reopen(workspace);
    }
  }

  void _recoverClosed(Workspace workspace, DatabaseException error) {
    if (error.isDatabaseClosedError() && !workspace.disposed) {
      _reopen(workspace);
    }
  }

  DateTime? _lastReopen;

  /// Buka ulang paling sering sekali per 10 detik (tidak berputar terus bila
  /// database memang tidak bisa dibuka).
  void _reopen(Workspace workspace) {
    final now = DateTime.now();
    if (_lastReopen != null && now.difference(_lastReopen!) < const Duration(seconds: 10)) {
      return;
    }
    _lastReopen = now;
    workspace.disposed = true;
    ref.invalidate(workspaceProvider);
  }

  Future<void> _cycle(Workspace workspace, {bool forceFull = false}) async {
    final ping = await workspace.engine.ping();
    if (_disposed || workspace.disposed) {
      return;
    }
    if (!ping.ok) {
      state = state.copyWith(connection: ConnectionStatus.offline, syncing: false);
      await refreshPending();
      return;
    }
    state = state.copyWith(connection: ConnectionStatus.online, syncing: true, mustUpdate: ping.mustUpdate, clearMessage: true);
    try {
      // Setelah outbox terkirim, header X-Outbox-Count langsung 0 (bukan
      // nilai lama) untuk request tarik data di siklus yang sama.
      final summary = await workspace.engine.run(forceFull: forceFull, afterPush: refreshPending);
      if (_disposed) {
        return;
      }
      final menus = await workspace.local.getJson(MetaKeys.menus);
      if (menus != null && !workspace.disposed) {
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
      state = state.copyWith(syncing: false, lastSyncAt: summary.failed ? null : DateTime.now(), message: message, clearMessage: message == null, clearMaintenance: true);
      _setMaintenance(null);
    } on ApiException catch (error) {
      if (_disposed) {
        return;
      }
      if (error.unauthenticated) {
        state = state.copyWith(syncing: false);
        await ref.read(sessionProvider.notifier).expire();
        return;
      }
      if (error.maintenance) {
        // Aplikasi HP dimatikan sementara (Administrator › Kanal Tim AI):
        // tetap masuk, antrean tetap di HP, dicoba lagi beberapa menit lagi.
        state = state.copyWith(syncing: false, connection: ConnectionStatus.online, maintenance: error.message, clearMessage: true);
        _setMaintenance(error.message);
        _retry?.cancel();
        _retry = Timer(maintenanceRetry, _autoSync);
        return;
      }
      if (error.companyClosed) {
        // Perusahaan ditutup pemiliknya: pesan + jumlah belum terkirim, lalu
        // lepas perusahaan ini (sinkron berhenti, tidak dicoba ulang). Data
        // HP dihapus setelah pengguna menekan "Mengerti".
        state = state.copyWith(syncing: false, connection: ConnectionStatus.online, clearMessage: true);
        await ref.read(sessionProvider.notifier).companyGone(workspace.tenant.id, reason: GoneReason.closed, message: error.message, local: workspace.local);
        return;
      }
      state = state.copyWith(syncing: false, connection: error.offline ? ConnectionStatus.offline : ConnectionStatus.online, message: error.message);
      if (error.mobileAccessDenied) {
        // Perusahaan ini sudah dilepas lewat ApiClient.onError (lihat workspace).
        return;
      }
      if (error.notMember) {
        // Dipastikan lewat GET /me: hilang dari daftar = dikeluarkan / ditutup
        // (pesan + hapus setelah Mengerti); masih ada / gagal = dicek lagi pada
        // sinkron berikutnya, tanpa timer coba ulang.
        await ref.read(sessionProvider.notifier).refreshMe(notMemberOf: workspace.tenant.id, local: workspace.local);
      } else if (error.code == 'perangkat_dicabut') {
        await ref.read(sessionProvider.notifier).refreshMe();
      } else {
        _scheduleRetry(workspace);
      }
    } on DatabaseException catch (error) {
      if (_disposed) {
        return;
      }
      if (error.isDatabaseClosedError()) {
        // Database tertutup di tengah sinkron: buka ulang lalu sinkron lagi,
        // tanpa menampilkan "database_closed" ke pengguna.
        state = state.copyWith(syncing: false, clearMessage: true);
        _recoverClosed(workspace, error);
      } else {
        state = state.copyWith(syncing: false, message: 'Data di HP belum bisa diperbarui. Coba lagi.');
        _scheduleRetry(workspace);
      }
    } catch (error) {
      if (_disposed) {
        return;
      }
      // Galat tak terduga (data server tidak sesuai): jangan biarkan status
      // "Menyinkron" menggantung tanpa pesan.
      debugPrint('Sinkron gagal: $error');
      state = state.copyWith(syncing: false, message: 'Sinkron gagal. Coba lagi sebentar lagi.');
      _scheduleRetry(workspace);
    } finally {
      if (!_disposed) {
        ref.read(dataVersionProvider.notifier).state++;
        await refreshPending();
      }
    }
  }

  void _setMaintenance(String? message) {
    if (_disposed) {
      return;
    }
    final notifier = ref.read(maintenanceProvider.notifier);
    if (notifier.state != message) {
      notifier.state = message;
    }
  }

  /// Coba lagi dengan jeda bertambah bila masih ada yang menunggu.
  void _scheduleRetry(Workspace workspace) {
    _retry?.cancel();
    if (!workspace.usable) {
      return;
    }
    workspace.outbox.pending(limit: 1).then((items) {
      if (items.isEmpty) {
        return;
      }
      final delay = Duration(seconds: (5 * (1 << items.first.attempts.clamp(0, 6))).clamp(5, 300));
      _retry = Timer(delay, _autoSync);
    }, onError: (Object _) {});
  }
}

final syncProvider = NotifierProvider<SyncController, SyncState>(SyncController.new);
