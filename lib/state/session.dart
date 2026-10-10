import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/config.dart';
import '../data/api_client.dart';
import '../data/app_storage.dart';
import '../data/local_db.dart';
import '../data/outbox_store.dart';
import '../domain/models.dart';

/// Diisi di main() dengan penyimpanan yang sudah dimuat.
final storageProvider = Provider<AppStorage>((ref) => throw UnimplementedError('storageProvider belum diisi'));

/// Cara membuat klien API (diganti di tes): dipakai login/`me`/keluar dan
/// workspace tiap perusahaan.
final apiFactoryProvider = Provider<ApiClient Function(String baseUrl, String? token, int? tenantId, int? Function() outboxCount)>((ref) {
  return (baseUrl, token, tenantId, outboxCount) => ApiClient(baseUrl: baseUrl, token: token, tenantId: tenantId, outboxCount: outboxCount);
});

/// Satu perusahaan yang ditolak aplikasi HP (lihat `akses_hp_tidak_tersedia`).
class DeniedTenant {
  const DeniedTenant({required this.name, this.id, this.slug, this.reason, this.unlockPlan});

  factory DeniedTenant.fromJson(Map<String, dynamic> json) => DeniedTenant(
        id: json['id'] is int ? json['id'] as int : int.tryParse('${json['id']}'),
        slug: (json['slug']?.toString() ?? '').trim().isEmpty ? null : json['slug'].toString(),
        name: json['name']?.toString() ?? 'Perusahaan',
        reason: json['reason']?.toString(),
        unlockPlan: json['unlock_plan']?.toString(),
      );

  final int? id;

  /// Slug website perusahaan (`/app/{slug}/langganan`); null dari server lama.
  final String? slug;
  final String name;

  /// `trial` | `tanpa_paket` | `paket_tanpa_hp` | `langganan_tidak_aktif`.
  final String? reason;

  /// Paket termurah yang sudah termasuk aplikasi HP (mis. "Starter").
  final String? unlockPlan;

  /// Alasan dalam bahasa sehari-hari.
  String get reasonLabel => switch (reason) {
        'trial' => 'masih masa trial',
        'tanpa_paket' => 'belum memilih paket berbayar',
        'paket_tanpa_hp' => unlockPlan == null ? 'paketnya belum termasuk aplikasi HP' : 'paketnya belum termasuk aplikasi HP (mulai paket $unlockPlan)',
        'langganan_tidak_aktif' => 'langganannya sudah berakhir atau dihentikan',
        _ => 'belum bisa memakai aplikasi HP',
      };
}

/// Pesan "aplikasi HP tidak tersedia" untuk layar Masuk / Pilih perusahaan.
class AccessNotice {
  const AccessNotice({required this.message, this.tenants = const []});

  /// Dari galat 403 `akses_hp_tidak_tersedia` / `langganan_tidak_aktif`.
  /// [fallbackTenant] dipakai bila server tidak menyertakan daftar perusahaan.
  factory AccessNotice.fromError(ApiException error, {String? fallbackTenant, String? fallbackSlug}) {
    final raw = error.data?['tenants'];
    final tenants = <DeniedTenant>[
      if (raw is List)
        for (final item in raw)
          if (item is Map) DeniedTenant.fromJson(Map<String, dynamic>.from(item)),
    ];
    if (tenants.isEmpty && fallbackTenant != null) {
      tenants.add(DeniedTenant(name: fallbackTenant, slug: fallbackSlug, reason: error.code == ApiException.subscriptionInactiveCode ? 'langganan_tidak_aktif' : null));
    }
    final message = error.message.trim().isNotEmpty
        ? error.message
        : 'Aplikasi HP Infois hanya untuk perusahaan dengan paket berbayar yang aktif dan termasuk aplikasi HP. Kelola paket lewat website: dashboard.infois.ai › Langganan.';
    return AccessNotice(message: message, tenants: tenants);
  }

  final String message;
  final List<DeniedTenant> tenants;

  /// Perusahaan yang halaman Langganan-nya dibuka tombol "Lihat paket".
  String? get billingSlug => tenants.map((tenant) => tenant.slug).whereType<String>().firstOrNull;
}

/// Halaman website: dasbor / Langganan satu perusahaan. Rute web Infois
/// selalu memakai slug perusahaan (`/app/{slug}/langganan`); tanpa slug
/// dibuka `/app` (website memilih perusahaan terakhir).
String tenantWebPath(String? slug, [String page = '']) => slug == null || slug.trim().isEmpty ? '/app' : '/app/${Uri.encodeComponent(slug.trim())}$page';

