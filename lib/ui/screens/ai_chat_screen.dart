import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store_policy.dart';
import '../../data/api_client.dart';
import '../../domain/ai_models.dart';
import '../../state/ai_state.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/ai_composer.dart';
import '../widgets/ai_markdown.dart';
import '../widgets/ai_widgets.dart';
import '../widgets/common.dart';
import 'ai_proposal_edit_sheet.dart';

/// Sapaan menurut jam: "Selamat pagi, Rani".
String aiGreeting(DateTime now, String? name) {
  final hour = now.hour;
  final part =
      hour >= 4 && hour < 11
          ? 'pagi'
          : hour >= 11 && hour < 15
          ? 'siang'
          : hour >= 15 && hour < 18
          ? 'sore'
          : 'malam';
  final first = (name ?? '').trim().split(RegExp(r'\s+')).first;
  return first.isEmpty ? 'Selamat $part' : 'Selamat $part, $first';
}

/// Saran perintah di layar awal: dari server, dilengkapi contoh tiap tim
/// yang terbuka (tanpa duplikat), maksimal [max].
List<String> aiSuggestions(AiOverview? overview, {int max = 4}) {
  final seen = <String>{};
  final out = <String>[];
  for (final text in [
    ...?overview?.suggestions,
    for (final team in overview?.teams ?? const <AiTeam>[])
      if (!team.locked && team.example != null) team.example!,
  ]) {
    final clean = text.trim();
    if (clean.isEmpty || !seen.add(clean.toLowerCase())) {
      continue;
    }
    out.add(clean);
    if (out.length >= max) {
      break;
    }
  }
  return out;
}

/// Judul percakapan di bilah atas. Status "sedang mengerjakan" cukup tampil
/// di baris percakapan + tombol Kirim (tidak diulang di sini).
/// [live] false = percakapan baru yang belum dikirim (provider belum dipakai).
class AiChatTitle extends ConsumerWidget {
  const AiChatTitle({super.key, required this.chatKey, required this.live, this.center = false});

  final int chatKey;
  final bool live;
  final bool center;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var title = 'Tim AI';
    if (live) {
      final chat = ref.watch(aiChatProvider(chatKey).select((state) => (state.conversationId, state.messages.isNotEmpty, state.title)));
      if (chat.$1 != null || chat.$2) {
        title = chat.$3;
      }
    }
    return Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: center ? TextAlign.center : TextAlign.start, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600));
  }
}

/// Layar percakapan (rute /ai/percakapan): bilah judul + [AiChatView].
class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({super.key, this.conversationId, this.initialText});

  /// null = percakapan baru (dibuat server saat pesan pertama dikirim).
  final int? conversationId;
  final String? initialText;

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  bool _started = false;

  int get _key => widget.conversationId ?? 0;
  bool get _live => _key != 0 || _started;

  @override
  Widget build(BuildContext context) {
    final canvas = AiColors.canvas(context);
    return Scaffold(
      backgroundColor: canvas,
      appBar: AppBar(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: AiChatTitle(chatKey: _key, live: _live),
        actions: [
          if (_live)
            Consumer(
              builder: (context, ref, _) {
                final chat = ref.watch(aiChatProvider(_key));
                if (chat.conversationId == null) {
                  return const SizedBox.shrink();
                }
                return IconButton(tooltip: 'Muat ulang', onPressed: chat.loading ? null : ref.read(aiChatProvider(_key).notifier).load, icon: const Icon(Icons.refresh));
              },
            ),
        ],
      ),
      body: AiChatView(
        chatKey: _key,
        initialText: widget.initialText,
        onStarted: () => setState(() => _started = true),
        onGone: () {
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
          }
        },
      ),
    );
  }
}

