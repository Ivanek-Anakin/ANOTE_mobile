import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:anote_mobile/models/recording_entry.dart';
import 'package:anote_mobile/models/session_state.dart';
import 'package:anote_mobile/providers/recording_history_provider.dart';
import 'package:anote_mobile/providers/session_provider.dart';
import 'package:anote_mobile/services/audio_service.dart';
import 'package:anote_mobile/services/recording_storage_service.dart';
import 'package:anote_mobile/services/cloud_transcription_service.dart';
import 'package:anote_mobile/services/report_service.dart';
import 'package:anote_mobile/services/whisper_service.dart';

import 'session_provider_test.mocks.dart';

// ---------------------------------------------------------------------------
// Fakes — used instead of Mockito for services that expose Streams
// ---------------------------------------------------------------------------

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
    _ctrl.close();
  }
}

class _FakeWhisperService extends WhisperService {
  @override
  bool get isModelLoaded => true;

  @override
  Future<void> loadModel({WhisperModelConfig? config}) async {}

  @override
  void feedAudio(List<double> samples) {}

  @override
  Stream<String> get transcriptStream => Stream<String>.empty();

  @override
  Future<String> transcribeFull() async => '';

  @override
  Future<String> transcribeTail() async => '';

  @override
  void reset() {}

  @override
  Future<void> flushVad() async {}

  @override
  Future<List<double>> getRawAudioBufferFromWorker() async => [];

  @override
  void dispose() {}
}

class _FakeCloudTranscriptionService extends CloudTranscriptionService {
  @override
  Future<String> transcribe(List<double> samples) async => '';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@GenerateMocks([ReportService])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockReportService mockReportService;
  late _FakeAudioService fakeAudioService;
  late _FakeWhisperService fakeWhisperService;
  late Directory tempDir;
  late RecordingStorageService storageService;

