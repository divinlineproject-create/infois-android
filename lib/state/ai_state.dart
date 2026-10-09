import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/ai_api.dart';
import '../data/api_client.dart';
import '../domain/ai_models.dart';
import 'session.dart';
import 'workspace.dart';

/// Klien Tim AI untuk perusahaan aktif (null bila belum ada perusahaan).
final aiApiProvider = Provider<AiApi?>((ref) {
  final workspace = ref.watch(workspaceProvider).valueOrNull;
  return workspace == null ? null : AiApi(workspace.api);
});

/// Jeda polling status proses AI (API.md: ~2 detik).
final aiPollIntervalProvider = Provider<Duration>((ref) => const Duration(seconds: 2));

/// Token HP sudah tidak berlaku (401): keluar seperti yang dilakukan sinkron,
/// supaya layar tidak menawarkan "Coba lagi" yang pasti gagal.
void _expireIfUnauthenticated(Ref ref, ApiException error) {
  if (error.unauthenticated) {
    unawaited(ref.read(sessionProvider.notifier).expire());
  }
}

/// Tim, pemakaian koin, contoh perintah, dan batas unggah.
final aiOverviewProvider = FutureProvider<AiOverview?>((ref) async {
  final api = ref.watch(aiApiProvider);
  if (api == null) {
    return null;
  }
  try {
    return await api.overview();
  } on ApiException catch (error) {
    _expireIfUnauthenticated(ref, error);
    rethrow;
  }
});

/// Isi lampiran yang baru-baru ini dibuka, dibatasi jumlahnya supaya memori
/// HP tidak terus bertambah saat riwayat berisi banyak foto.
class AiAttachmentCache {
  AiAttachmentCache({this.maxEntries = 20});

  final int maxEntries;
  final Map<String, Uint8List> _entries = {};

  Uint8List? get(String url) {
    final bytes = _entries.remove(url);
    if (bytes != null) {
      _entries[url] = bytes;
    }
    return bytes;
  }

  void put(String url, Uint8List bytes) {
    _entries.remove(url);
    _entries[url] = bytes;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  int get length => _entries.length;
}

final aiAttachmentCacheProvider = Provider<AiAttachmentCache>((ref) {
  ref.watch(aiApiProvider);
  return AiAttachmentCache();
});

/// Isi lampiran (foto/voice note): diunduh dengan token lalu disimpan di
/// cache kecil; provider sendiri dilepas saat tidak ada yang menampilkan.
final aiAttachmentBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>((ref, url) async {
  final api = ref.watch(aiApiProvider);
  if (api == null) {
    throw const ApiException('Belum ada perusahaan aktif.');
  }
  final cache = ref.watch(aiAttachmentCacheProvider);
  final cached = cache.get(url);
  if (cached != null) {
    return cached;
  }
  final raw = await api.attachmentBytes(url);
  final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
  cache.put(url, bytes);
  return bytes;
});

class AiConversationsState {
  const AiConversationsState({this.items = const [], this.nextCursor, this.loadingMore = false});

  final List<AiConversation> items;
  final String? nextCursor;
  final bool loadingMore;

  bool get hasMore => nextCursor != null;

  AiConversationsState copyWith({List<AiConversation>? items, String? nextCursor, bool clearCursor = false, bool? loadingMore}) => AiConversationsState(
        items: items ?? this.items,
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

/// Daftar percakapan (terbaru dulu) dengan halaman berikutnya.
class AiConversationsController extends AsyncNotifier<AiConversationsState> {
  @override
  Future<AiConversationsState> build() async {
    final api = ref.watch(aiApiProvider);
    if (api == null) {
      return const AiConversationsState();
    }
    try {
      final page = await api.conversations();
      return AiConversationsState(items: page.items, nextCursor: page.nextCursor);
    } on ApiException catch (error) {
      _expireIfUnauthenticated(ref, error);
      rethrow;
    }
  }

  AiApi? get _api => ref.read(aiApiProvider);

  Future<void> refresh() async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      final page = await api.conversations();
      state = AsyncData(AiConversationsState(items: page.items, nextCursor: page.nextCursor));
    } on ApiException catch (error, stack) {
      _expireIfUnauthenticated(ref, error);
      if (state.valueOrNull == null || state.valueOrNull!.items.isEmpty) {
        state = AsyncError(error, stack);
      } else {
        rethrow;
      }
    }
  }