/// Isi percakapan bergaya aplikasi chat: layar awal dengan sapaan dan saran
/// (kotak tulis di tengah), lalu pesan + kotak tulis menempel di bawah.
/// Jawaban Tim AI tanpa bubble (Markdown), pesan pengguna bubble lembut di
/// kanan, kartu usulan (Setujui · Ubah · Tolak), proses dipantau tiap 2 detik.
class AiChatView extends ConsumerStatefulWidget {
  const AiChatView({super.key, required this.chatKey, this.initialText, this.onStarted, this.onGone});

  /// Id percakapan; 0 = percakapan baru.
  final int chatKey;
  final String? initialText;

  /// Pesan pertama percakapan baru dikirim (judul di bilah atas mulai dipantau).
  final VoidCallback? onStarted;

  /// Percakapan dihapus di tempat lain (web/HP lain).
  final VoidCallback? onGone;

  @override
  ConsumerState<AiChatView> createState() => _AiChatViewState();
}

class _AiChatViewState extends ConsumerState<AiChatView> {
  final Set<int> _busyProposals = {};
  final ScrollController _scroll = ScrollController();
  final GlobalKey<AiComposerState> _composerKey = GlobalKey<AiComposerState>();
  bool _started = false;
  bool _showJump = false;

  /// Kotak tulis berisi teks/lampiran (saran di layar awal disembunyikan).
  bool _composerHasContent = false;

  /// Menunggu jawaban Tim AI untuk pesan yang baru dikirim.
  bool _awaitingAnswer = false;

  /// Pembungkus jawaban terbaru (selalu baris paling bawah daftar terbalik).
  final GlobalKey _newestAnswerKey = GlobalKey(debugLabel: 'ai-newest-answer');

  /// Kotak tulis yang menempel di bawah (tinggi dipakai untuk menaruh
  /// pemberitahuan singkat di atasnya).
  final GlobalKey _dockKey = GlobalKey(debugLabel: 'ai-dock');

  int get _key => widget.chatKey;

  /// Percakapan baru belum memakai provider sampai pesan pertama dikirim,
  /// supaya "Percakapan baru" selalu mulai dari keadaan bersih.
  bool get _live => _key != 0 || _started;

