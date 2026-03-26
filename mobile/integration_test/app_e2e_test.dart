// ignore_for_file: avoid_print

// End-to-end integration tests for ANOTE Mobile.
//
// These tests run on a real Android emulator (or device) via:
//   flutter test integration_test/app_e2e_test.dart
//
// All three heavy services — AudioService, WhisperService, ReportService —
// are replaced with fakes so the tests don't require a microphone, model
// files, or network access.
//
// Test scenarios:
// 1. App launches and shows the home screen with correct initial state.
// 2. Recording history: verify history list is present.
// 3. Recording flow: start → simulated audio + transcript → stop → report.
// 4. Clear/reset: after content is generated, clear everything.
// 5. Settings navigation: open settings, verify UI elements, go back.
// 6. Performance metrics: measure latency of key operations.
// 7. Error handling: verify error messages on report generation failure.
// 8. Theme toggle: verify dark/light mode switch.
// 9. Transcript panel: verify status badge during recording.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:anote_mobile/main.dart';
import 'package:anote_mobile/providers/session_provider.dart';
import 'package:anote_mobile/services/audio_service.dart';
import 'package:anote_mobile/services/report_service.dart';
import 'package:anote_mobile/services/whisper_service.dart';

// =============================================================================
// Fake Services
// =============================================================================

/// Fake AudioService that emits pre-loaded audio chunks from a
/// [StreamController] instead of using the real microphone.
class FakeAudioService extends AudioService {
  final StreamController<List<double>> _ctrl =
      StreamController<List<double>>.broadcast();

  @override
  Stream<List<double>> get audioStream => _ctrl.stream;

  @override
  Future<void> start() async {
    // No-op: microphone not needed.
  }

  @override
  Future<void> stop() async {
    // No-op.
  }

  /// Inject a chunk of audio data as if it came from the microphone.
  void injectAudio(List<double> samples) {
    if (!_ctrl.isClosed) {
      _ctrl.add(samples);
    }
  }

  @override
  void dispose() {
    if (!_ctrl.isClosed) {
      _ctrl.close();
    }
  }
}

/// Fake WhisperService that pretends the model is loaded and returns
/// controllable transcript text. No actual Whisper model is loaded.
class FakeWhisperService extends WhisperService {
  final StreamController<String> _transcriptCtrl =
      StreamController<String>.broadcast();

  /// The text that [transcribeFull] / [transcribeTail] will return.
  String transcribeFullResult = '';

  /// Count of feedAudio calls (for verification).
  int feedAudioCallCount = 0;

  @override
  bool get isModelLoaded => true;

  @override
  Future<void> loadModel({WhisperModelConfig? config}) async {
    // No-op: skip 250MB model download.
  }

  @override
  void feedAudio(List<double> samples) {
    feedAudioCallCount++;
  }

  @override
  Stream<String> get transcriptStream => _transcriptCtrl.stream;

  /// Simulate the worker isolate emitting a live transcript update.
  void emitTranscript(String text) {
    if (!_transcriptCtrl.isClosed) {
      _transcriptCtrl.add(text);
    }
  }

  @override
  Future<String> transcribeFull() async {
    // Simulate a small processing delay.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return transcribeFullResult;
  }

  @override
  Future<String> transcribeTail() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return transcribeFullResult;
  }

  @override
  void reset() {
    feedAudioCallCount = 0;
    transcribeFullResult = '';
  }

  @override
  void dispose() {
    if (!_transcriptCtrl.isClosed) {
      _transcriptCtrl.close();
    }
  }
}

/// Fake ReportService that returns a canned report string without
/// hitting the real backend. Tracks call count and last input for assertions.
class FakeReportService extends ReportService {
  /// The report text to return from [generateReport].
  String reportResult = _defaultReport;

  /// Number of times [generateReport] was called.
  int generateCallCount = 0;

  /// Last transcript passed to [generateReport].
  String? lastTranscript;

  /// Last visit type passed to [generateReport].
  String? lastVisitType;

  /// Artificial delay to simulate backend latency (default 100ms).
  Duration latency;