  /// Muat ulang tanpa melempar galat (dipakai saat kembali dari layar chat).
  Future<void> refreshQuietly() async {
    try {
      await refresh();
    } on ApiException {
      // Daftar lama tetap tampil; tarik ke bawah untuk mencoba lagi.
    }
  }

  Future<void> loadMore() async {
    final api = _api;
    final current = state.valueOrNull;
    if (api == null || current == null || !current.hasMore || current.loadingMore) {
      return;
    }
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await api.conversations(cursor: current.nextCursor);
      final known = {for (final item in current.items) item.id};
      state = AsyncData(AiConversationsState(
        items: [...current.items, ...page.items.where((item) => !known.contains(item.id))],
        nextCursor: page.nextCursor,
      ));
    } on ApiException catch (error) {
      _expireIfUnauthenticated(ref, error);
      state = AsyncData(current.copyWith(loadingMore: false));
      rethrow;
    }
  }

  /// Perbarui/tambahkan satu percakapan di urutan teratas (setelah kirim pesan).
  void upsert(AiConversation conversation) {
    final current = state.valueOrNull ?? const AiConversationsState();
    state = AsyncData(current.copyWith(items: [conversation, ...current.items.where((item) => item.id != conversation.id)]));
  }

  Future<void> remove(int id) async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      await api.deleteConversation(id);
    } on ApiException catch (error) {
      _expireIfUnauthenticated(ref, error);
      rethrow;
    }
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.copyWith(items: current.items.where((item) => item.id != id).toList()));
    }
  }
}

final aiConversationsProvider = AsyncNotifierProvider<AiConversationsController, AiConversationsState>(AiConversationsController.new);

/// Tahap proses di layar chat.
enum AiChatPhase { idle, sending, queued, running }

class AiChatState {
  const AiChatState({
    this.conversationId,
    this.title = 'Percakapan baru',
    this.messages = const [],
    this.loading = true,
    this.loadError,
    this.gone = false,
    this.phase = AiChatPhase.idle,
    this.activeRunId,
    this.uploadProgress,
    this.pollError,
    this.notice,
    this.noticeIsError = false,
  });

  final int? conversationId;
  final String title;

  /// Urut dari yang paling lama.
  final List<AiMessage> messages;
  final bool loading;
  final String? loadError;

  /// Percakapan sudah dihapus di server (mis. dari web): layar ditutup.
  final bool gone;
  final AiChatPhase phase;
  final int? activeRunId;

  /// 0–1 saat lampiran diunggah; null bila tidak ada unggahan.
  final double? uploadProgress;

  /// Polling status gagal beberapa kali (mis. internet putus).
  final String? pollError;

  /// Pesan singkat satu kali untuk snackbar (hasil Setujui/Tolak, galat).
  final String? notice;

  /// Snackbar [notice] adalah galat (merah), bukan kabar berhasil.
  final bool noticeIsError;

  bool get busy => phase != AiChatPhase.idle;

  /// Tim yang terakhir menjawab (untuk teks "Tim Penjualan sedang mengerjakan…").
  AiMessageTeam? get lastTeam {
    for (final message in messages.reversed) {
      if (!message.isUser && message.teams.isNotEmpty) {
        return message.teams.first;
      }
    }
    return null;
  }

