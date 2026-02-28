enum RecordingStatus { idle, recording, processing, demoPlaying }

class SessionState {
  final RecordingStatus status;
  final String transcript;
  final String report;
  final String? errorMessage;
  final bool isModelLoaded;

  /// Download progress 0.0–1.0 while model files are being fetched.
  /// null means no download in progress.
  final double? modelDownloadProgress;

  /// Name of the file currently being downloaded (e.g. 'small-encoder.int8.onnx').
  final String? modelDownloadFileName;

  const SessionState({
    this.status = RecordingStatus.idle,
    this.transcript = '',
    this.report = '',
    this.errorMessage,
    this.isModelLoaded = false,
    this.modelDownloadProgress,
    this.modelDownloadFileName,
  });

  SessionState copyWith({
    RecordingStatus? status,
    String? transcript,
    String? report,
    String? errorMessage,
    bool clearError = false,
    bool? isModelLoaded,
    double? modelDownloadProgress,
    String? modelDownloadFileName,
    bool clearDownload = false,
  }) {
    return SessionState(
      status: status ?? this.status,
      transcript: transcript ?? this.transcript,
      report: report ?? this.report,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isModelLoaded: isModelLoaded ?? this.isModelLoaded,
      modelDownloadProgress: clearDownload
          ? null
          : (modelDownloadProgress ?? this.modelDownloadProgress),
      modelDownloadFileName: clearDownload
          ? null
          : (modelDownloadFileName ?? this.modelDownloadFileName),
    );
  }
}
