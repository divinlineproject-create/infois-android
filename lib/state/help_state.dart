import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/help_api.dart';
import '../domain/help_models.dart';
import 'session.dart';

/// Klien Pusat Bantuan: token login saja (isi bantuan tidak per perusahaan),
/// null bila belum masuk.
final helpApiProvider = Provider<HelpApi?>((ref) {
  final (serverUrl, token) = ref.watch(sessionProvider.select((value) => (value.valueOrNull?.serverUrl, value.valueOrNull?.token)));
  if (serverUrl == null || token == null) {
    return null;
  }
  return HelpApi(ref.read(apiFactoryProvider)(serverUrl, token, null, () => null));
});

/// Simpan hasil sebentar setelah layar ditutup: kembali ke layar sebelumnya
/// (atau membuka artikel yang sama lagi) tidak memanggil server lagi, juga
/// saat sinyal sedang hilang. Galat tidak disimpan (dicoba lagi saat dibuka).
Future<T> _cached<T>(Ref ref, Duration duration, Future<T> Function(HelpApi api) request) async {
  final link = ref.keepAlive();
  final timer = Timer(duration, link.close);
  ref.onDispose(timer.cancel);
  try {
    return await _call(ref, request);
  } catch (_) {
    timer.cancel();
    link.close();
    rethrow;
  }
}

Future<T> _call<T>(Ref ref, Future<T> Function(HelpApi api) request) async {
  final api = ref.watch(helpApiProvider);
  if (api == null) {
    throw const ApiException('Masuk dulu untuk membuka Pusat Bantuan.');
  }
  final session = ref.read(sessionProvider.notifier);
  try {
    return await request(api);
  } on ApiException catch (error) {
    if (error.unauthenticated) {
      unawaited(session.expire());
    }
    rethrow;
  }
}

final helpHomeProvider = FutureProvider.autoDispose<HelpHome>((ref) async {
  return _cached(ref, const Duration(minutes: 10), (api) => api.home());
});

final helpSearchProvider = FutureProvider.autoDispose.family<List<HelpArticleSummary>, String>((ref, query) async {
  return _call(ref, (api) => api.search(query));
});

final helpCategoryProvider = FutureProvider.autoDispose.family<HelpCategoryPage, String>((ref, slug) async {
  return _cached(ref, const Duration(minutes: 10), (api) => api.category(slug));
});

final helpArticleProvider = FutureProvider.autoDispose.family<HelpArticle, String>((ref, slug) async {
  return _cached(ref, const Duration(minutes: 10), (api) => api.article(slug));
});

/// Gambar artikel (diunduh dengan token, disimpan sebentar di memori).
final helpImageProvider = FutureProvider.autoDispose.family<Uint8List, String>((ref, url) async {
  return Uint8List.fromList(await _cached(ref, const Duration(minutes: 5), (api) => api.media(url)));
});
