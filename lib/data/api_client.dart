import 'dart:io';

import 'package:dio/dio.dart';

import '../core/config.dart';

/// Galat API dengan pesan yang bisa langsung ditampilkan ke pengguna.
class ApiException implements Exception {
  const ApiException(this.message, {this.code, this.status, this.offline = false});

  final String message;
  final String? code;
  final int? status;

  /// Tidak ada koneksi / server tidak terjangkau.
  final bool offline;

  bool get unauthenticated => status == 401;

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

  static String _apiBase(String baseUrl) {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return '$trimmed/api/v1/';
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query, Duration? timeout}) =>
      _send(() => dio.get<dynamic>(path, queryParameters: query, options: timeout == null ? null : Options(receiveTimeout: timeout, sendTimeout: timeout)), timeout: timeout);

  Future<Map<String, dynamic>> post(String path, {Object? data}) => _send(() => dio.post<dynamic>(path, data: data));

  Future<Map<String, dynamic>> patch(String path, {Object? data}) => _send(() => dio.patch<dynamic>(path, data: data));

  Future<List<int>> bytes(String url) async {
    try {
      final response = await dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
      return response.data ?? const [];
    } on DioException catch (error) {
      throw _convert(error);
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
    final data = response.data;
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
    if (response.statusCode == 429) {
      message = 'Terlalu banyak percobaan. Tunggu sebentar lalu coba lagi.';
    }
    return ApiException(message, code: code, status: response.statusCode);
  }
}