/// Halaman Langganan (paket & koin) perusahaan [slug].
String billingPath(String? slug) => tenantWebPath(slug, '/langganan');

class SessionState {
  const SessionState({required this.serverUrl, this.token, this.user, this.tenants = const [], this.tenantId, this.notice});

  final String serverUrl;
  final String? token;
  final SessionUser? user;
  final List<TenantSummary> tenants;
  final int? tenantId;

  /// Pesan sekali tampil di layar Masuk / Pilih perusahaan (mis. perusahaan
  /// dilepas karena paketnya tidak termasuk aplikasi HP).
  final AccessNotice? notice;

  bool get loggedIn => token != null && user != null;

  TenantSummary? get tenant {
    for (final tenant in tenants) {
      if (tenant.id == tenantId) {
        return tenant;
      }
    }
    return null;
  }

  /// Alamat web Infois (tanpa `/` di akhir) + [path], mis. `/app/{slug}/langganan`.
  String webUrl(String path) => '${serverUrl.trim().replaceAll(RegExp(r'/+$'), '')}$path';

  SessionState copyWith({String? serverUrl, String? token, SessionUser? user, List<TenantSummary>? tenants, int? tenantId, bool clearTenant = false, AccessNotice? notice, bool clearNotice = false}) => SessionState(
        serverUrl: serverUrl ?? this.serverUrl,
        token: token ?? this.token,
        user: user ?? this.user,
        tenants: tenants ?? this.tenants,
        tenantId: clearTenant ? null : (tenantId ?? this.tenantId),
        notice: clearNotice ? null : (notice ?? this.notice),
      );
}

/// Login per HP, daftar perusahaan, dan perusahaan aktif.
class SessionController extends AsyncNotifier<SessionState> {
  AppStorage get _storage => ref.read(storageProvider);

  @override
  Future<SessionState> build() async {
    final storage = ref.watch(storageProvider);
    final token = await storage.token();
    final saved = storage.session();
    return SessionState(
      serverUrl: storage.serverUrl,
      token: token,
      user: token == null ? null : saved?.user,
      tenants: token == null ? const [] : (saved?.tenants ?? const []),
      tenantId: token == null ? null : storage.tenantId,
    );
  }

  SessionState get _current => state.valueOrNull ?? SessionState(serverUrl: _storage.serverUrl);

  ApiClient _api({String? token}) => ref.read(apiFactoryProvider)(_current.serverUrl, token, null, () => null);

  Future<void> setServerUrl(String url) async {
    await _storage.setServerUrl(url);
    state = AsyncData(_current.copyWith(serverUrl: _storage.serverUrl));
  }

  Future<void> login({required String email, required String password, required String deviceName}) async {
    final response = await _api().post('auth/login', data: {
      'email': email.trim(),
      'password': password,
      'device_name': deviceName.trim().isEmpty ? 'HP Android' : deviceName.trim(),
      'device_uid': await _storage.deviceUid(),
      'platform': Platform.isAndroid ? 'android' : Platform.operatingSystem,
      'app_version': AppConfig.version,
    });
    final token = response['token'] as String;
    final user = SessionUser.fromJson(Map<String, dynamic>.from(response['user'] as Map));
    final tenants = _eligible(response['tenants']);
    await _storage.setToken(token);
    await _storage.setSession(user, tenants);
    final tenantId = tenants.length == 1 ? tenants.first.id : null;
    await _storage.setTenantId(tenantId);
    state = AsyncData(SessionState(serverUrl: _current.serverUrl, token: token, user: user, tenants: tenants, tenantId: tenantId));
  }

