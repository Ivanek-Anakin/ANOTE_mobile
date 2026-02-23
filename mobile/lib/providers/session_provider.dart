import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session_state.dart';
import '../services/report_service.dart';

final reportServiceProvider = Provider<ReportService>((ref) {
  return ReportService();
});

final sessionProvider =
    StateNotifierProvider<SessionNotifier, SessionState>((ref) {
  return SessionNotifier(ref.watch(reportServiceProvider));
});

class SessionNotifier extends StateNotifier<SessionState> {
  final ReportService _reportService;

  SessionNotifier(this._reportService) : super(const SessionState());

  /// Start recording — sets status to recording (audio wired in Phase 3).
  void startRecording() {
    state = state.copyWith(
      status: RecordingStatus.recording,
      clearError: true,
    );
  }

  /// Stop recording — sets status back to idle.
  void stopRecording() {
    state = state.copyWith(status: RecordingStatus.idle);
  }

  /// Clear all session state.
  void resetSession() {
    state = const SessionState();
  }

  /// Generate a report from manually entered text (temporary — Phase 2 only).
  Future<void> generateReportFromText(String transcript) async {
    if (transcript.trim().isEmpty) return;
    state = state.copyWith(
      status: RecordingStatus.processing,
      transcript: transcript,
      clearError: true,
    );
    try {
      final report = await _reportService.generateReport(transcript);
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

    // Show transcript immediately so the user sees it appear
    state = state.copyWith(transcript: transcript);

    // Now call the backend to generate the report
    try {
      final report = await _reportService.generateReport(transcript);
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
}
