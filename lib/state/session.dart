import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/config.dart';
import '../data/api_client.dart';
import '../data/app_storage.dart';
import '../domain/models.dart';

/// Diisi di main() dengan penyimpanan yang sudah dimuat.
final storageProvider = Provider<AppStorage>((ref) => throw UnimplementedError('storageProvider belum diisi'));

class SessionState {
  const SessionState({required this.serverUrl, this.token, this.user, this.tenants = const [], this.tenantId});

  final String serverUrl;
  final String? token;
  final SessionUser? user;
  final List<TenantSummary> tenants;
  final int? tenantId;

  bool get loggedIn => token != null && user != null;

  TenantSummary? get tenant {
    for (final tenant in tenants) {
      if (tenant.id == tenantId) {
        return tenant;
      }
    }
    return null;
  }

  SessionState copyWith({String? serverUrl, String? token, SessionUser? user, List<TenantSummary>? tenants, int? tenantId, bool clearTenant = false}) => SessionState(
        serverUrl: serverUrl ?? this.serverUrl,
        token: token ?? this.token,
        user: user ?? this.user,
        tenants: tenants ?? this.tenants,
        tenantId: clearTenant ? null : (tenantId ?? this.tenantId),
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

  ApiClient _api({String? token}) => ApiClient(baseUrl: _current.serverUrl, token: token);

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
    final tenants = [for (final tenant in response['tenants'] as List) TenantSummary.fromJson(Map<String, dynamic>.from(tenant as Map))];
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
      final tenants = [for (final tenant in response['tenants'] as List) TenantSummary.fromJson(Map<String, dynamic>.from(tenant as Map))];
      await _storage.setSession(user, tenants);
      final stillMember = tenants.any((tenant) => tenant.id == current.tenantId);
      if (!stillMember) {
        await _storage.setTenantId(null);
      }
      state = AsyncData(current.copyWith(user: user, tenants: tenants, clearTenant: !stillMember));
    } on ApiException catch (error) {
      if (error.unauthenticated) {
        await _forgetLogin();
      }
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
    state = AsyncData(_current.copyWith(tenantId: tenantId, clearTenant: tenantId == null));
  }

  /// Keluar: token dicabut di server (bila online) dan data lokal semua
  /// perusahaan user ini dihapus dari HP.
  Future<void> logout() async {
    final current = _current;
    if (current.token != null) {
      try {
        await _api(token: current.token).post('auth/logout');
      } on ApiException {
        // Offline: token tetap dihapus dari HP.
      }
    }
    if (current.user != null) {
      await deleteLocalData(current.user!.id);
    }
    await _forgetLogin();
  }

  Future<void> _forgetLogin() async {
    await _storage.clearSession();
    state = AsyncData(SessionState(serverUrl: _current.serverUrl));
  }

  /// Dipanggil bila server menolak token (dicabut / kedaluwarsa).
  Future<void> expire() => _forgetLogin();

  static Future<void> deleteLocalData(int userId) async {
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
    } on Exception {
      // Abaikan: file akan ditimpa saat login berikutnya.
    }
  }
}

final sessionProvider = AsyncNotifierProvider<SessionController, SessionState>(SessionController.new);
