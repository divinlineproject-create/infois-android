import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/ai_api.dart';
import 'package:infois/domain/ai_models.dart';
import 'package:infois/state/ai_state.dart';

import 'support/fakes.dart';

/// Server palsu yang bisa menahan jawaban `ai/runs/*` sampai [gate] dibuka
/// (meniru request yang masih berjalan saat layar ditutup).
class GatedServer extends FakeServer {
  GatedServer(super.handler);

  Completer<void>? gate;

  /// Request status yang sedang ditahan (belum dicatat di [requests]).
  int held = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (gate != null && options.path.startsWith('ai/runs/')) {
      held++;
      await gate!.future;
      held--;
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}

Map<String, dynamic>? Function(RequestOptions, Map<String, dynamic>?) handler({Map<String, dynamic>? Function()? onRun}) => (options, body) => switch (options.path) {
      'ai/conversations' => {'data': <Map<String, dynamic>>[], 'next_cursor': null},
      'ai/messages' => {'_status': 201, 'conversation_id': 12, 'message_id': 40, 'run_id': 7, 'status': 'queued'},
      'ai/runs/7' => onRun?.call() ?? {'id': 7, 'conversation_id': 12, 'status': 'running', 'done': false, 'error': null, 'coins_charged': null, 'assistant_message': null, 'proposals': <Map<String, dynamic>>[]},
      _ => {'_status': 404, 'message': 'Tidak ditemukan: ${options.path}', 'code': 'tidak_ditemukan'},
    };

ProviderContainer container(FakeServer server) => ProviderContainer(overrides: [
      aiApiProvider.overrideWithValue(AiApi(fakeApi(server))),
      aiPollIntervalProvider.overrideWithValue(const Duration(milliseconds: 50)),
    ]);

/// Tunggu sampai [condition] benar (maks. [timeout]), dicek tiap 5 ms.
Future<void> waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Kondisi tidak terpenuhi dalam ${timeout.inSeconds} detik.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

int polls(FakeServer server) => server.requests.where((request) => request.path == 'ai/runs/7').length;

void main() {
  test('jawaban status proses rusak: tahap kembali idle dengan pesan, bukan menggantung', () async {
    final server = FakeServer(handler(onRun: () => {'id': 'x', 'status': <int>[]}));
    final scope = container(server);
    addTearDown(scope.dispose);
    final subscription = scope.listen(aiChatProvider(0), (_, __) {});
    addTearDown(subscription.close);

    await scope.read(aiChatProvider(0).notifier).send('kopi susu 2');
    await waitFor(() => scope.read(aiChatProvider(0)).pollError != null);

    final state = scope.read(aiChatProvider(0));
    expect(state.phase, AiChatPhase.idle, reason: 'Kotak tulis harus aktif lagi.');
    expect(state.pollError, contains('Status Tim AI tidak bisa dibaca'));
    expect(state.conversationId, 12);
  });

  test('lampiran yang filenya hilang: pesan ditandai gagal dan bisa dikirim ulang, bukan macet "Mengirim…"', () async {
    final server = FakeServer(handler());
    final scope = container(server);
    addTearDown(scope.dispose);
    final subscription = scope.listen(aiChatProvider(0), (_, __) {});
    addTearDown(subscription.close);

    final controller = scope.read(aiChatProvider(0).notifier);
    await controller.send('foto nota', attachments: const [AiDraftAttachment(path: '/tidak/ada/nota.jpg', name: 'nota.jpg', size: 10, kind: 'image')]);

    final state = scope.read(aiChatProvider(0));
    expect(state.phase, AiChatPhase.idle);
    expect(state.uploadProgress, isNull);
    expect(state.messages.single.sendError, contains('sudah tidak ada di HP'));
    expect(state.noticeIsError, isTrue);
    expect(controller.canRetry(state.messages.single.localId!), isTrue);
    expect(server.requests.where((request) => request.path == 'ai/messages'), isEmpty, reason: 'Tidak ada request tanpa file.');
  });

  test('koin habis: pesan dalam bahasa HP dan tanpa tombol kirim ulang', () async {
    final server = FakeServer((options, body) => options.path == 'ai/messages'
        ? {'_status': 422, 'message': 'Koin tidak cukup (tersisa 0 koin). Isi ulang koin di menu Services › Dompet Koin.', 'code': 'koin_habis'}
        : handler()(options, body));
    final scope = container(server);
    addTearDown(scope.dispose);
    final subscription = scope.listen(aiChatProvider(0), (_, __) {});
    addTearDown(subscription.close);

    final controller = scope.read(aiChatProvider(0).notifier);
    await controller.send('kopi susu 2');

    final message = scope.read(aiChatProvider(0)).messages.single;
    expect(message.sendError, contains('website Infois'));
    expect(message.sendError, isNot(contains('Services')));
    expect(controller.canRetry(message.localId!), isFalse);
  });

  test('layar ditutup saat request status masih berjalan: polling berhenti, tidak dijadwalkan lagi', () async {
    final server = GatedServer(handler());
    final scope = container(server);
    addTearDown(scope.dispose);
    final subscription = scope.listen(aiChatProvider(0), (_, __) {});

    await scope.read(aiChatProvider(0).notifier).send('kopi susu 2');
    // Tunggu keadaan yang diharapkan (bukan jeda tetap): stabil walau mesin tes sibuk.
    await waitFor(() => polls(server) >= 1);
    expect(polls(server), 1, reason: 'Status dicek segera setelah terkirim.');

    // Request kedua ditahan; layar ditutup selagi menunggu jawabannya.
    server.gate = Completer<void>();
    await waitFor(() => server.held == 1);
    expect(server.held, 1, reason: 'Polling kedua sedang menunggu jawaban.');
    expect(polls(server), 1);
    subscription.close();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    server.gate!.complete();
    server.gate = null;

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(polls(server), 2, reason: 'Tidak ada polling baru setelah controller dilepas.');
  });

  test('setelah kirim, percakapan langsung masuk daftar dengan tanda sedang dikerjakan', () async {
    final server = FakeServer(handler());
    final scope = container(server);
    addTearDown(scope.dispose);
    final subscription = scope.listen(aiChatProvider(0), (_, __) {});
    addTearDown(subscription.close);
    await scope.read(aiConversationsProvider.future);

    await scope.read(aiChatProvider(0).notifier).send('kopi susu 2');

    final list = scope.read(aiConversationsProvider).valueOrNull!.items;
    expect(list.single.id, 12);
    expect(list.single.title, 'kopi susu 2');
    expect(list.single.working, isTrue);
  });

  test('cache lampiran dibatasi jumlahnya', () {
    final cache = AiAttachmentCache(maxEntries: 2);
    cache.put('a', Uint8List(1));
    cache.put('b', Uint8List(1));
    cache.get('a');
    cache.put('c', Uint8List(1));
    expect(cache.length, 2);
    expect(cache.get('b'), isNull, reason: 'Yang paling lama tidak dipakai dibuang.');
    expect(cache.get('a'), isNotNull);
  });
}
