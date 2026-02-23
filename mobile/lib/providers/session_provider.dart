import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/constants.dart';
import '../models/session_state.dart';
import '../services/audio_service.dart';
import '../services/report_service.dart';
import '../services/whisper_service.dart';

final reportServiceProvider = Provider<ReportService>((ref) {
  return ReportService();
});

final audioServiceProvider = Provider<AudioService>((ref) {
  return AudioService();
});

final whisperServiceProvider = Provider<WhisperService>((ref) {
  return WhisperService();
});

final sessionProvider =
    StateNotifierProvider<SessionNotifier, SessionState>((ref) {
  return SessionNotifier(
    ref.watch(reportServiceProvider),
    ref.watch(audioServiceProvider),
    ref.watch(whisperServiceProvider),
  );
});

class SessionNotifier extends StateNotifier<SessionState> {
  final ReportService _reportService;
  final AudioService _audioService;
  final WhisperService _whisperService;

  StreamSubscription<List<double>>? _audioSubscription;
  StreamSubscription<String>? _transcriptSubscription;
  Timer? _reportTimer;

  SessionNotifier(
    this._reportService,
    this._audioService,
    this._whisperService,
  ) : super(const SessionState());

  // ---------------------------------------------------------------------------
  // Recording pipeline
  // ---------------------------------------------------------------------------

  /// Begin recording.
  ///
  /// Sets status to [RecordingStatus.recording] immediately, then asynchronously:
  /// 1. Loads the Whisper model if not already loaded.
  /// 2. Starts [AudioService] (requests mic permission).
  /// 3. Pipes audio samples into [WhisperService].
  /// 4. Subscribes to live transcript updates.
  /// 5. Starts a periodic timer that generates report previews.
  void startRecording() {
    state = state.copyWith(
      status: RecordingStatus.recording,
      transcript: '',
      report: '',
      clearError: true,
    );
    _startRecordingAsync();
  }

  Future<void> _startRecordingAsync() async {
    try {
      if (!_whisperService.isModelLoaded) {
        await _whisperService.loadModel();
        if (!mounted) return;
        state = state.copyWith(isModelLoaded: true);
      }

      await _audioService.start();
      if (!mounted) return;

      _audioSubscription = _audioService.audioStream.listen(
        (List<double> samples) => _whisperService.feedAudio(samples),
        onError: (Object error) {
          if (!mounted) return;
          state = state.copyWith(
            status: RecordingStatus.idle,
            errorMessage: 'Chyba mikrofonu: $error',
          );
        },
      );

      _transcriptSubscription = _whisperService.transcriptStream.listen(
        (String transcript) {
          if (!mounted) return;
          if (state.status == RecordingStatus.recording) {
            state = state.copyWith(transcript: transcript);
          }
        },
      );

      _reportTimer = Timer.periodic(
        AppConstants.reportGenerationInterval,
        (_) => _generateReportPreview(),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        status: RecordingStatus.idle,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> _generateReportPreview() async {
    if (!mounted) return;
    final String transcript = state.transcript;
    if (transcript.isEmpty || state.status != RecordingStatus.recording) {
      return;
    }
    try {
      final String report = await _reportService.generateReport(transcript);
      if (mounted && state.status == RecordingStatus.recording) {
        state = state.copyWith(report: report);
      }
    } catch (_) {
      // Silently ignore report errors during recording so the doctor is
      // not interrupted.  The final report on stop will surface errors.
    }
  }

  /// Stop recording and produce the final high-quality transcript and report.
  void stopRecording() {
    _reportTimer?.cancel();
    _reportTimer = null;

    _audioSubscription?.cancel();
    _audioSubscription = null;

    _transcriptSubscription?.cancel();
    _transcriptSubscription = null;

    state = state.copyWith(status: RecordingStatus.processing);
    _stopRecordingAsync();
  }

  Future<void> _stopRecordingAsync() async {
    try {
      await _audioService.stop();
      if (!mounted) return;

      final String fullTranscript = await _whisperService.transcribeFull();
      if (!mounted) return;

      if (fullTranscript.isNotEmpty) {
        state = state.copyWith(transcript: fullTranscript);
      }

      final String finalTranscript = state.transcript;
      if (finalTranscript.isNotEmpty) {
        final String report =
            await _reportService.generateReport(finalTranscript);
        if (!mounted) return;
        state = state.copyWith(report: report);
      }
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      if (mounted) {
        state = state.copyWith(status: RecordingStatus.idle);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Session management
  // ---------------------------------------------------------------------------

  /// Clear all session state and stop any running audio/timers.
  void resetSession() {
    _reportTimer?.cancel();
    _reportTimer = null;

    _audioSubscription?.cancel();
    _audioSubscription = null;

    _transcriptSubscription?.cancel();
    _transcriptSubscription = null;

    final bool wasRunning = state.status == RecordingStatus.recording ||
        state.status == RecordingStatus.processing;

    _whisperService.reset();
    state = const SessionState();

    if (wasRunning) {
      unawaited(_audioService.stop());
    }
  }

  // ---------------------------------------------------------------------------
  // Demo mode (Phase 4 — stub: load full text then generate report)
  // ---------------------------------------------------------------------------

  /// Load demo scenario from assets, display transcript, and generate report.
  Future<void> playDemo(String scenarioId) async {
    state = state.copyWith(
      status: RecordingStatus.demoPlaying,
      clearError: true,
    );

    String transcript;
    try {
      transcript = await rootBundle.loadString(
        'assets/demo_scenarios/$scenarioId.txt',
      );
      transcript = transcript.trim();
    } catch (e) {
      state = state.copyWith(
        status: RecordingStatus.idle,
        errorMessage: 'Scénář nelze načíst: $e',
      );
      return;
    }

    state = state.copyWith(transcript: transcript);

    try {
      final String report = await _reportService.generateReport(transcript);
      state = state.copyWith(
        status: RecordingStatus.idle,
        report: report,
      );
    } catch (e) {
      state = state.copyWith(
        status: RecordingStatus.idle,
        errorMessage: e.toString(),
      );
    }
  }

  /// Cancel demo playback — sets status to idle.
  void cancelDemo() {
    state = state.copyWith(status: RecordingStatus.idle);
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _audioSubscription?.cancel();
    _transcriptSubscription?.cancel();
    super.dispose();
  }
}
