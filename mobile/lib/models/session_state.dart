enum RecordingStatus { idle, recording, processing }

/// Transcription model selection.
enum TranscriptionModel {
  /// On-device Whisper Small INT8 (~358 MB)
  small,

  /// On-device Whisper Large-v3-Turbo INT8 (~1036 MB)
  turbo,

  /// Azure OpenAI Whisper cloud API
  cloud,

  /// Hybrid: on-device live preview + cloud final transcript
  hybrid,
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
      case TranscriptionModel.hybrid:
        return 'hybrid';
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
      case TranscriptionModel.hybrid:
        return 'Hybrid';
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
      case TranscriptionModel.hybrid:
        return 'On-device živý náhled + Cloud finální přepis';
    }
  }

  static TranscriptionModel fromString(String? value) {
    switch (value) {
      case 'turbo':
        return TranscriptionModel.turbo;
      case 'cloud':
        return TranscriptionModel.cloud;
      case 'hybrid':
        return TranscriptionModel.hybrid;
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

  /// Gastroscopy report.
  gastroscopy,

  /// Colonoscopy report.
  colonoscopy,

  /// Ultrasound report.
  ultrasound,
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
      case VisitType.gastroscopy:
        return 'gastroscopy';
      case VisitType.colonoscopy:
        return 'colonoscopy';
      case VisitType.ultrasound:
        return 'ultrasound';
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
      case VisitType.gastroscopy:
        return 'Gastroskopie';
      case VisitType.colonoscopy:
        return 'Koloskopie';
      case VisitType.ultrasound:
        return 'Ultrazvuk';
    }
  }

  static VisitType fromString(String? value) {
    switch (value) {
      case 'initial':
        return VisitType.initial;
      case 'followup':
        return VisitType.followup;
      case 'gastroscopy':
        return VisitType.gastroscopy;
      case 'colonoscopy':
        return VisitType.colonoscopy;
      case 'ultrasound':
        return VisitType.ultrasound;
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