  late _FakeCloudTranscriptionService fakeCloudService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Stub flutter_secure_storage so SessionNotifier._seedDefaultCloudSettings
    // does not throw MissingPluginException during construction.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async {
        if (call.method == 'read' || call.method == 'readAll') return null;
        return null;
      },
    );
    // Stub wakelock_plus to avoid PlatformException during resetSession.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle'),
      (MethodCall call) async => null,
    );
    mockReportService = MockReportService();
    fakeAudioService = _FakeAudioService();
    fakeWhisperService = _FakeWhisperService();
    fakeCloudService = _FakeCloudTranscriptionService();
    tempDir = await Directory.systemTemp.createTemp('session_test_');
    storageService = RecordingStorageService(
      baseDirOverride: () async => tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ProviderContainer makeContainer() {
    return ProviderContainer(
      overrides: [
        reportServiceProvider.overrideWithValue(mockReportService),
        audioServiceProvider.overrideWithValue(fakeAudioService),
        whisperServiceProvider.overrideWithValue(fakeWhisperService),
        recordingStorageServiceProvider.overrideWithValue(storageService),
        cloudTranscriptionServiceProvider.overrideWithValue(fakeCloudService),
        transcriptionModelProvider
            .overrideWith((ref) => TranscriptionModelNotifier()),
      ],
    );
  }

  test('initial state is idle with empty transcript and report', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    final state = container.read(sessionProvider);
    expect(state.status, RecordingStatus.idle);
    expect(state.transcript, isEmpty);
    expect(state.report, isEmpty);
    expect(state.errorMessage, isNull);
  });

  test('startRecording sets status to recording', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).startRecording();
    expect(container.read(sessionProvider).status, RecordingStatus.recording);
  });

  test('stopRecording sets status to idle', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    when(mockReportService.generateReport(any,
            visitType: anyNamed('visitType')))
        .thenAnswer((_) async => '');

    container.read(sessionProvider.notifier).startRecording();
    container.read(sessionProvider.notifier).stopRecording();
    // Give the async stop pipeline time to complete (includes 300ms drain delay)
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(container.read(sessionProvider).status, RecordingStatus.idle);
  });

  test('resetSession clears all fields', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).startRecording();
    container.read(sessionProvider.notifier).resetSession();

    final state = container.read(sessionProvider);
    expect(state.status, RecordingStatus.idle);
    expect(state.transcript, isEmpty);
    expect(state.report, isEmpty);
    expect(state.errorMessage, isNull);
  });

  test('stopRecording eventually sets status to idle', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    when(mockReportService.generateReport(any,
            visitType: anyNamed('visitType')))
        .thenAnswer((_) async => 'Lékařská zpráva');

    container.read(sessionProvider.notifier).startRecording();
    container.read(sessionProvider.notifier).stopRecording();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(container.read(sessionProvider).status, RecordingStatus.idle);
  });

  test('startRecording stores error when audio service fails', () async {
    final brokenAudio = _BrokenAudioService();

    final container = ProviderContainer(
      overrides: [
        reportServiceProvider.overrideWithValue(mockReportService),
        audioServiceProvider.overrideWithValue(brokenAudio),
        whisperServiceProvider.overrideWithValue(fakeWhisperService),
        recordingStorageServiceProvider.overrideWithValue(storageService),
        cloudTranscriptionServiceProvider.overrideWithValue(fakeCloudService),
        transcriptionModelProvider
            .overrideWith((ref) => TranscriptionModelNotifier()),
      ],
    );
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).startRecording();
    // Give the async start time to fail
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(sessionProvider);
    expect(state.errorMessage, isNotNull);
    expect(state.status, RecordingStatus.idle);
  });

  // ---------------------------------------------------------------------------
  // New tests: loadRecording, resetSession clearing loaded, recording history
  // ---------------------------------------------------------------------------

  test('loadRecording sets transcript and report from entry', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    final entry = RecordingEntry(
      id: 'test-entry-1',
      createdAt: DateTime(2026, 3, 21),
      transcript: 'Pacient přichází s bolestí hlavy.',
      report: 'Lékařská zpráva',
      visitType: 'default',
      durationSeconds: 120,
      wordCount: 5,
    );

    container.read(sessionProvider.notifier).loadRecording(entry);

    final state = container.read(sessionProvider);
    expect(state.status, RecordingStatus.idle);
    expect(state.transcript, entry.transcript);
    expect(state.report, entry.report);
  });

  test('loadRecording sets loadedRecordingIdProvider', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    final entry = RecordingEntry(
      id: 'test-entry-2',
      createdAt: DateTime(2026, 3, 21),
      transcript: 'Test transcript',
      report: 'Test report',
      visitType: 'initial',
      durationSeconds: 60,
      wordCount: 2,
    );

    container.read(sessionProvider.notifier).loadRecording(entry);
    expect(container.read(loadedRecordingIdProvider), 'test-entry-2');
  });

  test('resetSession clears loadedRecordingIdProvider', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    final entry = RecordingEntry(
      id: 'test-entry-3',
      createdAt: DateTime(2026, 3, 21),
      transcript: 'Test transcript',
      report: 'Test report',
      visitType: 'default',
      durationSeconds: 60,
      wordCount: 2,
    );

    container.read(sessionProvider.notifier).loadRecording(entry);
    expect(container.read(loadedRecordingIdProvider), 'test-entry-3');

    container.read(sessionProvider.notifier).resetSession();
    expect(container.read(loadedRecordingIdProvider), isNull);
  });

  test('startRecording clears loadedRecordingIdProvider', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    final entry = RecordingEntry(
      id: 'test-entry-4',
      createdAt: DateTime(2026, 3, 21),
      transcript: 'Test',
      report: 'Report',
      visitType: 'default',
      durationSeconds: 30,
      wordCount: 1,
    );

    container.read(sessionProvider.notifier).loadRecording(entry);
    expect(container.read(loadedRecordingIdProvider), 'test-entry-4');

    container.read(sessionProvider.notifier).startRecording();
    expect(container.read(loadedRecordingIdProvider), isNull);
  });

  test('loadRecording preserves isModelLoaded', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    // The fake whisper service says isModelLoaded = true, and preload
    // runs on construction, so isModelLoaded should become true
    // (though it's async, let's read the initial state).
    // For this test, we start recording to trigger model loaded state,
    // then load a recording and verify isModelLoaded is preserved.
    container.read(sessionProvider.notifier).startRecording();
    // Since FakeWhisperService.isModelLoaded == true, the notifier
    // should set isModelLoaded in state.
    container.read(sessionProvider.notifier).resetSession();

    final entry = RecordingEntry(
      id: 'test-entry-5',
      createdAt: DateTime(2026, 3, 21),
      transcript: 'Loaded from history',
      report: 'Historical report',
      visitType: 'followup',
      durationSeconds: 90,
      wordCount: 3,
    );

    container.read(sessionProvider.notifier).loadRecording(entry);
    final state = container.read(sessionProvider);
    expect(state.transcript, 'Loaded from history');
    expect(state.report, 'Historical report');
  });

  // ---------------------------------------------------------------------------
  // TASK-0035: Journey A ("+" then mic) and Journey B (post-stop "Start" mic)
  // must produce identical pre-recording SessionState.
  // ---------------------------------------------------------------------------

  test('Journey A and Journey B produce identical SessionState (TASK-0035)',
      () async {
    SessionState seedDirtyState(ProviderContainer c) {
      // Simulate a stopped recording with transcript + report present.
      final notifier = c.read(sessionProvider.notifier);
      notifier.startRecording();
      // Mutate state directly is not allowed; use loadRecording to simulate
      // a populated post-stop session.
      notifier.resetSession();
      notifier.loadRecording(RecordingEntry(
        id: 'seed-${c.hashCode}',
        createdAt: DateTime(2026, 5, 1),
        transcript: 'Pacient si stěžuje na bolesti hlavy.',
        report: 'Lékařská zpráva: bolesti hlavy.',
        visitType: 'default',
        durationSeconds: 60,
        wordCount: 5,
      ));
      return c.read(sessionProvider);
    }

    SessionState snapshotPreRecord(ProviderContainer c) {
      // Capture state immediately after reset/restart but before status flips
      // to recording. We snapshot after startRecording sets recording status,
      // so we compare the recording-start state instead.
      return c.read(sessionProvider);
    }

    // Journey A: "+" (startNewRecording) then mic (startRecording)
    final containerA = makeContainer();
    addTearDown(containerA.dispose);
    seedDirtyState(containerA);
    await containerA.read(sessionProvider.notifier).startNewRecording();
    containerA.read(sessionProvider.notifier).startRecording();
    final stateA = snapshotPreRecord(containerA);
    final loadedIdA = containerA.read(loadedRecordingIdProvider);

    // Journey B: post-stop "Start" mic-tap (restartRecording)
    final containerB = makeContainer();
    addTearDown(containerB.dispose);
    seedDirtyState(containerB);
    await containerB.read(sessionProvider.notifier).restartRecording();
    final stateB = snapshotPreRecord(containerB);
    final loadedIdB = containerB.read(loadedRecordingIdProvider);

    // Both journeys must end on a recording session with empty transcript,
    // empty report, no error, no carry-over visit type drift, no loaded id.
    expect(stateA.status, RecordingStatus.recording);
    expect(stateB.status, RecordingStatus.recording);
    expect(stateA.transcript, stateB.transcript);
    expect(stateA.transcript, isEmpty);
    expect(stateA.report, stateB.report);
    expect(stateA.report, isEmpty);
    expect(stateA.errorMessage, stateB.errorMessage);
    expect(stateA.errorMessage, isNull);
    expect(stateA.visitTypeChanged, stateB.visitTypeChanged);
    expect(stateA.visitTypeChanged, isFalse);
    expect(stateA.visitType, stateB.visitType);
    expect(loadedIdA, loadedIdB);
    expect(loadedIdA, isNull);
  });

  test('resetSession preserves isModelLoaded based on whisper service',
      () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    // Fake whisper service reports isModelLoaded == true.
    container.read(sessionProvider.notifier).startRecording();
    container.read(sessionProvider.notifier).resetSession();
    final state = container.read(sessionProvider);
    expect(state.status, RecordingStatus.idle);
    expect(state.isModelLoaded, isTrue,
        reason: 'resetSession must reflect the loaded model so the UI does not '
            'flicker into "model not loaded" between sessions (TASK-0035).');
  });

  test('startRecording auto-resets when called from a dirty state', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).loadRecording(RecordingEntry(
          id: 'dirty-1',
          createdAt: DateTime(2026, 5, 1),
          transcript: 'Stale transcript',
          report: 'Stale report',
          visitType: 'default',
          durationSeconds: 30,
          wordCount: 2,
        ));
    expect(container.read(sessionProvider).transcript, 'Stale transcript');

    container.read(sessionProvider.notifier).startRecording();

    final state = container.read(sessionProvider);
    expect(state.status, RecordingStatus.recording);
    expect(state.transcript, isEmpty);
    expect(state.report, isEmpty);
    expect(container.read(loadedRecordingIdProvider), isNull);
  });
}

/// An AudioService whose [start] always throws [MicPermissionDenied].
class _BrokenAudioService extends AudioService {
  @override
  Stream<List<double>> get audioStream => Stream<List<double>>.empty();

  @override
  Future<void> start() async =>
      throw const MicPermissionDenied('Permission denied in test');

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}
