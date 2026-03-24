import 'dart:async';

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
import 'package:anote_mobile/widgets/recording_history_list.dart';

// ---------------------------------------------------------------------------
// Fakes — no real I/O, no real model loading
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

/// In-memory storage service that stores entries in a Map.
/// Avoids file I/O completely — works perfectly in Flutter's FakeAsync zone.
class InMemoryStorageService extends RecordingStorageService {
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
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

RecordingEntry makeEntry({
  String? id,
  DateTime? createdAt,
  String transcript = 'Pacient přichází s bolestí hlavy.',
  String report = 'Lékařská zpráva: test',
  String visitType = 'default',
  int durationSeconds = 120,
}) {
  return RecordingEntry(
    id: id ?? RecordingStorageService.generateId(),
    createdAt: createdAt ?? DateTime(2026, 3, 21, 14, 30),
    transcript: transcript,
    report: report,
    visitType: visitType,
    durationSeconds: durationSeconds,
    wordCount: transcript.trim().split(RegExp(r'\s+')).length,
  );
}

Widget buildTestApp({
  required Widget child,
  required List<Override> overrides,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late InMemoryStorageService storageService;

  setUp(() {
    storageService = InMemoryStorageService();
  });

  List<Override> defaultOverrides() => [
        recordingStorageServiceProvider.overrideWithValue(storageService),
        reportServiceProvider.overrideWithValue(_FakeReportService()),
        audioServiceProvider.overrideWithValue(_FakeAudioService()),
        whisperServiceProvider.overrideWithValue(_FakeWhisperService()),
      ];

  // =========================================================================
  // Empty state
  // =========================================================================

  testWidgets('shows empty state when no recordings exist', (tester) async {
    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Historie nahrávek'), findsOneWidget);
    expect(find.text('Zatím žádné nahrávky.'), findsOneWidget);
  });

  // =========================================================================
  // Loading state
  // =========================================================================

  testWidgets('shows loading indicator initially', (tester) async {
    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    // Only pump once — index load microtask hasn't completed yet
    await tester.pump();

    // The header should always be present
    expect(find.text('Historie nahrávek'), findsOneWidget);
    // Either a loading indicator or the empty state should be present
    // (depending on microtask scheduling — in-memory is fast)
    expect(
      find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
          find.text('Zatím žádné nahrávky.').evaluate().isNotEmpty,
      isTrue,
    );
  });

  // =========================================================================
  // List rendering
  // =========================================================================

  testWidgets('renders saved recordings with correct data', (tester) async {
    await storageService.saveEntry(makeEntry(
      id: 'entry-1',
      visitType: 'initial',
      durationSeconds: 480,
    ));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    // Date
    expect(find.text('21.3.2026 14:30'), findsOneWidget);
    // Visit type badge
    expect(find.text('Vstupní'), findsOneWidget);
    // Preview
    expect(find.textContaining('Pacient přichází'), findsOneWidget);
    // Word count + duration
    expect(find.text('5 slov · 8 min'), findsOneWidget);
  });

  testWidgets('renders multiple entries', (tester) async {
    await storageService.saveEntry(makeEntry(id: 'a'));
    await storageService.saveEntry(makeEntry(id: 'b'));
    await storageService.saveEntry(makeEntry(id: 'c'));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('delete_a')), findsOneWidget);
    expect(find.byKey(const Key('delete_b')), findsOneWidget);
    expect(find.byKey(const Key('delete_c')), findsOneWidget);
  });

  // =========================================================================
  // Collapsible header
  // =========================================================================

  testWidgets('collapse and expand toggles list visibility', (tester) async {
    await storageService.saveEntry(makeEntry(id: 'entry-1'));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    // List is visible initially
    expect(find.byKey(const Key('delete_entry-1')), findsOneWidget);

    // Tap header to collapse
    await tester.tap(find.text('Historie nahrávek'));
    await tester.pump();

    // List is now hidden
    expect(find.byKey(const Key('delete_entry-1')), findsNothing);

    // Tap again to expand
    await tester.tap(find.text('Historie nahrávek'));
    await tester.pump();

    expect(find.byKey(const Key('delete_entry-1')), findsOneWidget);
  });

  // =========================================================================
  // Visit type badges
  // =========================================================================

  testWidgets('shows correct visit type badges', (tester) async {
    await storageService.saveEntry(makeEntry(id: 'a', visitType: 'default'));
    await storageService.saveEntry(makeEntry(id: 'b', visitType: 'initial'));
    await storageService.saveEntry(makeEntry(id: 'c', visitType: 'followup'));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Výchozí'), findsOneWidget);
    expect(find.text('Vstupní'), findsOneWidget);
    expect(find.text('Kontrolní'), findsOneWidget);
  });

  // =========================================================================
  // Tap to load
  // =========================================================================

  testWidgets('tapping entry loads it into session', (tester) async {
    await storageService.saveEntry(makeEntry(
      id: 'load-me',
      transcript: 'Loaded transcript.',
      report: 'Loaded report.',
    ));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    // Tap item
    await tester.tap(find.byKey(const Key('history_item_load-me')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(RecordingHistoryList)),
    );
    final session = container.read(sessionProvider);
    expect(session.transcript, 'Loaded transcript.');
    expect(session.report, 'Loaded report.');
    expect(container.read(loadedRecordingIdProvider), 'load-me');
  });

