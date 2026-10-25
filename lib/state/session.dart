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
import '../services/product_photos.dart';

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

/// Mengapa satu perusahaan tidak bisa dipakai lagi di HP ini.
enum GoneReason {
  /// Ditutup pemiliknya (403 `perusahaan_ditutup`).
  closed,

  /// User bukan anggotanya lagi (403 `bukan_anggota` lalu hilang dari
  /// `GET /me`).
  removed,
}

/// Perusahaan yang ditutup / tempat user dikeluarkan. Data HP-nya (termasuk
/// transaksi belum terkirim) tidak bisa dikirim lagi: pesannya tampil di
/// Pilih perusahaan dan layar Masuk, lalu data itu dihapus setelah pengguna
/// menekan "Mengerti" ([SessionController.acknowledgeGone]).
class GoneCompany {
  const GoneCompany({required this.userId, required this.tenantId, required this.name, required this.reason, this.unsent, this.held, this.message});

  factory GoneCompany.fromJson(Map<String, dynamic> json) => GoneCompany(
        userId: (json['user_id'] as num).toInt(),
        tenantId: (json['tenant_id'] as num).toInt(),
        name: json['name']?.toString() ?? 'Perusahaan',
        reason: json['reason'] == 'removed' ? GoneReason.removed : GoneReason.closed,
        unsent: (json['unsent'] as num?)?.toInt(),
        held: (json['held'] as num?)?.toInt(),
        message: json['message']?.toString(),
      );

  final int userId;
  final int tenantId;
  final String name;
  final GoneReason reason;

  /// Transaksi di outbox yang belum terkirim; null = tidak bisa dihitung.
  final int? unsent;

  /// Pesanan tersimpan (belum dibayar); null = tidak bisa dihitung.
  final int? held;

  /// Pesan dari server (bila ada).
  final String? message;

  bool same(int user, int tenant) => userId == user && tenantId == tenant;

  String get title => reason == GoneReason.closed ? '$name sudah ditutup' : 'Anda tidak lagi menjadi anggota $name';

  String get explanation {
    final server = message?.trim() ?? '';
    if (server.isNotEmpty && reason == GoneReason.closed) {
      return '$server HP ini tidak bisa lagi mengirim atau mengambil data perusahaan ini.';
    }
    return reason == GoneReason.closed
        ? 'Pemilik usaha sudah menutup perusahaan ini. HP ini tidak bisa lagi mengirim atau mengambil datanya.'
        : 'Akses Anda ke perusahaan ini sudah dicabut. Hubungi pemilik usaha bila ini keliru.';
  }

  /// Kalimat data yang ikut hilang; null bila tidak ada yang hilang.
  String? get lossWarning {
    if (unsent == null || held == null) {
      return 'Transaksi yang belum terkirim di HP ini (bila ada) tidak bisa dikirim lagi dan ikut terhapus.';
    }
    final parts = <String>[
      if (unsent! > 0) '$unsent transaksi di HP ini belum terkirim dan tidak bisa dikirim lagi.',
      if (held! > 0) '$held pesanan tersimpan (belum dibayar) juga ada di HP ini.',
    ];
    return parts.isEmpty ? null : '${parts.join(' ')} Semuanya ikut terhapus.';
  }

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'tenant_id': tenantId,
        'name': name,
        'reason': reason.name,
        'unsent': unsent,
        'held': held,
        'message': message,
      };
}

class SessionState {
  const SessionState({this.token, this.user, this.tenants = const [], this.tenantId, this.notice, this.gone = const []});

  /// Server aplikasi: tetap sejak build ([AppConfig.serverUrl]), tidak bisa
  /// diganti dari aplikasi.
  String get serverUrl => AppConfig.serverUrl;
  final String? token;
  final SessionUser? user;
  final List<TenantSummary> tenants;
  final int? tenantId;

  /// Pesan sekali tampil di layar Masuk / Pilih perusahaan (mis. perusahaan
  /// dilepas karena paketnya tidak termasuk aplikasi HP).
  final AccessNotice? notice;

  /// Perusahaan yang ditutup / tempat user dikeluarkan, menunggu "Mengerti"
  /// (data HP-nya belum dihapus). Tetap ada setelah login dilupakan.
  final List<GoneCompany> gone;

