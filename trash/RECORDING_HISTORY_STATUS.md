# Recording History — Implementation Status

## Completed (Phases 1, 2, 5 — Session A)

### Phase 1: Data Model + Storage Layer ✅

**Files created:**
- `mobile/lib/models/recording_entry.dart` — `RecordingEntry` (full data) and `RecordingIndexEntry` (lightweight list metadata) models with JSON round-trip serialization, `copyWith`, `fromEntry` factory.
- `mobile/lib/services/recording_storage_service.dart` — File-per-entry JSON storage in app documents directory. Index file `_index.json` for fast list loading. Atomic writes (temp + rename). Auto-rebuild on index corruption. Built-in UUID v4 generation. API: `loadIndex()`, `loadEntry(id)`, `saveEntry(entry)`, `deleteEntry(id)`, `updateReport(id, report)`, `deleteAll()`. Constructor accepts optional `baseDirOverride` for testing.
- `mobile/test/services/recording_storage_service_test.dart` — 19 tests covering: model serialization round-trips, missing fields, preview truncation, CRUD operations, index ordering, overwrite, deleteAll, index corruption recovery, UUID format/uniqueness.

### Phase 2: State Management Integration ✅

**Files created:**
- `mobile/lib/providers/recording_history_provider.dart` — Three Riverpod providers:
  - `recordingStorageServiceProvider` — singleton `RecordingStorageService`
  - `recordingIndexProvider` — `StateNotifierProvider<RecordingIndexNotifier, AsyncValue<List<RecordingIndexEntry>>>` with `refresh()` and `deleteEntry(id)` methods
  - `loadedRecordingIdProvider` — `StateProvider<String?>` tracking which history entry is currently displayed (null = fresh session)

**Files modified:**
- `mobile/lib/providers/session_provider.dart`:
  - `SessionNotifier` constructor now takes `RecordingStorageService` and `Ref` (injected via Riverpod)
  - `_recordingStartTime: DateTime?` — set in `startRecording()`, used to compute duration
  - `_autoSaveRecording()` — called at end of `_stopRecordingAsync()`, creates `RecordingEntry` with UUID, saves to storage, refreshes index provider, sets `loadedRecordingIdProvider` to the new entry ID
  - `loadRecording(RecordingEntry entry)` — loads transcript + report into `SessionState`, sets `loadedRecordingIdProvider`, preserves `isModelLoaded`
  - `resetSession()` — now also clears `loadedRecordingIdProvider` and `_recordingStartTime`
  - `startRecording()` — now clears `loadedRecordingIdProvider` (new session)

**Tests updated:**
- `mobile/test/providers/session_provider_test.dart` — 11 tests total (6 original + 5 new): `loadRecording` sets transcript/report, sets loadedRecordingIdProvider, resetSession clears it, startRecording clears it, loadRecording preserves isModelLoaded.

### Phase 5: Demo Mode Removed ✅

**Files deleted:**
- `mobile/lib/widgets/demo_picker.dart`

**Files modified:**
- `mobile/lib/models/session_state.dart` — removed `demoPlaying` from `RecordingStatus` enum (now: `idle`, `recording`, `processing`)
- `mobile/lib/providers/session_provider.dart` — removed `playDemo()`, `cancelDemo()`, and `rootBundle` import
- `mobile/lib/screens/home_screen.dart` — removed `_showDemo` state, `_buildDemoSection()`, `DemoPicker` import. Placeholder comments mark where `RecordingHistoryList` goes (lines ~228 and ~254)
- `mobile/lib/widgets/recording_controls.dart` — removed `isDemoPlaying` variable and its use in progress indicator
- `mobile/lib/widgets/transcript_panel.dart` — removed `demoPlaying` from `isActive` check

---

## Remaining (Phases 3, 4, 6 — Session B)

### Phase 3: UI — Recording History List Widget

**Create:** `mobile/lib/widgets/recording_history_list.dart`

This is a `ConsumerWidget` that reads `recordingIndexProvider` and `loadedRecordingIdProvider`. It replaces the placeholder comments in `home_screen.dart`.

Requirements:
1. **Collapsible section** with header "📋 Historie nahrávek" and expand/collapse toggle
2. **List items** — each `Card` shows:
   - Date/time formatted as `dd.M.yyyy HH:mm` (Czech locale)
   - Visit type badge (Výchozí / Vstupní / Kontrolní)
   - Transcript preview (first ~80 chars, from `RecordingIndexEntry.preview`)
   - Word count + duration formatted as "245 slov · 8 min"
   - Delete icon button (🗑)
