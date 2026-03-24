import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anote_mobile/models/recording_entry.dart';
import 'package:anote_mobile/providers/recording_history_provider.dart';
import 'package:anote_mobile/providers/session_provider.dart';
import 'package:anote_mobile/services/audio_service.dart';
import 'package:anote_mobile/services/recording_storage_service.dart';
import 'package:anote_mobile/services/report_service.dart';
import 'package:anote_mobile/services/whisper_service.dart';
import 'package:anote_mobile/widgets/report_panel.dart';

// ---------------------------------------------------------------------------
// Fakes — same approach as recording_history_list_test.dart
// ---------------------------------------------------------------------------

class _FakeAudioService extends AudioService {
  @override
  Stream<List<double>> get audioStream => Stream<List<double>>.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
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

class _FakeReportService extends ReportService {
  @override
  Future<String> generateReport(String transcript,
      {String visitType = 'default'}) async {
    return 'Mock report';
  }
}

/// In-memory storage service for tests.
class _InMemoryStorageService extends RecordingStorageService {
  final Map<String, RecordingEntry> _entries = {};

  @override
  Future<List<RecordingIndexEntry>> loadIndex() async {
    final list =
        _entries.values.map((e) => RecordingIndexEntry.fromEntry(e)).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<RecordingEntry> loadEntry(String id) async {
    final entry = _entries[id];
    if (entry == null) throw RecordingNotFoundException(id);
    return entry;
  }

  @override
  Future<void> saveEntry(RecordingEntry entry) async {
    _entries[entry.id] = entry;
  }

  @override
  Future<void> deleteEntry(String id) async {
    _entries.remove(id);
  }

  @override
  Future<void> updateReport(String id, String report) async {
    final entry = _entries[id];
    if (entry == null) throw RecordingNotFoundException(id);
    _entries[id] = entry.copyWith(
      report: report,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> deleteAll() async {
    _entries.clear();
  }

  RecordingEntry? getEntry(String id) => _entries[id];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget buildTestApp({
  required Widget child,
  required List<Override> overrides,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          // ReportPanel uses Expanded, so it needs a bounded height parent.
          height: 600,
          child: child,
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late _InMemoryStorageService storageService;

  setUp(() {
    storageService = _InMemoryStorageService();
  });

  List<Override> defaultOverrides() => [
        recordingStorageServiceProvider.overrideWithValue(storageService),
        reportServiceProvider.overrideWithValue(_FakeReportService()),
        audioServiceProvider.overrideWithValue(_FakeAudioService()),
        whisperServiceProvider.overrideWithValue(_FakeWhisperService()),
      ];

  // =========================================================================
  // Save button visibility
  // =========================================================================

  testWidgets('save button hidden when no loaded recording', (tester) async {
    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const ReportPanel(showCloseButton: false),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('btn_save_changes')), findsNothing);
  });

  testWidgets('save button hidden when loaded but not edited', (tester) async {
    await storageService.saveEntry(RecordingEntry(
      id: 'entry-1',
      createdAt: DateTime(2026, 3, 21),
      transcript: 'Test transcript',
      report: 'Original report',
      visitType: 'default',
      durationSeconds: 60,
      wordCount: 2,
    ));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const ReportPanel(showCloseButton: false),
    ));
    await tester.pumpAndSettle();

    // Load the recording into session
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReportPanel)),
    );
    container.read(sessionProvider.notifier).loadRecording(RecordingEntry(
          id: 'entry-1',
          createdAt: DateTime(2026, 3, 21),
          transcript: 'Test transcript',
          report: 'Original report',
          visitType: 'default',
          durationSeconds: 60,
          wordCount: 2,
        ));
    await tester.pumpAndSettle();

    // Loaded but not edited — save button should be hidden
    expect(container.read(loadedRecordingIdProvider), 'entry-1');
    expect(find.byKey(const Key('btn_save_changes')), findsNothing);
  });

  testWidgets('save button appears after editing report text', (tester) async {
    await storageService.saveEntry(RecordingEntry(
      id: 'entry-1',
      createdAt: DateTime(2026, 3, 21),
      transcript: 'Test transcript',
      report: 'Original report',
      visitType: 'default',
      durationSeconds: 60,
      wordCount: 2,
    ));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const ReportPanel(showCloseButton: false),
    ));
    await tester.pumpAndSettle();

    // Load entry
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReportPanel)),
    );
    container.read(sessionProvider.notifier).loadRecording(RecordingEntry(
          id: 'entry-1',
          createdAt: DateTime(2026, 3, 21),
          transcript: 'Test transcript',
          report: 'Original report',
          visitType: 'default',
          durationSeconds: 60,
          wordCount: 2,
        ));
    await tester.pumpAndSettle();

    // Edit the report text
    await tester.enterText(find.byType(TextField), 'Modified report text');
    await tester.pump();

    // Save button should now appear
    expect(find.byKey(const Key('btn_save_changes')), findsOneWidget);
    expect(find.text('Uložit změny'), findsOneWidget);
  });

  // =========================================================================
  // Save functionality
  // =========================================================================

  testWidgets('save button persists changes and shows snackbar',
      (tester) async {
    await storageService.saveEntry(RecordingEntry(
      id: 'entry-1',
      createdAt: DateTime(2026, 3, 21),
      transcript: 'Test transcript',
      report: 'Original report',
      visitType: 'default',
      durationSeconds: 60,
      wordCount: 2,
    ));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const ReportPanel(showCloseButton: false),
    ));
    await tester.pumpAndSettle();

    // Load entry
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReportPanel)),
    );
    container.read(sessionProvider.notifier).loadRecording(RecordingEntry(
          id: 'entry-1',
          createdAt: DateTime(2026, 3, 21),
          transcript: 'Test transcript',
          report: 'Original report',
          visitType: 'default',
          durationSeconds: 60,
          wordCount: 2,
        ));
    await tester.pumpAndSettle();

    // Edit report
    await tester.enterText(find.byType(TextField), 'Updated report');
    await tester.pump();

    // Tap save
    await tester.tap(find.byKey(const Key('btn_save_changes')));
    await tester.pumpAndSettle();

    // Snackbar should appear
    expect(find.text('Změny uloženy'), findsOneWidget);

    // Verify storage was updated
    final updated = storageService.getEntry('entry-1');
    expect(updated?.report, 'Updated report');
  });

  testWidgets('save button disappears after successful save', (tester) async {
    await storageService.saveEntry(RecordingEntry(
      id: 'entry-1',
      createdAt: DateTime(2026, 3, 21),
      transcript: 'Test transcript',
      report: 'Original report',
      visitType: 'default',
      durationSeconds: 60,
      wordCount: 2,
    ));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const ReportPanel(showCloseButton: false),
    ));
    await tester.pumpAndSettle();

    // Load entry
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReportPanel)),
    );
    container.read(sessionProvider.notifier).loadRecording(RecordingEntry(
          id: 'entry-1',
          createdAt: DateTime(2026, 3, 21),
          transcript: 'Test transcript',
          report: 'Original report',
          visitType: 'default',
          durationSeconds: 60,
          wordCount: 2,
        ));
    await tester.pumpAndSettle();

    // Edit report
    await tester.enterText(find.byType(TextField), 'Updated text');
    await tester.pump();
    expect(find.byKey(const Key('btn_save_changes')), findsOneWidget);

    // Save changes
    await tester.tap(find.byKey(const Key('btn_save_changes')));
    await tester.pumpAndSettle();

    // Button should disappear after save
    expect(find.byKey(const Key('btn_save_changes')), findsNothing);
  });
}
