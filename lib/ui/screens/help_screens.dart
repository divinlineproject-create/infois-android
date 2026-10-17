import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../core/store_policy.dart';
import '../../data/api_client.dart';
import '../../domain/help_models.dart';
import '../../services/file_downloads.dart';
import '../../state/help_state.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/ai_markdown.dart' show confirmExternalLink, openUntrustedLink;
import '../widgets/common.dart';
import '../widgets/help_html.dart';

/// Ikon kategori: nama Heroicon dari server → ikon Material yang mirip.
IconData helpCategoryIcon(String icon) => switch (icon.replaceFirst(RegExp(r'^heroicon-[os]-'), '')) {
      'rocket-launch' => Icons.rocket_launch_outlined,
      'document-text' => Icons.description_outlined,
      'shopping-cart' => Icons.shopping_cart_outlined,
      'shopping-bag' => Icons.shopping_bag_outlined,
      'archive-box' => Icons.inventory_2_outlined,
      'banknotes' => Icons.payments_outlined,
      'calculator' => Icons.calculate_outlined,
      'chart-bar' => Icons.bar_chart_rounded,
      'receipt-percent' => Icons.receipt_long_outlined,
      'sparkles' => Icons.auto_awesome_outlined,
      'device-phone-mobile' => Icons.smartphone_outlined,
      'credit-card' => Icons.credit_card_outlined,
      'users' => Icons.group_outlined,
      'cog-6-tooth' => Icons.settings_outlined,
      'shield-check' => Icons.verified_user_outlined,
      'question-mark-circle' => Icons.help_outline,
      'wrench-screwdriver' => Icons.build_outlined,
      _ => Icons.menu_book_outlined,
    };

/// Pesan galat Pusat Bantuan yang mudah dipahami.
({IconData icon, String title, String message}) _helpError(Object? error, {String notFound = 'Panduan ini tidak ditemukan. Mungkin sudah dipindah atau dihapus.'}) {
  if (error is ApiException && error.offline) {
    return (icon: Icons.cloud_off_outlined, title: 'Tidak ada koneksi internet', message: 'Pusat Bantuan perlu internet. Sambungkan HP ke internet lalu coba lagi.');
  }
  if (error is ApiException && error.status == 404) {
    return (icon: Icons.search_off_rounded, title: 'Tidak ditemukan', message: notFound);
  }
  if (error is ApiException && error.code == 'kanal_pemeliharaan') {
    return (icon: Icons.construction_rounded, title: 'Sedang pemeliharaan', message: error.message);
  }
  return (icon: Icons.error_outline, title: 'Belum bisa dimuat', message: plainError(error, fallback: 'Pusat Bantuan belum bisa dibuka. Coba lagi sebentar lagi.'));
}

class _HelpErrorView extends StatelessWidget {
  const _HelpErrorView({required this.error, required this.onRetry, this.notFound});

  final Object? error;
  final VoidCallback onRetry;
  final String? notFound;

  @override
  Widget build(BuildContext context) {
    final info = notFound == null ? _helpError(error) : _helpError(error, notFound: notFound!);
    final missing = error is ApiException && (error as ApiException).status == 404;
    return EmptyState(
      key: const Key('help-error'),
      icon: info.icon,
      title: info.title,
      message: info.message,
      action: missing
          ? OutlinedButton(onPressed: () => context.canPop() ? context.pop() : context.go('/'), child: const Text('Kembali'))
          : FilledButton.icon(key: const Key('help-retry'), onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Coba lagi')),
    );
  }
}

/// "Belum menemukan jawaban? Tanya Tim AI" (hanya bila Tim AI terbuka).
class _AskTeamAi extends ConsumerWidget {
  const _AskTeamAi({this.question});

  final String? question;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menus = ref.watch(masterDataProvider).valueOrNull?.menus;
    if (menus == null || !menus.ai) {
      return const SizedBox.shrink();
    }
    return Card(
      key: const Key('help-ask-ai'),
      child: ListTile(
        leading: Icon(Icons.auto_awesome_outlined, color: Theme.of(context).colorScheme.primary),
        title: const Text('Belum menemukan jawaban?'),
        subtitle: const Text('Tanyakan langsung ke Tim AI.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/ai/percakapan', extra: question),
      ),
    );
  }
}

/// Kartu satu artikel di daftar.
class HelpArticleTile extends StatelessWidget {
  const HelpArticleTile({super.key, required this.article, this.showCategory = true});

  final HelpArticleSummary article;
  final bool showCategory;