  /// Perbarui daftar perusahaan + hak akses (mis. role diubah di web).
  Future<void> refreshMe() async {
    final current = _current;
    if (!current.loggedIn) {
      return;
    }
    try {
      final response = await _api(token: current.token).get('me');
      final user = SessionUser.fromJson(Map<String, dynamic>.from(response['user'] as Map));
      final tenants = _eligible(response['tenants']);
      await _storage.setSession(user, tenants);
      final stillMember = tenants.any((tenant) => tenant.id == current.tenantId);
      if (!stillMember) {
        await _storage.setTenantId(null);
      }
      state = AsyncData(_current.copyWith(user: user, tenants: tenants, clearTenant: !stillMember));
    } on ApiException catch (error) {
      if (error.unauthenticated) {
        await _forgetLogin();
      } else if (error.status == 403 && error.code == ApiException.mobileAccessDeniedCode) {
        // Tidak ada lagi perusahaan yang boleh memakai aplikasi HP: lupakan
        // login dan cabut tokennya (server tidak mencabut lewat /me) supaya
        // HP ini tidak tetap terdaftar aktif di Tim & Akses › Perangkat.
        final token = current.token;
        await _forgetLogin(notice: AccessNotice.fromError(error));
        _revokeQuietly(token);
      }
    } on Object {
      // Jawaban server tidak sesuai: tetap pakai daftar terakhir.
    }
  }

  /// Hanya perusahaan yang boleh memakai aplikasi HP (server sudah menyaring;
  /// `mobile_eligible: false` tetap dibuang bila ada).
  static List<TenantSummary> _eligible(Object? raw) => [
        for (final tenant in raw is List ? raw : const [])
          if (tenant is Map && tenant['mobile_eligible'] != false) TenantSummary.fromJson(Map<String, dynamic>.from(tenant)),
      ];

  /// Server menolak aplikasi HP untuk [tenantId] (403 `akses_hp_tidak_tersedia`
  /// / `langganan_tidak_aktif`) saat sedang dipakai: lupakan perusahaan itu di
  /// HP lalu kembali ke Pilih perusahaan (atau Masuk bila tidak ada yang
  /// tersisa) dengan pesannya. Data lokal (termasuk transaksi yang belum
  /// terkirim) tidak dihapus: terkirim lagi bila paketnya diaktifkan.
  Future<void> dropTenant(int tenantId, ApiException error) async {
    final current = _current;
    if (!current.loggedIn) {
      return;
    }
    final dropped = current.tenants.where((tenant) => tenant.id == tenantId).firstOrNull;
    if (dropped == null && current.tenantId != tenantId) {
      return;
    }
    final notice = AccessNotice.fromError(error, fallbackTenant: dropped?.name, fallbackSlug: dropped?.slug);
    final remaining = [for (final tenant in current.tenants) if (tenant.id != tenantId) tenant];
    if (remaining.isEmpty) {
      final token = current.token;
      await _forgetLogin(notice: notice);
      _revokeQuietly(token);
      return;
    }
    await _storage.setSession(current.user, remaining);
    await _storage.setTenantId(null);
    state = AsyncData(current.copyWith(tenants: remaining, clearTenant: true, notice: notice));
  }

  /// Cabut token di server tanpa menunggu (offline / galat diabaikan).
  void _revokeQuietly(String? token) {
    if (token != null) {
      unawaited(_api(token: token).post('auth/logout', timeout: logoutTimeout).then<void>((_) {}, onError: (Object _) {}));
    }
  }

  /// Pesan di layar Masuk / Pilih perusahaan sudah dibaca.
  void clearNotice() {
    final current = state.valueOrNull;
    if (current?.notice != null) {
      state = AsyncData(current!.copyWith(clearNotice: true));
    }
  }

  /// Perbarui menu satu perusahaan dari hasil sinkron.
  ///
  /// Bila menunya berubah (peran diubah di web) atau sesi lama belum punya
  /// daftar permission, `GET /me` dipanggil di belakang supaya hak lihat di
  /// tab Catatan ikut berubah tanpa harus keluar-masuk.
  Future<void> updateMenus(int tenantId, Menus menus) async {
    final current = _current;
    final previous = current.tenants.where((tenant) => tenant.id == tenantId).firstOrNull;
    final changed = previous != null && (previous.permissions == null || jsonEncode(previous.menus.toJson()) != jsonEncode(menus.toJson()));
    final tenants = [
      for (final tenant in current.tenants)
        tenant.id == tenantId
            ? TenantSummary(id: tenant.id, slug: tenant.slug, name: tenant.name, role: tenant.role, roleLabel: tenant.roleLabel, active: tenant.active, menus: menus, permissions: tenant.permissions)
            : tenant,
    ];
    await _storage.setSession(current.user, tenants);
    state = AsyncData(current.copyWith(tenants: tenants));
    if (changed) {
      unawaited(refreshMe().catchError((Object _) {}));
    }
  }

