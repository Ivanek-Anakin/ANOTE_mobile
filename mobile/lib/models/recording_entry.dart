/// Data model for a persisted recording entry.
///
/// Each entry stores the transcript, medical report, and metadata from a
/// completed recording session. Audio is NOT stored — only text data.
class RecordingEntry {
  final String id;
  final DateTime createdAt;
  final String transcript;
  final String report;
  final String visitType;
  final int durationSeconds;
  final int wordCount;
  final DateTime? updatedAt;

  const RecordingEntry({
    required this.id,
    required this.createdAt,
    required this.transcript,
    required this.report,
    required this.visitType,
    required this.durationSeconds,
    required this.wordCount,
    this.updatedAt,
  });

  RecordingEntry copyWith({
    String? transcript,
    String? report,
    String? visitType,
    DateTime? updatedAt,
  }) {
    return RecordingEntry(
      id: id,
      createdAt: createdAt,
      transcript: transcript ?? this.transcript,
      report: report ?? this.report,
      visitType: visitType ?? this.visitType,
      durationSeconds: durationSeconds,
      wordCount: wordCount,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'createdAt': createdAt.toIso8601String(),
      'transcript': transcript,
      'report': report,
      'visitType': visitType,
      'durationSeconds': durationSeconds,
      'wordCount': wordCount,
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    };
  }

  factory RecordingEntry.fromJson(Map<String, dynamic> json) {
    return RecordingEntry(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      transcript: json['transcript'] as String? ?? '',
      report: json['report'] as String? ?? '',
      visitType: json['visitType'] as String? ?? 'default',
      durationSeconds: json['durationSeconds'] as int? ?? 0,
      wordCount: json['wordCount'] as int? ?? 0,
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }
}

/// Lightweight index entry for fast list loading.
///
/// Stored in `_index.json` — avoids reading every full entry file
/// just to populate the history list.
class RecordingIndexEntry {
  final String id;
  final DateTime createdAt;
  final String visitType;
  final int wordCount;
  final int durationSeconds;
  final String preview;

  const RecordingIndexEntry({
    required this.id,
    required this.createdAt,
    required this.visitType,
    required this.wordCount,
    required this.durationSeconds,
    required this.preview,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'createdAt': createdAt.toIso8601String(),
      'visitType': visitType,
      'wordCount': wordCount,
      'durationSeconds': durationSeconds,
      'preview': preview,
    };
  }

  factory RecordingIndexEntry.fromJson(Map<String, dynamic> json) {
    return RecordingIndexEntry(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      visitType: json['visitType'] as String? ?? 'default',
      wordCount: json['wordCount'] as int? ?? 0,
      durationSeconds: json['durationSeconds'] as int? ?? 0,
      preview: json['preview'] as String? ?? '',
    );
  }

  /// Create an index entry from a full recording entry.
  factory RecordingIndexEntry.fromEntry(RecordingEntry entry) {
    final preview = entry.transcript.length > 80
        ? '${entry.transcript.substring(0, 80)}...'
        : entry.transcript;
    return RecordingIndexEntry(
      id: entry.id,
      createdAt: entry.createdAt,
      visitType: entry.visitType,
      wordCount: entry.wordCount,
      durationSeconds: entry.durationSeconds,
      preview: preview,
    );
  }
}
