import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:anote_mobile/models/session_state.dart';
import 'package:anote_mobile/providers/session_provider.dart';
import 'package:anote_mobile/services/audio_service.dart';
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
  Future<void> loadModel() async {}

  @override
  void feedAudio(List<double> samples) {}

  @override
  Stream<String> get transcriptStream => Stream<String>.empty();

  @override
  Future<String> transcribeFull() async => '';

  @override
  void reset() {}

  @override
  void dispose() {}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@GenerateMocks([ReportService])
void main() {
  late MockReportService mockReportService;
  late _FakeAudioService fakeAudioService;
  late _FakeWhisperService fakeWhisperService;

  setUp(() {
    mockReportService = MockReportService();
    fakeAudioService = _FakeAudioService();
    fakeWhisperService = _FakeWhisperService();
  });

  ProviderContainer makeContainer() {
    return ProviderContainer(
      overrides: [
        reportServiceProvider.overrideWithValue(mockReportService),
        audioServiceProvider.overrideWithValue(fakeAudioService),
        whisperServiceProvider.overrideWithValue(fakeWhisperService),
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
    // Give the async stop pipeline time to complete
    await Future<void>.delayed(const Duration(milliseconds: 50));
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
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(sessionProvider).status, RecordingStatus.idle);
  });

  test('startRecording stores error when audio service fails', () async {
    final brokenAudio = _BrokenAudioService();

    final container = ProviderContainer(
      overrides: [
        reportServiceProvider.overrideWithValue(mockReportService),
        audioServiceProvider.overrideWithValue(brokenAudio),
        whisperServiceProvider.overrideWithValue(fakeWhisperService),
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
