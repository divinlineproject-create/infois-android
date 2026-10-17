import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/store_policy.dart';
import '../../data/api_client.dart';
import '../../domain/ai_models.dart';
import '../../state/ai_state.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../theme.dart';
import '../widgets/ai_markdown.dart';
import '../widgets/ai_widgets.dart';
import '../widgets/common.dart';
import 'ai_chat_screen.dart';

/// Kelompok riwayat percakapan: Hari ini, Kemarin, 7 hari terakhir, Lebih lama.
List<({String label, List<AiConversation> items})> groupConversations(List<AiConversation> items, DateTime now) {
  const labels = ['Hari ini', 'Kemarin', '7 hari terakhir', 'Lebih lama'];
  final buckets = [for (var i = 0; i < labels.length; i++) <AiConversation>[]];
  final today = DateTime(now.year, now.month, now.day);
  for (final item in items) {
    final at = item.lastMessageAt?.toLocal();
    var bucket = 3;
    if (at != null) {
      final days = today.difference(DateTime(at.year, at.month, at.day)).inDays;
      bucket = days <= 0 ? 0 : (days == 1 ? 1 : (days <= 7 ? 2 : 3));
    }
    buckets[bucket].add(item);
  }
  return [
    for (var i = 0; i < labels.length; i++)
      if (buckets[i].isNotEmpty) (label: labels[i], items: buckets[i]),
  ];
}

/// Tab Tim AI bergaya aplikasi chat: percakapan langsung di layar (layar awal
/// dengan sapaan bila belum ada percakapan terbuka), Riwayat di laci kiri,
/// tombol Percakapan baru di kanan atas. Butuh internet.
class AiHomeScreen extends ConsumerStatefulWidget {
  const AiHomeScreen({super.key});

  @override
  ConsumerState<AiHomeScreen> createState() => _AiHomeScreenState();
}

class _AiHomeScreenState extends ConsumerState<AiHomeScreen> {
  /// Laci Riwayat yang sedang terbuka (rute di atas seluruh layar, termasuk
  /// navigasi bawah), atau null.
  Route<void>? _historyRoute;

  /// Percakapan yang dibuka dari Riwayat; null = percakapan baru.
  int? _openId;

  /// Naik setiap kali pindah percakapan supaya layar chat mulai bersih.
  int _generation = 0;

  /// Percakapan baru sudah mengirim pesan pertama.
  bool _started = false;

  @override
  void dispose() {
    _closeHistory();
    super.dispose();
  }

  int get _chatKey => _openId ?? 0;
  bool get _live => _openId != null || _started;

  int? get _currentId => _live ? ref.read(aiChatProvider(_chatKey)).conversationId : null;

  Future<void> _refresh() async {
    ref.invalidate(aiOverviewProvider);
    try {
      await ref.read(aiConversationsProvider.notifier).refresh();
    } on ApiException catch (error) {
      if (mounted) {
        showMessage(context, error.message, error: true);
      }
    }
  }