3. **Tap to load** — calls `recordingStorageServiceProvider.loadEntry(id)` then `sessionProvider.notifier.loadRecording(entry)`. If current session has unsaved data (transcript or report non-empty AND `loadedRecordingIdProvider` is null), show confirmation dialog first.
4. **Delete** — delete icon triggers confirmation dialog ("Opravdu smazat nahrávku?"), then calls `recordingIndexProvider.notifier.deleteEntry(id)`. If the deleted entry was currently loaded, also call `resetSession()`.
5. **Highlight** — currently loaded entry (matching `loadedRecordingIdProvider`) gets `primaryContainer` background color
6. **Empty state** — when index is empty, show centered text "Zatím žádné nahrávky."
7. **Loading state** — show `CircularProgressIndicator` while index loads
8. **Error state** — show error message with retry button

**Integrate into HomeScreen:**
- Replace `// Recording history list will be added in Session B (Phases 3-6)` comments in both `_buildNarrowLayout` and `_buildWideLayout` with:
  ```dart
  const SizedBox(height: 12),
  const RecordingHistoryList(),
  ```
- Add import for the new widget

### Phase 4: UI — Report Panel Save Button

**Modify:** `mobile/lib/widgets/report_panel.dart`

Requirements:
1. Read `loadedRecordingIdProvider` — when non-null and report text in controller differs from `session.report`, show "Uložit změny" (`OutlinedButton.icon` with 💾 icon)
2. On press: call `recordingStorageServiceProvider.updateReport(loadedId, controllerText)`, refresh index, show snackbar "Změny uloženy"
3. Track edit state by comparing `_controller.text` against `session.report` — use a `ValueListenableBuilder` on the controller or a simple `setState` listener
4. Button appears below the report text field, above the existing disclaimer text

**Key providers to import:**
- `recording_history_provider.dart` → `loadedRecordingIdProvider`, `recordingStorageServiceProvider`, `recordingIndexProvider`

### Phase 6: Testing & Polish

1. **Widget test** for `RecordingHistoryList` — mock the providers, verify: empty state renders, items render with correct data, tap loads recording, delete shows dialog, highlight works
2. **Widget test** for save button in `ReportPanel` — verify button appears only when editing a loaded recording, saves on press
3. **Integration test** — full flow: the app starts → no history → record → stop → entry appears in history → tap entry → transcript+report display → edit report → save → verify persisted
4. Verify `flutter analyze` passes with 0 errors
5. Verify all existing + new tests pass

---

## Key Provider & Service Reference

| Provider | Type | Purpose |
|----------|------|---------|
| `sessionProvider` | `StateNotifierProvider<SessionNotifier, SessionState>` | Current session state (transcript, report, status) |
| `recordingStorageServiceProvider` | `Provider<RecordingStorageService>` | Storage service singleton |
| `recordingIndexProvider` | `StateNotifierProvider<..., AsyncValue<List<RecordingIndexEntry>>>` | Index of all saved recordings |
| `loadedRecordingIdProvider` | `StateProvider<String?>` | ID of currently loaded history entry (null = fresh) |

## Key Methods on SessionNotifier

| Method | What it does |
|--------|-------------|
| `loadRecording(RecordingEntry)` | Loads a history entry into the current session |
| `resetSession()` | Clears session + loaded recording ID |
| `startRecording()` | Starts new recording, clears loaded recording ID |

## All UI Strings (Czech)

- Header: "📋 Historie nahrávek"
- Empty: "Zatím žádné nahrávky."
- Delete confirm title: "Smazat nahrávku?"
- Delete confirm body: "Opravdu chcete smazat tuto nahrávku? Tuto akci nelze vrátit."
- Delete confirm yes: "Smazat"
- Delete confirm no: "Zrušit"
- Load confirm title: "Neuložená data"
- Load confirm body: "Máte neuložená data. Chcete je zahodit a načíst vybranou nahrávku?"
- Load confirm yes: "Zahodit a načíst"
- Load confirm no: "Zrušit"
- Save button: "Uložit změny"
- Save snackbar: "Změny uloženy"
- Duration format: "{wordCount} slov · {minutes} min"
- Visit type labels: Výchozí / Vstupní / Kontrolní
