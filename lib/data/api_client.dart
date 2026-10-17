import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../core/config.dart';
import '../core/store_policy.dart';

/// Galat API dengan pesan yang bisa langsung ditampilkan ke pengguna.
class ApiException implements Exception {
  const ApiException(this.message, {this.code, this.status, this.offline = false, this.data});

  final String message;
  final String? code;
  final int? status;

  /// Tidak ada koneksi / server tidak terjangkau.
  final bool offline;

  /// Isi jawaban galat dari server (mis. `tenants` pada `akses_hp_tidak_tersedia`).
  final Map<String, dynamic>? data;

  bool get unauthenticated => status == 401;

  /// Server menolak aplikasi HP untuk perusahaan ini (paket tanpa aplikasi HP,
  /// masa trial, atau langganan tidak aktif).
  bool get mobileAccessDenied => status == 403 && (code == mobileAccessDeniedCode || code == subscriptionInactiveCode);

  static const mobileAccessDeniedCode = 'akses_hp_tidak_tersedia';
  static const subscriptionInactiveCode = 'langganan_tidak_aktif';

  /// Perusahaan ini sudah ditutup pemiliknya (server baru, aplikasi ≥ 1.1.0).
  bool get companyClosed => status == 403 && code == companyClosedCode;

  /// User bukan anggota perusahaan ini (dikeluarkan, atau ditutup untuk
  /// aplikasi lama). Dipastikan lewat `GET /me` sebelum data HP dihapus.
  bool get notMember => status == 403 && code == notMemberCode;

  /// Verifikasi dua langkah saat masuk (API.md › Login): kode belum
  /// dikirim, salah, atau terlalu sering salah.
  static const twoFactorRequiredCode = 'butuh_kode_2fa';
  static const twoFactorInvalidCode = 'kode_2fa_salah';
  static const twoFactorThrottledCode = 'kode_2fa_terlalu_sering';

  bool get twoFactorRequired => code == twoFactorRequiredCode;

  /// Cara verifikasi akun ini dari `metode_2fa`: `aplikasi` dan/atau `email`.
  List<String> get twoFactorMethods => [for (final method in (data?['metode_2fa'] as List? ?? const [])) method.toString()];

  /// Aplikasi HP sedang dimatikan sementara oleh admin Infois (503
  /// `kanal_pemeliharaan`). Sesi tetap; transaksi tetap di antrean HP.
  bool get maintenance => code == maintenanceCode;

  static const maintenanceCode = 'kanal_pemeliharaan';

  static const companyClosedCode = 'perusahaan_ditutup';
  static const notMemberCode = 'bukan_anggota';

  @override
  String toString() => message;
}

