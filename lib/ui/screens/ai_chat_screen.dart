import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ai_models.dart';
import '../../state/ai_state.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/ai_composer.dart';
import '../widgets/ai_widgets.dart';
import '../widgets/common.dart';
import 'ai_proposal_edit_sheet.dart';

/// Layar percakapan dengan Tim AI: bubble pesan, lampiran, kartu usulan
/// (Setujui · Ubah · Tolak), status proses yang dipantau tiap 2 detik.
class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({super.key, this.conversationId, this.initialText});

  /// null = percakapan baru (dibuat server saat pesan pertama dikirim).
  final int? conversationId;
  final String? initialText;

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final Set<int> _busyProposals = {};

  int get _key => widget.conversationId ?? 0;

  Future<void> _approve(AiProposal proposal, {Map<String, dynamic>? edits}) async {
    setState(() => _busyProposals.add(proposal.id));
    try {
      await ref.read(aiChatProvider(_key).notifier).approve(proposal, edits: edits);
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
      await ref.read(aiChatProvider(_key).notifier).reject(proposal);
    } finally {
      if (mounted) {
        setState(() => _busyProposals.remove(proposal.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(aiChatProvider(_key));
    final controller = ref.read(aiChatProvider(_key).notifier);
    final sync = ref.watch(syncProvider);
    final overview = ref.watch(aiOverviewProvider).valueOrNull;
    final user = ref.watch(sessionProvider).valueOrNull?.user;
    final offline = sync.connection == ConnectionStatus.offline;

    ref.listen(aiChatProvider(_key).select((state) => (state.notice, state.noticeIsError, state.gone)), (_, value) {
      final (notice, isError, gone) = value;
      if (notice != null) {
        showMessage(context, notice, error: isError);
        controller.clearNotice();
      }
      // Percakapan dihapus dari web/HP lain: kembali ke daftar.
      if (gone && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    });

    final working = chat.phase == AiChatPhase.queued || chat.phase == AiChatPhase.running;
    final teamName = chat.lastTeam?.name ?? 'Tim AI';
    final limits = overview?.limits ?? const AiLimits();
    final disabledReason = offline
        ? 'Tim AI butuh internet.'
        : (chat.busy ? 'Tunggu jawaban Tim AI dulu.' : (overview != null && !overview.enabled ? 'Tim AI sedang tidak tersedia. Coba lagi nanti.' : null));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
          Text(working ? '$teamName sedang mengerjakan…' : 'Tim AI', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: mutedText(context))),
        ]),
        actions: [
          if (chat.conversationId != null) IconButton(tooltip: 'Muat ulang', onPressed: chat.loading ? null : controller.load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(children: [
        if (offline)
          MaterialBanner(
            key: const Key('ai-offline'),
            backgroundColor: Brand.amber.withValues(alpha: 0.12),
            leading: const Icon(Icons.cloud_off_outlined, color: Brand.amber),
            content: const Text('Tim AI butuh internet. Pesan bisa dikirim lagi setelah tersambung.'),
            actions: [TextButton(onPressed: () => ref.read(syncProvider.notifier).syncNow(), child: const Text('Cek lagi'))],
          ),
        if (chat.loadError != null)
          MaterialBanner(
            key: const Key('ai-load-error'),
            backgroundColor: Brand.danger.withValues(alpha: 0.08),
            leading: Icon(Icons.error_outline, color: dangerText(context)),
            content: Text(chat.loadError!),
            actions: [TextButton(onPressed: controller.load, child: const Text('Coba lagi'))],
          ),
        if (chat.pollError != null)
          MaterialBanner(
            key: const Key('ai-poll-error'),
            backgroundColor: Brand.amber.withValues(alpha: 0.12),
            leading: const Icon(Icons.sync_problem, color: Brand.amber),
            content: Text(chat.pollError!),
            actions: [TextButton(onPressed: controller.resumePolling, child: const Text('Coba lagi'))],
          ),
        Expanded(
          child: chat.loading && chat.messages.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : chat.messages.isEmpty && !chat.busy
                  ? _Welcome(teams: overview?.teams ?? const [])
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      itemCount: chat.messages.length + (chat.busy ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (chat.busy && index == 0) {
                          return _WorkingIndicator(phase: chat.phase, team: chat.lastTeam, uploadProgress: chat.uploadProgress);
                        }
                        final message = chat.messages[chat.messages.length - 1 - (chat.busy ? index - 1 : index)];
                        return message.isUser
                            ? _UserBubble(message: message, userName: user?.name ?? 'Anda', onRetry: message.sendError == null || message.localId == null || !controller.canRetry(message.localId!) ? null : () => controller.retry(message.localId!))
                            : _AssistantBubble(
                                message: message,
                                teamIcon: overview?.team(message.teams.isEmpty ? '' : message.teams.first.key)?.icon ?? '',
                                busyProposals: _busyProposals,
                                onApprove: _approve,
                                onEdit: _edit,
                                onReject: _reject,
                                onResend: message.failed && !chat.busy ? controller.resendLast : null,
                              );
                      },
                    ),
        ),
        AiComposer(
          key: ValueKey('composer-$_key'),
          enabled: !offline && !chat.busy && (overview?.enabled ?? true),
          limits: limits,
          initialText: widget.initialText,
          disabledReason: disabledReason,
          onSend: (text, attachments) => controller.send(text, attachments: attachments),
        ),
      ]),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.teams});

  final List<AiTeam> teams;

  @override
  Widget build(BuildContext context) {
    final open = teams.where((team) => !team.locked).toList();
    return ListView(padding: const EdgeInsets.all(24), children: [
      const SizedBox(height: 24),
      Center(child: Icon(Icons.auto_awesome, size: 48, color: Theme.of(context).colorScheme.primary)),
      const SizedBox(height: 12),
      const Text('Apa yang perlu dicatat?', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text('Tulis seperti bicara ke karyawan, rekam suara, atau foto nota. Tim AI menyiapkan catatannya; Anda cukup menyetujui.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: mutedText(context))),
      const SizedBox(height: 20),
      for (final team in open.take(4))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            TeamAvatar(tone: team.tone, icon: team.icon, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(team.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                if (team.example != null) Text('“${team.example}”', style: TextStyle(fontSize: 12, color: mutedText(context))),
              ]),
            ),
          ]),
        ),
    ]);
  }
}