  Future<void> selectTenant(int? tenantId) async {
    await _storage.setTenantId(tenantId);
    state = AsyncData(_current.copyWith(tenantId: tenantId, clearTenant: tenantId == null, clearNotice: tenantId != null));
  }

  /// Batas waktu mencabut token saat keluar: offline / server lambat tidak
  /// boleh menahan tombol Keluar.
  static const Duration logoutTimeout = Duration(seconds: 8);

  /// Keluar: token dicabut di server (bila online) dan data lokal semua
  /// perusahaan user ini dihapus dari HP. Selalu berakhir di layar Masuk,
  /// juga saat offline, token sudah ditolak server (401), atau database HP
  /// sudah tertutup.
  Future<void> logout() async {
    final current = _current;
    final token = current.token;
    final userId = current.user?.id;
    try {
      if (token != null) {
        await _api(token: token).post('auth/logout', timeout: logoutTimeout);
      }
    } catch (_) {
      // Offline / 401 / galat lain: token tetap dihapus dari HP.
    } finally {
      // Sesi dihapus dulu: layar pindah ke Masuk dan workspace menutup
      // database-nya; baru setelah itu file database dihapus.
      await _forgetLogin();
    }
    if (userId != null) {
      await deleteLocalData(userId);
    }
  }

  Future<void> _forgetLogin({AccessNotice? notice}) async {
    try {
      await _storage.clearSession();
    } finally {
      state = AsyncData(SessionState(serverUrl: _current.serverUrl, notice: notice));
    }
  }

  /// Dipanggil bila server menolak token (dicabut / kedaluwarsa).
  Future<void> expire() => _forgetLogin();

  /// Jumlah transaksi belum terkirim di database perusahaan lain milik user
  /// ini di HP (selain [exceptTenantId]); dipakai peringatan sebelum keluar.
  /// Diganti di tes.
  static Future<int> Function(int userId, {int? exceptTenantId}) unsentElsewhere = _countUnsentInFiles;

  /// Jumlah pesanan tersimpan (open bill, belum dibayar) di database
  /// perusahaan lain milik user ini di HP (selain [exceptTenantId]). Pesanan
  /// tersimpan tidak pernah dikirim ke server: ikut hilang saat keluar.
  /// Diganti di tes.
  static Future<int> Function(int userId, {int? exceptTenantId}) heldElsewhere = _countHeldInFiles;

  static Future<int> _countUnsentInFiles(int userId, {int? exceptTenantId}) =>
      _countInFiles(userId, exceptTenantId, (local) => OutboxStore(local).pendingCount());

  static Future<int> _countHeldInFiles(int userId, {int? exceptTenantId}) => _countInFiles(
        userId,
        exceptTenantId,
        (local) async => Sqflite.firstIntValue(await local.db.rawQuery('SELECT COUNT(*) FROM held_orders')) ?? 0,
      );

  static Future<int> _countInFiles(int userId, int? exceptTenantId, Future<int> Function(LocalDb local) count) async {
    var total = 0;
    try {
      final directory = Directory(await getDatabasesPath());
      if (!directory.existsSync()) {
        return 0;
      }
      final pattern = RegExp('^infois_u${userId}_t(\\d+)\\.db\$');
      for (final file in directory.listSync()) {
        final match = pattern.firstMatch(p.basename(file.path));
        if (match == null || int.tryParse(match.group(1)!) == exceptTenantId) {
          continue;
        }
        try {
          final local = await LocalDb.open(file.path);
          try {
            total += await count(local);
          } finally {
            await local.close();
          }
        } catch (_) {
          // File rusak / terkunci: lewati.
        }
      }
    } catch (_) {
      // Folder database tidak terbaca: anggap tidak ada.
    }
    return total;
  }

  /// Penghapus file database lokal (diganti di tes).
  @visibleForTesting
  static Future<void> Function(int userId) deleteLocalData = _deleteLocalDataFiles;

  static Future<void> _deleteLocalDataFiles(int userId) async {
    try {
      final directory = Directory(await getDatabasesPath());
      if (!directory.existsSync()) {
        return;
      }
      for (final file in directory.listSync()) {
        final name = p.basename(file.path);
        if (name.startsWith('infois_u${userId}_t')) {
          await deleteDatabase(file.path);
        }
      }
    } catch (_) {
      // Abaikan: file akan ditimpa saat login berikutnya.
    }
  }
}

final sessionProvider = AsyncNotifierProvider<SessionController, SessionState>(SessionController.new);
