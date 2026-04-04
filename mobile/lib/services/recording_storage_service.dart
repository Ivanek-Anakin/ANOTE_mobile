import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../models/recording_entry.dart';

/// Persists recording entries as JSON files on device.
///
/// Storage layout:
/// ```
/// {appDocDir}/recordings/
///   _index.json           ← lightweight list for fast UI loading
///   {id}.json             ← full RecordingEntry per recording
/// ```
class RecordingStorageService {
  static const String _dirName = 'recordings';
  static const String _indexFileName = '_index.json';

  /// Allow injecting a custom base directory (for testing).
  final Future<Directory> Function()? _baseDirOverride;

  RecordingStorageService({Future<Directory> Function()? baseDirOverride})
      : _baseDirOverride = baseDirOverride;

  Future<Directory> _getRecordingsDir() async {
    final Directory baseDir = _baseDirOverride != null
        ? await _baseDirOverride()
        : await getApplicationDocumentsDirectory();
    final dir = Directory('${baseDir.path}/$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  File _indexFile(Directory dir) => File('${dir.path}/$_indexFileName');

  File _entryFile(Directory dir, String id) => File('${dir.path}/$id.json');

  // ---------------------------------------------------------------------------
  // Index operations
  // ---------------------------------------------------------------------------

  /// Load the index of all recordings (lightweight metadata only).
  /// Returns entries sorted by createdAt descending (newest first).
  Future<List<RecordingIndexEntry>> loadIndex() async {
    final dir = await _getRecordingsDir();
    final file = _indexFile(dir);
    if (!await file.exists()) return [];

    try {
      final content = await file.readAsString();
      final List<dynamic> jsonList = json.decode(content) as List<dynamic>;
      final entries = jsonList
          .map((e) => RecordingIndexEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      // Sort newest first
      entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return entries;
    } catch (e) {
      // Index corrupted — rebuild from individual files
      return _rebuildIndex(dir);
    }
  }

  /// Write index to disk with atomic rename to prevent corruption.
  Future<void> _writeIndex(
      Directory dir, List<RecordingIndexEntry> entries) async {
    final file = _indexFile(dir);
    final tempFile = File('${file.path}.tmp');
    final jsonStr = json.encode(entries.map((e) => e.toJson()).toList());
    await tempFile.writeAsString(jsonStr, flush: true);
    await tempFile.rename(file.path);
  }

  /// Rebuild the index by scanning all entry files.
  Future<List<RecordingIndexEntry>> _rebuildIndex(Directory dir) async {
    final entries = <RecordingIndexEntry>[];
    await for (final entity in dir.list()) {
      if (entity is File &&
          entity.path.endsWith('.json') &&
          !entity.path.endsWith(_indexFileName)) {
        try {
          final content = await entity.readAsString();
          final entry = RecordingEntry.fromJson(
              json.decode(content) as Map<String, dynamic>);
          entries.add(RecordingIndexEntry.fromEntry(entry));
        } catch (_) {
          // Skip corrupted files
        }
      }
    }
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _writeIndex(dir, entries);
    return entries;
  }

  // ---------------------------------------------------------------------------
  // CRUD operations
  // ---------------------------------------------------------------------------

  /// Load a full recording entry by ID.
  Future<RecordingEntry> loadEntry(String id) async {
    final dir = await _getRecordingsDir();
    final file = _entryFile(dir, id);
    if (!await file.exists()) {
      throw RecordingNotFoundException(id);
    }
    final content = await file.readAsString();
    return RecordingEntry.fromJson(
        json.decode(content) as Map<String, dynamic>);
  }

  /// Save a new recording entry (or overwrite existing).
  /// Updates the index automatically.
  Future<void> saveEntry(RecordingEntry entry) async {
    final dir = await _getRecordingsDir();

    // Write entry file (atomic rename)
    final entryFile = _entryFile(dir, entry.id);
    final tempFile = File('${entryFile.path}.tmp');
    await tempFile.writeAsString(json.encode(entry.toJson()), flush: true);
    await tempFile.rename(entryFile.path);

    // Update index
    final index = await loadIndex();
    final existingIdx = index.indexWhere((e) => e.id == entry.id);
    final indexEntry = RecordingIndexEntry.fromEntry(entry);
    if (existingIdx >= 0) {
      index[existingIdx] = indexEntry;
    } else {
      index.insert(0, indexEntry); // Newest first
    }
    await _writeIndex(dir, index);
  }

  /// Delete a recording entry and update the index.
  Future<void> deleteEntry(String id) async {
    final dir = await _getRecordingsDir();
    final file = _entryFile(dir, id);
    if (await file.exists()) {
      await file.delete();
    }

    final index = await loadIndex();
    index.removeWhere((e) => e.id == id);
    await _writeIndex(dir, index);
  }

  /// Update only the report text for an existing entry.
  /// Sets `updatedAt` to now.
  Future<void> updateReport(String id, String report) async {
    final entry = await loadEntry(id);
    final updated = entry.copyWith(
      report: report,
      updatedAt: DateTime.now(),
    );
    await saveEntry(updated);
  }

  /// Delete all recordings (for testing / settings).
  Future<void> deleteAll() async {
    final dir = await _getRecordingsDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }

  // ---------------------------------------------------------------------------
  // UUID generation (simple v4 without external dependency)
  // ---------------------------------------------------------------------------

  static String generateId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    // Set version 4
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    // Set variant 1
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}

class RecordingNotFoundException implements Exception {
  final String id;
  const RecordingNotFoundException(this.id);

  @override
  String toString() => 'RecordingNotFoundException: $id';
}