  /// If non-null, [generateReport] will throw this instead of returning.
  Exception? errorToThrow;

  FakeReportService({this.latency = const Duration(milliseconds: 100)});

  static const String _defaultReport = '''Anamneza:
Pacient prichazi s bolesti na hrudi.

Objektivni nalez:
TK 140/90, TF 88/min, sat 97%.

Zaver:
Doporucena hospitalizace k observaci.''';

  @override
  Future<String> generateReport(String transcript,
      {String visitType = 'default'}) async {
    generateCallCount++;
    lastTranscript = transcript;
    lastVisitType = visitType;
    await Future<void>.delayed(latency);
    if (errorToThrow != null) throw errorToThrow!;
    return reportResult;
  }

  @override
  Future<bool> isBackendReachable() async => true;
}

// =============================================================================
// Test Helpers
// =============================================================================

/// Pump the app with all three service providers overridden with fakes.
/// Returns a record containing the fakes for manipulation during tests.
({
  FakeAudioService audio,
  FakeWhisperService whisper,
  FakeReportService report,
}) pumpApp(
  WidgetTester tester, {
  FakeAudioService? audio,
  FakeWhisperService? whisper,
  FakeReportService? report,
}) {
  final fakeAudio = audio ?? FakeAudioService();
  final fakeWhisper = whisper ?? FakeWhisperService();
  final fakeReport = report ?? FakeReportService();
  return (audio: fakeAudio, whisper: fakeWhisper, report: fakeReport);
}

Future<
    ({
      FakeAudioService audio,
      FakeWhisperService whisper,
      FakeReportService report,
    })> pumpTestApp(WidgetTester tester) async {
  final fakes = pumpApp(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        audioServiceProvider.overrideWithValue(fakes.audio),
        whisperServiceProvider.overrideWithValue(fakes.whisper),
        reportServiceProvider.overrideWithValue(fakes.report),
      ],
      child: const AnoteApp(initialThemeMode: ThemeMode.light),
    ),
  );
  // Let the initial frame settle (including deferred model preload).
  await tester.pumpAndSettle();
  return fakes;
}

// =============================================================================
// Performance tracking
// =============================================================================

class PerfMetric {
  final String name;
  final Duration duration;
  const PerfMetric(this.name, this.duration);

  @override
  String toString() => '$name: ${duration.inMilliseconds}ms';
}

final List<PerfMetric> _perfMetrics = [];

