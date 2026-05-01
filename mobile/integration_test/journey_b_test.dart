// ignore_for_file: avoid_print

// TASK-0035: Journey B integration test.
//
// Verifies that pressing the record button after Stop+Report (Journey B)
// produces a pre-recording state functionally and visually identical to
// pressing "+" (new recording) followed by tapping the record button
// (Journey A).
//
// Both flows must converge through SessionNotifier.resetSession(), so
// transcript, report, error message, visit-type drift and loaded-recording
// id must all be cleared before the second recording begins, while the
// previous recording must remain in history.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anote_mobile/main.dart';
import 'package:anote_mobile/models/session_state.dart';
import 'package:anote_mobile/providers/recording_history_provider.dart';
import 'package:anote_mobile/providers/session_provider.dart';
import 'package:anote_mobile/services/audio_service.dart';
import 'package:anote_mobile/services/cloud_transcription_service.dart';
import 'package:anote_mobile/services/report_service.dart';
import 'package:anote_mobile/services/whisper_service.dart';

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
  String tail = '';

  @override
  bool get isModelLoaded => true;

  @override
  Future<void> loadModel({WhisperModelConfig? config}) async {}

  @override
  void feedAudio(List<double> samples) {}

  @override
  Stream<String> get transcriptStream => _transcriptCtrl.stream;

  @override
  Future<String> transcribeFull() async => tail;

  @override
  Future<String> transcribeTail() async => tail;

  @override
  Future<void> flushVad() async {}

  @override
  Future<List<double>> getRawAudioBufferFromWorker() async => const [];

  @override
  void reset() {
    tail = '';
  }

  @override
  void dispose() {
    if (!_transcriptCtrl.isClosed) _transcriptCtrl.close();
  }
}

class _FakeCloudTranscriptionService extends CloudTranscriptionService {
  @override
  Future<String> transcribe(List<double> samples) async => '';
}

class _FakeReportService extends ReportService {
  String result = 'Lékařská zpráva: pacient bez akutních potíží.';
  int calls = 0;

  @override
  Future<String> generateReport(String transcript,
      {String visitType = 'default'}) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return result;
  }

  @override
  Future<bool> isBackendReachable() async => true;
}

void _stubPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle'),
    (_) async => null,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _stubPlatformChannels();
  });

  testWidgets(
      'TASK-0035: Stop → report → Start tap resets state identically to "+" + mic',
      (tester) async {
    final audio = _FakeAudioService();
    final whisper = _FakeWhisperService();
    final report = _FakeReportService();
    final cloud = _FakeCloudTranscriptionService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioServiceProvider.overrideWithValue(audio),
          whisperServiceProvider.overrideWithValue(whisper),
          reportServiceProvider.overrideWithValue(report),
          cloudTranscriptionServiceProvider.overrideWithValue(cloud),
        ],
        child: const AnoteApp(initialThemeMode: ThemeMode.light),
      ),
    );
    await tester.pumpAndSettle();

    // Locate the home screen's ProviderContainer via a known widget.
    final BuildContext homeCtx = tester.element(find.byType(Scaffold).first);
    final container = ProviderScope.containerOf(homeCtx);
    final notifier = container.read(sessionProvider.notifier);

    // ---------------------------------------------------------------------
    // Step 1: Drive a recording → stop → report cycle.
    // ---------------------------------------------------------------------
    whisper.tail = 'Pacient si stěžuje na bolesti hlavy a únavu.';
    notifier.startRecording();
    await tester.pump(const Duration(milliseconds: 50));
    notifier.stopRecording();
    // Allow the async stop pipeline to finish (300ms drain + report gen).
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final afterStop = container.read(sessionProvider);
    expect(afterStop.status, RecordingStatus.idle);
    expect(afterStop.transcript, contains('Pacient'));
    expect(afterStop.report, isNotEmpty);
    final savedRecordingId = container.read(loadedRecordingIdProvider);
    expect(savedRecordingId, isNotNull,
        reason: 'Recording should be auto-saved to history after stop.');

    // ---------------------------------------------------------------------
    // Step 2: Press the mic FAB ("Start") — Journey B.
    //   With content present, _onRecordFabIdleTap routes through
    //   _saveAndClear(thenStartRecording: true) → restartRecording().
    // ---------------------------------------------------------------------
    whisper.tail = ''; // fresh slate
    final fabFinder = find.byKey(const ValueKey('record_fab')).hitTestable();
    // record_fab uses an internal GestureDetector; tap the RecordFAB widget.
    final recordTapTarget = find
        .descendant(
          of: find.byType(GestureDetector),
          matching: find.byIcon(Icons.mic),
        )
        .first;
    await tester.tap(recordTapTarget, warnIfMissed: false);
    // _saveAndClear awaits storage; pump until restartRecording completes.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // After Journey B, the session must be RECORDING with a fully clean
    // pre-recording snapshot (transcript empty, report empty, no error,
    // no carry-over visit-type drift, no loaded recording reference).
    final afterRestart = container.read(sessionProvider);
    expect(afterRestart.status, RecordingStatus.recording,
        reason: 'Mic tap on idle-with-content must start a new recording.');
    expect(afterRestart.transcript, isEmpty,
        reason: 'Transcript must be cleared before second recording.');
    expect(afterRestart.report, isEmpty,
        reason: 'Report must be cleared before second recording.');
    expect(afterRestart.errorMessage, isNull);
    expect(afterRestart.visitTypeChanged, isFalse);
    expect(container.read(loadedRecordingIdProvider), isNull,
        reason: 'Loaded recording id must be cleared on restart.');

    // History must still contain the previous recording (no data loss).
    final historyAsync = container.read(recordingIndexProvider);
    final history = historyAsync.value ?? const [];
    expect(history.length, greaterThanOrEqualTo(1),
        reason: 'Previous recording must remain accessible in history.');
    expect(
      history.any((e) => e.id == savedRecordingId),
      isTrue,
      reason: 'The pre-stop recording must still be in _index.json.',
    );

    // ---------------------------------------------------------------------
    // Step 3: Cleanly stop the second recording so the test tears down.
    // ---------------------------------------------------------------------
    notifier.stopRecording();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(container.read(sessionProvider).status, RecordingStatus.idle);

    // Ignore unused locals on this finder helper.
    fabFinder.toString();

    audio.dispose();
    whisper.dispose();
  });
}