  AiChatController get _controller => ref.read(aiChatProvider(_key).notifier);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final show = _scroll.hasClients && _scroll.offset > 320;
    if (show != _showJump) {
      setState(() => _showJump = show);
    }
  }

  void _scrollToBottom() {
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  /// Jawaban baru yang lebih tinggi dari layar dibaca dari awalnya: geser
  /// sehingga nama tim + baris pertama ada di atas layar (bukan ujungnya).
  bool _revealNewestAnswer() {
    final context = _newestAnswerKey.currentContext;
    final box = context?.findRenderObject();
    if (context == null || box is! RenderBox || !box.hasSize || !_scroll.hasClients) {
      return false;
    }
    if (box.size.height <= _scroll.position.viewportDimension * 0.85) {
      return false;
    }
    // Daftar terbalik: alignment 1 = tepi atas jawaban di tepi atas layar.
    Scrollable.ensureVisible(context, alignment: 1, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    return true;
  }

  Future<void> _send(String text, List<AiDraftAttachment> attachments) async {
    if (!_live) {
      setState(() => _started = true);
      widget.onStarted?.call();
      // Tampilkan (pantau) percakapan dulu, baru kirim: provider yang dibaca
      // tanpa pemantau bisa langsung dibuang di frame berikutnya.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return;
      }
    }
    _scrollToBottom();
    await _controller.send(text, attachments: attachments);
  }

  Future<void> _approve(AiProposal proposal, {Map<String, dynamic>? edits}) async {
    setState(() => _busyProposals.add(proposal.id));
    try {
      await _controller.approve(proposal, edits: edits);
    } finally {
      if (mounted) {
        setState(() => _busyProposals.remove(proposal.id));
      }
    }
  }

  Future<void> _edit(AiProposal proposal) async {
    final accounts = ref.read(masterDataProvider).valueOrNull?.accounts ?? const [];
    final edits = await showProposalEditSheet(context, proposal, accounts: accounts);
    if (edits != null && mounted) {
      await _approve(proposal, edits: edits);
    }
  }

  Future<void> _reject(AiProposal proposal) async {
    setState(() => _busyProposals.add(proposal.id));
    try {
      await _controller.reject(proposal);
    } finally {
      if (mounted) {
        setState(() => _busyProposals.remove(proposal.id));
      }
    }
  }

  Future<void> _setFastMode(bool enabled) async {
    final api = ref.read(aiApiProvider);
    if (api == null) {
      throw const ApiException('Belum ada perusahaan aktif.');
    }
    try {
      await api.setFastMode(enabled);
      ref.invalidate(aiOverviewProvider);
      if (mounted) {
        showMessage(context, enabled ? 'Mode cepat aktif.' : 'Mode cepat dimatikan.');
      }
    } on ApiException catch (error) {
      if (mounted) {
        showMessage(context, error.message, error: true);
      }
      rethrow;
    }
  }

  Future<void> _copy(String text, {String message = 'Teks disalin.'}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      _toast(message);
    }
  }

  /// Pemberitahuan singkat yang melayang di atas kotak tulis (tidak menutupi
  /// tombol Kirim seperti pemberitahuan biasa di dasar layar).
  void _toast(String message) {
    final dock = _dockKey.currentContext?.findRenderObject();
    final lift = dock is RenderBox && dock.hasSize ? dock.size.height : 0.0;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('ai-toast'),
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          margin: EdgeInsets.fromLTRB(16, 0, 16, lift + 4),
        ),
      );
  }

  void _showActions(AiMessage message, VoidCallback? onRegenerate) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder:
          (sheet) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  key: const Key('action-copy'),
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('Salin teks'),
                  onTap: () {
                    Navigator.pop(sheet);
                    _copy(markdownToPlainText(message.content));
                  },
                ),
                if (onRegenerate != null)
                  ListTile(
                    key: const Key('action-regenerate'),
                    leading: const Icon(Icons.refresh_rounded),
                    title: const Text('Coba lagi'),
                    subtitle: const Text('Kirim ulang pesan terakhir Anda'),
                    onTap: () {
                      Navigator.pop(sheet);
                      onRegenerate();
                    },
                  ),
              ],
            ),
          ),
    );
  }

  void _showTeams(List<AiTeam> teams) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder:
          (sheet) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            maxChildSize: 0.9,
            builder:
                (context, scroll) => ListView(
                  key: const Key('ai-teams'),
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  children: [
                    Text('Tim yang bekerja untuk Anda', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('Tulis saja kebutuhan Anda; tim yang tepat akan mengerjakannya.', style: TextStyle(fontSize: 13, color: mutedText(context))),
                    const SizedBox(height: 12),
                    for (final team in teams)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Opacity(opacity: team.locked ? 0.55 : 1, child: TeamAvatar(tone: team.tone, icon: team.icon, size: 40, locked: team.locked)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(team.name, style: TextStyle(fontWeight: FontWeight.w600, color: team.locked ? mutedText(context) : null)),
                                  if (team.role.isNotEmpty) Text(team.role, style: TextStyle(fontSize: 12.5, color: mutedText(context))),
                                  if (team.locked)
                                    Text(aiTeamLockedLabel, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: warningText(context))),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = _live ? ref.watch(aiChatProvider(_key)) : const AiChatState(loading: false);
    final sync = ref.watch(syncProvider);
    final overview = ref.watch(aiOverviewProvider).valueOrNull;
    final userName = ref.watch(sessionProvider).valueOrNull?.user?.name;
    final offline = sync.connection == ConnectionStatus.offline;

    if (_live) {
      ref.listen(aiChatProvider(_key).select((state) => (state.notice, state.noticeIsError, state.gone)), (_, value) {
        final (notice, isError, gone) = value;
        if (notice != null) {
          showMessage(context, notice, error: isError);
          _controller.clearNotice();
        }
        if (gone) {
          widget.onGone?.call();
        }
      });
      // Pesan baru masuk saat pengguna di bawah: tetap ikuti yang terbaru;
      // jawaban panjang ditampilkan dari awalnya.
      ref.listen(aiChatProvider(_key).select((state) => (state.messages.length, state.busy)), (previous, next) {
        if (next.$2) {
          _awaitingAnswer = true;
        }
        final messages = ref.read(aiChatProvider(_key)).messages;
        final answered = _awaitingAnswer && previous != null && next.$1 > previous.$1 && messages.isNotEmpty && !messages.last.isUser;
        if (answered) {
          _awaitingAnswer = false;
        }
        if (_scroll.hasClients && _scroll.offset < 160) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || (answered && _revealNewestAnswer())) {
              return;
            }
            _scrollToBottom();
          });
        }
      });
    }

    final paused = overview != null && !overview.enabled;
    final enabled = !offline && !paused;
    final uploading = chat.phase == AiChatPhase.sending && chat.uploadProgress != null;
    final teamName = chat.lastTeam?.name ?? 'Tim AI';
    final workingLabel = switch (chat.phase) {
      AiChatPhase.sending => uploading ? 'Mengunggah lampiran' : 'Mengirim pesan',
      _ => '$teamName sedang bekerja',
    };
    final composer = AiComposer(
      key: _composerKey,
      enabled: enabled,
      working: chat.busy,
      workingLabel: workingLabel,
      progress: uploading ? chat.uploadProgress : null,
      limits: overview?.limits ?? const AiLimits(),
      initialText: widget.initialText,
      disabledReason: offline ? 'Tim AI butuh internet.' : (paused ? 'Tim AI sedang tidak tersedia. Coba lagi nanti.' : null),
      fastMode: overview?.fastMode,
      onFastModeChanged: overview == null ? null : _setFastMode,
      onContentChanged: (has) {
        if (mounted && has != _composerHasContent) {
          setState(() => _composerHasContent = has);
        }
      },
      onSend: _send,
    );

    final notices = <Widget>[
      if (offline)
        _Notice(
          key: const Key('ai-offline'),
          icon: Icons.cloud_off_outlined,
          text: 'Tim AI butuh internet. Pesan bisa dikirim lagi setelah tersambung.',
          actionLabel: 'Cek lagi',
          onAction: () => ref.read(syncProvider.notifier).syncNow(),
        ),
      if (paused && !offline) const _Notice(key: Key('ai-paused'), icon: Icons.pause_circle_outline, text: 'Tim AI sedang istirahat. Coba lagi beberapa saat lagi.'),
      if (chat.loadError != null) _Notice(key: const Key('ai-load-error'), icon: Icons.error_outline, error: true, text: chat.loadError!, actionLabel: 'Coba lagi', onAction: _controller.load),
      if (chat.pollError != null) _Notice(key: const Key('ai-poll-error'), icon: Icons.sync_problem, text: chat.pollError!, actionLabel: 'Coba lagi', onAction: _controller.resumePolling),
    ];

    // Kotak tulis selalu menempel di bawah (layar awal maupun percakapan),
    // tingginya dibatasi supaya bilah alat + Kirim tetap terlihat di atas
    // keyboard; isinya yang menggulir.
    Widget dock(BoxConstraints constraints) => ConstrainedBox(
      key: _dockKey,
      constraints: BoxConstraints(maxHeight: math.max(AiComposerState.toolbarHeight + 62, constraints.maxHeight * 0.6)),
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: composer),
              // Disembunyikan saat keyboard terbuka supaya Kirim tetap terlihat di layar kecil.
              if (View.of(context).viewInsets.bottom == 0) ...[
                const SizedBox(height: 4),
                Text('AI dapat membuat kesalahan, periksa sebelum melakukan keputusan!', key: const Key('ai-disclaimer'), textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: mutedText(context))),
              ],
            ],
          ),
        ),
      ),
    );

    final content = LayoutBuilder(
      builder: (context, constraints) {
        if (chat.loading && chat.messages.isEmpty) {
          return Column(children: [const Expanded(child: Center(child: CircularProgressIndicator())), dock(constraints)]);
        }
        if (chat.messages.isEmpty && !chat.busy) {
          return _Welcome(
            greeting: aiGreeting(DateTime.now(), userName),
            teams: overview?.teams ?? const [],
            suggestions: aiSuggestions(overview),
            showSuggestions: !_composerHasContent,
            composer: dock(constraints),
            enabled: enabled,
            onSuggestion: (text) => _composerKey.currentState?.fill(text),
            onShowTeams: () => _showTeams(overview?.teams ?? const []),
          );
        }
        return Column(children: [Expanded(child: _messages(chat, overview, enabled)), dock(constraints)]);
      },
    );

    return ColoredBox(
      color: AiColors.canvas(context),
      child: Column(children: [...notices, Expanded(child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: content)))]),
    );
  }

  Widget _messages(AiChatState chat, AiOverview? overview, bool enabled) {
    final messages = chat.messages;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBubble = constraints.maxWidth * 0.8;
        return Stack(
          children: [
            ListView.builder(
              key: const Key('ai-messages'),
              controller: _scroll,
              reverse: true,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              itemCount: messages.length + (chat.busy ? 1 : 0),
              itemBuilder: (context, index) {
                if (chat.busy && index == 0) {
                  final team = chat.lastTeam;
                  return _WorkingIndicator(phase: chat.phase, team: team, teamIcon: overview?.team(team?.key ?? '')?.icon ?? '', uploadProgress: chat.uploadProgress);
                }
                final position = messages.length - 1 - (chat.busy ? index - 1 : index);
                final message = messages[position];
                if (message.isUser) {
                  final uploadingThis = chat.phase == AiChatPhase.sending && chat.uploadProgress != null && message.id == null && position == messages.length - 1;
                  return _UserMessage(
                    message: message,
                    maxWidth: maxBubble,
                    uploadProgress: uploadingThis ? chat.uploadProgress : null,
                    onCopy: message.content.isEmpty ? null : () => _copy(message.content, message: 'Pesan disalin.'),
                    onRetry: message.sendError == null || message.localId == null || !_controller.canRetry(message.localId!) ? null : () => _controller.retry(message.localId!),
                  );
                }
                final regenerate = _canRegenerate(chat, position, enabled) ? _controller.resendLast : null;
                final answer = _AssistantMessage(
                  message: message,
                  teamIcon: overview?.team(message.teams.isEmpty ? '' : message.teams.first.key)?.icon ?? '',
                  busyProposals: _busyProposals,
                  onApprove: _approve,
                  onEdit: _edit,
                  onReject: _reject,
                  onCopy: () => _copy(markdownToPlainText(message.content)),
                  onActions: () => _showActions(message, regenerate),
                  onResend: message.failed && !chat.busy ? _controller.resendLast : null,
                  onRegenerate: regenerate,
                );
                // Hanya baris paling bawah yang memakai kunci ini (tidak pernah ganda).
                return index == 0 ? KeyedSubtree(key: _newestAnswerKey, child: answer) : answer;
              },
            ),
            // Pesan memudar ke arah kotak tulis, tidak terpotong tajam.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 20,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [AiColors.canvas(context).withValues(alpha: 0), AiColors.canvas(context)]),
                  ),
                ),
              ),
            ),
            if (_showJump)
              Positioned(
                left: 0,
                right: 0,
                bottom: 16,
                child: Center(
                  child: Material(
                    color: AiColors.composerFill(context),
                    shape: CircleBorder(side: BorderSide(color: AiColors.border(context))),
                    elevation: 2,
                    child: IconButton(key: const Key('ai-jump-bottom'), tooltip: 'Ke pesan terbaru', onPressed: _scrollToBottom, icon: const Icon(Icons.arrow_downward_rounded)),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// "Coba lagi" untuk jawaban terakhir yang hanya berisi teks (tanpa usulan,
  /// supaya tidak ada transaksi ganda) dari pesan teks tanpa lampiran.
  bool _canRegenerate(AiChatState chat, int position, bool enabled) {
    final message = chat.messages[position];
    if (!enabled || chat.busy || message.failed || message.proposals.isNotEmpty || position != chat.messages.length - 1) {
      return false;
    }
    for (var i = position - 1; i >= 0; i--) {
      final previous = chat.messages[i];
      if (previous.isUser) {
        return previous.content.trim().isNotEmpty && previous.attachments.isEmpty;
      }
    }
    return false;
  }
}

/// Pemberitahuan tipis di atas percakapan (offline, gagal memuat, dsb).
class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.text, this.error = false, this.actionLabel, this.onAction});

  final IconData icon;
  final String text;
  final bool error;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final color = error ? dangerText(context) : warningText(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(color: (error ? Brand.danger : Brand.amber).withValues(alpha: error ? 0.1 : 0.13), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          if (actionLabel != null && onAction != null) TextButton(style: TextButton.styleFrom(visualDensity: VisualDensity.compact), onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// Layar awal percakapan baru: logo, sapaan, dan deretan tim di tengah ruang
/// kosong; saran perintah tepat di atas kotak tulis yang menempel di bawah
/// (posisinya sama dengan saat percakapan berjalan, jadi tidak melompat).
class _Welcome extends StatelessWidget {
  const _Welcome({
    required this.greeting,
    required this.teams,
    required this.suggestions,
    required this.showSuggestions,
    required this.composer,
    required this.enabled,
    required this.onSuggestion,
    required this.onShowTeams,
  });

  final String greeting;
  final List<AiTeam> teams;
  final List<String> suggestions;

  /// false selama kotak tulis berisi (saran tidak relevan lagi).
  final bool showSuggestions;
  final Widget composer;
  final bool enabled;
  final ValueChanged<String> onSuggestion;
  final VoidCallback onShowTeams;

  @override
  Widget build(BuildContext context) {
    final muted = mutedText(context);
    final open = teams.where((team) => !team.locked).length;
    final header = <Widget>[
      const BrandMark(size: 44),
      const SizedBox(height: 14),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(greeting, key: const Key('ai-greeting'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, height: 1.25)),
      ),
      const SizedBox(height: 6),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('Apa yang bisa Tim AI kerjakan hari ini?', textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: muted))),
      if (teams.isNotEmpty) ...[
        const SizedBox(height: 14),
        Semantics(
          button: true,
          label: 'Lihat tim yang bekerja untuk Anda',
          excludeSemantics: true,
          child: InkWell(
            key: const Key('ai-teams-row'),
            borderRadius: BorderRadius.circular(24),
            onTap: onShowTeams,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TeamAvatarRow(teams: teams, size: 28),
                  const SizedBox(width: 8),
                  Flexible(child: Text('$open tim siap bekerja', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: muted))),
                  Icon(Icons.chevron_right_rounded, size: 18, color: muted),
                ],
              ),
            ),
          ),
        ),
      ],
    ];
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Saran disembunyikan saat mengetik / melampirkan, dan saat ruang
        // sangat sempit (keyboard terbuka di HP kecil).
        final visible = suggestions.isNotEmpty && showSuggestions && constraints.maxHeight > 300 * scale;
        return Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder:
                    (context, area) => ShaderMask(
                      // Bagian bawah memudar: isi yang tergulir tidak terpotong di tengah huruf.
                      blendMode: BlendMode.dstIn,
                      shaderCallback:
                          (rect) => LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: const [Colors.white, Colors.white, Colors.transparent],
                            stops: [0, rect.height <= 20 ? 0 : 1 - 20 / rect.height, 1],
                          ).createShader(rect),
                      child: SingleChildScrollView(
                        key: const Key('ai-welcome'),
                        padding: const EdgeInsets.fromLTRB(12, 16, 12, 20),
                        child: ConstrainedBox(constraints: BoxConstraints(minHeight: math.max(0, area.maxHeight - 36)), child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: header))),
                      ),
                    ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child:
                  visible
                      ? Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SingleChildScrollView(
                          key: const Key('ai-suggestions'),
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < suggestions.length; i++)
                                Padding(
                                  padding: EdgeInsets.only(right: i == suggestions.length - 1 ? 0 : 8),
                                  child: _SuggestionCard(key: Key('ai-suggestion-$i'), text: suggestions[i], onTap: enabled ? () => onSuggestion(suggestions[i]) : null),
                                ),
                            ],
                          ),
                        ),
                      )
                      : const SizedBox(width: double.infinity),
            ),
            composer,
          ],
        );
      },
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({super.key, required this.text, this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Pakai saran: $text',
      excludeSemantics: true,
      child: Material(
        color: AiColors.composerFill(context).withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: AiColors.border(context))),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            width: 196,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.auto_awesome_outlined, size: 16, color: scheme.primary)),
                const SizedBox(width: 8),
                Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.35))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Teks yang berkilau pelan (gaya "sedang berpikir").
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});

  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = mutedText(context);
    final highlight = Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value * 2 - 0.5;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(colors: [base, highlight, base], stops: [(t - 0.25).clamp(0.0, 1.0), t.clamp(0.0, 1.0), (t + 0.25).clamp(0.0, 1.0)]).createShader(bounds),
          child: child,
        );
      },
    );
  }
}

