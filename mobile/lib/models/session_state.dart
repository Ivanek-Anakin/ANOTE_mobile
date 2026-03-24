enum RecordingStatus { idle, recording, processing }

/// Visit type mode — determines report structure.
enum VisitType {
  /// Model auto-detects from transcript.
  defaultType,

  /// First visit — full 13-section structure.
  initial,

  /// Follow-up — compact control report.
  followup,
}

/// Map VisitType to backend API string value.
extension VisitTypeApi on VisitType {
  String get apiValue {
    switch (this) {
      case VisitType.defaultType:
        return 'default';
      case VisitType.initial:
        return 'initial';
      case VisitType.followup:
        return 'followup';
    }
  }

  String get label {
    switch (this) {
      case VisitType.defaultType:
        return 'Výchozí';
      case VisitType.initial:
        return 'Vstupní';
      case VisitType.followup:
        return 'Kontrolní';
    }
  }

  static VisitType fromString(String? value) {
    switch (value) {
      case 'initial':
        return VisitType.initial;
      case 'followup':
        return VisitType.followup;
      default:
        return VisitType.defaultType;
    }
  }
}

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

  /// Current visit type used for last report generation.
  final VisitType visitType;

  /// True when visit type was changed after a report was already generated.
  final bool visitTypeChanged;

  const SessionState({
    this.status = RecordingStatus.idle,
    this.transcript = '',
    this.report = '',
    this.errorMessage,
    this.isModelLoaded = false,
    this.modelDownloadProgress,
    this.modelDownloadFileName,
    this.visitType = VisitType.defaultType,
    this.visitTypeChanged = false,
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
    VisitType? visitType,
    bool? visitTypeChanged,
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
      visitType: visitType ?? this.visitType,
      visitTypeChanged: visitTypeChanged ?? this.visitTypeChanged,
    );
  }
}
