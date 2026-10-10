import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/domain/ai_models.dart';
import 'package:infois/services/ai_media.dart';
import 'package:infois/ui/theme.dart';
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
  final composerKey = GlobalKey<AiComposerState>();

  Future<FakeVoiceRecorder> pumpComposer(
    WidgetTester tester, {
    required Future<void> Function(String, List<AiDraftAttachment>) onSend,
    bool working = false,
    bool? fastMode,
    Future<void> Function(bool)? onFastModeChanged,
  }) async {
    final recorder = FakeVoiceRecorder();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [voiceRecorderProvider.overrideWithValue(recorder)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: AiComposer(
                key: composerKey,
                enabled: true,
                working: working,
                workingLabel: 'Tim Gudang sedang bekerja',
                limits: const AiLimits(),
                fastMode: fastMode,
                onFastModeChanged: onFastModeChanged,
                onSend: onSend,
              ),
            ),
          ),
        ),
      ),
    );
    return recorder;
  }

  Future<void> holdMic(WidgetTester tester, Future<void> Function(TestGesture gesture) whileHeld) async {
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('ai-mic'))));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    await whileHeld(gesture);
  }

  testWidgets('tahan tombol mikrofon mulai merekam, lepas menyimpan voice note sebagai lampiran', (tester) async {
    final recorder = await pumpComposer(tester, onSend: (_, __) async {});

    await holdMic(tester, (gesture) async {
      expect(recorder.startCalls, 1, reason: 'Tekan-lama harus sampai ke perekam, bukan ditelan Tooltip.');
      expect(find.byKey(const Key('ai-recording')), findsOneWidget);
      expect(find.text('Geser untuk batal'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      expect(find.text('0:02'), findsOneWidget, reason: 'Waktu rekaman berjalan.');
      await gesture.up();
      await tester.pump();
      await tester.pump();
    });
    expect(recorder.stopCalls, 1);
    expect(find.byKey(const Key('ai-recording')), findsNothing);
    expect(find.text('Voice note'), findsOneWidget, reason: 'Rekaman masuk ke daftar lampiran.');
    expect(find.byKey(const Key('ai-send')), findsOneWidget, reason: 'Ada lampiran: mikrofon berganti tombol Kirim.');
  });

  testWidgets('jari dilepas selagi menunggu izin mikrofon: rekaman tidak dimulai tanpa pengawasan', (tester) async {
    final recorder = await pumpComposer(tester, onSend: (_, __) async {});
    recorder.gate = Completer<bool>();

    await holdMic(tester, (gesture) async {
      expect(recorder.startCalls, 1);
      await gesture.up();
      await tester.pump();
    });
    recorder.gate!.complete(true);
    await tester.pump();
    await tester.pump();

    expect(recorder.cancelCalls, 1, reason: 'Perekam yang baru siap setelah jari lepas dibatalkan.');
    expect(recorder.stopCalls, 0);
    expect(find.byKey(const Key('ai-recording')), findsNothing);
    expect(find.text('Voice note'), findsNothing);
  });

  testWidgets('geser ke kiri saat merekam membatalkan rekaman', (tester) async {
    final recorder = await pumpComposer(tester, onSend: (_, __) async {});

    await holdMic(tester, (gesture) async {
      expect(find.byKey(const Key('ai-recording')), findsOneWidget);
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump();
    });

    expect(recorder.cancelCalls, 1);
    expect(recorder.stopCalls, 0, reason: 'Rekaman yang dibatalkan tidak disimpan.');
    expect(find.text('Voice note'), findsNothing);
    expect(find.byKey(const Key('ai-mic')), findsOneWidget);
  });

  testWidgets('ketukan singkat pada mikrofon memberi petunjuk, tidak merekam', (tester) async {
    final recorder = await pumpComposer(tester, onSend: (_, __) async {});
    await tester.tap(find.byKey(const Key('ai-mic')));
    await tester.pump();
    expect(recorder.startCalls, 0);
    expect(find.textContaining('Tahan tombol mikrofon'), findsOneWidget);
  });

  testWidgets('tombol Kirim hanya muncul bila ada isi; Enter membuat baris baru', (tester) async {
    final sent = <String>[];
    await pumpComposer(tester, onSend: (text, _) async => sent.add(text));

    expect(find.byKey(const Key('ai-send')), findsNothing);
    expect(find.byKey(const Key('ai-mic')), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const Key('ai-text')));
    expect(field.keyboardType, TextInputType.multiline);
    expect(field.textInputAction, TextInputAction.newline);
    expect(field.maxLines, 6);
    expect(find.text('Pesan untuk Tim AI'), findsOneWidget, reason: 'Petunjuk pendek satu baris.');
    expect(tester.widget<TextField>(find.byKey(const Key('ai-text'))).decoration!.hintMaxLines, 1);

    await tester.enterText(find.byKey(const Key('ai-text')), '   ');
    await tester.pump();
    expect(find.byKey(const Key('ai-send')), findsNothing, reason: 'Spasi saja bukan isi.');

    await tester.enterText(find.byKey(const Key('ai-text')), 'kopi susu 2 tunai');
    await tester.pump();
    expect(find.byKey(const Key('ai-send')), findsOneWidget);
    expect(find.byKey(const Key('ai-mic')), findsNothing);

    await tester.tap(find.byKey(const Key('ai-send')));
    await tester.pump();
    expect(sent, ['kopi susu 2 tunai']);
    expect(find.byKey(const Key('ai-send')), findsNothing);
    expect(find.byKey(const Key('ai-mic')), findsOneWidget);
  });

  testWidgets('lampiran bisa dihapus dengan tombol ×', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpComposer(tester, onSend: (_, __) async {});
    await holdMic(tester, (gesture) async {
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pump();
      await tester.pump();
    });
    expect(find.text('Voice note'), findsOneWidget);
    expect(find.bySemanticsLabel('Hapus lampiran voice note'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-remove-0')));
    await tester.pump();
    expect(find.text('Voice note'), findsNothing);
    expect(find.byKey(const Key('ai-send')), findsNothing);
    expect(find.byKey(const Key('ai-mic')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('saat Tim AI bekerja: Kirim menjadi tanda sedang bekerja, teks tetap tersimpan', (tester) async {
    final semantics = tester.ensureSemantics();
    final sent = <String>[];
    await pumpComposer(tester, working: true, onSend: (text, _) async => sent.add(text));

    await tester.enterText(find.byKey(const Key('ai-text')), 'pesan berikutnya');
    await tester.pump();
    expect(find.byKey(const Key('ai-stop')), findsOneWidget);
    expect(find.byKey(const Key('ai-send')), findsNothing);
    expect(find.bySemanticsLabel('Tim Gudang sedang bekerja'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-stop')));
    await tester.pump();
    expect(sent, isEmpty);
    expect(find.text('pesan berikutnya'), findsOneWidget, reason: 'Teks tidak hilang.');
    expect(find.textContaining('setelah selesai'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('saran mengisi kotak tulis lewat fill()', (tester) async {
    await pumpComposer(tester, onSend: (_, __) async {});
    composerKey.currentState!.fill('Beli 2 karung gula');
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('ai-text'))).controller!.text, 'Beli 2 karung gula');
    expect(find.byKey(const Key('ai-send')), findsOneWidget);
  });

  testWidgets('tombol + membuka Kamera, Galeri, Berkas, dan Mode cepat', (tester) async {
    final changes = <bool>[];
    await pumpComposer(tester, fastMode: false, onFastModeChanged: (value) async => changes.add(value), onSend: (_, __) async {});

    await tester.tap(find.byKey(const Key('ai-attach')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-pick-camera')), findsOneWidget);
    expect(find.byKey(const Key('ai-pick-gallery')), findsOneWidget);
    expect(find.byKey(const Key('ai-pick-file')), findsOneWidget);
    expect(find.text('Mode cepat'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-fast-mode')));
    await tester.pumpAndSettle();
    expect(changes, [true]);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('ai-fast-mode'))).value, isTrue);
  });

  for (final fast in [true, false]) {
    testWidgets('mikrofon/Kirim rata kanan sejajar "+" dan tidak bergeser saat merekam (Mode cepat ${fast ? 'aktif' : 'mati'})', (tester) async {
      await pumpComposer(tester, fastMode: fast, onSend: (_, __) async {});
      final composer = tester.getRect(find.byKey(const Key('ai-composer')));
      final attach = tester.getRect(find.byKey(const Key('ai-attach')));
      final mic = tester.getRect(find.byKey(const Key('ai-mic')));
      final mid = tester.getCenter(find.byIcon(Icons.mic_none_rounded));
      expect(composer.right - mic.right, moreOrLessEquals(attach.left - composer.left, epsilon: 0.5), reason: 'Jarak tepi kanan sama dengan tepi kiri.');
      expect(composer.right - mic.right, lessThan(12));
      expect(find.byKey(const Key('ai-fast-chip')), fast ? findsOneWidget : findsNothing);

      await holdMic(tester, (gesture) async {
        await tester.pump(const Duration(seconds: 1));
        expect(find.byKey(const Key('ai-recording')), findsOneWidget);
        expect(tester.getCenter(find.byIcon(Icons.mic)).dx, moreOrLessEquals(mid.dx, epsilon: 0.5), reason: 'Tombol tidak bergeser di bawah jari.');
        // Petunjuk "geser untuk batal" bergeser lewat tata letak: tidak menimpa gelombang.
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump();
        final waves = tester.getRect(find.descendant(of: find.byKey(const Key('ai-recording')), matching: find.byType(ClipRect)).first);
        final hint = tester.getRect(find.byIcon(Icons.chevron_left_rounded));
        expect(waves.right, lessThanOrEqualTo(hint.left), reason: 'Petunjuk tidak menutupi gelombang.');
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
        await gesture.up();
        await tester.pump();
        await tester.pump();
      });
      expect(find.text('Voice note'), findsOneWidget);
      // Ada isi: Kirim menggantikan mikrofon di tempat yang sama.
      expect(tester.getCenter(find.byKey(const Key('ai-send'))).dx, moreOrLessEquals(mid.dx, epsilon: 0.5));
    });
  }

  testWidgets('area ketuk × lampiran, +, dan Kirim minimal 48×48 (pedoman Android)', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpComposer(tester, onSend: (_, __) async {});
    await holdMic(tester, (gesture) async {
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pump();
      await tester.pump();
    });
    await tester.enterText(find.byKey(const Key('ai-text')), 'catat ini');
    await tester.pump();
    expect(find.byKey(const Key('ai-remove-0')), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });

  testWidgets('huruf 1,3×: petunjuk rekaman dipendekkan, tidak meluap', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await pumpComposer(tester, fastMode: true, onSend: (_, __) async {});
    await holdMic(tester, (gesture) async {
      await tester.pump(const Duration(seconds: 1));
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final waves = tester.getRect(find.descendant(of: find.byKey(const Key('ai-recording')), matching: find.byType(ClipRect)).first);
      final hint = tester.getRect(find.byIcon(Icons.chevron_left_rounded));
      expect(waves.right, lessThanOrEqualTo(hint.left));
      await gesture.up();
      await tester.pump();
      await tester.pump();
    });
  });

  testWidgets('kotak tulis memberi tahu saat mulai/berhenti berisi (untuk menyembunyikan saran)', (tester) async {
    final changes = <bool>[];
    final recorder = FakeVoiceRecorder();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [voiceRecorderProvider.overrideWithValue(recorder)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: AiComposer(enabled: true, limits: const AiLimits(), onContentChanged: changes.add, onSend: (_, __) async {}))),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('ai-text')), 'a');
    await tester.pump();
    await tester.enterText(find.byKey(const Key('ai-text')), 'ab');
    await tester.pump();
    await tester.enterText(find.byKey(const Key('ai-text')), '');
    await tester.pump();
    expect(changes, [true, false]);
  });
}