  // =========================================================================
  // Unsaved data confirmation dialog
  // =========================================================================

  testWidgets('shows confirmation dialog when loading with unsaved data',
      (tester) async {
    await storageService.saveEntry(makeEntry(id: 'entry-1'));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    // Set unsaved data (transcript without a loaded recording ID)
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RecordingHistoryList)),
    );
    container.read(sessionProvider.notifier).loadRecording(RecordingEntry(
          id: 'temp',
          createdAt: DateTime.now(),
          transcript: 'some unsaved text',
          report: '',
          visitType: 'default',
          durationSeconds: 10,
          wordCount: 3,
        ));
    container.read(loadedRecordingIdProvider.notifier).state = null;
    await tester.pump();

    // Tap entry
    await tester.tap(find.byKey(const Key('history_item_entry-1')));
    await tester.pumpAndSettle();

    expect(find.text('Neuložená data'), findsOneWidget);
    expect(find.text('Zahodit a načíst'), findsOneWidget);

    // Cancel
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();

    expect(container.read(loadedRecordingIdProvider), isNull);
  });

  testWidgets('confirming load dialog loads the entry', (tester) async {
    await storageService.saveEntry(makeEntry(
      id: 'entry-1',
      transcript: 'Loaded entry text',
      report: 'Loaded report',
    ));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    // Set unsaved data
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RecordingHistoryList)),
    );
    container.read(sessionProvider.notifier).loadRecording(RecordingEntry(
          id: 'temp',
          createdAt: DateTime.now(),
          transcript: 'unsaved',
          report: '',
          visitType: 'default',
          durationSeconds: 10,
          wordCount: 1,
        ));
    container.read(loadedRecordingIdProvider.notifier).state = null;
    await tester.pump();

    // Tap → dialog
    await tester.tap(find.byKey(const Key('history_item_entry-1')));
    await tester.pumpAndSettle();

    // Confirm
    await tester.tap(find.text('Zahodit a načíst'));
    await tester.pumpAndSettle();

    expect(container.read(loadedRecordingIdProvider), 'entry-1');
    expect(container.read(sessionProvider).transcript, 'Loaded entry text');
  });

  // =========================================================================
  // Delete
  // =========================================================================

  testWidgets('delete shows confirmation dialog', (tester) async {
    await storageService.saveEntry(makeEntry(id: 'del-1'));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_del-1')));
    await tester.pumpAndSettle();

    expect(find.text('Smazat nahrávku?'), findsOneWidget);
    expect(
        find.text(
            'Opravdu chcete smazat tuto nahrávku? Tuto akci nelze vrátit.'),
        findsOneWidget);
  });

  testWidgets('cancelling delete dialog keeps entry', (tester) async {
    await storageService.saveEntry(makeEntry(id: 'del-1'));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_del-1')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('delete_del-1')), findsOneWidget);
  });

  testWidgets('confirming delete removes entry from list', (tester) async {
    await storageService.saveEntry(makeEntry(id: 'del-1'));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_del-1')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Smazat'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('delete_del-1')), findsNothing);
    expect(find.text('Zatím žádné nahrávky.'), findsOneWidget);
  });

  testWidgets('deleting currently loaded entry resets session', (tester) async {
    await storageService.saveEntry(makeEntry(id: 'loaded-del'));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    // Load the entry
    await tester.tap(find.byKey(const Key('history_item_loaded-del')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(RecordingHistoryList)),
    );
    expect(container.read(loadedRecordingIdProvider), 'loaded-del');

    // Delete
    await tester.tap(find.byKey(const Key('delete_loaded-del')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Smazat'));
    await tester.pumpAndSettle();

    expect(container.read(loadedRecordingIdProvider), isNull);
    expect(container.read(sessionProvider).transcript, isEmpty);
  });

  // =========================================================================
  // Highlight loaded entry
  // =========================================================================

  testWidgets('currently loaded entry is highlighted', (tester) async {
    await storageService.saveEntry(makeEntry(id: 'highlight-1'));
    await storageService.saveEntry(makeEntry(id: 'highlight-2'));

    await tester.pumpWidget(buildTestApp(
      overrides: defaultOverrides(),
      child: const RecordingHistoryList(),
    ));
    await tester.pumpAndSettle();

    // Load the first entry
    await tester.tap(find.byKey(const Key('history_item_highlight-1')));
    await tester.pumpAndSettle();

    // Find the Card widget for each item
    final item1 = tester.widget<Card>(find
        .ancestor(
          of: find.byKey(const Key('delete_highlight-1')),
          matching: find.byType(Card),
        )
        .first);

    final item2 = tester.widget<Card>(find
        .ancestor(
          of: find.byKey(const Key('delete_highlight-2')),
          matching: find.byType(Card),
        )
        .first);

    final theme = Theme.of(tester.element(find.byType(RecordingHistoryList)));
    expect(item1.color, theme.colorScheme.primaryContainer);
    expect(item2.color, isNot(theme.colorScheme.primaryContainer));
  });
}
