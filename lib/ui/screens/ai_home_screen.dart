import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../domain/ai_models.dart';
import '../../state/ai_state.dart';
import '../../state/sync_controller.dart';
import '../theme.dart';
import '../widgets/ai_widgets.dart';
import '../widgets/common.dart';

/// Tab Tim AI: tim yang bekerja untuk Anda, jatah bulan ini, contoh
/// perintah, dan riwayat percakapan. Butuh internet.
class AiHomeScreen extends ConsumerStatefulWidget {
  const AiHomeScreen({super.key});

  @override
  ConsumerState<AiHomeScreen> createState() => _AiHomeScreenState();
}

class _AiHomeScreenState extends ConsumerState<AiHomeScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 200) {
        ref.read(aiConversationsProvider.notifier).loadMore().catchError((_) {});
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

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

  void _openChat({int? id, String? text}) {
    // Saat kembali, daftar dimuat ulang: percakapan yang baru dikirim dan
    // belum selesai dijawab ikut tampil dengan status terbaru.
    unawaited(context.push(id == null ? '/ai/percakapan' : '/ai/percakapan?id=$id', extra: text).then((_) {
      if (mounted) {
        unawaited(ref.read(aiConversationsProvider.notifier).refreshQuietly());
      }
    }));
  }

  Future<void> _delete(AiConversation conversation) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus percakapan?'),
        content: Text('"${conversation.title}" akan dihapus dari riwayat. Transaksi yang sudah tercatat tetap ada.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Brand.danger), onPressed: () => Navigator.pop(context, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    try {
      await ref.read(aiConversationsProvider.notifier).remove(conversation.id);
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
    final conversations = ref.watch(aiConversationsProvider);
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
        'langganan_tidak_aktif' => (Icons.card_membership_outlined, 'Langganan belum aktif'),
        'perangkat_dicabut' => (Icons.phonelink_erase_outlined, 'Akses HP ini dicabut'),
        _ => (Icons.error_outline, 'Tim AI belum bisa dibuka'),
      };
      return EmptyState(
        icon: icon,
        title: title,
        message: message,
        action: code == 'tidak_berhak' ? null : OutlinedButton(onPressed: _refresh, child: const Text('Coba lagi')),
      );
    }
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (data.channelLocked) {
      // Trial atau paket tanpa aplikasi HP: jelaskan paketnya, jangan tampilkan chat.
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          EmptyState(
            key: const Key('ai-channel-locked'),
            icon: Icons.lock_outline,
            title: 'Tim AI lewat HP belum termasuk paket',
            message: data.channels.message ??
                'Tersedia di paket berbayar${data.channels.unlockPlan == null ? '' : ' mulai paket ${data.channels.unlockPlan}'}. Sementara ini, Tim AI tetap bisa dipakai lewat web.',
            action: data.channels.unlockPlan == null
                ? null
                : Text('Pilih paket ${data.channels.unlockPlan} di menu Langganan (web) untuk membuka Tim AI di HP.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: mutedText(context))),
          ),
        ]),
      );
    }

    final items = conversations.valueOrNull?.items ?? const <AiConversation>[];
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
          if (offline) const _OfflineNote(),
          if (!data.enabled)
            Card(
              color: Brand.amber.withValues(alpha: 0.1),
              child: const ListTile(leading: Icon(Icons.pause_circle_outline, color: Brand.amber), title: Text('Tim AI sedang istirahat'), subtitle: Text('Layanan sedang tidak tersedia. Coba lagi beberapa saat lagi.')),
            ),
          _TeamsHeader(teams: data.teams),
          const SizedBox(height: 12),
          CoinUsageBar(data.coins),
          if (data.suggestions.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Coba katakan', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final suggestion in data.suggestions)
                ActionChip(
                  avatar: const Icon(Icons.chat_bubble_outline, size: 16),
                  label: Text(suggestion, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onPressed: offline ? null : () => _openChat(text: suggestion),
                ),
            ]),
          ],
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: Text('Percakapan', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
            if (data.pendingProposals > 0)
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
                  child: Text('${data.pendingProposals} menunggu persetujuan', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: warningText(context))),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          if (conversations.isLoading && items.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (conversations.hasError && items.isEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.error_outline, color: Brand.danger),
                title: const Text('Riwayat belum bisa dimuat'),
                subtitle: Text(conversations.error is ApiException ? (conversations.error as ApiException).message : 'Coba tarik ke bawah untuk memuat ulang.'),
              ),
            )
          else if (items.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  Icon(Icons.forum_outlined, size: 40, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 10),
                  const Text('Belum ada percakapan', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('Ketik, rekam suara, atau foto nota. Tim AI yang mencatat.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: mutedText(context))),
                ]),
              ),
            )
          else
            Card(
              child: Column(children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _ConversationTile(conversation: items[i], onTap: () => _openChat(id: items[i].id), onDelete: () => _delete(items[i])),
                ],
                if (conversations.valueOrNull?.loadingMore ?? false) const Padding(padding: EdgeInsets.all(12), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
              ]),
            ),
        ]),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new-conversation'),
        onPressed: offline || !data.enabled ? null : () => _openChat(),
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('Percakapan baru'),
      ),
    );
  }
}

