// Model Tim AI dari server (lihat API.md › 6. Tim AI). Semua angka koin
// disimpan sebagai string 3 desimal; uang di usulan string 2 desimal.

String _s(Object? value, [String fallback = '']) => value == null ? fallback : value.toString();

bool _b(Object? value) => value == true || value == 1 || value == '1' || value == 'true';

int? _i(Object? value) => value == null ? null : (value is int ? value : int.tryParse(value.toString()));

Map<String, dynamic> _map(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => [for (final item in (value as List? ?? const [])) _map(item)];

DateTime? _date(Object? value) => value == null ? null : DateTime.tryParse(value.toString());

/// Satu tim AI (Tim Penjualan, Tim Gudang, …) dengan warna dan ikon web.
class AiTeam {
  const AiTeam({required this.key, required this.name, this.role = '', this.tone = 'sky', this.icon = '', this.example, this.locked = false, this.unlockPlan});

  factory AiTeam.fromJson(Map<String, dynamic> json) => AiTeam(
        key: _s(json['key']),
        name: _s(json['name'], 'Tim AI'),
        role: _s(json['role']),
        tone: _s(json['tone'], 'sky'),
        icon: _s(json['icon']),
        example: json['example']?.toString(),
        locked: _b(json['locked']),
        unlockPlan: json['unlock_plan']?.toString(),
      );

  final String key;
  final String name;
  final String role;
  final String tone;
  final String icon;
  final String? example;

  /// Belum termasuk paket langganan; tampil dengan gembok.
  final bool locked;
  final String? unlockPlan;
}

/// Pemakaian koin bulan ini (untuk bilah pemakaian, tanpa istilah token).
class AiCoins {
  const AiCoins({this.used = '0.000', this.available = '0.000', this.percent = 0, this.resetsAt});

  factory AiCoins.fromJson(Map<String, dynamic> json) => AiCoins(
        used: _s(json['used'], '0.000'),
        available: _s(json['available'], '0.000'),
        percent: (_i(json['percent']) ?? 0).clamp(0, 100),
        resetsAt: _date(json['resets_at']),
      );

  final String used;
  final String available;
  final int percent;
  final DateTime? resetsAt;
}

class AiLimits {
  const AiLimits({this.maxAttachments = 5, this.maxUploadKb = 10240, this.maxText = 4000});

  factory AiLimits.fromJson(Map<String, dynamic> json) => AiLimits(
        maxAttachments: _i(json['max_attachments']) ?? 5,
        maxUploadKb: _i(json['max_upload_kb']) ?? 10240,
        maxText: _i(json['max_text']) ?? 4000,
      );

  final int maxAttachments;
  final int maxUploadKb;
  final int maxText;

  int get maxUploadBytes => maxUploadKb * 1024;

  String get maxUploadLabel => maxUploadKb >= 1024 ? '${(maxUploadKb / 1024).round()} MB' : '$maxUploadKb KB';
}

/// Kanal Tim AI yang dibuka paket perusahaan (web selalu terbuka). Bila HP
/// terkunci (trial atau paket tanpa aplikasi HP), [message] dan [unlockPlan]
/// menjelaskan paket yang membukanya.
class AiChannels {
  const AiChannels({this.web = true, this.telegram = true, this.mobile = true, this.unlockPlan, this.message});

  /// Server lama tanpa `channels` → semua kanal dianggap terbuka.
  factory AiChannels.fromJson(Map<String, dynamic> json) => json.isEmpty
      ? const AiChannels()
      : AiChannels(
          web: json['web'] == null || _b(json['web']),
          telegram: _b(json['telegram']),
          mobile: _b(json['mobile']),
          unlockPlan: json['unlock_plan']?.toString(),
          message: json['message']?.toString(),
        );

  final bool web;
  final bool telegram;
  final bool mobile;
  final String? unlockPlan;
  final String? message;
}

/// Jawaban GET /ai/overview.
class AiOverview {
  const AiOverview({
    this.enabled = true,
    this.reason,
    this.channels = const AiChannels(),
    this.fastMode = false,
    this.hasBusinessContext = false,
    this.teams = const [],
    this.coins = const AiCoins(),
    this.suggestions = const [],
    this.pendingProposals = 0,
    this.limits = const AiLimits(),
  });

  factory AiOverview.fromJson(Map<String, dynamic> json) => AiOverview(
        enabled: json['enabled'] == null || _b(json['enabled']),
        reason: json['reason']?.toString(),
        channels: AiChannels.fromJson(_map(json['channels'])),
        fastMode: _b(json['fast_mode']),
        hasBusinessContext: _b(json['has_business_context']),
        teams: [for (final team in _maps(json['teams'])) AiTeam.fromJson(team)],
        coins: AiCoins.fromJson(_map(json['coins'])),
        suggestions: [for (final item in (json['suggestions'] as List? ?? const [])) item.toString()],
        pendingProposals: _i(json['pending_proposals']) ?? 0,
        limits: AiLimits.fromJson(_map(json['limits'])),
      );

  final bool enabled;

  /// Alasan [enabled] false: `ai_tidak_tersedia` | `kanal_tidak_termasuk_paket`.
  final String? reason;
  final AiChannels channels;
  final bool fastMode;

  /// Pemilik sudah mengisi "Tentang usaha Anda" (konteks untuk Tim AI).
  final bool hasBusinessContext;
  final List<AiTeam> teams;
  final AiCoins coins;
  final List<String> suggestions;
  final int pendingProposals;
  final AiLimits limits;

  /// Tim AI lewat HP belum termasuk paket: tampilkan penjelasan, bukan chat.
  bool get channelLocked => !channels.mobile || reason == 'kanal_tidak_termasuk_paket';

  AiTeam? team(String key) {
    for (final team in teams) {
      if (team.key == key) {
        return team;
      }
    }
    return null;
  }
}

/// Ringkasan percakapan di daftar riwayat.
class AiConversation {
  const AiConversation({required this.id, required this.title, this.channel = 'mobile', this.preview, this.pendingProposals = 0, this.working = false, this.lastMessageAt});

  factory AiConversation.fromJson(Map<String, dynamic> json) => AiConversation(
        id: _i(json['id'])!,
        title: _s(json['title'], 'Percakapan baru'),
        channel: _s(json['channel'], 'mobile'),
        preview: json['preview']?.toString(),
        pendingProposals: _i(json['pending_proposals']) ?? 0,
        working: _b(json['working']),
        lastMessageAt: _date(json['last_message_at']),
      );

  final int id;
  final String title;
  final String channel;
  final String? preview;
  final int pendingProposals;
  final bool working;
  final DateTime? lastMessageAt;

  AiConversation copyWith({String? title, String? preview, int? pendingProposals, bool? working, DateTime? lastMessageAt}) => AiConversation(
        id: id,
        title: title ?? this.title,
        channel: channel,
        preview: preview ?? this.preview,
        pendingProposals: pendingProposals ?? this.pendingProposals,
        working: working ?? this.working,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      );
}

/// Lampiran pesan: foto, voice note, PDF/Excel, atau file laporan buatan AI.
class AiAttachment {
  const AiAttachment({required this.index, required this.name, this.mime, this.size = 0, this.kind = 'file', this.seconds, this.transcript, this.url, this.localPath});

  factory AiAttachment.fromJson(Map<String, dynamic> json) => AiAttachment(
        index: _i(json['index']) ?? 0,
        name: _s(json['name'], 'file'),
        mime: json['mime']?.toString(),
        size: _i(json['size']) ?? 0,
        kind: _s(json['kind'], 'file'),
        seconds: _i(json['seconds']),
        transcript: json['transcript']?.toString(),
        url: json['url']?.toString(),
      );

  final int index;
  final String name;
  final String? mime;
  final int size;

  /// `image` | `audio` | `pdf` | `sheet` | `report` | `file`.
  final String kind;
  final int? seconds;
  final String? transcript;
  final String? url;

  /// File di HP (lampiran yang baru dikirim, sebelum/selama diunggah).
  final String? localPath;

  bool get isImage => kind == 'image';
  bool get isAudio => kind == 'audio';

  String get sizeLabel {
    if (size >= 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1).replaceFirst('.', ',')} MB';
    }
    if (size >= 1024) {
      return '${(size / 1024).round()} KB';
    }
    return '$size B';
  }
}