  /// Pesan perusahaan hilang yang tampil: milik user yang sedang masuk, atau
  /// semuanya di layar Masuk.
  List<GoneCompany> get goneNotices => user == null ? gone : [for (final item in gone) if (item.userId == user!.id) item];

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

  SessionState copyWith({String? token, SessionUser? user, List<TenantSummary>? tenants, int? tenantId, bool clearTenant = false, AccessNotice? notice, bool clearNotice = false, List<GoneCompany>? gone}) => SessionState(
        token: token ?? this.token,
        user: user ?? this.user,
        tenants: tenants ?? this.tenants,
        tenantId: clearTenant ? null : (tenantId ?? this.tenantId),
        notice: clearNotice ? null : (notice ?? this.notice),
        gone: gone ?? this.gone,
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
      token: token,
      user: token == null ? null : saved?.user,
      tenants: token == null ? const [] : (saved?.tenants ?? const []),
      tenantId: token == null ? null : storage.tenantId,
      gone: goneIn(storage),
    );
  }

  SessionState get _current => state.valueOrNull ?? const SessionState();

  ApiClient _api({String? token}) => ref.read(apiFactoryProvider)(_current.serverUrl, token, null, () => null);

  /// Masuk. Akun dengan verifikasi dua langkah: tanpa [code] server menjawab
  /// 401 `butuh_kode_2fa` (+ `metode_2fa`; kode email dikirim saat itu), lalu
  /// login diulang dengan [code] (6 angka atau kode pemulihan). "Kirim ulang
  /// kode" = login tanpa [code] dengan [resend]; terlalu cepat → 429 +
  /// `retry_after` (server membatasi 1 email kode per 60 detik).
  Future<void> login({required String email, required String password, required String deviceName, String? code, bool resend = false}) async {
    final response = await _api().post('auth/login', data: {
      'email': email.trim(),
      'password': password,
      'device_name': deviceName.trim().isEmpty ? 'HP Android' : deviceName.trim(),
      'device_uid': await _storage.deviceUid(),
      'platform': Platform.isAndroid ? 'android' : Platform.operatingSystem,
      'app_version': AppConfig.version,
      if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
      if (resend) 'resend': true,
    });
    final token = response['token'] as String;
    final user = SessionUser.fromJson(Map<String, dynamic>.from(response['user'] as Map));
    final tenants = _eligible(response['tenants']);
    await _storage.setToken(token);
    await _storage.setSession(user, tenants);
    final tenantId = tenants.length == 1 ? tenants.first.id : null;
    await _storage.setTenantId(tenantId);
    final gone = await _forgetGoneListed(user.id, tenants);
    state = AsyncData(SessionState(token: token, user: user, tenants: tenants, tenantId: tenantId, gone: gone));
  }

  /// Perbarui daftar perusahaan + hak akses (mis. role diubah di web).
  ///
  /// [notMemberOf]: perusahaan yang baru menjawab 403 `bukan_anggota`. Bila
  /// perusahaan itu juga tidak ada di jawaban `GET /me` (dan bukan di daftar
  /// tolak paket), user sudah dikeluarkan / perusahaannya ditutup: dicatat
  /// lewat [companyGone] dengan jumlah data dari [local] (database perusahaan
  /// itu yang masih terbuka). Hilang dari `GET /me` saja bukan bukti (bisa
  /// karena paketnya tanpa aplikasi HP).
  Future<void> refreshMe({int? notMemberOf, LocalDb? local}) async {
    final current = _current;
    if (!current.loggedIn) {
      return;
    }
    try {
      final response = await _api(token: current.token).get('me');
      final user = SessionUser.fromJson(Map<String, dynamic>.from(response['user'] as Map));
      final tenants = _eligible(response['tenants']);
      if (notMemberOf != null && !tenants.any((tenant) => tenant.id == notMemberOf)) {
        await companyGone(notMemberOf, reason: GoneReason.removed, local: local);
      }
      await _storage.setSession(user, tenants);
      final stillMember = tenants.any((tenant) => tenant.id == _current.tenantId);
      if (!stillMember) {
        await _storage.setTenantId(null);
      }
      final gone = await _forgetGoneListed(user.id, tenants);
      state = AsyncData(_current.copyWith(user: user, tenants: tenants, clearTenant: !stillMember, gone: gone));
    } on ApiException catch (error) {
      if (error.unauthenticated) {
        await _forgetLogin();
      } else if (error.status == 403 && error.code == ApiException.mobileAccessDeniedCode) {
        if (notMemberOf != null && !AccessNotice.fromError(error).tenants.any((tenant) => tenant.id == notMemberOf)) {
          await companyGone(notMemberOf, reason: GoneReason.removed, local: local);
        }
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

  /// Kunci SharedPreferences untuk daftar [GoneCompany] yang belum "Mengerti".
  static const goneKey = 'gone_companies';

  /// Daftar perusahaan hilang yang tersimpan di HP (rusak = kosong).
  static List<GoneCompany> goneIn(AppStorage storage) {
    try {
      final raw = storage.prefs.getString(goneKey);
      if (raw == null) {
        return const [];
      }
      return [
        for (final item in jsonDecode(raw) as List)
          if (item is Map) GoneCompany.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _saveGone(AppStorage storage, List<GoneCompany> gone) =>
      gone.isEmpty ? storage.prefs.remove(goneKey) : storage.prefs.setString(goneKey, jsonEncode([for (final item in gone) item.toJson()]));

  /// Jumlah transaksi belum terkirim + pesanan tersimpan di [local]; null bila
  /// database tidak bisa dibaca (mis. sedang ditutup).
  static Future<({int? unsent, int? held})> countLocal(LocalDb? local) async {
    if (local == null) {
      return (unsent: null, held: null);
    }
    try {
      return await local.hold(() async => (
            unsent: await OutboxStore(local).pendingCount(),
            held: Sqflite.firstIntValue(await local.db.rawQuery('SELECT COUNT(*) FROM held_orders')) ?? 0,
          ));
    } catch (_) {
      return (unsent: null, held: null);
    }
  }

  /// Catat perusahaan [tenantId] milik [userId] sebagai hilang di
  /// penyimpanan HP: masuk daftar pesan, keluar dari daftar perusahaan, dan
  /// bukan lagi perusahaan aktif (sinkron latar ikut berhenti). Dipakai
  /// aplikasi dan sinkron latar. Data lokalnya belum dihapus.
  static Future<GoneCompany> recordGone(AppStorage storage, {required int userId, required int tenantId, required GoneReason reason, String? message, String? name, LocalDb? local}) async {
    final saved = storage.session();
    final tenant = saved?.tenants.where((item) => item.id == tenantId).firstOrNull;
    final counts = await countLocal(local);
    final gone = GoneCompany(
      userId: userId,
      tenantId: tenantId,
      name: name ?? tenant?.name ?? 'Perusahaan',
      reason: reason,
      unsent: counts.unsent,
      held: counts.held,
      message: message,
    );
    await _saveGone(storage, [...goneIn(storage).where((item) => !item.same(userId, tenantId)), gone]);
    if (saved != null && saved.user.id == userId) {
      await storage.setSession(saved.user, [for (final item in saved.tenants) if (item.id != tenantId) item]);
      if (storage.tenantId == tenantId) {
        await storage.setTenantId(null);
      }
    }
    return gone;
  }

  final Set<String> _goneInFlight = {};

  /// Perusahaan [tenantId] ditutup (403 `perusahaan_ditutup`) atau user
  /// dikeluarkan ([GoneReason.removed]): catat pesannya dengan jumlah data
  /// yang belum terkirim (dari [local], database perusahaan itu), lepas
  /// perusahaan itu, dan kembali ke Pilih perusahaan. Sinkron perusahaan itu
  /// berhenti (tidak dicoba ulang). Data HP baru dihapus di [acknowledgeGone].
  /// Aman dipanggil berkali-kali untuk perusahaan yang sama.
  Future<void> companyGone(int tenantId, {required GoneReason reason, String? message, LocalDb? local}) async {
    final current = _current;
    final user = current.user;
    if (!current.loggedIn || user == null) {
      return;
    }
    final key = '${user.id}:$tenantId';
    if (_goneInFlight.contains(key) || current.gone.any((item) => item.same(user.id, tenantId))) {
      return;
    }
    _goneInFlight.add(key);
    try {
      final name = current.tenants.where((tenant) => tenant.id == tenantId).firstOrNull?.name;
      final gone = await recordGone(_storage, userId: user.id, tenantId: tenantId, reason: reason, message: message, name: name, local: local);
      final now = _current;
      state = AsyncData(now.copyWith(
        tenants: [for (final tenant in now.tenants) if (tenant.id != tenantId) tenant],
        clearTenant: now.tenantId == tenantId,
        gone: [...now.gone.where((item) => !item.same(user.id, tenantId)), gone],
      ));
    } finally {
      _goneInFlight.remove(key);
    }
  }

  /// Pengguna menekan "Mengerti": hapus data HP perusahaan itu (database +
  /// outbox) lalu buang pesannya.
  Future<void> acknowledgeGone(GoneCompany gone) async {
    await deleteCompanyData(gone.userId, gone.tenantId);
    await _saveGone(_storage, [...goneIn(_storage).where((item) => !item.same(gone.userId, gone.tenantId))]);
    final now = _current;
    state = AsyncData(now.copyWith(gone: [...now.gone.where((item) => !item.same(gone.userId, gone.tenantId))]));
  }

  /// Perusahaan yang muncul lagi di daftar server (mis. diundang lagi):
  /// pesannya dibatalkan tanpa menghapus data (transaksinya bisa terkirim).
  Future<List<GoneCompany>> _forgetGoneListed(int userId, List<TenantSummary> tenants) async {
    final saved = goneIn(_storage);
    bool listed(GoneCompany item) => item.userId == userId && tenants.any((tenant) => tenant.id == item.tenantId);
    if (saved.any(listed)) {
      await _saveGone(_storage, [...saved.where((item) => !listed(item))]);
    }
    return [..._current.gone.where((item) => !listed(item))];
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
      // Data perusahaan yang ditutup ikut terhapus: pesannya tidak perlu lagi.
      try {
        await _saveGone(_storage, [...goneIn(_storage).where((item) => item.userId != userId)]);
      } finally {
        state = AsyncData(_current.copyWith(gone: [..._current.gone.where((item) => item.userId != userId)]));
      }
    }
  }

  Future<void> _forgetLogin({AccessNotice? notice}) async {
    final gone = _current.gone;
    try {
      await _storage.clearSession();
    } finally {
      // Pesan perusahaan ditutup tetap tampil di layar Masuk sampai "Mengerti".
      state = AsyncData(SessionState(notice: notice, gone: gone));
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

  /// Penghapus data HP satu perusahaan (diganti di tes).
  @visibleForTesting
  static Future<void> Function(int userId, int tenantId) deleteCompanyData = _deleteCompanyDataFiles;

  static Future<void> _deleteCompanyDataFiles(int userId, int tenantId) async {
    await ProductPhotoStore.deleteFor(userId, tenantId: tenantId);
    try {
      await deleteCompanyDataIn(Directory(await getDatabasesPath()), userId, tenantId);
    } catch (_) {
      // Folder database tidak terbaca: file terhapus saat Keluar.
    }
  }

  /// Hapus file database perusahaan [tenantId] milik [userId] di [directory]
  /// (beserta `-wal`/`-shm`/`-journal`), bukan perusahaan lain.
  @visibleForTesting
  static Future<void> deleteCompanyDataIn(Directory directory, int userId, int tenantId) async {
    if (!directory.existsSync()) {
      return;
    }
    final base = LocalDb.fileName(userId, tenantId);
    for (final file in directory.listSync()) {
      final name = p.basename(file.path);
      if (file is File && (name == base || name.startsWith('$base-'))) {
        try {
          await file.delete();
        } catch (_) {
          // Terkunci: dihapus saat Keluar.
        }
      }
    }
  }

  /// Penghapus file database lokal (diganti di tes).
  @visibleForTesting
  static Future<void> Function(int userId) deleteLocalData = _deleteLocalDataFiles;

  static Future<void> _deleteLocalDataFiles(int userId) async {
    await ProductPhotoStore.deleteFor(userId);
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
