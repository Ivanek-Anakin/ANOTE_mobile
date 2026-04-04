import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anote_mobile/models/recording_entry.dart';
import 'package:anote_mobile/services/recording_storage_service.dart';

void main() {
  late Directory tempDir;
  late RecordingStorageService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('recording_storage_test_');
    service = RecordingStorageService(
      baseDirOverride: () async => tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  RecordingEntry _makeEntry({
    String? id,
    String transcript = 'Pacient přichází s bolestí hlavy.',
    String report = 'Lékařská zpráva: bolest hlavy',
    String visitType = 'default',
    int durationSeconds = 120,
  }) {
    return RecordingEntry(
      id: id ?? RecordingStorageService.generateId(),
      createdAt: DateTime.now(),
      transcript: transcript,
      report: report,
      visitType: visitType,
      durationSeconds: durationSeconds,
      wordCount: transcript.split(RegExp(r'\s+')).length,
    );
  }

  // -------------------------------------------------------------------------
  // RecordingEntry model tests
  // -------------------------------------------------------------------------
  group('RecordingEntry', () {
    test('toJson and fromJson round-trip', () {
      final entry = _makeEntry();
      final json = entry.toJson();
      final restored = RecordingEntry.fromJson(json);

      expect(restored.id, entry.id);
      expect(restored.transcript, entry.transcript);
      expect(restored.report, entry.report);
      expect(restored.visitType, entry.visitType);
      expect(restored.durationSeconds, entry.durationSeconds);
      expect(restored.wordCount, entry.wordCount);
    });

    test('fromJson handles missing optional fields', () {
      final json = {
        'id': 'test-id',
        'createdAt': DateTime.now().toIso8601String(),
      };
      final entry = RecordingEntry.fromJson(json);
      expect(entry.transcript, '');
      expect(entry.report, '');
      expect(entry.visitType, 'default');
      expect(entry.durationSeconds, 0);
      expect(entry.wordCount, 0);
      expect(entry.updatedAt, isNull);
    });

    test('fromJson parses updatedAt', () {
      final now = DateTime.now();
      final json = {
        'id': 'test-id',
        'createdAt': now.toIso8601String(),
        'transcript': 'test',
        'report': 'report',
        'updatedAt': now.toIso8601String(),
      };
      final entry = RecordingEntry.fromJson(json);
      expect(entry.updatedAt, isNotNull);
    });

    test('copyWith updates report and updatedAt', () {
      final entry = _makeEntry();
      final updated = entry.copyWith(
        report: 'New report',
        updatedAt: DateTime.now(),
      );
      expect(updated.report, 'New report');
      expect(updated.updatedAt, isNotNull);
      expect(updated.id, entry.id);
      expect(updated.transcript, entry.transcript);
    });
  });

  // -------------------------------------------------------------------------
  // RecordingIndexEntry model tests
  // -------------------------------------------------------------------------
  group('RecordingIndexEntry', () {
    test('fromEntry truncates preview to 80 chars', () {
      final longTranscript = 'A' * 200;
      final entry = _makeEntry(transcript: longTranscript);
      final indexEntry = RecordingIndexEntry.fromEntry(entry);
      expect(indexEntry.preview.length, 83); // 80 + '...'
      expect(indexEntry.preview.endsWith('...'), isTrue);
    });

    test('fromEntry keeps short transcript as-is', () {
      final entry = _makeEntry(transcript: 'Short text');
      final indexEntry = RecordingIndexEntry.fromEntry(entry);
      expect(indexEntry.preview, 'Short text');
    });

    test('toJson and fromJson round-trip', () {
      final entry = _makeEntry();
      final indexEntry = RecordingIndexEntry.fromEntry(entry);
      final json = indexEntry.toJson();
      final restored = RecordingIndexEntry.fromJson(json);

      expect(restored.id, indexEntry.id);
      expect(restored.visitType, indexEntry.visitType);
      expect(restored.wordCount, indexEntry.wordCount);
      expect(restored.durationSeconds, indexEntry.durationSeconds);
      expect(restored.preview, indexEntry.preview);
    });
  });

  // -------------------------------------------------------------------------
  // RecordingStorageService tests
  // -------------------------------------------------------------------------
  group('RecordingStorageService', () {
    test('loadIndex returns empty list when no recordings exist', () async {
      final index = await service.loadIndex();
      expect(index, isEmpty);
    });

    test('saveEntry persists entry and updates index', () async {
      final entry = _makeEntry();
      await service.saveEntry(entry);

      final index = await service.loadIndex();
      expect(index, hasLength(1));
      expect(index.first.id, entry.id);
    });

    test('loadEntry returns saved entry', () async {
      final entry = _makeEntry();
      await service.saveEntry(entry);

      final loaded = await service.loadEntry(entry.id);
      expect(loaded.id, entry.id);
      expect(loaded.transcript, entry.transcript);
      expect(loaded.report, entry.report);
    });

    test('loadEntry throws RecordingNotFoundException for missing id',
        () async {
      expect(
        () => service.loadEntry('nonexistent'),
        throwsA(isA<RecordingNotFoundException>()),
      );
    });

    test('deleteEntry removes entry and updates index', () async {
      final entry = _makeEntry();
      await service.saveEntry(entry);
      await service.deleteEntry(entry.id);

      final index = await service.loadIndex();
      expect(index, isEmpty);

      expect(
        () => service.loadEntry(entry.id),
        throwsA(isA<RecordingNotFoundException>()),
      );
    });

    test('updateReport modifies only report and sets updatedAt', () async {
      final entry = _makeEntry(report: 'Original report');
      await service.saveEntry(entry);

      await service.updateReport(entry.id, 'Updated report');

      final loaded = await service.loadEntry(entry.id);
      expect(loaded.report, 'Updated report');
      expect(loaded.updatedAt, isNotNull);
      expect(loaded.transcript, entry.transcript);
    });

    test('multiple entries are sorted newest first in index', () async {
      final entry1 = RecordingEntry(
        id: RecordingStorageService.generateId(),
        createdAt: DateTime(2026, 3, 20),
        transcript: 'First entry',
        report: 'Report 1',
        visitType: 'default',
        durationSeconds: 60,
        wordCount: 2,
      );
      final entry2 = RecordingEntry(
        id: RecordingStorageService.generateId(),
        createdAt: DateTime(2026, 3, 21),
        transcript: 'Second entry',
        report: 'Report 2',
        visitType: 'initial',
        durationSeconds: 120,
        wordCount: 2,
      );

      await service.saveEntry(entry1);
      await service.saveEntry(entry2);

      final index = await service.loadIndex();
      expect(index, hasLength(2));
      expect(index.first.id, entry2.id); // Newer first
      expect(index.last.id, entry1.id);
    });

    test('saveEntry overwrites existing entry', () async {
      final entry = _makeEntry(report: 'First version');
      await service.saveEntry(entry);

      final updated = entry.copyWith(report: 'Second version');
      await service.saveEntry(updated);

      final loaded = await service.loadEntry(entry.id);
      expect(loaded.report, 'Second version');

      final index = await service.loadIndex();
      expect(index, hasLength(1));
    });

    test('deleteAll clears all entries', () async {
      await service.saveEntry(_makeEntry());
      await service.saveEntry(_makeEntry());
      await service.saveEntry(_makeEntry());

      await service.deleteAll();

      final index = await service.loadIndex();
      expect(index, isEmpty);
    });

    test('index rebuilds from entry files when corrupted', () async {
      final entry = _makeEntry();
      await service.saveEntry(entry);

      // Corrupt the index file
      final dir = Directory('${tempDir.path}/recordings');
      final indexFile = File('${dir.path}/_index.json');
      await indexFile.writeAsString('NOT VALID JSON!!!');

      // loadIndex should rebuild from entry files
      final index = await service.loadIndex();
      expect(index, hasLength(1));
      expect(index.first.id, entry.id);
    });

    test('generateId produces valid UUID v4 format', () {
      final id = RecordingStorageService.generateId();
      final uuidRegex = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      expect(uuidRegex.hasMatch(id), isTrue);
    });

    test('generateId produces unique values', () {
      final ids =
          List.generate(100, (_) => RecordingStorageService.generateId());
      expect(ids.toSet().length, 100);
    });
  });
}