/// Usulan AI (penjualan, pembelian, pembayaran, …) yang menunggu Setujui/Tolak.
class AiProposal {
  const AiProposal({
    required this.id,
    this.conversationId,
    this.runId,
    required this.type,
    required this.title,
    this.status = 'pending',
    this.statusLabel = 'Menunggu persetujuan',
    this.editable = false,
    this.editableFields = const [],
    this.payload = const {},
    this.preview = const {},
    this.error,
    this.resultLabel,
    this.resultUrl,
    this.printLinks = const [],
    this.decidedAt,
    this.createdAt,
    this.resultMessage,
    this.resultDetails = const [],
    this.proofFiles = const [],
    this.mockupFiles = const [],
  });

  factory AiProposal.fromJson(Map<String, dynamic> json) => AiProposal(
        id: _i(json['id'])!,
        conversationId: _i(json['conversation_id']),
        runId: _i(json['run_id']),
        type: _s(json['type'], 'other'),
        title: _s(json['title'], 'Usulan'),
        status: _s(json['status'], 'pending'),
        statusLabel: _s(json['status_label'], 'Menunggu persetujuan'),
        editable: _b(json['editable']),
        editableFields: [for (final field in (json['editable_fields'] as List? ?? const [])) field.toString()],
        payload: _map(json['payload']),
        preview: _map(json['preview']),
        error: json['error']?.toString(),
        resultLabel: json['result_label']?.toString(),
        resultUrl: json['result_url']?.toString(),
        printLinks: _maps(json['print_links']),
        decidedAt: _date(json['decided_at']),
        createdAt: _date(json['created_at']),
        resultMessage: (json['result_message']?.toString() ?? '').trim().isEmpty ? null : json['result_message'].toString(),
        resultDetails: _strings(json['result_details']),
        proofFiles: _strings(json['proof_files']),
        mockupFiles: _strings(json['mockup_files']),
      );

