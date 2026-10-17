import '../domain/help_models.dart';
import 'ai_api.dart';
import 'api_client.dart';

/// Pusat Bantuan (`/api/v1/help…`, API.md › Pusat Bantuan): cukup token,
/// tanpa perusahaan aktif.
class HelpApi {
  HelpApi(this.client);

  final ApiClient client;

  Future<HelpHome> home() async => HelpHome.fromJson(await client.get('help'));

  Future<List<HelpArticleSummary>> search(String query) async {
    final response = await client.get('help/search', query: {'q': query.trim()});
    return [
      for (final item in response['results'] as List? ?? const [])
        if (item is Map) HelpArticleSummary.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<HelpCategoryPage> category(String slug) async => HelpCategoryPage.fromJson(await client.get('help/categories/${Uri.encodeComponent(slug)}'));

  Future<HelpArticle> article(String slug) async => HelpArticle.fromJson(await client.get('help/articles/${Uri.encodeComponent(slug)}'));

  /// "Apakah artikel ini membantu?" Mengembalikan pesan terima kasih dari server.
  Future<String> feedback(String slug, {required bool helpful}) async {
    final response = await client.post('help/articles/${Uri.encodeComponent(slug)}/feedback', data: {'helpful': helpful});
    return response['message']?.toString() ?? 'Terima kasih atas jawabannya.';
  }

  /// Isi gambar/video artikel dengan token. URL dari server dipakai relatif
  /// terhadap `/api/v1/` (sama dengan lampiran Tim AI).
  Future<List<int>> media(String url, {void Function(int received, int total)? onProgress}) => client.bytes(AiApi.relativeApiPath(url), onProgress: onProgress);
}