/// "Tim Penjualan sedang mengerjakan…" dengan titik berkedip; saat
/// mengunggah lampiran tampil bilah kemajuan.
class _WorkingIndicator extends StatelessWidget {
  const _WorkingIndicator({required this.phase, required this.team, this.uploadProgress});

  final AiChatPhase phase;
  final AiMessageTeam? team;
  final double? uploadProgress;

  @override
  Widget build(BuildContext context) {
    final sending = phase == AiChatPhase.sending;
    final label = sending ? (uploadProgress == null ? 'Mengirim…' : 'Mengunggah lampiran ${(uploadProgress! * 100).round()}%') : '${team?.name ?? 'Tim AI'} sedang mengerjakan…';
    return Padding(
      key: const Key('ai-working'),
      padding: const EdgeInsets.only(bottom: 10, right: 48),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        TeamAvatar(tone: team?.tone ?? 'sky', icon: '', size: 32),
        const SizedBox(width: 8),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16), bottomRight: Radius.circular(16), bottomLeft: Radius.circular(4))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(label, style: TextStyle(fontSize: 13, color: mutedText(context)))),
                const SizedBox(width: 8),
                const TypingDots(),
              ]),
              if (sending && uploadProgress != null) ...[
                const SizedBox(height: 8),
                SizedBox(width: 160, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: uploadProgress, minHeight: 5))),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message, required this.userName, this.onRetry});

  final AiMessage message;
  final String userName;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = message.sendError != null;
    return Padding(
      key: Key('msg-${message.key}'),
      padding: const EdgeInsets.only(bottom: 10, left: 48),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (message.attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 6, children: [
              for (final file in message.attachments)
                if (file.isImage) AttachmentImage(file, size: 140) else if (file.isAudio) AudioNotePlayer(file, compact: true) else AttachmentChip(file),
            ]),
          ),
        if (message.content.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: failed ? Brand.danger.withValues(alpha: 0.12) : scheme.primary,
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16), bottomLeft: Radius.circular(16), bottomRight: Radius.circular(4)),
            ),
            child: Text(message.content, style: TextStyle(color: failed ? scheme.onSurface : scheme.onPrimary, fontSize: 14.5)),
          ),
        if (failed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(message.sendError!, style: TextStyle(fontSize: 12, color: dangerText(context)))),
              if (onRetry != null) TextButton(key: Key('retry-${message.key}'), onPressed: onRetry, child: const Text('Kirim ulang')),
            ]),
          ),
      ]),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.message, required this.teamIcon, required this.busyProposals, required this.onApprove, required this.onEdit, required this.onReject, this.onResend});

  final AiMessage message;
  final String teamIcon;
  final Set<int> busyProposals;
  final Future<void> Function(AiProposal proposal) onApprove;
  final Future<void> Function(AiProposal proposal) onEdit;
  final Future<void> Function(AiProposal proposal) onReject;
  final VoidCallback? onResend;

  @override
  Widget build(BuildContext context) {
    final team = message.teams.isEmpty ? null : message.teams.first;
    final failed = message.failed;
    return Padding(
      key: Key('msg-${message.key}'),
      padding: const EdgeInsets.only(bottom: 12, right: 24),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TeamAvatar(tone: team?.tone ?? 'sky', icon: teamIcon, size: 32),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(team?.name ?? 'Tim AI', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: toneColors(team?.tone ?? 'sky', dark: Theme.of(context).brightness == Brightness.dark).foreground)),
            ),
            if (message.content.isNotEmpty || failed)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: failed ? Brand.danger.withValues(alpha: 0.08) : Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(4), topRight: Radius.circular(16), bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  MarkdownLite(message.content.isEmpty ? 'Maaf, permintaan ini gagal diproses.' : message.content, style: const TextStyle(fontSize: 14.5, height: 1.35)),
                  if (failed && onResend != null)
                    Align(alignment: Alignment.centerRight, child: TextButton.icon(key: Key('resend-${message.key}'), onPressed: onResend, icon: const Icon(Icons.refresh, size: 18), label: const Text('Coba lagi'))),
                ]),
              ),
            if (message.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final file in message.attachments)
                    if (file.isImage) AttachmentImage(file, size: 160) else if (file.isAudio) AudioNotePlayer(file) else AttachmentChip(file),
                ]),
              ),
            for (final proposal in message.proposals)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ProposalCard(
                  proposal: proposal,
                  busy: busyProposals.contains(proposal.id),
                  onApprove: () => onApprove(proposal),
                  onEdit: () => onEdit(proposal),
                  onReject: () => onReject(proposal),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}
