# Recording History — Technical Specification & Implementation Plan

## 1. Overview

Replace the debug Demo/Prezentační režim section at the bottom of the home screen with a **Recording History** list that persists completed recordings on-device. Each entry stores transcript, medical report, and metadata. Users can tap an entry to load it into the main panels, delete entries, and save edits back to storage.

## 2. Requirements

### 2.1 Functional Requirements

| ID | Requirement |
|----|-------------|
| F1 | **Auto-save on stop** — When a recording session completes (status transitions from `processing` → `idle` with non-empty transcript), the session is automatically saved to on-device storage. |
| F2 | **History list** — A scrollable list of saved recordings replaces the DemoPicker widget area. Each item shows: title (date/time), duration metadata, word count, visit type badge, and a truncated transcript preview. |
| F3 | **Load recording** — Tapping a history item loads its transcript and report into the existing `TranscriptPanel` and `ReportPanel`. The current unsaved session (if any) is cleared first (with confirmation if data exists). |
| F4 | **Delete recording** — Swipe-to-dismiss or a delete icon button on each item. Confirmation dialog before deletion. |
| F5 | **Save edits** — When viewing a loaded recording and editing the report in `ReportPanel`, a "Uložit změny" (Save changes) button appears. Pressing it persists edits back to storage. |
| F6 | **Remove demo mode** — Delete `DemoPicker` widget, remove demo section from `HomeScreen`, remove `playDemo()`/`cancelDemo()` from `SessionNotifier`, remove `demoPlaying` references where no longer needed. |
| F7 | **Empty state** — When no recordings exist, show a friendly message: "Zatím žádné nahrávky" (No recordings yet). |

### 2.2 Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NF1 | Storage must be lightweight — no audio files. Typical entry: ~2–50 KB (transcript + report text + metadata JSON). |
| NF2 | History list must load fast — target < 100ms for up to 500 entries. |
| NF3 | All UI strings remain in Czech, consistent with existing app language. |
| NF4 | Data stored in app-internal directory (not accessible to other apps). |

## 3. Architecture & Design

### 3.1 Data Model

New file: `lib/models/recording_entry.dart`

```dart
class RecordingEntry {
  final String id;           // UUID v4
  final DateTime createdAt;  // When recording was saved
  final String transcript;   // Full transcript text
  final String report;       // Generated/edited medical report
  final String visitType;    // "default" | "initial" | "followup"
  final int durationSeconds; // Recording duration in seconds
  final int wordCount;       // Word count of transcript
  final DateTime? updatedAt; // Last edit timestamp (null if never edited)

  // JSON serialization: toJson() / fromJson()
}
```

### 3.2 Storage Layer

New file: `lib/services/recording_storage_service.dart`

**Approach: JSON file-per-entry in app documents directory.**

Each recording is saved as `{app_docs}/recordings/{id}.json`. An index file `{app_docs}/recordings/_index.json` stores a lightweight list of `{id, createdAt, wordCount, visitType, previewText}` for fast list loading without reading every full entry.

```
recordings/
  _index.json           ← [{id, createdAt, wordCount, visitType, preview}, ...]
  abc123.json           ← full RecordingEntry JSON
  def456.json
```

**Why file-per-entry over SQLite:**
- No additional dependency needed (`path_provider` already in pubspec)
- Transcript/report are large text blobs — not benefiting from relational queries
- Simpler implementation, easier debugging (human-readable files)
- Index file gives O(1) list loading

**API surface:**

```dart
class RecordingStorageService {
  Future<List<RecordingIndexEntry>> loadIndex();        // Load list metadata
  Future<RecordingEntry> loadEntry(String id);          // Load full entry
  Future<void> saveEntry(RecordingEntry entry);         // Create or update
  Future<void> deleteEntry(String id);                  // Delete entry + update index
  Future<void> updateReport(String id, String report);  // Update only the report text
}
```

### 3.3 State Management (Riverpod)

New file: `lib/providers/recording_history_provider.dart`

```dart
// Index provider — lightweight list for the UI
final recordingIndexProvider = StateNotifierProvider<RecordingIndexNotifier, AsyncValue<List<RecordingIndexEntry>>>(...)

// Currently loaded historical recording (null = none loaded, fresh session)
final loadedRecordingIdProvider = StateProvider<String?>((ref) => null);
```

**Integration with existing `SessionNotifier`:**

- After `_stopRecordingAsync()` completes successfully with non-empty transcript, call `RecordingStorageService.saveEntry()` and refresh the index provider.
- New method: `loadRecording(RecordingEntry entry)` — sets transcript + report into `SessionState`, sets `loadedRecordingIdProvider`.
- Modify `resetSession()` to also clear `loadedRecordingIdProvider`.

### 3.4 UI Changes

#### 3.4.1 Remove DemoPicker

- Delete `lib/widgets/demo_picker.dart`
- Remove `_buildDemoSection()` from `HomeScreen`
- Remove `_showDemo` state variable
- Remove `playDemo()`, `cancelDemo()`, `demoPlaying` from `SessionNotifier` (and `RecordingStatus.demoPlaying` enum value)
- Remove demo scenario asset references (optional — keep assets for now if desired)