  static List<String> _strings(Object? value) => [
        for (final item in value is List ? value : const [])
          if (item != null && item.toString().trim().isNotEmpty) item.toString(),
      ];

  final int id;
  final int? conversationId;
  final int? runId;
  final String type;
  final String title;

  /// `pending` | `executed` | `rejected` | `failed`.
  final String status;
  final String statusLabel;
  final bool editable;
  final List<String> editableFields;
  final Map<String, dynamic> payload;
  final Map<String, dynamic> preview;
  final String? error;
  final String? resultLabel;
  final String? resultUrl;
  final List<Map<String, dynamic>> printLinks;
  final DateTime? decidedAt;
  final DateTime? createdAt;

  /// Kalimat hasil setelah disetujui/ditolak, mis. "Penjualan INV-0012 …
  /// berhasil dicatat", dan rinciannya (dampak kas, bukti dilampirkan).
  final String? resultMessage;
  final List<String> resultDetails;

  /// Nama file bukti (foto/PDF dari chat) yang akan dilampirkan saat disetujui.
  final List<String> proofFiles;

  /// Desain yang akan menjadi mockup pesanan penjualan saat disetujui.
  final List<String> mockupFiles;

  bool get pending => status == 'pending';
  bool get executed => status == 'executed';
  bool get rejected => status == 'rejected';
  bool get failed => status == 'failed';

  List<String> get warnings => [for (final item in (preview['warnings'] as List? ?? const [])) item.toString()];

  AiProposal copyWith({String? error, bool clearError = false}) => AiProposal(
        id: id,
        conversationId: conversationId,
        runId: runId,
        type: type,
        title: title,
        status: status,
        statusLabel: statusLabel,
        editable: editable,
        editableFields: editableFields,
        payload: payload,
        preview: preview,
        error: clearError ? null : (error ?? this.error),
        resultLabel: resultLabel,
        resultUrl: resultUrl,
        printLinks: printLinks,
        decidedAt: decidedAt,
        createdAt: createdAt,
        resultMessage: resultMessage,
        resultDetails: resultDetails,
        proofFiles: proofFiles,
        mockupFiles: mockupFiles,
      );
}

/// Tim yang menjawab satu pesan (untuk avatar & nama di bubble).
class AiMessageTeam {
  const AiMessageTeam({required this.key, required this.name, this.tone = 'sky'});

  factory AiMessageTeam.fromJson(Map<String, dynamic> json) => AiMessageTeam(key: _s(json['key']), name: _s(json['name'], 'Tim AI'), tone: _s(json['tone'], 'sky'));

  final String key;
  final String name;
  final String tone;
}

/// Pesan percakapan. [localId] dipakai untuk pesan yang baru dikirim dari HP
/// sebelum server memberi id.
class AiMessage {
  const AiMessage({
    this.id,
    this.localId,
    this.conversationId,
    this.runId,
    required this.role,
    this.content = '',
    this.failed = false,
    this.coins,
    this.teams = const [],
    this.attachments = const [],
    this.proposals = const [],
    this.runStatus,
    this.createdAt,
    this.sendError,
  });

  factory AiMessage.fromJson(Map<String, dynamic> json) => AiMessage(
        id: _i(json['id']),
        conversationId: _i(json['conversation_id']),
        runId: _i(json['run_id']),
        role: _s(json['role'], 'assistant'),
        content: _s(json['content']),
        failed: _b(json['failed']),
        coins: json['coins']?.toString(),
        teams: [for (final team in _maps(json['teams'])) AiMessageTeam.fromJson(team)],
        attachments: [for (final file in _maps(json['attachments'])) AiAttachment.fromJson(file)],
        proposals: [for (final proposal in _maps(json['proposals'])) AiProposal.fromJson(proposal)],
        runStatus: json['run_status']?.toString(),
        createdAt: _date(json['created_at']),
      );