  void _closeHistory() {
    final route = _historyRoute;
    _historyRoute = null;
    if (route == null || !route.isActive) {
      return;
    }
    final navigator = route.navigator!;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// Riwayat sebagai laci setinggi layar (menutupi juga navigasi bawah),
  /// seperti aplikasi chat: ketuk luar / geser ke kiri / Tutup untuk menutup.
  Future<void> _openHistory() async {
    if (_historyRoute != null) {
      return;
    }
    unawaited(ref.read(aiConversationsProvider.notifier).refreshQuietly());
    final chatKey = _chatKey;
    final live = _live;
    final route = RawDialogRoute<void>(
      barrierDismissible: true,
      barrierLabel: 'Tutup riwayat',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder:
          (context, _, __) => Align(
            alignment: AlignmentDirectional.centerStart,
            child: GestureDetector(
              onHorizontalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) < -250) {
                  Navigator.of(context).maybePop();
                }
              },
              child: Consumer(
                builder: (context, ref, _) {
                  final data = ref.watch(aiOverviewProvider).valueOrNull;
                  final currentId = live ? ref.watch(aiChatProvider(chatKey).select((state) => state.conversationId)) : null;
                  final tenantName = ref.watch(sessionProvider.select((value) => value.valueOrNull?.tenant?.name));
                  return AiHistoryDrawer(
                    conversations: ref.watch(aiConversationsProvider),
                    currentId: currentId,
                    coins: data?.coins ?? const AiCoins(),
                    pendingProposals: data?.pendingProposals ?? 0,
                    status: _DrawerStatus(
                      tenantName: tenantName,
                      onSync: () {
                        _closeHistory();
                        this.context.push('/sync');
                      },
                    ),
                    onNew: _newChat,
                    onOpen: _openConversation,
                    onDelete: _delete,
                    onRefresh: _refresh,
                    onLoadMore: () => ref.read(aiConversationsProvider.notifier).loadMore().catchError((_) {}),
                  );
                },
              ),
            ),
          ),
      transitionBuilder:
          (context, animation, _, child) => SlideTransition(
            position: Tween(begin: const Offset(-1, 0), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
            child: child,
          ),
    );
    _historyRoute = route;
    await Navigator.of(context, rootNavigator: true).push(route);
    if (identical(_historyRoute, route)) {
      _historyRoute = null;
    }
  }

  void _newChat() {
    _closeHistory();
    if (!_live) {
      return;
    }
    setState(() {
      _openId = null;
      _started = false;
      _generation++;
    });
  }

  void _openConversation(int id) {
    _closeHistory();
    if (_currentId == id) {
      return;
    }
    setState(() {
      _openId = id;
      _started = false;
      _generation++;
    });
  }

  Future<void> _delete(AiConversation conversation) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Hapus percakapan?'),
            content: Text('"${conversation.title}" akan dihapus dari riwayat. Transaksi yang sudah tercatat tetap ada.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
              FilledButton(style: FilledButton.styleFrom(backgroundColor: Brand.danger), onPressed: () => Navigator.pop(context, true), child: const Text('Hapus')),
            ],
          ),
    );
    if (ok != true || !mounted) {
      return;
    }
    try {
      await ref.read(aiConversationsProvider.notifier).remove(conversation.id);
      if (mounted && _currentId == conversation.id) {
        _newChat();
      }
    } on ApiException catch (error) {
      if (mounted) {
        showMessage(context, error.message, error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncProvider);
    final overview = ref.watch(aiOverviewProvider);
    final offline = sync.connection == ConnectionStatus.offline;
    final data = overview.valueOrNull;

    if (offline && data == null) {
      return EmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Tim AI butuh internet',
        message: 'Sambungkan internet untuk mengobrol dengan Tim AI. Kasir tetap bisa dipakai offline.',
        action: OutlinedButton(onPressed: () => ref.read(syncProvider.notifier).syncNow(), child: const Text('Coba lagi')),
      );
    }
    if (overview.hasError && data == null) {
      final error = overview.error;
      final message = error is ApiException ? error.message : 'Tim AI belum bisa dibuka. Coba lagi.';
      final code = error is ApiException ? error.code : null;
      final (icon, title) = switch (code) {
        'tidak_berhak' => (Icons.lock_outline, 'Belum punya akses Tim AI'),
        'langganan_tidak_aktif' => (Icons.card_membership_outlined, 'Perusahaan sedang tidak aktif'),
        'perangkat_dicabut' => (Icons.phonelink_erase_outlined, 'Akses HP ini dicabut'),
        _ => (Icons.error_outline, 'Tim AI belum bisa dibuka'),
      };
      return EmptyState(icon: icon, title: title, message: message, action: code == 'tidak_berhak' ? null : OutlinedButton(onPressed: _refresh, child: const Text('Coba lagi')));
    }
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (data.channelLocked) {
      // Trial atau paket tanpa aplikasi HP: kalimat netral tanpa nama paket /
      // tempat membeli (kebijakan Google Play), jangan tampilkan chat.
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            EmptyState(
              key: const Key('ai-channel-locked'),
              icon: Icons.lock_outline,
              title: aiChannelLockedTitle,
              message: aiChannelLockedMessage,
            ),
          ],
        ),
      );
    }

    final canvas = AiColors.canvas(context);
    final conversations = ref.watch(aiConversationsProvider);
    final currentId = _live ? ref.watch(aiChatProvider(_chatKey).select((state) => state.conversationId)) : null;
    AiConversation? current;
    for (final item in conversations.valueOrNull?.items ?? const <AiConversation>[]) {
      if (item.id == currentId) {
        current = item;
      }
    }

    // Satu bilah atas saja (bilah aplikasi disembunyikan di tab ini oleh
    // HomeShell): menu Riwayat · judul · Percakapan baru.
    return Scaffold(
      backgroundColor: canvas,
      appBar: AppBar(
        key: const Key('ai-topbar'),
        toolbarHeight: 52,
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        centerTitle: true,
        titleSpacing: 4,
        leading: IconButton(
          key: const Key('ai-history'),
          tooltip: 'Riwayat percakapan',
          onPressed: _openHistory,
          icon: Badge(isLabelVisible: data.pendingProposals > 0, smallSize: 8, backgroundColor: Brand.amber, child: const Icon(Icons.menu_rounded)),
        ),
        title: AiChatTitle(chatKey: _chatKey, live: _live, center: true),
        actions: [
          if (currentId != null)
            PopupMenuButton<String>(
              key: const Key('ai-chat-menu'),
              tooltip: 'Pilihan percakapan',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (value) {
                if (value == 'muat') {
                  ref.read(aiChatProvider(_chatKey).notifier).load();
                } else if (value == 'hapus') {
                  _delete(current ?? AiConversation(id: currentId, title: ref.read(aiChatProvider(_chatKey)).title));
                }
              },
              itemBuilder: (context) => const [PopupMenuItem(value: 'muat', child: Text('Muat ulang')), PopupMenuItem(value: 'hapus', child: Text('Hapus percakapan'))],
            ),
          IconButton(key: const Key('new-conversation'), tooltip: 'Percakapan baru', onPressed: _newChat, icon: const NewChatIcon()),
          const SizedBox(width: 4),
        ],
      ),
      body: AiChatView(key: ValueKey('ai-chat-$_chatKey-$_generation'), chatKey: _chatKey, onStarted: () => setState(() => _started = true), onGone: _newChat),
    );
  }
}