  @override
  Widget build(BuildContext context) {
    final muted = mutedText(context);
    final meta = [if (showCategory && article.category != null) article.category!.name, '${article.readingMinutes} menit baca'].join(' · ');
    return Card(
      child: InkWell(
        key: Key('help-article-${article.slug}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/bantuan/artikel/${Uri.encodeComponent(article.slug)}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(article.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, height: 1.3)),
                    if (article.summary.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(article.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: muted, height: 1.35)),
                    ],
                    const SizedBox(height: 6),
                    Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted)),
                  ],
                ),
              ),
              Padding(padding: const EdgeInsets.only(left: 4, top: 2), child: Icon(Icons.chevron_right, color: muted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      );
}

/// Pusat Bantuan: cari panduan, kategori, artikel pilihan & populer.
class HelpHomeScreen extends ConsumerStatefulWidget {
  const HelpHomeScreen({super.key});

  @override
  ConsumerState<HelpHomeScreen> createState() => _HelpHomeScreenState();
}

class _HelpHomeScreenState extends ConsumerState<HelpHomeScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) {
        setState(() => _query = value.trim());
      }
    });
    setState(() {});
  }

  void _clear() {
    _debounce?.cancel();
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final home = ref.watch(helpHomeProvider);
    final minLength = home.valueOrNull?.minSearchLength ?? 2;
    final searching = _query.length >= minLength;
    return Scaffold(
      appBar: AppBar(title: const Text('Pusat Bantuan')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: RefreshIndicator(
              onRefresh: () async {
                if (searching) {
                  ref.invalidate(helpSearchProvider(_query));
                  await ref.read(helpSearchProvider(_query).future).catchError((Object _) => const <HelpArticleSummary>[]);
                } else {
                  ref.invalidate(helpHomeProvider);
                  await ref.read(helpHomeProvider.future).catchError((Object _) => const HelpHome());
                }
              },
              child: ListView(
                key: const Key('help-home'),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Text('Ada yang bisa kami bantu?', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('help-search'),
                    controller: _search,
                    onChanged: _onChanged,
                    onSubmitted: (value) {
                      _debounce?.cancel();
                      setState(() => _query = value.trim());
                    },
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Cari panduan, mis. cetak struk',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _search.text.isEmpty ? null : IconButton(key: const Key('help-search-clear'), tooltip: 'Hapus', onPressed: _clear, icon: const Icon(Icons.close_rounded)),
                    ),
                  ),
                  if (searching) ..._results(context) else ..._home(context, home),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _results(BuildContext context) {
    final results = ref.watch(helpSearchProvider(_query));
    return [
      _SectionTitle('Hasil untuk "$_query"'),
      ...results.when(
        loading: () => [const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))],
        error: (error, _) => [SizedBox(height: 360, child: _HelpErrorView(error: error, onRetry: () => ref.invalidate(helpSearchProvider(_query))))],
        data: (items) => items.isEmpty
            ? [
                Padding(
                  key: const Key('help-no-results'),
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                  child: Text('Belum ada panduan untuk "$_query". Coba kata lain, mis. "invoice", "stok", atau "struk".', textAlign: TextAlign.center, style: TextStyle(color: mutedText(context))),
                ),
                _AskTeamAi(question: _query),
              ]
            : [for (final item in items) HelpArticleTile(article: item)],
      ),
    ];
  }

  List<Widget> _home(BuildContext context, AsyncValue<HelpHome> home) {
    return home.when(
      loading: () => [const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))],
      error: (error, _) => [SizedBox(height: 400, child: _HelpErrorView(error: error, onRetry: () => ref.invalidate(helpHomeProvider)))],
      data: (data) {
        if (data.isEmpty) {
          return [
            const SizedBox(height: 32),
            const EmptyState(key: Key('help-empty'), icon: Icons.menu_book_outlined, title: 'Panduan sedang kami siapkan', message: 'Sementara ini, tanyakan langsung ke Tim AI atau pemilik usaha Anda.'),
            const _AskTeamAi(),
          ];
        }
        return [
          if (data.categories.isNotEmpty) ...[
            const _SectionTitle('Kategori'),
            for (final category in data.categories) _CategoryTile(category: category),
          ],
          if (data.featured.isNotEmpty) ...[
            const _SectionTitle('Artikel pilihan'),
            for (final article in data.featured) HelpArticleTile(article: article),
          ],
          if (data.popular.isNotEmpty) ...[
            const _SectionTitle('Paling sering dibaca'),
            for (final article in data.popular) HelpArticleTile(article: article),
          ],
          const SizedBox(height: 12),
          const _AskTeamAi(),
        ];
      },
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category});

  final HelpCategory category;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final description = category.description;
    return Card(
      child: ListTile(
        key: Key('help-category-${category.slug}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
          child: Icon(helpCategoryIcon(category.icon), color: scheme.primary, size: 22),
        ),
        title: Text(category.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [if (description != null) description, '${category.articleCount} artikel'].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/bantuan/kategori/${Uri.encodeComponent(category.slug)}'),
      ),
    );
  }
}