/// "Tim Gudang sedang mengerjakan…" berkilau (tanpa titik tambahan); saat
/// mengunggah lampiran tampil bilah kemajuan.
class _WorkingIndicator extends StatelessWidget {
  const _WorkingIndicator({required this.phase, required this.team, required this.teamIcon, this.uploadProgress});

  final AiChatPhase phase;
  final AiMessageTeam? team;
  final String teamIcon;
  final double? uploadProgress;

  @override
  Widget build(BuildContext context) {
    final sending = phase == AiChatPhase.sending;
    final label = sending ? (uploadProgress == null ? 'Mengirim…' : 'Mengunggah lampiran ${(uploadProgress! * 100).round()}%') : '${team?.name ?? 'Tim AI'} sedang mengerjakan…';
    return Padding(
      key: const Key('ai-working'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Semantics(
        liveRegion: true,
        label: label,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                TeamAvatar(tone: team?.tone ?? 'sky', icon: teamIcon, size: 26),
                const SizedBox(width: 10),
                Flexible(child: _Shimmer(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)))),
              ],
            ),
            if (sending && uploadProgress != null)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 8),
                child: SizedBox(width: 180, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: uploadProgress, minHeight: 4))),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lampiran yang sedang diunggah: lapisan gelap + cincin kemajuan.