void recordMetric(String name, Duration duration) {
  _perfMetrics.add(PerfMetric(name, duration));
  print('[PERF] $name: ${duration.inMilliseconds}ms');
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDownAll(() {
    print('\n========== PERFORMANCE METRICS ==========');
    for (final m in _perfMetrics) {
      print('  $m');
    }
    print('==========================================\n');
  });

  // -----------------------------------------------------------------------
  // 1. App Launch & Initial State
  // -----------------------------------------------------------------------
  group('App Launch', () {
    testWidgets('shows home screen with correct initial UI elements',
        (tester) async {
      final sw = Stopwatch()..start();
      await pumpTestApp(tester);
      sw.stop();
      recordMetric('app_launch', sw.elapsed);

      // AppBar title
      expect(find.text('ANOTE'), findsOneWidget);
      expect(find.byIcon(Icons.medical_services), findsOneWidget);

      // Status pill shows "Pripraveno" (ready) because model is "loaded" (fake)
      // The fake whisper service reports isModelLoaded = true, but the
      // SessionState.isModelLoaded is set via provider after preload.
      // With our fake, it stays false initially, but the status is idle.
      expect(find.textContaining('Připraveno'), findsOneWidget);

      // Settings button
      expect(find.byKey(const Key('btn_settings')), findsOneWidget);

      // Record button
      expect(find.byKey(const Key('btn_record')), findsOneWidget);

      // Report panel title
      expect(find.textContaining('Lékařská zpráva'), findsWidgets);

      // Stop button
      expect(find.byKey(const Key('btn_stop')), findsOneWidget);

      // Clear button
      expect(find.byKey(const Key('btn_clear')), findsOneWidget);
    });

    testWidgets('report panel shows placeholder text when empty',
        (tester) async {
      await pumpTestApp(tester);

      expect(
        find.text(
            'Začněte nahrávat pro automatické generování lékařské zprávy...'),
        findsOneWidget,
      );
    });

    testWidgets('transcript panel is hidden when no content', (tester) async {
      await pumpTestApp(tester);

      // TranscriptPanel returns SizedBox.shrink() when idle + empty transcript
      expect(find.textContaining('Přepis řeči'), findsNothing);
    });
  });

  // -----------------------------------------------------------------------
  // 2. Recording History (replaced Demo Mode)
  // -----------------------------------------------------------------------
  group('Recording History', () {
    testWidgets('recording history area shows empty state on home screen',
        (tester) async {
      await pumpTestApp(tester);

      // When no recordings exist, the empty state text should be visible
      final emptyText =
          find.textContaining('Zat\u00edm \u017e\u00e1dn\u00e9 nahr\u00e1vky');
      await tester.scrollUntilVisible(emptyText, 200,
          scrollable: find.byType(Scrollable).first);
      expect(emptyText, findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // 3. Recording Flow (simulated audio)
  // -----------------------------------------------------------------------
  group('Recording Flow', () {
    testWidgets(
        'start recording, receive live transcript, stop, get final report',
        (tester) async {
      final fakes = await pumpTestApp(tester);

      // Configure fake whisper to return a final transcript
      fakes.whisper.transcribeFullResult =
          'Pacient prichazi s bolesti na hrudi, tlak 140/90.';

      // Scroll to record button (may be off-screen on small devices)
      final recordBtn = find.byKey(const Key('btn_record'));
      await tester.ensureVisible(recordBtn);

      // Tap record
      final sw = Stopwatch()..start();
      await tester.tap(recordBtn);
      await tester.pump();

      // Status should change to recording
      expect(find.textContaining('Nahrávání'), findsOneWidget);

      // Simulate live transcript updates from the whisper isolate
      fakes.whisper.emitTranscript('Pacient prichazi');
      await tester.pump(const Duration(milliseconds: 100));

      // The transcript panel should appear with partial text
      expect(find.textContaining('Přepis řeči'), findsOneWidget);

      // Simulate more audio being fed
      fakes.audio.injectAudio(List<double>.filled(16000, 0.1)); // 1s of audio
      await tester.pump(const Duration(milliseconds: 100));

      // Emit more transcript
      fakes.whisper.emitTranscript('Pacient prichazi s bolesti na hrudi');
      await tester.pump(const Duration(milliseconds: 100));

      // Scroll to stop button and tap
      final stopBtn = find.byKey(const Key('btn_stop'));
      await tester.ensureVisible(stopBtn);
      await tester.tap(stopBtn);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      sw.stop();
      recordMetric('recording_flow_total', sw.elapsed);

      // After stop, status should be idle
      expect(find.textContaining('Připraveno'), findsOneWidget);

      // Report should have been generated (transcribeFull → generateReport)
      expect(fakes.report.generateCallCount, greaterThanOrEqualTo(1));

      // Report text should appear in the UI
      expect(find.textContaining('Anamneza'), findsWidgets);
    });

    testWidgets('stop button is disabled when not recording', (tester) async {
      await pumpTestApp(tester);

      final stopBtn = find.byKey(const Key('btn_stop'));
      await tester.ensureVisible(stopBtn);
      expect(stopBtn, findsOneWidget);
      final button = tester.widget<FilledButton>(stopBtn);
      expect(button.onPressed, isNull);
    });

    testWidgets('record button is disabled while recording', (tester) async {
      final fakes = await pumpTestApp(tester);
      fakes.whisper.transcribeFullResult = 'Test.';

      // Scroll to and start recording
      final recordBtn = find.byKey(const Key('btn_record'));
      await tester.ensureVisible(recordBtn);
      await tester.tap(recordBtn);
      await tester.pump(const Duration(milliseconds: 100));

      // Record button should now be disabled
      final button2 = tester.widget<FilledButton>(recordBtn);
      expect(button2.onPressed, isNull);

      // Stop to clean up — scroll to stop button, then wait with pump
      final stopBtn = find.byKey(const Key('btn_stop'));
      await tester.ensureVisible(stopBtn);
      await tester.tap(stopBtn);
      // Use pump with duration instead of pumpAndSettle to avoid timeout
      // from recording/processing animation
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    });
  });

  // -----------------------------------------------------------------------
  // 4. Clear / Reset Session
  // -----------------------------------------------------------------------
  group('Clear Session', () {
    testWidgets('clear button resets transcript and report', (tester) async {
      final fakes = await pumpTestApp(tester);

      // Populate content via recording flow
      fakes.whisper.transcribeFullResult =
          'Pacient prichazi s bolesti na hrudi.';

      final recordBtn = find.byKey(const Key('btn_record'));
      await tester.ensureVisible(recordBtn);
      await tester.tap(recordBtn);
      await tester.pump();

      // Simulate transcript
      fakes.whisper.emitTranscript('Pacient prichazi s bolesti na hrudi.');
      await tester.pump(const Duration(milliseconds: 100));

      // Stop recording to trigger report generation
      final stopBtn = find.byKey(const Key('btn_stop'));
      await tester.ensureVisible(stopBtn);
      await tester.tap(stopBtn);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // Verify content exists
      expect(fakes.report.generateCallCount, greaterThan(0));

      // Now tap clear
      final clearBtn = find.byKey(const Key('btn_clear'));
      await tester.ensureVisible(clearBtn);
      await tester.tap(clearBtn);
      await tester.pumpAndSettle();

      // Report placeholder should reappear
      expect(
        find.text(
            'Začněte nahrávat pro automatické generování lékařské zprávy...'),
        findsOneWidget,
      );

      // Transcript panel should be hidden again
      expect(find.textContaining('Přepis řeči'), findsNothing);
    });

    testWidgets('clear button is disabled when no content exists',
        (tester) async {
      await pumpTestApp(tester);

      final clearBtn = find.byKey(const Key('btn_clear'));
      await tester.ensureVisible(clearBtn);
      final button = tester.widget<OutlinedButton>(clearBtn);
      expect(button.onPressed, isNull);
    });
  });

  // -----------------------------------------------------------------------
  // 5. Settings Screen Navigation
  // -----------------------------------------------------------------------
  group('Settings Screen', () {
    testWidgets('navigate to settings and back', (tester) async {
      await pumpTestApp(tester);

      // Tap settings button
      final sw = Stopwatch()..start();
      await tester.tap(find.byKey(const Key('btn_settings')));
      await tester.pumpAndSettle();
      sw.stop();
      recordMetric('settings_navigation', sw.elapsed);

      // Verify we're on the settings screen
      expect(find.text('Nastavení'), findsOneWidget);

      // Check key UI elements exist
      expect(find.text('URL backendu'), findsOneWidget);
      expect(find.text('API Bearer Token'), findsOneWidget);
      expect(find.text('Uložit nastavení'), findsOneWidget);
      expect(find.text('Test připojení'), findsOneWidget);

      // Visit type selector segments
      expect(find.text('Výchozí'), findsOneWidget);
      expect(find.text('Vstupní'), findsOneWidget);
      expect(find.text('Kontrolní'), findsOneWidget);

      // Navigate back
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      // Should be back on home screen
      expect(find.text('ANOTE'), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // 7. Performance: Report Generation Latency
  // -----------------------------------------------------------------------
  group('Performance', () {
    testWidgets('report generation latency under 10s with fake backend',
        (tester) async {
      final fakes = await pumpTestApp(tester);

      // Use a very fast fake
      fakes.report.latency = const Duration(milliseconds: 10);
      fakes.whisper.transcribeFullResult = 'Pacient prichazi s bolesti.';

      // Record and stop to trigger report generation
      final recordBtn = find.byKey(const Key('btn_record'));
      await tester.ensureVisible(recordBtn);

      final sw = Stopwatch()..start();
      await tester.tap(recordBtn);
      await tester.pump();

      fakes.whisper.emitTranscript('Pacient prichazi s bolesti.');
      await tester.pump(const Duration(milliseconds: 100));

      final stopBtn = find.byKey(const Key('btn_stop'));
      await tester.ensureVisible(stopBtn);
      await tester.tap(stopBtn);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      sw.stop();

      recordMetric('report_generation_fast', sw.elapsed);

      // The total time (record + stop + report + UI render) should be reasonable
      // Note: on emulator this is much slower than real device, so allow 10s
      expect(sw.elapsed.inMilliseconds, lessThan(10000),
          reason:
              'Recording flow should complete in under 10s with fast fake on emulator');
    });

    testWidgets('app renders initial frame quickly', (tester) async {
      final sw = Stopwatch()..start();

      final fakeAudio = FakeAudioService();
      final fakeWhisper = FakeWhisperService();
      final fakeReport = FakeReportService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioServiceProvider.overrideWithValue(fakeAudio),
            whisperServiceProvider.overrideWithValue(fakeWhisper),
            reportServiceProvider.overrideWithValue(fakeReport),
          ],
          child: const AnoteApp(initialThemeMode: ThemeMode.light),
        ),
      );
      // Just pump one frame (not pumpAndSettle) to measure initial render
      await tester.pump();
      sw.stop();
      recordMetric('first_frame_render', sw.elapsed);

      expect(sw.elapsed.inMilliseconds, lessThan(3000),
          reason: 'First frame should render in under 3s');
    });
  });

  // -----------------------------------------------------------------------
  // 8. Error Handling UI
  // -----------------------------------------------------------------------
  group('Error Handling', () {
    testWidgets('report error during recording shows error message',
        (tester) async {
      final fakes = await pumpTestApp(tester);
      fakes.report.errorToThrow =
          const ReportNetworkException('Server nedostupny');
      fakes.whisper.transcribeFullResult = 'Test transcript.';

      // Start recording
      final recordBtn = find.byKey(const Key('btn_record'));
      await tester.ensureVisible(recordBtn);
      await tester.tap(recordBtn);
      await tester.pump();

      fakes.whisper.emitTranscript('Test transcript.');
      await tester.pump(const Duration(milliseconds: 100));

      // Stop recording — this triggers report generation which will throw
      final stopBtn = find.byKey(const Key('btn_stop'));
      await tester.ensureVisible(stopBtn);
      await tester.tap(stopBtn);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // Error should be displayed
      expect(find.textContaining('Server nedostupny'), findsOneWidget);

      // Status should show error
      expect(find.textContaining('Chyba'), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // 9. Theme Toggle
  // -----------------------------------------------------------------------
  group('Theme Toggle', () {
    testWidgets('tapping theme icon toggles theme', (tester) async {
      await pumpTestApp(tester);

      // In light mode, the icon should be dark_mode (to switch to dark)
      expect(find.byIcon(Icons.dark_mode), findsOneWidget);

      // Tap it
      await tester.tap(find.byIcon(Icons.dark_mode));
      await tester.pumpAndSettle();

      // Now it should show light_mode icon (we're in dark mode)
      expect(find.byIcon(Icons.light_mode), findsOneWidget);

      // Tap again to go back
      await tester.tap(find.byIcon(Icons.light_mode));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.dark_mode), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // 10. Transcript Panel Interaction
  // -----------------------------------------------------------------------
  group('Transcript Panel', () {
    testWidgets('transcript panel shows status badge during recording',
        (tester) async {
      await pumpTestApp(tester);

      // Scroll to and start recording to make transcript panel appear
      final recordBtn = find.byKey(const Key('btn_record'));
      await tester.ensureVisible(recordBtn);
      await tester.tap(recordBtn);
      await tester.pump(const Duration(milliseconds: 100));

      // During recording, the transcript panel is shown.
      // The panel shows when isActive (recording) OR hasContent.

      // Check for the "Probíhá..." badge
      expect(find.textContaining('Probíhá'), findsOneWidget);

      // Stop recording
      final stopBtn = find.byKey(const Key('btn_stop'));
      await tester.ensureVisible(stopBtn);
      await tester.tap(stopBtn);
      await tester.pumpAndSettle(const Duration(seconds: 2));
    });
  });
}
