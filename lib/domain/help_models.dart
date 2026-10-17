// Pusat Bantuan (API.md › Pusat Bantuan): isi milik platform, sama untuk
// semua perusahaan.

String _s(Object? value, [String fallback = '']) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? fallback : text;
}

int? _i(Object? value) => value is int ? value : int.tryParse('${value ?? ''}');

DateTime? _date(Object? value) => value == null ? null : DateTime.tryParse(value.toString());

List<Map<String, dynamic>> _maps(Object? value) => [
      for (final item in value is List ? value : const [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];

/// Kategori bantuan. [icon] = nama ikon Heroicon dari server
/// (mis. `heroicon-o-shopping-cart`), dipetakan ke ikon Material di layar.
class HelpCategory {
  const HelpCategory({required this.id, required this.name, required this.slug, this.description, this.icon = 'heroicon-o-book-open', this.articleCount = 0});

  factory HelpCategory.fromJson(Map<String, dynamic> json) => HelpCategory(
        id: _i(json['id']) ?? 0,
        name: _s(json['name'], 'Bantuan'),
        slug: _s(json['slug']),
        description: (json['description']?.toString() ?? '').trim().isEmpty ? null : json['description'].toString(),
        icon: _s(json['icon'], 'heroicon-o-book-open'),
        articleCount: _i(json['article_count']) ?? 0,
      );

  final int id;
  final String name;
  final String slug;
  final String? description;
  final String icon;
  final int articleCount;
}

/// Kartu artikel (daftar, pencarian, terkait).
class HelpArticleSummary {
  const HelpArticleSummary({required this.id, required this.slug, required this.title, this.summary = '', this.category, this.readingMinutes = 1, this.featured = false, this.coverUrl, this.updatedAt});

  factory HelpArticleSummary.fromJson(Map<String, dynamic> json) => HelpArticleSummary(
        id: _i(json['id']) ?? 0,
        slug: _s(json['slug']),
        title: _s(json['title'], 'Artikel'),
        summary: _s(json['summary']),
        category: json['category'] is Map ? HelpCategory.fromJson(Map<String, dynamic>.from(json['category'] as Map)) : null,
        readingMinutes: _i(json['reading_minutes']) ?? 1,
        featured: json['is_featured'] == true,
        coverUrl: (json['cover_url']?.toString() ?? '').isEmpty ? null : json['cover_url'].toString(),
        updatedAt: _date(json['updated_at']),
      );

  final int id;
  final String slug;
  final String title;
  final String summary;
  final HelpCategory? category;
  final int readingMinutes;
  final bool featured;
  final String? coverUrl;
  final DateTime? updatedAt;
}

/// Judul bagian untuk daftar isi (id = anchor di HTML).
class HelpHeading {
  const HelpHeading({required this.id, required this.text, this.level = 2});

  factory HelpHeading.fromJson(Map<String, dynamic> json) => HelpHeading(id: _s(json['id']), text: _s(json['text']), level: _i(json['level']) ?? 2);

  final String id;
  final String text;
  final int level;
}

/// Video di artikel: `upload` (file, perlu token), `youtube`, atau `vimeo`.
class HelpVideo {
  const HelpVideo({required this.kind, required this.url, this.caption});

  factory HelpVideo.fromJson(Map<String, dynamic> json) => HelpVideo(kind: _s(json['kind'], 'upload'), url: _s(json['url']), caption: (json['caption']?.toString() ?? '').trim().isEmpty ? null : json['caption'].toString());

  final String kind;
  final String url;
  final String? caption;

  bool get uploaded => kind == 'upload';
}

class HelpArticle {
  const HelpArticle({
    required this.summary,
    this.html = '',
    this.headings = const [],
    this.videos = const [],
    this.viewCount = 0,
    this.myVote,
    this.related = const [],
  });

  factory HelpArticle.fromJson(Map<String, dynamic> json) {
    final article = Map<String, dynamic>.from(json['article'] as Map? ?? const {});
    return HelpArticle(
      summary: HelpArticleSummary.fromJson(article),
      html: _s(article['html']),
      headings: [for (final item in _maps(article['headings'])) HelpHeading.fromJson(item)],
      videos: [for (final item in _maps(article['videos'])) HelpVideo.fromJson(item)],
      viewCount: _i(article['view_count']) ?? 0,
      myVote: article['my_vote'] is bool ? article['my_vote'] as bool : null,
      related: [for (final item in _maps(json['related'])) HelpArticleSummary.fromJson(item)],
    );
  }

  final HelpArticleSummary summary;
  final String html;
  final List<HelpHeading> headings;
  final List<HelpVideo> videos;
  final int viewCount;

  /// true = membantu, false = tidak, null = belum menjawab.
  final bool? myVote;
  final List<HelpArticleSummary> related;

  String get slug => summary.slug;
  String get title => summary.title;
}

class HelpHome {
  const HelpHome({this.categories = const [], this.featured = const [], this.popular = const [], this.minSearchLength = 2});

  factory HelpHome.fromJson(Map<String, dynamic> json) => HelpHome(
        categories: [for (final item in _maps(json['categories'])) HelpCategory.fromJson(item)],
        featured: [for (final item in _maps(json['featured'])) HelpArticleSummary.fromJson(item)],
        popular: [for (final item in _maps(json['popular'])) HelpArticleSummary.fromJson(item)],
        minSearchLength: _i(json['min_search_length']) ?? 2,
      );

  final List<HelpCategory> categories;
  final List<HelpArticleSummary> featured;
  final List<HelpArticleSummary> popular;
  final int minSearchLength;

  bool get isEmpty => categories.isEmpty && featured.isEmpty && popular.isEmpty;
}

class HelpCategoryPage {
  const HelpCategoryPage({required this.category, this.articles = const []});

  factory HelpCategoryPage.fromJson(Map<String, dynamic> json) => HelpCategoryPage(
        category: HelpCategory.fromJson(Map<String, dynamic>.from(json['category'] as Map? ?? const {})),
        articles: [for (final item in _maps(json['articles'])) HelpArticleSummary.fromJson(item)],
      );

  final HelpCategory category;
  final List<HelpArticleSummary> articles;
}