  AiChatState copyWith({
    int? conversationId,
    String? title,
    List<AiMessage>? messages,
    bool? loading,
    String? loadError,
    bool clearLoadError = false,
    bool? gone,
    AiChatPhase? phase,
    int? activeRunId,
    bool clearRun = false,
    double? uploadProgress,
    bool clearUpload = false,
    String? pollError,
    bool clearPollError = false,
    String? notice,
    bool clearNotice = false,
    bool noticeIsError = false,
  }) =>
      AiChatState(
        conversationId: conversationId ?? this.conversationId,
        title: title ?? this.title,
        messages: messages ?? this.messages,
        loading: loading ?? this.loading,
        loadError: clearLoadError ? null : (loadError ?? this.loadError),
        gone: gone ?? this.gone,
        phase: phase ?? this.phase,
        activeRunId: clearRun ? null : (activeRunId ?? this.activeRunId),
        uploadProgress: clearUpload ? null : (uploadProgress ?? this.uploadProgress),
        pollError: clearPollError ? null : (pollError ?? this.pollError),
        notice: clearNotice ? null : (notice ?? this.notice),
        noticeIsError: clearNotice ? false : (notice != null ? noticeIsError : this.noticeIsError),
      );
}

/// Draf pesan yang dikirim dari HP; disimpan untuk tombol "Kirim ulang".
class _Outgoing {
  const _Outgoing(this.text, this.attachments);

  final String text;
  final List<AiDraftAttachment> attachments;
}

/// Satu layar percakapan: muat pesan, kirim, polling proses tiap 2 detik,
/// Setujui/Tolak usulan. Kunci family = id percakapan (0 = percakapan baru).
class AiChatController extends AutoDisposeFamilyNotifier<AiChatState, int> {
  Timer? _poll;
  int _pollFailures = 0;
  bool _disposed = false;
  final Map<String, _Outgoing> _outgoing = {};

  static const int maxPollFailures = 5;

  /// Teks galat kirim yang tidak perlu "Kirim ulang" (mengirim lagi pasti gagal).
  static const Set<String> _finalSendErrors = {'koin_habis', 'tidak_berhak', 'tidak_ditemukan'};

  @override
  AiChatState build(int arg) {
    ref.onDispose(() {
      _disposed = true;
      _poll?.cancel();
      _poll = null;
    });
    final initial = AiChatState(conversationId: arg == 0 ? null : arg, loading: arg != 0);
    if (arg != 0) {
      Future.microtask(() => load());
    }
    return initial;
  }

  AiApi? get _api => _disposed ? null : ref.read(aiApiProvider);

  /// Masih boleh menyentuh state setelah `await` (layar belum ditutup).
  bool get _alive => !_disposed;

  /// Pesan HP yang gagal terkirim masih bisa dikirim ulang.
  bool canRetry(String localId) => _outgoing.containsKey(localId);

  Future<void> load() async {
    final api = _api;
    final id = state.conversationId;
    if (api == null || id == null) {
      if (_alive) {
        state = state.copyWith(loading: false);
      }
      return;
    }
    state = state.copyWith(loading: true, clearLoadError: true);
    try {
      final detail = await api.conversation(id);
      if (!_alive) {
        return;
      }
      final locals = state.messages.where((message) => message.id == null).toList();
      state = state.copyWith(
        title: detail.conversation.title,
        messages: [...detail.messages, ...locals],
        loading: false,
        phase: detail.working ? AiChatPhase.running : (state.phase == AiChatPhase.sending ? AiChatPhase.sending : AiChatPhase.idle),
        activeRunId: detail.activeRunId,
        clearRun: !detail.working && state.phase != AiChatPhase.sending,
        clearPollError: true,
      );
      if (detail.working && detail.activeRunId != null) {
        _schedulePoll(detail.activeRunId!, immediate: true);
      }
    } on ApiException catch (error) {
      if (!_alive) {
        return;
      }
      _expireIfUnauthenticated(ref, error);
      if (error.code == 'tidak_ditemukan') {
        state = state.copyWith(loading: false, gone: true, notice: 'Percakapan ini sudah dihapus.', noticeIsError: true);
        return;
      }
      state = state.copyWith(loading: false, loadError: error.message);
    } catch (error) {
      // Jawaban server tidak sesuai bentuk yang diharapkan: tampilkan alasan,
      // jangan biarkan layar berputar terus.
      if (_alive) {
        state = state.copyWith(loading: false, loadError: 'Percakapan belum bisa dimuat: $error');
      }
    }
  }

