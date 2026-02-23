enum RecordingStatus { idle, recording, processing, demoPlaying }

class SessionState {
  final RecordingStatus status;
  final String transcript;
  final String report;
  final String? errorMessage;
  final bool isModelLoaded;

  const SessionState({
    this.status = RecordingStatus.idle,
    this.transcript = '',
    this.report = '',
    this.errorMessage,
    this.isModelLoaded = false,
  });

  SessionState copyWith({
    RecordingStatus? status,
    String? transcript,
    String? report,
    String? errorMessage,
    bool clearError = false,
    bool? isModelLoaded,
  }) {
    return SessionState(
      status: status ?? this.status,
      transcript: transcript ?? this.transcript,
      report: report ?? this.report,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isModelLoaded: isModelLoaded ?? this.isModelLoaded,
    );
  }
}