/// Laci Riwayat: Percakapan baru, cari, daftar per hari, dan jatah Tim AI
/// bulan ini (bahasa sehari-hari) di bagian bawah.
class AiHistoryDrawer extends StatefulWidget {
  const AiHistoryDrawer({
    super.key,
    required this.conversations,
    required this.currentId,
    required this.coins,
    this.pendingProposals = 0,
    required this.onNew,
    required this.onOpen,
    required this.onDelete,
    required this.onRefresh,
    required this.onLoadMore,
    this.status,
  });

  final AsyncValue<AiConversationsState> conversations;

  /// Baris kecil di bawah judul: nama usaha + status sinkron (bilah aplikasi
  /// disembunyikan di tab Tim AI).
  final Widget? status;
  final int? currentId;
  final AiCoins coins;
  final int pendingProposals;
  final VoidCallback onNew;
  final ValueChanged<int> onOpen;
  final ValueChanged<AiConversation> onDelete;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;

  @override
  State<AiHistoryDrawer> createState() => _AiHistoryDrawerState();
}

class _AiHistoryDrawerState extends State<AiHistoryDrawer> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_query.isEmpty && _scroll.position.pixels > _scroll.position.maxScrollExtent - 200) {
        widget.onLoadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = mutedText(context);
    final state = widget.conversations.valueOrNull;
    final items = state?.items ?? const <AiConversation>[];
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty ? items : items.where((item) => item.title.toLowerCase().contains(query) || (item.preview ?? '').toLowerCase().contains(query)).toList();
    final groups = groupConversations(filtered, DateTime.now());
    final width = math.min(330.0, MediaQuery.sizeOf(context).width * 0.88);

