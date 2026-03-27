enum RecordingStatus { idle, recording, processing }

/// Transcription model selection.
enum TranscriptionModel {
  /// On-device Whisper Small INT8 (~358 MB)
  small,

  /// On-device Whisper Large-v3-Turbo INT8 (~1036 MB)
  turbo,

  /// Azure OpenAI Whisper cloud API
  cloud,
}

extension TranscriptionModelApi on TranscriptionModel {
  String get prefValue {
    switch (this) {
      case TranscriptionModel.small:
        return 'small';
      case TranscriptionModel.turbo:
        return 'turbo';
      case TranscriptionModel.cloud:
        return 'cloud';
    }
  }

  String get label {
    switch (this) {
      case TranscriptionModel.small:
        return 'Small (výchozí)';
      case TranscriptionModel.turbo:
        return 'Turbo';
      case TranscriptionModel.cloud:
        return 'Cloud';
    }
  }

  String get description {
    switch (this) {
      case TranscriptionModel.small:
        return '358 MB · On-device · Bez internetu';
      case TranscriptionModel.turbo:
        return '~1 GB · On-device · Bez internetu';
      case TranscriptionModel.cloud:
        return 'Azure OpenAI · Vyžaduje internet';
    }
  }

  static TranscriptionModel fromString(String? value) {
    switch (value) {
      case 'turbo':
        return TranscriptionModel.turbo;
      case 'cloud':
        return TranscriptionModel.cloud;
      default:
        return TranscriptionModel.small;
    }
  }
}

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