  /// Kirim teks dan/atau lampiran. Pesan langsung tampil di layar; bila
  /// gagal terkirim, bisa dikirim ulang.
  Future<void> send(String text, {List<AiDraftAttachment> attachments = const []}) async {
    final api = _api;
    if (api == null || state.busy) {
      return;
    }
    final localId = const Uuid().v4();
    _outgoing[localId] = _Outgoing(text, attachments);
    final local = AiMessage(
      localId: localId,
      role: 'user',
      content: text.trim(),
      attachments: [for (var i = 0; i < attachments.length; i++) attachments[i].toAttachment(i)],
      createdAt: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, local], phase: AiChatPhase.sending, uploadProgress: attachments.isEmpty ? null : 0, clearNotice: true, clearPollError: true);
    await _deliver(localId);
  }

  /// Kirim ulang pesan HP yang gagal terkirim.
  Future<void> retry(String localId) async {
    if (state.busy || !_outgoing.containsKey(localId)) {
      return;
    }
    state = state.copyWith(
      messages: [for (final message in state.messages) message.localId == localId ? message.copyWith(clearSendError: true) : message],
      phase: AiChatPhase.sending,
      uploadProgress: _outgoing[localId]!.attachments.isEmpty ? null : 0,
    );
    await _deliver(localId);
  }

  /// Kirim ulang isi pesan HP terakhir (setelah proses AI gagal).
  Future<void> resendLast() async {
    for (final message in state.messages.reversed) {
      if (message.isUser) {
        final outgoing = message.localId == null ? null : _outgoing[message.localId!];
        await send(outgoing?.text ?? message.content, attachments: outgoing?.attachments ?? const []);
        return;
      }
    }
  }

  Future<void> _deliver(String localId) async {
    final api = _api;
    final outgoing = _outgoing[localId];
    if (api == null || outgoing == null) {
      return;
    }
    try {
      final result = await api.send(
        conversationId: state.conversationId,
        text: outgoing.text,
        attachments: outgoing.attachments,
        onProgress: outgoing.attachments.isEmpty
            ? null
            : (progress) {
                if (_alive) {
                  state = state.copyWith(uploadProgress: progress);
                }
              },
      );
      if (!_alive) {
        return;
      }
      _outgoing.remove(localId);
      final title = state.conversationId == null && state.title == 'Percakapan baru' && outgoing.text.trim().isNotEmpty ? _titleFrom(outgoing.text) : state.title;
      state = state.copyWith(
        conversationId: result.conversationId,
        title: title,
        messages: [
          for (final message in state.messages)
            message.localId == localId ? message.copyWith(id: result.messageId, runId: result.runId, conversationId: result.conversationId, runStatus: result.status, clearSendError: true) : message,
        ],
        phase: result.status == 'running' ? AiChatPhase.running : AiChatPhase.queued,
        activeRunId: result.runId,
        clearUpload: true,
      );
      // Percakapan langsung masuk daftar (tanda "sedang dikerjakan"), walau
      // pengguna kembali sebelum jawaban selesai.
      _bumpConversation(outgoing.text.trim(), working: true);
      _schedulePoll(result.runId, immediate: true);
    } on ApiException catch (error) {
      if (!_alive) {
        return;
      }
      _expireIfUnauthenticated(ref, error);
      final message = _sendErrorText(error);
      if (_finalSendErrors.contains(error.code)) {
        _outgoing.remove(localId);
      }
      state = state.copyWith(
        messages: [for (final item in state.messages) item.localId == localId ? item.copyWith(sendError: message) : item],
        phase: AiChatPhase.idle,
        clearUpload: true,
        notice: message,
        noticeIsError: true,
      );
    } catch (error) {
      // Galat tak terduga (file lampiran hilang, jawaban server rusak):
      // pesan ditandai gagal supaya tombol kirim aktif lagi.
      if (!_alive) {
        return;
      }
      state = state.copyWith(
        messages: [for (final item in state.messages) item.localId == localId ? item.copyWith(sendError: 'Pesan tidak terkirim. Coba lagi.') : item],
        phase: AiChatPhase.idle,
        clearUpload: true,
        notice: 'Pesan tidak terkirim: $error',
        noticeIsError: true,
      );
    }
  }

  /// Pesan galat kirim dalam bahasa pengguna HP (menu web tidak ada di HP).
  static String _sendErrorText(ApiException error) => switch (error.code) {
        'koin_habis' => 'Koin Tim AI bulan ini habis. Minta pemilik usaha mengisi ulang koin lewat website Infois.',
        _ => error.message,
      };

  static String _titleFrom(String text) {
    final clean = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return clean.length > 80 ? '${clean.substring(0, 77)}…' : clean;
  }

  void _schedulePoll(int runId, {bool immediate = false}) {
    _poll?.cancel();
    if (!_alive) {
      return;
    }
    _poll = Timer(immediate ? Duration.zero : ref.read(aiPollIntervalProvider), () => _pollOnce(runId));
  }

  /// Hentikan polling (mis. setelah galat beberapa kali); [resumePolling] melanjutkan.
  void resumePolling() {
    final runId = state.activeRunId;
    if (runId != null) {
      _pollFailures = 0;
      state = state.copyWith(clearPollError: true, phase: state.phase == AiChatPhase.idle ? AiChatPhase.running : state.phase);
      _schedulePoll(runId, immediate: true);
    }
  }

  Future<void> _pollOnce(int runId) async {
    final api = _api;
    if (api == null || state.activeRunId != runId) {
      return;
    }
    try {
      final run = await api.run(runId);
      // Layar sudah ditutup atau proses lain yang dipantau: jangan jadwalkan lagi.
      if (!_alive || state.activeRunId != runId) {
        return;
      }
      _pollFailures = 0;
      if (!run.done) {
        state = state.copyWith(phase: run.status == 'running' ? AiChatPhase.running : AiChatPhase.queued, clearPollError: true);
        _schedulePoll(runId);
        return;
      }
      _finishRun(run);
    } on ApiException catch (error) {
      if (!_alive || state.activeRunId != runId) {
        return;
      }
      if (error.unauthenticated) {
        _expireIfUnauthenticated(ref, error);
        state = state.copyWith(phase: AiChatPhase.idle, clearRun: true);
        return;
      }
      _pollFailures++;
      if (_pollFailures >= maxPollFailures) {
        state = state.copyWith(phase: AiChatPhase.idle, pollError: error.offline ? 'Tim AI butuh internet. Sambungkan internet lalu coba lagi.' : error.message);
        return;
      }
      _schedulePoll(runId);
    } catch (error) {
      // Jawaban status tidak sesuai bentuk: berhenti dengan pesan yang bisa dicoba lagi.
      if (_alive && state.activeRunId == runId) {
        state = state.copyWith(phase: AiChatPhase.idle, pollError: 'Status Tim AI tidak bisa dibaca: $error');
      }
    }
  }

  void _finishRun(AiRun run) {
    final reply = run.assistantMessage;
    final messages = [
      for (final message in state.messages)
        if (reply == null || message.id != reply.id) _withProposals(message.runId == run.id ? message.copyWith(runStatus: run.status) : message, run.proposals),
    ];
    if (reply != null) {
      messages.add(reply.proposals.isEmpty && run.proposals.isNotEmpty ? reply.copyWith(proposals: run.proposals.where((proposal) => proposal.runId == run.id).toList()) : reply);
    } else if (run.failed) {
      messages.add(AiMessage(id: -run.id, runId: run.id, role: 'assistant', content: 'Maaf, permintaan ini gagal diproses. Koin Anda tidak terpakai. Silakan kirim ulang.', failed: true, runStatus: 'failed', createdAt: DateTime.now()));
    }
    state = state.copyWith(messages: messages, phase: AiChatPhase.idle, clearRun: true, clearPollError: true);
    ref.invalidate(aiOverviewProvider);
    _bumpConversation(reply?.content ?? '');
  }

  void _bumpConversation(String preview, {bool working = false}) {
    final id = state.conversationId;
    if (id == null) {
      return;
    }
    final pending = state.messages.fold<int>(0, (sum, message) => sum + message.proposals.where((proposal) => proposal.pending).length);
    ref.read(aiConversationsProvider.notifier).upsert(AiConversation(
      id: id,
      title: state.title,
      preview: preview.isEmpty ? null : (preview.length > 120 ? '${preview.substring(0, 117)}…' : preview),
      pendingProposals: pending,
      working: working,
      lastMessageAt: DateTime.now(),
    ));
  }

  static AiMessage _withProposals(AiMessage message, List<AiProposal> fresh) {
    if (message.proposals.isEmpty || fresh.isEmpty) {
      return message;
    }
    final byId = {for (final proposal in fresh) proposal.id: proposal};
    return message.copyWith(proposals: [for (final proposal in message.proposals) byId[proposal.id] ?? proposal]);
  }

  void _replaceProposal(AiProposal proposal) {
    state = state.copyWith(messages: [
      for (final message in state.messages)
        message.proposals.any((item) => item.id == proposal.id) ? message.copyWith(proposals: [for (final item in message.proposals) item.id == proposal.id ? proposal : item]) : message,
    ]);
    _bumpConversation(state.messages.isEmpty ? '' : state.messages.last.content);
  }

  /// Setujui usulan (opsional dengan isian yang diubah). Mengembalikan true
  /// bila tercatat; bila ditolak aturan pembukuan, alasannya tampil di kartu.
  Future<bool> approve(AiProposal proposal, {Map<String, dynamic>? edits}) async {
    final api = _api;
    if (api == null) {
      return false;
    }
    try {
      final result = await api.approve(proposal.id, edits: edits);
      if (!_alive) {
        return true;
      }
      _replaceProposal(result.proposal);
      state = state.copyWith(notice: result.message);
      ref.invalidate(aiOverviewProvider);
      return true;
    } on ApiException catch (error) {
      if (!_alive) {
        return false;
      }
      _expireIfUnauthenticated(ref, error);
      if (error.code == 'sudah_diproses') {
        await load();
      } else {
        _replaceProposal(proposal.copyWith(error: error.message));
      }
      if (_alive) {
        state = state.copyWith(notice: error.message, noticeIsError: true);
      }
      return false;
    } catch (error) {
      if (_alive) {
        state = state.copyWith(notice: 'Usulan belum bisa disetujui: $error', noticeIsError: true);
      }
      return false;
    }
  }

  Future<void> reject(AiProposal proposal) async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      final result = await api.reject(proposal.id);
      if (!_alive) {
        return;
      }
      _replaceProposal(result.proposal);
      state = state.copyWith(notice: result.message);
      ref.invalidate(aiOverviewProvider);
    } on ApiException catch (error) {
      if (!_alive) {
        return;
      }
      _expireIfUnauthenticated(ref, error);
      if (error.code == 'sudah_diproses') {
        await load();
      }
      if (_alive) {
        state = state.copyWith(notice: error.message, noticeIsError: true);
      }
    } catch (error) {
      if (_alive) {
        state = state.copyWith(notice: 'Usulan belum bisa ditolak: $error', noticeIsError: true);
      }
    }
  }

  void clearNotice() {
    if (state.notice != null) {
      state = state.copyWith(clearNotice: true);
    }
  }
}

final aiChatProvider = NotifierProvider.autoDispose.family<AiChatController, AiChatState, int>(AiChatController.new);