class _UploadOverlay extends StatelessWidget {
  const _UploadOverlay({required this.progress, required this.child});

  final double? progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (progress == null) {
      return child;
    }
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(12)),
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(value: progress, strokeWidth: 3, color: Colors.white, backgroundColor: Colors.white24, semanticsLabel: 'Mengunggah lampiran'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UserMessage extends StatelessWidget {
  const _UserMessage({required this.message, required this.maxWidth, this.uploadProgress, this.onRetry, this.onCopy});

  final AiMessage message;
  final double maxWidth;
  final double? uploadProgress;
  final VoidCallback? onRetry;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = message.sendError != null;
    return Padding(
      key: Key('msg-${message.key}'),
      padding: const EdgeInsets.only(bottom: 18, left: 24),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final file in message.attachments)
                        _UploadOverlay(
                          progress: file.localPath != null ? uploadProgress : null,
                          child: file.isImage ? AttachmentImage(file, size: 120) : (file.isAudio ? AudioNotePlayer(file, compact: true) : AttachmentChip(file)),
                        ),
                    ],
                  ),
                ),
              if (message.content.isNotEmpty)
                GestureDetector(
                  onLongPress: onCopy,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: failed ? Brand.danger.withValues(alpha: 0.12) : AiColors.userBubble(context),
                      borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20), bottomLeft: Radius.circular(20), bottomRight: Radius.circular(6)),
                    ),
                    child: Text(message.content, style: TextStyle(color: scheme.onSurface, fontSize: 15.5, height: 1.45)),
                  ),
                ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 14, color: dangerText(context)),
                      const SizedBox(width: 4),
                      Text(message.sendError!, style: TextStyle(fontSize: 12, color: dangerText(context))),
                      if (onRetry != null) TextButton(key: Key('retry-${message.key}'), onPressed: onRetry, child: const Text('Kirim ulang')),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Jawaban Tim AI: avatar + nama tim, lalu teks penuh (tanpa bubble), file,