/// Klien `/api/v1`. Token per HP dan perusahaan (X-Tenant) dikirim di setiap
/// request; galat diubah menjadi pesan berbahasa Indonesia yang sederhana.
class ApiClient {
  ApiClient({required String baseUrl, this.token, this.tenantId, this.outboxCount, Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              baseUrl: _apiBase(baseUrl),
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 60),
              headers: {'Accept': 'application/json'},
            )) {
    this.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      if (tenantId != null) {
        options.headers['X-Tenant'] = tenantId.toString();
      }
      options.headers['X-App-Version'] = AppConfig.version;
      options.headers['X-Platform'] = Platform.operatingSystem;
      final pending = outboxCount?.call();
      if (pending != null) {
        options.headers['X-Outbox-Count'] = pending.toString();
      }
      handler.next(options);
    }));
  }

  final Dio dio;
  final String? token;
  final int? tenantId;
  final int? Function()? outboxCount;

  /// Dipanggil untuk setiap galat dari server (sebelum dilempar), mis. untuk
  /// melepas perusahaan yang ditolak aplikasi HP di mana pun galat itu muncul.
  void Function(ApiException error)? onError;

  static String _apiBase(String baseUrl) {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return '$trimmed/api/v1/';
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query, Duration? timeout}) =>
      _send(() => dio.get<dynamic>(path, queryParameters: query, options: timeout == null ? null : Options(receiveTimeout: timeout, sendTimeout: timeout)), timeout: timeout);

  /// [onSendProgress] (terkirim, total byte) dipakai saat mengunggah lampiran.
  Future<Map<String, dynamic>> post(String path, {Object? data, Duration? timeout, void Function(int, int)? onSendProgress}) => _send(
        () => dio.post<dynamic>(path, data: data, onSendProgress: onSendProgress, options: timeout == null ? null : Options(receiveTimeout: timeout, sendTimeout: timeout)),
        timeout: timeout,
      );

  Future<Map<String, dynamic>> patch(String path, {Object? data}) => _send(() => dio.patch<dynamic>(path, data: data));

  Future<Map<String, dynamic>> delete(String path) => _send(() => dio.delete<dynamic>(path));

  /// Unduh isi file dengan token + X-Tenant. [onProgress] (diterima, total
  /// byte; total -1 bila server tidak menyebutkan ukuran).
  Future<List<int>> bytes(String url, {void Function(int received, int total)? onProgress}) async {
    try {
      final response = await dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes), onReceiveProgress: onProgress);
      return response.data ?? const [];
    } on DioException catch (error) {
      throw _convert(error);
    } on SocketException {
      throw const ApiException('Tidak ada koneksi internet.', offline: true);
    }
  }

  Future<Map<String, dynamic>> _send(Future<Response<dynamic>> Function() request, {Duration? timeout}) async {
    try {
      final future = request();
      final response = timeout == null ? await future : await future.timeout(timeout);
      final data = response.data;
      return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    } on DioException catch (error) {
      throw _convert(error);
    } on SocketException {
      throw const ApiException('Tidak ada koneksi internet.', offline: true);
    } on Exception catch (error) {
      if (error.toString().contains('TimeoutException')) {
        throw const ApiException('Server tidak menjawab. Coba lagi.', offline: true);
      }
      rethrow;
    }
  }

  ApiException _convert(DioException error) {
    final response = error.response;
    if (response == null) {
      return const ApiException('Tidak bisa terhubung ke server. Periksa internet Anda.', offline: true);
    }
    final converted = _fromResponse(response);
    try {
      onError?.call(converted);
    } catch (_) {
      // Pendengar galat tidak boleh mengganti galat aslinya.
    }
    return converted;
  }

  static ApiException _fromResponse(Response<dynamic> response) {
    var data = response.data;
    if (data is List<int>) {
      // Unduhan (ResponseType.bytes): galat JSON datang sebagai byte.
      try {
        data = jsonDecode(utf8.decode(data));
      } catch (_) {
        data = null;
      }
    }
    var message = 'Terjadi kesalahan di server (${response.statusCode}). Coba lagi nanti.';
    String? code;
    if (data is Map) {
      code = data['code']?.toString();
      final errors = data['errors'];
      if (errors is Map && errors.isNotEmpty) {
        final first = errors.values.first;
        message = first is List && first.isNotEmpty ? first.first.toString() : (data['message']?.toString() ?? message);
      } else if (data['message'] is String && (data['message'] as String).isNotEmpty) {
        message = data['message'] as String;
      }
    }
    // Pembatas laju Laravel menjawab "Too Many Attempts." tanpa `code`;
    // 429 dengan `code` (mis. sedang_diproses di Tim AI) sudah berbahasa Indonesia.
    if (response.statusCode == 429 && code == null) {
      message = 'Terlalu banyak percobaan. Tunggu sebentar lalu coba lagi.';
    }
    // Aplikasi Play Store tidak boleh mengarahkan ke pembelian paket/koin di
    // web: pesan server yang menyebut paket/Langganan diganti kalimat netral.
    message = storeSafeServerMessage(code, message);
    return ApiException(message, code: code, status: response.statusCode, data: data is Map ? Map<String, dynamic>.from(data) : null);
  }
}