/// Daftar artikel dalam satu kategori.
class HelpCategoryScreen extends ConsumerWidget {
  const HelpCategoryScreen({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(helpCategoryProvider(slug));
    final category = page.valueOrNull?.category;
    return Scaffold(
      appBar: AppBar(title: Text(category?.name ?? 'Pusat Bantuan', overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: page.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _HelpErrorView(error: error, notFound: 'Kategori ini tidak ditemukan.', onRetry: () => ref.invalidate(helpCategoryProvider(slug))),
              data: (data) => RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(helpCategoryProvider(slug));
                  await ref.read(helpCategoryProvider(slug).future).catchError((Object _) => data);
                },
                child: ListView(
                  key: const Key('help-category'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    Row(children: [
                      Icon(helpCategoryIcon(data.category.icon), color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 10),
                      Expanded(child: Text(data.category.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
                    ]),
                    if (data.category.description != null) ...[
                      const SizedBox(height: 6),
                      Text(data.category.description!, style: TextStyle(color: mutedText(context))),
                    ],
                    const SizedBox(height: 12),
                    if (data.articles.isEmpty)
                      Padding(padding: const EdgeInsets.all(24), child: Text('Belum ada artikel di kategori ini.', textAlign: TextAlign.center, style: TextStyle(color: mutedText(context))))
                    else
                      for (final article in data.articles) HelpArticleTile(article: article, showCategory: false),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Satu artikel: isi, daftar isi (lompat ke bagian), video, "Apakah
/// artikel ini membantu?", dan artikel terkait.
class HelpArticleScreen extends ConsumerStatefulWidget {
  const HelpArticleScreen({super.key, required this.slug});

  final String slug;

  @override
  ConsumerState<HelpArticleScreen> createState() => _HelpArticleScreenState();
}

class _HelpArticleScreenState extends ConsumerState<HelpArticleScreen> {
  final Map<String, GlobalKey> _anchors = {};
  final _scroll = ScrollController();

  /// Jawaban yang baru dikirim (menimpa `my_vote` dari server).
  bool? _vote;
  bool _voting = false;
  String? _thanks;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _jump(String id) async {
    final target = _anchors[id]?.currentContext;
    if (target == null) {
      return;
    }
    await Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOut, alignment: 0.02);
  }

  Future<void> _showToc(List<HelpHeading> headings) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.7),
          child: ListView(
            key: const Key('help-toc-sheet'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Daftar isi', style: Theme.of(sheet).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              for (final heading in headings)
                ListTile(
                  key: Key('help-toc-${heading.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.only(left: heading.level > 2 ? 32 : 16, right: 16),
                  title: Text(heading.text, style: TextStyle(fontWeight: heading.level > 2 ? FontWeight.w400 : FontWeight.w600)),
                  onTap: () => Navigator.pop(sheet, heading.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (id != null && mounted) {
      // Tunggu lembar tertutup sebelum menggulir.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _jump(id);
    }
  }

  void _openLink(String href, String? helpSlug) {
    final trimmed = href.trim();
    if (trimmed.startsWith('#')) {
      unawaited(_jump(trimmed.substring(1)));
      return;
    }
    final slug = helpSlug ?? helpArticleSlugFromUrl(trimmed);
    if (slug != null && slug.isNotEmpty) {
      context.push('/bantuan/artikel/${Uri.encodeComponent(slug)}');
      return;
    }
    unawaited(openUntrustedLink(context, ref, trimmed));
  }

  Future<void> _openVideo(HelpVideo video) async {
    if (!video.uploaded) {
      final site = video.kind == 'vimeo' ? 'Vimeo' : 'YouTube';
      final ok = await confirmExternalLink(context, video.url, title: 'Tonton di $site?', intro: 'Video ini dibuka di aplikasi $site atau browser, di luar Infois:');
      if (ok && mounted) {
        await openExternalLink(context, ref, video.url);
      }
      return;
    }
    await playHelpVideo(context, ref, video);
  }

  Future<void> _rate(HelpArticle article, bool helpful) async {
    final api = ref.read(helpApiProvider);
    if (api == null || _voting) {
      return;
    }
    setState(() => _voting = true);
    try {
      final message = await api.feedback(article.slug, helpful: helpful);
      if (mounted) {
        setState(() {
          _vote = helpful;
          _thanks = message;
        });
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, plainError(error, fallback: 'Jawaban belum terkirim. Coba lagi.'), error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _voting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final article = ref.watch(helpArticleProvider(widget.slug));
    final headings = article.valueOrNull?.headings ?? const <HelpHeading>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Panduan'),
        actions: [
          if (headings.isNotEmpty) IconButton(key: const Key('help-toc'), tooltip: 'Daftar isi', onPressed: () => _showToc(headings), icon: const Icon(Icons.toc_rounded)),
        ],
      ),
      body: SafeArea(
        top: false,
        child: article.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _HelpErrorView(error: error, notFound: 'Artikel ini tidak ditemukan. Mungkin sudah dipindah atau dihapus.', onRetry: () => ref.invalidate(helpArticleProvider(widget.slug))),
          data: (data) => _body(context, data),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, HelpArticle article) {
    final muted = mutedText(context);
    final scheme = Theme.of(context).colorScheme;
    final updated = article.summary.updatedAt;
    final meta = [
      '${article.summary.readingMinutes} menit baca',
      if (updated != null) 'Diperbarui ${DateFormat('d MMM yyyy', 'id_ID').format(updated.toLocal())}',
    ].join(' · ');
    final category = article.summary.category;
    final cover = article.summary.coverUrl;
    final vote = _vote ?? article.myVote;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          key: const Key('help-article'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (category != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: ActionChip(
                    key: const Key('help-article-category'),
                    avatar: Icon(helpCategoryIcon(category.icon), size: 18, color: scheme.primary),
                    label: Text(category.name),
                    onPressed: () => context.push('/bantuan/kategori/${Uri.encodeComponent(category.slug)}'),
                  ),
                ),
              const SizedBox(height: 8),
              Text(article.title, key: const Key('help-article-title'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.3)),
              const SizedBox(height: 6),
              Text(meta, style: TextStyle(fontSize: 12.5, color: muted)),
              if (article.summary.summary.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(article.summary.summary, style: TextStyle(fontSize: 15, color: muted, height: 1.5)),
              ],
              if (cover != null) ...[
                const SizedBox(height: 14),
                HelpImage(url: cover),
              ],
              if (article.headings.length > 1) ...[
                const SizedBox(height: 12),
                Card(
                  margin: EdgeInsets.zero,
                  child: Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      key: const Key('help-toc-inline'),
                      leading: const Icon(Icons.toc_rounded),
                      title: const Text('Daftar isi', style: TextStyle(fontWeight: FontWeight.w600)),
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      children: [
                        for (final heading in article.headings)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.only(left: heading.level > 2 ? 40 : 24, right: 16),
                            title: Text(heading.text),
                            onTap: () => _jump(heading.id),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              HelpHtml(
                html: article.html,
                anchors: _anchors,
                onLink: _openLink,
                onVideo: _openVideo,
                imageBuilder: (src, alt) => HelpImage(url: src, alt: alt),
              ),
              const SizedBox(height: 12),
              _feedback(context, article, vote),
              if (article.related.isNotEmpty) ...[
                const _SectionTitle('Artikel terkait'),
                for (final related in article.related) HelpArticleTile(article: related, showCategory: false),
              ],
              const SizedBox(height: 12),
              _AskTeamAi(question: 'Saya sudah membaca panduan "${article.title}", tapi masih bingung: '),
            ],
          ),
        ),
      ),
    );
  }

  Widget _feedback(BuildContext context, HelpArticle article, bool? vote) {
    final thanks = _thanks ?? (vote == null ? null : (vote ? 'Terima kasih! Senang bisa membantu.' : 'Terima kasih atas masukannya, kami akan memperbaiki artikel ini.'));
    Widget button(bool helpful) {
      final selected = vote == helpful;
      final icon = helpful ? Icons.thumb_up_alt_outlined : Icons.thumb_down_alt_outlined;
      final label = Text(helpful ? 'Ya' : 'Tidak');
      final key = Key(helpful ? 'help-vote-yes' : 'help-vote-no');
      final onPressed = _voting ? null : () => _rate(article, helpful);
      return selected
          ? FilledButton.icon(key: key, onPressed: onPressed, icon: Icon(icon, size: 18), label: label)
          : OutlinedButton.icon(key: key, onPressed: onPressed, icon: Icon(icon, size: 18), label: label);
    }

    return Card(
      key: const Key('help-feedback'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Apakah artikel ini membantu?', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [button(true), button(false)]),
            if (thanks != null) ...[
              const SizedBox(height: 10),
              Text(thanks, key: const Key('help-feedback-thanks'), style: TextStyle(fontSize: 13, color: mutedText(context))),
            ],
          ],
        ),
      ),
    );
  }
}

/// Gambar artikel (diunduh dengan token). Ketuk untuk memperbesar.
class HelpImage extends ConsumerWidget {
  const HelpImage({super.key, required this.url, this.alt});

  final String url;
  final String? alt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = ref.watch(helpImageProvider(url));
    final fill = AiColors.codeFill(context);
    Widget placeholder(Widget child) => Container(
          height: 160,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.all(12),
          child: child,
        );
    Widget broken() => placeholder(Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.image_not_supported_outlined, color: mutedText(context)),
          const SizedBox(height: 6),
          Text(alt ?? 'Gambar belum bisa dimuat', textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: mutedText(context))),
        ]));
    return image.when(
      loading: () => placeholder(const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
      error: (_, __) => GestureDetector(onTap: () => ref.invalidate(helpImageProvider(url)), child: broken()),
      data: (bytes) => Semantics(
        image: true,
        label: alt,
        child: GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (dialog) => Dialog.fullscreen(
              backgroundColor: Colors.black,
              child: Stack(children: [
                Positioned.fill(child: InteractiveViewer(maxScale: 5, child: Center(child: Image.memory(bytes, fit: BoxFit.contain)))),
                Positioned(
                  top: MediaQuery.paddingOf(dialog).top + 8,
                  right: 8,
                  child: IconButton(tooltip: 'Tutup', color: Colors.white, onPressed: () => Navigator.pop(dialog), icon: const Icon(Icons.close_rounded)),
                ),
              ]),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: (_, __, ___) => broken()),
          ),
        ),
      ),
    );
  }
}

/// Video unggahan di artikel: diunduh sekali dengan token (disimpan di
/// folder sementara aplikasi), lalu diputar dengan pemutar video HP.
Future<void> playHelpVideo(BuildContext context, WidgetRef ref, HelpVideo video) async {
  final messenger = ScaffoldMessenger.of(context);
  final api = ref.read(helpApiProvider);
  if (api == null) {
    return;
  }
  final platform = ref.read(filePlatformProvider);
  final extension = p.extension(Uri.tryParse(video.url)?.path ?? '').toLowerCase();
  final mime = extension == '.webm' ? 'video/webm' : 'video/mp4';
  final progress = ValueNotifier<double?>(null);
  // Dilepas setelah pemberitahuan progres benar-benar tertutup (animasi
  // keluar masih memakai nilainya).
  var progressShown = false;
  var closed = false;
  try {
    final directory = await platform.workDirectory();
    final file = File(p.join(directory.path, 'bantuan-video-${video.url.hashCode.toUnsigned(32)}${extension.isEmpty ? '.mp4' : extension}'));
    if (!file.existsSync() || file.lengthSync() == 0) {
      messenger.hideCurrentSnackBar();
      progressShown = true;
      messenger
          .showSnackBar(SnackBar(
            key: const Key('help-video-progress'),
            duration: const Duration(minutes: 10),
            content: ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (context, value, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(value == null ? 'Menyiapkan video…' : 'Menyiapkan video… ${(value * 100).round()}%'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: value, minHeight: 4, semanticsLabel: 'Progres video'),
              ]),
            ),
          ))
          .closed
          .then((_) {
            closed = true;
            progress.dispose();
          });
      final bytes = await api.media(video.url, onProgress: (received, total) {
        if (!closed) {
          progress.value = total > 0 ? received / total : null;
        }
      });
      await file.writeAsBytes(bytes, flush: true);
      messenger.hideCurrentSnackBar();
    }
    if (!await platform.openFile(file.path, mime)) {
      messenger.showSnackBar(const SnackBar(content: Text('Tidak ada aplikasi pemutar video di HP ini.')));
    }
  } on ApiException catch (error) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(error.offline ? 'Video perlu internet. Sambungkan HP ke internet lalu coba lagi.' : error.message)));
  } catch (_) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(content: Text('Video belum bisa diputar. Coba lagi.')));
  } finally {
    if (!progressShown) {
      progress.dispose();
    }
  }
}