/// kartu usulan, dan tombol kecil Salin / Coba lagi.
class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.message,
    required this.teamIcon,
    required this.busyProposals,
    required this.onApprove,
    required this.onEdit,
    required this.onReject,
    required this.onCopy,
    required this.onActions,
    this.onResend,
    this.onRegenerate,
  });

  final AiMessage message;
  final String teamIcon;
  final Set<int> busyProposals;
  final Future<void> Function(AiProposal proposal) onApprove;
  final Future<void> Function(AiProposal proposal) onEdit;
  final Future<void> Function(AiProposal proposal) onReject;
  final VoidCallback onCopy;
  final VoidCallback onActions;
  final VoidCallback? onResend;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    final team = message.teams.isEmpty ? null : message.teams.first;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final failed = message.failed;
    final hasText = message.content.trim().isNotEmpty;
    final muted = mutedText(context);
    final fileAttachments = message.attachments;
    return Padding(
      key: Key('msg-${message.key}'),
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TeamAvatar(tone: team?.tone ?? 'sky', icon: teamIcon, size: 26),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  team?.name ?? 'Tim AI',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: toneColors(team?.tone ?? 'sky', dark: dark).foreground),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (failed)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
              decoration: BoxDecoration(color: Brand.danger.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.error_outline, size: 18, color: dangerText(context))),
                      const SizedBox(width: 8),
                      Expanded(child: AiMarkdown(hasText ? message.content : 'Maaf, permintaan ini gagal diproses.', style: const TextStyle(fontSize: 14.5, height: 1.45))),
                    ],
                  ),
                  if (onResend != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(key: Key('resend-${message.key}'), onPressed: onResend, icon: const Icon(Icons.refresh, size: 18), label: const Text('Coba lagi')),
                    ),
                ],
              ),
            )
          else if (hasText)
            GestureDetector(onLongPress: onActions, child: AiMarkdown(message.content)),
          if (fileAttachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final file in fileAttachments)
                    if (file.isImage) AttachmentImage(file, size: 160) else if (file.isAudio) AudioNotePlayer(file) else if (file.url != null) AiFileCard(file) else AttachmentChip(file),
                ],
              ),
            ),
          for (final proposal in message.proposals)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ProposalCard(
                proposal: proposal,
                busy: busyProposals.contains(proposal.id),
                onApprove: () => onApprove(proposal),
                onEdit: () => onEdit(proposal),
                onReject: () => onReject(proposal),
              ),
            ),
          if (!failed && hasText)
            // Area ketuk 48dp; digeser supaya ikonnya sejajar dengan teks.
            Transform.translate(
              offset: const Offset(-15, 0),
              child: Row(
                children: [
                  IconButton(key: Key('copy-${message.key}'), tooltip: 'Salin', iconSize: 18, color: muted, onPressed: onCopy, icon: const Icon(Icons.copy_rounded)),
                  if (onRegenerate != null)
                    IconButton(key: Key('regenerate-${message.key}'), tooltip: 'Coba lagi', iconSize: 18, color: muted, onPressed: onRegenerate, icon: const Icon(Icons.refresh_rounded)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