class _OfflineNote extends StatelessWidget {
  const _OfflineNote();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
        child: const Row(children: [
          Icon(Icons.cloud_off_outlined, color: Brand.amber),
          SizedBox(width: 10),
          Expanded(child: Text('Tim AI butuh internet. Riwayat di bawah dari pembukaan terakhir.', style: TextStyle(fontSize: 13))),
        ]),
      );
}

/// Deretan avatar tim (warna & ikon sama dengan web); tim terkunci diberi gembok.
class _TeamsHeader extends StatelessWidget {
  const _TeamsHeader({required this.teams});

  final List<AiTeam> teams;

  @override
  Widget build(BuildContext context) {
    if (teams.isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Tim yang bekerja untuk Anda', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: teams.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final team = teams[index];
                return Tooltip(
                  message: team.locked ? '${team.role}\nTersedia di paket ${team.unlockPlan ?? 'lebih tinggi'}' : team.role,
                  child: SizedBox(
                    width: 84,
                    child: Column(children: [
                      Opacity(opacity: team.locked ? 0.55 : 1, child: TeamAvatar(tone: team.tone, icon: team.icon, size: 48, locked: team.locked)),
                      const SizedBox(height: 6),
                      Text(team.name.replaceFirst('Tim ', ''), maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: team.locked ? mutedText(context) : null)),
                    ]),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.onTap, required this.onDelete});

  final AiConversation conversation;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final at = conversation.lastMessageAt?.toLocal();
    final channelIcon = switch (conversation.channel) {
      'telegram' => Icons.send_outlined,
      'web' => Icons.language,
      _ => null,
    };
    return ListTile(
      key: Key('conversation-${conversation.id}'),
      onTap: onTap,
      onLongPress: onDelete,
      contentPadding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
      title: Row(children: [
        Expanded(child: Text(conversation.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
        if (channelIcon != null) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(channelIcon, size: 14, color: mutedText(context))),
      ]),
      subtitle: Text(_plain(conversation.preview) ?? 'Belum ada pesan', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: mutedText(context))),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (at != null) Text(_when(at), style: TextStyle(fontSize: 11, color: mutedText(context))),
          const SizedBox(height: 4),
          if (conversation.working)
            const TypingDots()
          else if (conversation.pendingProposals > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
              child: Text('${conversation.pendingProposals} usulan', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: warningText(context))),
            ),
        ]),
        // Hapus juga tersedia lewat menu (bukan hanya tahan lama) untuk pembaca layar.
        PopupMenuButton<String>(
          key: Key('conversation-menu-${conversation.id}'),
          tooltip: 'Menu percakapan',
          iconSize: 20,
          padding: EdgeInsets.zero,
          onSelected: (_) => onDelete(),
          itemBuilder: (context) => const [PopupMenuItem(value: 'hapus', child: Text('Hapus percakapan'))],
        ),
      ]),
    );
  }

  /// Buang tanda Markdown (**tebal**, `kode`, # judul) dari cuplikan pesan.
  static String? _plain(String? text) => text?.replaceAll('**', '').replaceAll('`', '').replaceAll(RegExp(r'^#+\s*', multiLine: true), '').trim();

  static String _when(DateTime at) {
    final now = DateTime.now();
    if (at.year == now.year && at.month == now.month && at.day == now.day) {
      return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    }
    return dateLabel(at);
  }
}