#### 3.4.2 New Widget: `RecordingHistoryList`

New file: `lib/widgets/recording_history_list.dart`

Replaces the demo section in `_buildNarrowLayout()` and `_buildWideLayout()`.

```
┌─────────────────────────────────────┐
│ 📋 Historie nahrávek          [▼/▲] │  ← Collapsible header
├─────────────────────────────────────┤
│ ┌─────────────────────────────────┐ │
│ │ 21.3.2026 14:30    Vstupní     │ │  ← Date + visit type badge
│ │ "Pacient přichází s bolestí..." │ │  ← Transcript preview (first ~80 chars)
│ │ 245 slov · 8 min          🗑️   │ │  ← Word count, duration, delete btn
│ └─────────────────────────────────┘ │
│ ┌─────────────────────────────────┐ │
│ │ 20.3.2026 09:15    Kontrolní   │ │
│ │ "Kontrolní prohlídka po..."     │ │
│ │ 180 slov · 5 min          🗑️   │ │
│ └─────────────────────────────────┘ │
│                                     │
│   Zatím žádné nahrávky.             │  ← Empty state (when list is empty)
└─────────────────────────────────────┘
```

**Item interactions:**
- **Tap** → Load recording into main panels (with confirmation dialog if current session has unsaved data)
- **Delete icon** → Confirmation dialog → delete from storage → refresh list
- Currently loaded item is visually highlighted (e.g., primary container color, similar to DemoPicker's selected state)

#### 3.4.3 Report Panel — Save Changes Button

When `loadedRecordingIdProvider` is non-null and the report text in the `TextEditingController` differs from the stored report, show:

```
┌──────────────────────────────────┐
│ [💾 Uložit změny]                │  ← OutlinedButton, appears below report
└──────────────────────────────────┘
```

On press: calls `RecordingStorageService.updateReport(id, editedText)`, updates index if needed, shows snackbar confirmation.

#### 3.4.4 HomeScreen Layout Updates

The `_buildNarrowLayout` changes:
```
ReportPanel          (unchanged — 55% screen height)
TranscriptPanel      (unchanged)
RecordingControls    (unchanged)
RecordingHistoryList (NEW — replaces _buildDemoSection)
```

The `_buildWideLayout` changes:
```
Left pane:  ReportPanel           (unchanged)
Right pane: TranscriptPanel       (unchanged)
            RecordingControls     (unchanged)
            RecordingHistoryList  (NEW — replaces _buildDemoSection)
```

### 3.5 Recording Duration Tracking

Currently the app does not track recording duration. We need a simple timer:

- In `SessionNotifier.startRecording()`: capture `_recordingStartTime = DateTime.now()`
- In `_stopRecordingAsync()`: compute `durationSeconds = DateTime.now().difference(_recordingStartTime).inSeconds`
- Pass to `RecordingEntry` when saving.

### 3.6 Data Flow Diagram

```
[User taps Stop]
       │
       ▼
SessionNotifier._stopRecordingAsync()
       │
       ├──► WhisperService.transcribeFull()  →  final transcript
       ├──► ReportService.generateReport()   →  final report
       │
       ▼
RecordingStorageService.saveEntry(
  RecordingEntry(id, createdAt, transcript, report, visitType, duration, wordCount)
)
       │
       ├──► Write {id}.json to disk
       ├──► Update _index.json
       │
       ▼
RecordingIndexNotifier.refresh()  →  UI list updates

[User taps history item]
       │
       ▼
RecordingStorageService.loadEntry(id)
       │
       ▼
SessionNotifier.loadRecording(entry)
       │
       ├──► state = state.copyWith(transcript: ..., report: ...)
       ├──► loadedRecordingIdProvider = id
       │
       ▼
UI updates: ReportPanel + TranscriptPanel show loaded data

[User edits report + taps "Uložit změny"]
       │
       ▼
RecordingStorageService.updateReport(id, newReport)
       │
       ├──► Re-write {id}.json with updated report + updatedAt
       │
       ▼
Snackbar: "Změny uloženy"
```

## 4. Implementation Plan

### Phase 1: Foundation (data model + storage layer)

| Step | Task | Files | Est. |
|------|------|-------|------|
| 1.1 | Create `RecordingEntry` model with JSON serialization | `lib/models/recording_entry.dart` | 30 min |
| 1.2 | Create `RecordingIndexEntry` lightweight model | `lib/models/recording_entry.dart` | 15 min |
| 1.3 | Implement `RecordingStorageService` (save, load, delete, updateReport, loadIndex) | `lib/services/recording_storage_service.dart` | 1.5 hr |
| 1.4 | Write unit tests for storage service | `test/services/recording_storage_service_test.dart` | 1 hr |

### Phase 2: State Management Integration

| Step | Task | Files | Est. |
|------|------|-------|------|
| 2.1 | Create `RecordingIndexNotifier` + `recordingIndexProvider` | `lib/providers/recording_history_provider.dart` | 45 min |
| 2.2 | Create `loadedRecordingIdProvider` | `lib/providers/recording_history_provider.dart` | 15 min |
| 2.3 | Add duration tracking (`_recordingStartTime`) to `SessionNotifier` | `lib/providers/session_provider.dart` | 15 min |
| 2.4 | Add auto-save logic at end of `_stopRecordingAsync()` | `lib/providers/session_provider.dart` | 30 min |
| 2.5 | Add `loadRecording()` method to `SessionNotifier` | `lib/providers/session_provider.dart` | 30 min |
| 2.6 | Modify `resetSession()` to clear loaded recording state | `lib/providers/session_provider.dart` | 10 min |
| 2.7 | Wire up `RecordingStorageService` as a Riverpod provider | `lib/providers/session_provider.dart` | 15 min |

### Phase 3: UI — Recording History List

| Step | Task | Files | Est. |
|------|------|-------|------|
| 3.1 | Create `RecordingHistoryList` widget with collapsible header | `lib/widgets/recording_history_list.dart` | 1.5 hr |
| 3.2 | Implement history item card (date, preview, badges, delete icon) | `lib/widgets/recording_history_list.dart` | 1 hr |
| 3.3 | Implement tap-to-load with unsaved data confirmation dialog | `lib/widgets/recording_history_list.dart` | 45 min |
| 3.4 | Implement swipe/delete with confirmation dialog | `lib/widgets/recording_history_list.dart` | 30 min |
| 3.5 | Implement empty state | `lib/widgets/recording_history_list.dart` | 15 min |
| 3.6 | Highlight currently loaded recording in list | `lib/widgets/recording_history_list.dart` | 15 min |

### Phase 4: UI — Report Panel Save Button

| Step | Task | Files | Est. |
|------|------|-------|------|
| 4.1 | Add "Uložit změny" button to `ReportPanel` (visible when editing a loaded recording) | `lib/widgets/report_panel.dart` | 45 min |
| 4.2 | Track edit state (compare controller text vs stored report) | `lib/widgets/report_panel.dart` | 30 min |
| 4.3 | Wire save button to `RecordingStorageService.updateReport()` | `lib/widgets/report_panel.dart` | 15 min |

### Phase 5: Remove Demo Mode

| Step | Task | Files | Est. |
|------|------|-------|------|
| 5.1 | Delete `lib/widgets/demo_picker.dart` | — | 5 min |
| 5.2 | Remove `_buildDemoSection()`, `_showDemo` from `HomeScreen` | `lib/screens/home_screen.dart` | 10 min |
| 5.3 | Replace demo section with `RecordingHistoryList` in both layouts | `lib/screens/home_screen.dart` | 15 min |
| 5.4 | Remove `playDemo()`, `cancelDemo()` from `SessionNotifier` | `lib/providers/session_provider.dart` | 10 min |
| 5.5 | Remove `RecordingStatus.demoPlaying` enum value and all references | `lib/models/session_state.dart`, all files referencing it | 30 min |

### Phase 6: Testing & Polish

| Step | Task | Files | Est. |
|------|------|-------|------|
| 6.1 | Unit tests for `RecordingEntry` serialization | `test/models/` | 30 min |
| 6.2 | Unit tests for `RecordingIndexNotifier` | `test/providers/` | 30 min |
| 6.3 | Widget test for `RecordingHistoryList` | `test/widgets/` | 1 hr |
| 6.4 | Integration test: record → auto-save → load from history → edit → save | `integration_test/` | 1 hr |
| 6.5 | Manual QA on device (Android) | — | 30 min |
| 6.6 | Edge cases: very long transcripts, 500+ entries scroll performance, empty states | — | 30 min |

**Total estimated effort: ~14 hours**

### Recommended Execution Order

```
Phase 1 → Phase 2 → Phase 5 (remove demo) → Phase 3 → Phase 4 → Phase 6
```

Removing demo mode (Phase 5) before building the new UI (Phase 3) gives a clean slate in `HomeScreen` to slot in the new widget.

## 5. Edge Cases & Risks

| Risk | Mitigation |
|------|-----------|
| Index file corruption (crash during write) | Write to temp file, then atomic rename. |
| User clears app data | Recordings are lost — acceptable for local-only storage. |
| Very long transcript/report (>100KB) | Unlikely in medical context. Preview is truncated to 80 chars. |
| Hundreds of recordings slow down list | Use `ListView.builder` (already lazy). Index file keeps list load O(1). Consider pagination if >500. |
| Concurrent write (unlikely in single-user app) | Sequential access enforced by async/await — no parallel writes. |
| Loaded recording deleted while viewing | Check existence on save; if deleted, treat as new save. |

## 6. Future Considerations (Out of Scope)

- **Search/filter** recordings by date, visit type, or content
- **Export** recordings as PDF or share via email
- **Cloud sync** to backup recordings across devices
- **Audio file storage** for re-transcription or playback
- **Pagination** for very large history lists