    Widget message(IconData icon, String title, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
      child: Column(
        children: [
          Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: muted)),
        ],
      ),
    );

    final List<Widget> list;
    if (widget.conversations.isLoading && items.isEmpty) {
      list = [const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))];
    } else if (widget.conversations.hasError && items.isEmpty) {
      final error = widget.conversations.error;
      list = [message(Icons.error_outline, 'Riwayat belum bisa dimuat', error is ApiException ? error.message : 'Tarik ke bawah untuk memuat ulang.')];
    } else if (items.isEmpty) {
      list = [message(Icons.forum_outlined, 'Belum ada percakapan', 'Ketik, rekam suara, atau foto nota. Tim AI yang mencatat.')];
    } else if (filtered.isEmpty) {
      list = [message(Icons.search_off_rounded, 'Tidak ada yang cocok', 'Coba kata lain.')];
    } else {
      list = [
        for (final group in groups) ...[
          Padding(
            key: Key('history-group-${group.label}'),
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
            child: Text(group.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: muted, letterSpacing: 0.2)),
          ),
          for (final conversation in group.items)
            _HistoryTile(conversation: conversation, selected: conversation.id == widget.currentId, onTap: () => widget.onOpen(conversation.id), onDelete: () => widget.onDelete(conversation)),
        ],
        if (state?.loadingMore ?? false) const Padding(padding: EdgeInsets.all(12), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
      ];
    }

    return Drawer(
      key: const Key('ai-history-drawer'),
      width: width,
      backgroundColor: AiColors.canvas(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(20))),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(child: Text('Riwayat', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600))),
                  IconButton(tooltip: 'Tutup', onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.close_rounded)),
                ],
              ),
            ),
            if (widget.status != null) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 12, 4), child: widget.status),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: FilledButton.tonalIcon(
                key: const Key('drawer-new-conversation'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  alignment: Alignment.centerLeft,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
                  textStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 15, fontWeight: FontWeight.w600),
                ),
                onPressed: widget.onNew,
                icon: const NewChatIcon(size: 20),
                label: const Text('Percakapan baru'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: TextField(
                key: const Key('history-search'),
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Cari percakapan',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon:
                      _query.isEmpty
                          ? null
                          : IconButton(
                            tooltip: 'Hapus pencarian',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed:
                                () => setState(() {
                                  _search.clear();
                                  _query = '';
                                }),
                          ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  fillColor: AiColors.composerFill(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: AiColors.border(context))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: AiColors.border(context))),
                ),
              ),
            ),
            if (widget.pendingProposals > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Row(
                  children: [
                    Icon(Icons.hourglass_top_rounded, size: 16, color: warningText(context)),
                    const SizedBox(width: 6),
                    Expanded(child: Text('${widget.pendingProposals} usulan menunggu persetujuan', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: warningText(context)))),
                  ],
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: widget.onRefresh,
                child: ListView(key: const Key('history-list'), controller: _scroll, physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(8, 0, 8, 12), children: list),
              ),
            ),
            Divider(height: 1, color: AiColors.border(context)),
            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: CoinUsageBar(widget.coins, compact: true)),
          ],
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.conversation, required this.selected, required this.onTap, required this.onDelete});

  final AiConversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final muted = mutedText(context);
    final scheme = Theme.of(context).colorScheme;
    final channelIcon = switch (conversation.channel) {
      'telegram' => Icons.send_outlined,
      'web' => Icons.language,
      _ => null,
    };
    final preview = conversation.preview == null ? null : markdownToPlainText(conversation.preview!).replaceAll(RegExp(r'\s+'), ' ').trim();
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.1) : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: Key('conversation-${conversation.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onDelete,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(conversation.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
                        ),
                        if (channelIcon != null) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(channelIcon, size: 14, color: muted)),
                      ],
                    ),
                    if (preview != null && preview.isNotEmpty) Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted)),
                    if (conversation.working || conversation.pendingProposals > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child:
                            conversation.working
                                ? Row(
                                  children: [
                                    TypingDots(color: scheme.primary),
                                    const SizedBox(width: 6),
                                    Flexible(child: Text('Sedang dikerjakan', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: scheme.primary))),
                                  ],
                                )
                                : Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
                                  child: Text('${conversation.pendingProposals} usulan', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: warningText(context))),
                                ),
                      ),
                  ],
                ),
              ),
              // Hapus juga tersedia lewat menu (bukan hanya tahan lama) untuk pembaca layar.
              PopupMenuButton<String>(
                key: Key('conversation-menu-${conversation.id}'),
                tooltip: 'Menu percakapan',
                iconSize: 18,
                icon: Icon(Icons.more_vert_rounded, color: muted),
                onSelected: (_) => onDelete(),
                itemBuilder: (context) => const [PopupMenuItem(value: 'hapus', child: Text('Hapus percakapan'))],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Nama usaha + status sinkron (Online / Menyinkron / Offline) di laci.
class _DrawerStatus extends StatelessWidget {
  const _DrawerStatus({required this.tenantName, required this.onSync});

  final String? tenantName;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(tenantName ?? 'Infois', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: mutedText(context)))),
        const SizedBox(width: 8),
        SyncStatusBadge(onTap: onSync),
      ],
    );
  }
}
