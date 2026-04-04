import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recording_entry.dart';
import '../services/recording_storage_service.dart';

/// Provider for the storage service singleton.
final recordingStorageServiceProvider =
    Provider<RecordingStorageService>((ref) {
  return RecordingStorageService();
});

/// Provider for the recording index (lightweight list metadata).
///
/// Watches the notifier so the UI rebuilds when recordings are
/// added, deleted, or updated.
final recordingIndexProvider = StateNotifierProvider<RecordingIndexNotifier,
    AsyncValue<List<RecordingIndexEntry>>>((ref) {
  final storage = ref.watch(recordingStorageServiceProvider);
  return RecordingIndexNotifier(storage);
});

/// Tracks which recording from history is currently loaded in the session.
/// `null` means a fresh/new session (not loaded from history).
final loadedRecordingIdProvider = StateProvider<String?>((ref) => null);

/// Manages the recording index state.
class RecordingIndexNotifier
    extends StateNotifier<AsyncValue<List<RecordingIndexEntry>>> {
  final RecordingStorageService _storage;

  RecordingIndexNotifier(this._storage) : super(const AsyncValue.loading()) {
    refresh();
  }

  /// Reload the index from disk.
  Future<void> refresh() async {
    try {
      final index = await _storage.loadIndex();
      if (!mounted) return;
      state = AsyncValue.data(index);
    } catch (e, st) {
      if (!mounted) return;
      state = AsyncValue.error(e, st);
    }
  }

  /// Delete a recording and refresh the index.
  Future<void> deleteEntry(String id) async {
    await _storage.deleteEntry(id);
    await refresh();
  }
}
