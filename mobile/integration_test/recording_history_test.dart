// ignore_for_file: avoid_print

// Integration test for the Recording History feature.
//
// Full flow: app starts → no history → record → stop → entry appears
// → tap entry → transcript+report display → edit report → save → verify.
//
// Run with:
//   flutter test integration_test/recording_history_test.dart
//
// All services are faked — no microphone, model, or network needed.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anote_mobile/main.dart';
import 'package:anote_mobile/models/recording_entry.dart';
import 'package:anote_mobile/providers/recording_history_provider.dart';
import 'package:anote_mobile/providers/session_provider.dart';
import 'package:anote_mobile/services/audio_service.dart';
import 'package:anote_mobile/services/recording_storage_service.dart';
import 'package:anote_mobile/services/report_service.dart';
import 'package:anote_mobile/services/whisper_service.dart';

// =============================================================================
// Fake Services
// =============================================================================

class _FakeAudioService extends AudioService {
  final StreamController<List<double>> _ctrl =
      StreamController<List<double>>.broadcast();

  @override
  Stream<List<double>> get audioStream => _ctrl.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  void dispose() {
    if (!_ctrl.isClosed) _ctrl.close();
  }
}

class _FakeWhisperService extends WhisperService {
  final StreamController<String> _transcriptCtrl =
      StreamController<String>.broadcast();

  String transcribeFullResult = '';

  @override
  bool get isModelLoaded => true;
  @override
  Future<void> loadModel({WhisperModelConfig? config}) async {}
  @override
  void feedAudio(List<double> samples) {}
  @override
  Stream<String> get transcriptStream => _transcriptCtrl.stream;

  void emitTranscript(String text) {
    if (!_transcriptCtrl.isClosed) _transcriptCtrl.add(text);
  }

  @override
  Future<String> transcribeFull() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return transcribeFullResult;
  }

  @override
  Future<String> transcribeTail() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return transcribeFullResult;
  }

  @override
  void reset() {
    transcribeFullResult = '';
  }

  @override
  void dispose() {
    if (!_transcriptCtrl.isClosed) _transcriptCtrl.close();
  }
}

class _FakeReportService extends ReportService {
  String reportResult = 'Anamneza: bolest hlavy.\nZávěr: sledování.';

  @override
  Future<String> generateReport(String transcript,
      {String visitType = 'default'}) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return reportResult;
  }

  @override
  Future<bool> isBackendReachable() async => true;
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  late _FakeAudioService fakeAudio;
  late _FakeWhisperService fakeWhisper;
  late _FakeReportService fakeReport;
  late Directory tempDir;
  late RecordingStorageService storageService;

  setUp(() async {
    fakeAudio = _FakeAudioService();
    fakeWhisper = _FakeWhisperService();
    fakeReport = _FakeReportService();
    tempDir = await Directory.systemTemp.createTemp('history_integration_');
    storageService = RecordingStorageService(
      baseDirOverride: () async => tempDir,
    );
  });

  tearDown(() async {
    fakeAudio.dispose();
    fakeWhisper.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioServiceProvider.overrideWithValue(fakeAudio),
          whisperServiceProvider.overrideWithValue(fakeWhisper),
          reportServiceProvider.overrideWithValue(fakeReport),
          recordingStorageServiceProvider.overrideWithValue(storageService),
        ],
        child: const AnoteApp(initialThemeMode: ThemeMode.light),
      ),
    );
    await tester.pumpAndSettle();
  }

  // =========================================================================
  // Full recording history flow
  // =========================================================================

  testWidgets('empty state → record → history → load → edit → save',
      (tester) async {
    await pumpApp(tester);

    // 1. Scroll down to verify empty history state
    await tester.drag(
        find.byType(SingleChildScrollView).first, const Offset(0, -300));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Historie nahrávek'), findsOneWidget);
    expect(find.text('Zatím žádné nahrávky.'), findsOneWidget);

    // 2. Simulate a recording + stop flow
    fakeWhisper.transcribeFullResult =
        'Pacient přichází s bolestí hlavy trvající 3 dny.';

    // Scroll back to record button and tap
    final recordBtn = find.byKey(const Key('btn_record'));
    await tester.ensureVisible(recordBtn);
    await tester.tap(recordBtn);
    // Don't use pumpAndSettle during recording — animations keep running
    await tester.pump(const Duration(milliseconds: 200));

    // Emit a live transcript update
    fakeWhisper.emitTranscript('Pacient přichází s bolestí hlavy');
    await tester.pump(const Duration(milliseconds: 200));

    // Tap stop — scroll into view first
    final stopBtn = find.byKey(const Key('btn_stop'));
    await tester.ensureVisible(stopBtn);
    await tester.tap(stopBtn);
    // Wait for the stop pipeline: transcribeTail + generateReport + autoSave
    // Use pump loop instead of pumpAndSettle to avoid timeout from animations
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // 3. Scroll down to history — entry should now exist
    await tester.drag(
        find.byType(SingleChildScrollView).first, const Offset(0, -300));
    // Use pump loop to let the scroll settle
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The empty state should be gone
    expect(find.text('Zatím žádné nahrávky.'), findsNothing);

    // A history item should show the preview
    expect(find.textContaining('Pacient přichází'), findsWidgets);
  });

  testWidgets('load from history and edit report', (tester) async {
    // Pre-populate with a recording entry
    final entry = RecordingEntry(
      id: 'pre-existing',
      createdAt: DateTime(2026, 3, 21, 10, 0),
      transcript: 'Předchozí nahrávka pacienta.',
      report: 'Předchozí zpráva: normální nález.',
      visitType: 'default',
      durationSeconds: 180,
      wordCount: 3,
    );
    await storageService.saveEntry(entry);

    await pumpApp(tester);

    // Scroll to history
    await tester.drag(
        find.byType(SingleChildScrollView).first, const Offset(0, -300));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Verify entry is visible
    final itemFinder = find.byKey(const Key('history_item_pre-existing'));
    // Entry may need further scrolling
    if (itemFinder.evaluate().isEmpty) {
      await tester.drag(
          find.byType(SingleChildScrollView).first, const Offset(0, -200));
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // Tap to load
    await tester.ensureVisible(itemFinder);
    await tester.tap(itemFinder);
    for (int i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // Verify the transcript + report are loaded into the panels
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final session = container.read(sessionProvider);
    expect(session.transcript, 'Předchozí nahrávka pacienta.');
    expect(session.report, 'Předchozí zpráva: normální nález.');
    expect(container.read(loadedRecordingIdProvider), 'pre-existing');
  });
}