  final int? id;
  final String? localId;
  final int? conversationId;
  final int? runId;

  /// `user` | `assistant`.
  final String role;
  final String content;
  final bool failed;
  final String? coins;
  final List<AiMessageTeam> teams;
  final List<AiAttachment> attachments;
  final List<AiProposal> proposals;
  final String? runStatus;
  final DateTime? createdAt;

  /// Pesan HP yang gagal terkirim (belum sampai server) + alasannya.
  final String? sendError;

  bool get isUser => role == 'user';

  /// Kunci stabil untuk daftar: id server atau id lokal.
  String get key => id != null ? 'm$id' : 'l$localId';

  AiMessage copyWith({int? id, int? runId, int? conversationId, List<AiProposal>? proposals, String? sendError, bool clearSendError = false, String? runStatus}) => AiMessage(
        id: id ?? this.id,
        localId: localId,
        conversationId: conversationId ?? this.conversationId,
        runId: runId ?? this.runId,
        role: role,
        content: content,
        failed: failed,
        coins: coins,
        teams: teams,
        attachments: attachments,
        proposals: proposals ?? this.proposals,
        runStatus: runStatus ?? this.runStatus,
        createdAt: createdAt,
        sendError: clearSendError ? null : (sendError ?? this.sendError),
      );
}

/// Status satu proses AI (GET /ai/runs/{id}).
class AiRun {
  const AiRun({required this.id, this.conversationId, this.status = 'queued', this.done = false, this.error, this.coinsCharged, this.assistantMessage, this.proposals = const []});

  factory AiRun.fromJson(Map<String, dynamic> json) => AiRun(
        id: _i(json['id'])!,
        conversationId: _i(json['conversation_id']),
        status: _s(json['status'], 'queued'),
        done: _b(json['done']),
        error: json['error']?.toString(),
        coinsCharged: json['coins_charged']?.toString(),
        assistantMessage: json['assistant_message'] is Map ? AiMessage.fromJson(_map(json['assistant_message'])) : null,
        proposals: [for (final proposal in _maps(json['proposals'])) AiProposal.fromJson(proposal)],
      );

  final int id;
  final int? conversationId;

  /// `queued` | `running` | `completed` | `failed`.
  final String status;
  final bool done;
  final String? error;
  final String? coinsCharged;
  final AiMessage? assistantMessage;
  final List<AiProposal> proposals;

  bool get failed => status == 'failed';
}

/// Jawaban POST /ai/messages.
class AiSendResult {
  const AiSendResult({required this.conversationId, this.messageId, required this.runId, this.status = 'queued'});

  factory AiSendResult.fromJson(Map<String, dynamic> json) =>
      AiSendResult(conversationId: _i(json['conversation_id'])!, messageId: _i(json['message_id']), runId: _i(json['run_id'])!, status: _s(json['status'], 'queued'));

  final int conversationId;
  final int? messageId;
  final int runId;
  final String status;
}

/// Isi GET /ai/conversations/{id}.
class AiConversationDetail {
  const AiConversationDetail({required this.conversation, this.messages = const [], this.working = false, this.activeRunId});

  factory AiConversationDetail.fromJson(Map<String, dynamic> json) => AiConversationDetail(
        conversation: AiConversation.fromJson(_map(json['conversation'])),
        messages: [for (final message in _maps(json['messages'])) AiMessage.fromJson(message)],
        working: _b(json['working']),
        activeRunId: _i(json['active_run_id']),
      );

  final AiConversation conversation;
  final List<AiMessage> messages;
  final bool working;
  final int? activeRunId;
}

/// Lampiran yang dipilih pengguna dan akan dikirim bersama pesan.
class AiDraftAttachment {
  const AiDraftAttachment({required this.path, required this.name, required this.size, required this.kind, this.seconds});

  final String path;
  final String name;
  final int size;

  /// `image` | `audio` | `file`.
  final String kind;

  /// Lama voice note (detik), dikirim sebagai `durations[i]`.
  final int? seconds;

  bool get isImage => kind == 'image';
  bool get isAudio => kind == 'audio';

  AiAttachment toAttachment(int index) => AiAttachment(index: index, name: name, size: size, kind: kind, seconds: seconds, localPath: path);
}
