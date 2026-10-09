import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/domain/ai_models.dart';
import 'package:infois/services/ai_media.dart';
import 'package:infois/ui/widgets/ai_composer.dart';

/// Perekam palsu: mencatat panggilan; [gate] menunda start() seperti saat
/// dialog izin mikrofon masih terbuka.
class FakeVoiceRecorder implements VoiceRecorder {
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  Completer<bool>? gate;

  @override
  Future<bool> start() async {
    startCalls++;
    return gate?.future ?? true;
  }

  @override
  Future<AiDraftAttachment?> stop() async {
    stopCalls++;
    return const AiDraftAttachment(path: '/tmp/voice.m4a', name: 'voice.m4a', size: 4096, kind: 'audio', seconds: 2);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

void main() {
  Future<FakeVoiceRecorder> pumpComposer(WidgetTester tester, {required Future<void> Function(String, List<AiDraftAttachment>) onSend}) async {
    final recorder = FakeVoiceRecorder();
    await tester.pumpWidget(ProviderScope(
      overrides: [voiceRecorderProvider.overrideWithValue(recorder)],
      child: MaterialApp(
        home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: AiComposer(enabled: true, limits: const AiLimits(), onSend: onSend))),
      ),
    ));
    return recorder;
  }

  testWidgets('tahan tombol mikrofon mulai merekam, lepas menyimpan voice note sebagai lampiran', (tester) async {
    final recorder = await pumpComposer(tester, onSend: (_, __) async {});

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('ai-mic'))));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(recorder.startCalls, 1, reason: 'Tekan-lama harus sampai ke perekam, bukan ditelan Tooltip.');
    expect(find.textContaining('Merekam'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(recorder.stopCalls, 1);
    expect(find.textContaining('Merekam'), findsNothing);
    expect(find.text('Voice note'), findsOneWidget, reason: 'Rekaman masuk ke daftar lampiran.');
  });

  testWidgets('jari dilepas selagi menunggu izin mikrofon: rekaman tidak dimulai tanpa pengawasan', (tester) async {
    final recorder = await pumpComposer(tester, onSend: (_, __) async {});
    recorder.gate = Completer<bool>();

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('ai-mic'))));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(recorder.startCalls, 1);

    await gesture.up();
    await tester.pump();
    recorder.gate!.complete(true);
    await tester.pump();
    await tester.pump();

    expect(recorder.cancelCalls, 1, reason: 'Perekam yang baru siap setelah jari lepas dibatalkan.');
    expect(recorder.stopCalls, 0);
    expect(find.textContaining('Merekam'), findsNothing);
    expect(find.text('Voice note'), findsNothing);
  });

  testWidgets('ketukan singkat pada mikrofon memberi petunjuk, tidak merekam', (tester) async {
    final recorder = await pumpComposer(tester, onSend: (_, __) async {});
    await tester.tap(find.byKey(const Key('ai-mic')));
    await tester.pump();
    expect(recorder.startCalls, 0);
    expect(find.textContaining('Tahan tombol mikrofon'), findsOneWidget);
  });
}
