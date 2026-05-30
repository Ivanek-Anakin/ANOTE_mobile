# ANOTE Mobile — Implementation Plan

> **Instructions for the AI agent:** This document defines the phased
> implementation plan for the ANOTE Mobile application. The full technical
> specification is in `MOBILE_TECHNICAL_SPEC.md` — refer to it for all
> architectural details, data flows, algorithms, and configuration values.
>
> **Implement one phase at a time.** Each phase produces runnable, testable
> output. Do not skip ahead. Do not build files listed in later phases.
> After completing a phase, stop and report what was built and how to verify it.

---

## Phase 1 — Backend API Proxy

**Goal:** A deployable FastAPI backend that accepts a text transcript and
returns a structured Czech medical report via Azure OpenAI.

### Files to create

```
├── README.md
├── backend/
│   ├── main.py
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── .env.example
│   └── tests/
│       ├── __init__.py
│       └── test_report_endpoint.py
└── mobile/
    └── .gitkeep
```

### backend/main.py

Implement exactly as specified in `MOBILE_TECHNICAL_SPEC.md` Section 5.2.

Requirements:
- Use `AzureOpenAI` client from the `openai` package (NOT the plain `OpenAI` client)
- Read config from environment variables: `AZURE_OPENAI_KEY`, `AZURE_OPENAI_ENDPOINT`,
  `AZURE_OPENAI_DEPLOYMENT`, `APP_API_TOKEN`
- Bearer token authentication: every request must include `Authorization: Bearer <token>`.
  Compare against `APP_API_TOKEN` env var. Return 401 if missing or invalid.
- `GET /health` → `{"status": "ok"}` (no auth required)
- `POST /report` → accepts JSON `{"transcript": "...", "language": "cs"}`
  - Use `ReportRequest` Pydantic model with `transcript: str` and `language: str = "cs"`
  - If transcript is empty or whitespace-only, return 400
  - Build the system prompt with today's date injected (see Section 5.2 for the exact
    Czech prompt text — copy it verbatim, all 7 sections and all rules)
  - Call `client.chat.completions.create()` with `temperature=0.3`, `max_tokens=2000`
  - Return `{"report": "<response text>"}`
  - On Azure OpenAI errors, return 502 with `{"detail": "Azure OpenAI error: <message>"}`
- **GDPR:** Do NOT log request bodies, transcript content, or report content anywhere.
  Only log metadata (request received, status codes, timing).
- All functions must have type hints and docstrings.

### backend/requirements.txt

```
fastapi==0.115.0
uvicorn[standard]==0.30.0
openai==1.50.0
python-dotenv==1.0.1
pydantic==2.9.0
httpx==0.27.0
pytest==8.3.0
pytest-asyncio==0.24.0
```

### backend/Dockerfile

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### backend/.env.example

```
AZURE_OPENAI_KEY=your-azure-openai-key
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com
AZURE_OPENAI_DEPLOYMENT=gpt-4o-mini
APP_API_TOKEN=your-secret-bearer-token
```

### backend/tests/test_report_endpoint.py

Write tests using `pytest` + `fastapi.testclient.TestClient`. Mock the `AzureOpenAI`
client so tests run without real credentials.

Required test cases:
1. `POST /report` with valid transcript + valid bearer token → 200, response contains
   `"report"` key with non-empty string value
2. `POST /report` with empty transcript → 400
3. `POST /report` with whitespace-only transcript → 400
4. `POST /report` without `Authorization` header → 401 or 422
5. `POST /report` with wrong bearer token → 401
6. `GET /health` → 200, `{"status": "ok"}`
7. `POST /report` when Azure OpenAI raises an exception → 502

Mock setup: patch the `AzureOpenAI` client's `chat.completions.create` method to return
a mock response with a `.choices[0].message.content` string. Use `unittest.mock.patch`.

### README.md

Write a project README covering:
- Project name and one-line description
- Architecture diagram (text, copy from spec Section 2)
- Repository structure (current structure with Phase 1 files + mobile/ placeholder)
- Backend local development: `cd backend && pip install -r requirements.txt`,
  `cp .env.example .env`, fill in values, `uvicorn main:app --reload --port 8000`
- Backend testing: `cd backend && pytest tests/ -v`
- Backend deployment: the `az containerapp up` command from spec Section 12.2
- Note: "Mobile app will be implemented in Phase 2-4"

### Verification checklist (complete all before moving to Phase 2)

- [ ] `cd backend && pytest tests/ -v` — all tests pass
- [ ] `docker build -t anote-api ./backend` — builds successfully
- [ ] `uvicorn main:app --port 8000` starts without errors (with .env configured)
- [ ] `curl http://localhost:8000/health` → `{"status":"ok"}`
- [ ] `curl -X POST http://localhost:8000/report -H "Authorization: Bearer wrong" -H "Content-Type: application/json" -d '{"transcript":"test"}'` → 401

---

## Phase 2 — Flutter Project, UI Shell, and ReportService

**Goal:** A Flutter app that builds and runs on iOS/Android, shows the full
UI (report panel, transcript panel, recording controls, settings, themes),
and can call the Phase 1 backend to generate reports from manually entered text.

**Prerequisite:** Phase 1 is complete and verified.

### Files to create

```
mobile/
├── pubspec.yaml
├── lib/
│   ├── main.dart
│   ├── config/
│   │   └── constants.dart
│   ├── models/
│   │   └── session_state.dart
│   ├── services/
│   │   └── report_service.dart
│   ├── providers/
│   │   └── session_provider.dart
│   ├── screens/
│   │   ├── home_screen.dart
│   │   └── settings_screen.dart
│   └── widgets/
│       ├── report_panel.dart
│       ├── transcript_panel.dart
│       ├── recording_controls.dart
│       └── demo_picker.dart
├── assets/
│   └── demo_scenarios/
│       ├── cardiac_emergency.txt
│       ├── cz_detska_prohlidka.txt
│       ├── cz_kardialni_nahoda.txt
│       ├── cz_otrava_jidlem.txt
│       ├── cz_respiracni_infekce.txt
│       ├── food_poisoning.txt
│       ├── pediatric_checkup.txt
│       └── respiratory_infection.txt
├── android/
│   └── app/src/main/AndroidManifest.xml   (modify for permissions)
├── ios/
│   └── Runner/Info.plist                   (modify for permissions)
└── test/
    ├── services/
    │   └── report_service_test.dart
    └── providers/
        └── session_provider_test.dart
```

### pubspec.yaml

```yaml
name: anote_mobile
description: ANOTE — Medical report generation from voice

environment:
  sdk: '>=3.2.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^2.4.0
  dio: ^5.4.0
  flutter_secure_storage: ^9.0.0
  path_provider: ^2.1.0
  permission_handler: ^11.0.0
  shared_preferences: ^2.2.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0
  mockito: ^5.4.0
  build_runner: ^2.4.0

flutter:
  uses-material-design: true
  assets:
    - assets/demo_scenarios/
```

**Note:** Do NOT add `whisper_flutter_plus` or `audio_streamer` yet. Those are Phase 3.

### lib/config/constants.dart

```dart
class AppConstants {
  static const String defaultBackendUrl = 'https://anote-api.westeurope.azurecontainerapps.io';
  static const Duration reportGenerationInterval = Duration(seconds: 15);
  static const Duration pollInterval = Duration(milliseconds: 500);
  static const String secureStorageKeyToken = 'api_bearer_token';
  static const String secureStorageKeyUrl = 'backend_url';
}
```

### lib/models/session_state.dart

As specified in `MOBILE_TECHNICAL_SPEC.md` Section 4.6:
- `RecordingStatus` enum: `idle`, `recording`, `processing`, `demoPlaying`
- `SessionState` immutable class with: `status`, `transcript`, `report`,
  `errorMessage` (nullable), `isModelLoaded` (bool, default false)
- Implement `copyWith` method for immutable state updates

### lib/services/report_service.dart

As specified in `MOBILE_TECHNICAL_SPEC.md` Section 4.4:
- Dio HTTP client
- Read backend URL and bearer token from `FlutterSecureStorage`
- `Future<String> generateReport(String transcript)` — POST to `/report`
- `Future<bool> isBackendReachable()` — GET `/health`, return true/false
- Handle errors: throw typed exceptions for 401, 400, 502, network errors

### lib/providers/session_provider.dart

StateNotifier<SessionState> using Riverpod:
- `startRecording()` — for now, just set status to `recording` (audio comes in Phase 3)
- `stopRecording()` — set status to `idle`
- `resetSession()` — clear transcript, report, error; set status to `idle`
- `generateReportFromText(String transcript)` — call ReportService, update
  state.report. This allows testing the backend integration from the UI by
  typing/pasting a transcript manually.
- `playDemo(String scenarioId)` — stub, just set status to `demoPlaying` for now
- `cancelDemo()` — set status to `idle`

### lib/screens/home_screen.dart

Main screen layout as specified in `MOBILE_TECHNICAL_SPEC.md` Section 9.1:
- App bar with "🩺 ANOTE" title, settings gear icon, theme toggle button
- Status pill below app bar showing current status with correct colors and
  pulse animation (see Section 9.2)
- **Report panel** — large scrollable area with editable text field. Placeholder
  text: "Začněte nahrávat pro automatické generování lékařské zprávy..."
- **Transcript panel** — collapsible card below report. Shows transcript text.
  Hidden when status is `idle` and transcript is empty.
- **Recording controls** — Start/Stop/Clear buttons in a row. Start and Stop
  are primary buttons (accent color). Clear is a danger outline button.
  Button enabled/disabled states must match `RecordingStatus`.
- **Demo toggle** — dashed border button "🎬 Demo / Prezentační režim" that
  expands the demo picker below it
- **Temporary "Generate" button** — since audio isn't wired yet, add a temporary
  text input + "Generovat zprávu" button that calls `generateReportFromText()`.
  This will be removed in Phase 3 when audio recording is connected.
  Label it clearly as "(dočasné — pro testování)" so it's obvious it's temporary.

**Responsive layout:**
- Portrait: single column (report → transcript → controls)
- Landscape / width > 900px: two columns (report 2/3, transcript 1/3)
  Use `LayoutBuilder` or `MediaQuery`

### lib/screens/settings_screen.dart

Settings page with:
- Text field for backend URL (pre-filled with default, saved to secure storage)
- Text field for API bearer token (obscured, saved to secure storage)
- "Test connection" button that calls `isBackendReachable()` and shows result
- Theme selector (Light / Dark / System)
- App version info

All settings persist via `FlutterSecureStorage` (token, URL) or
`SharedPreferences` (theme).

### lib/widgets/

Implement each widget as a separate file:
- **report_panel.dart** — Card with "📋 Lékařská zpráva" header, editable
  TextField (multiline, scrollable), helper text below
- **transcript_panel.dart** — Collapsible card with "🎤 Přepis řeči" header,
  status badge ("Probíhá..." / "Dokončeno"), read-only text area
- **recording_controls.dart** — Row of buttons (Start/Stop/Clear) that read
  state from Riverpod provider and call provider methods
- **demo_picker.dart** — Lists available demo scenarios loaded from assets.
  Each scenario shown as a tappable card with name, preview, word count.
  "▶ Spustit simulaci" button at bottom (disabled until scenario selected).
  Scenario metadata: parse filename into display name using this mapping:
  ```
  cz_kardialni_nahoda → 🇨🇿 Kardiální nehoda
  cz_respiracni_infekce → 🇨🇿 Respirační infekce
  cz_detska_prohlidka → 🇨🇿 Dětská prohlídka
  cz_otrava_jidlem → 🇨🇿 Otrava jídlem
  cardiac_emergency → Cardiac Emergency
  food_poisoning → Food Poisoning
  pediatric_checkup → Pediatric Checkup
  respiratory_infection → Respiratory Infection
  ```

### lib/main.dart

- `ProviderScope` wrapping the app
- `MaterialApp` with light and dark theme definitions using the color tokens
  from `MOBILE_TECHNICAL_SPEC.md` Section 9.1
- Theme mode from `SharedPreferences` (light/dark/system)
- Home route → `HomeScreen`
- Settings route → `SettingsScreen`

### Theme colors

Copy exactly from `MOBILE_TECHNICAL_SPEC.md` Section 9.1:

Light mode:
- bg: `#F1F5F9`, card: `#FFFFFF`, border: `#CBD5E1`
- text: `#1E293B`, accent: `#0891B2`, danger: `#DC2626`, success: `#059669`

Dark mode:
- bg: `#0F172A`, card: `#1E293B`, border: `#334155`
- text: `#F1F5F9`, accent: `#06B6D4`, danger: `#EF4444`, success: `#10B981`

### Platform permissions

**Android** — add to `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
```

**iOS** — add to `ios/Runner/Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>ANOTE potřebuje přístup k mikrofonu pro nahrávání lékařských konzultací.</string>
```

### Demo scenario files

Copy the following demo scenario text files into `mobile/assets/demo_scenarios/`.
The content of each file is plain text — a medical consultation transcript.
Use these exact contents:

(The files already exist in the repository root under `demo_scenarios/` if available.
Otherwise create placeholder files with ~3 lines of representative text each, clearly
marked as placeholders.)

### Tests

**test/services/report_service_test.dart:**
- Test `generateReport()` with mocked Dio returning 200 + report body
- Test `generateReport()` with mocked Dio returning 401 → throws auth error
- Test `generateReport()` with mocked Dio returning 502 → throws server error
- Test `isBackendReachable()` with mocked Dio returning 200 → true
- Test `isBackendReachable()` with mocked Dio throwing → false

**test/providers/session_provider_test.dart:**
- Test initial state is `RecordingStatus.idle` with empty transcript/report
- Test `startRecording()` sets status to `recording`
- Test `stopRecording()` sets status to `idle`
- Test `resetSession()` clears all fields
- Test `generateReportFromText()` updates `state.report` (mock ReportService)

### Verification checklist

- [ ] `cd mobile && flutter pub get` — no errors
- [ ] `cd mobile && flutter analyze` — no errors or warnings
- [ ] `cd mobile && flutter test` — all tests pass
- [ ] `cd mobile && flutter run` — app launches on emulator/device
- [ ] UI shows report panel, transcript panel, controls, status pill
- [ ] Theme toggle switches between light and dark mode
- [ ] Settings screen saves and loads backend URL and token
- [ ] Temporary "Generate" button sends text to backend and displays report
- [ ] Demo picker lists all 8 scenarios with correct names

### What NOT to do in Phase 2

- Do NOT add `whisper_flutter_plus` or `audio_streamer` dependencies
- Do NOT implement AudioService or WhisperService
- Do NOT implement real audio recording (start/stop buttons change state only)
- Do NOT implement demo playback animation (just UI selection for now)
- Do NOT modify any files in `backend/`

---

## Phase 3 — On-Device Audio Capture and Whisper Transcription

**Goal:** The app records audio from the microphone, transcribes it to Czech
text on-device using Whisper.cpp, and generates reports automatically — the
full recording pipeline works end-to-end.

**Prerequisite:** Phase 2 is complete and verified.

### Files to create or modify

```
mobile/lib/services/
├── audio_service.dart        (NEW)
└── whisper_service.dart      (NEW)
mobile/lib/utils/
└── wav_encoder.dart          (NEW)
mobile/lib/providers/
└── session_provider.dart     (MODIFY — wire real audio+whisper pipeline)
mobile/assets/models/
└── .gitkeep                  (NEW — placeholder for Whisper model file)
mobile/test/services/
├── whisper_service_test.dart (NEW)
└── wav_encoder_test.dart     (NEW)
```

### Dependencies to add to pubspec.yaml

```yaml
dependencies:
  whisper_flutter_plus: ^1.0.0
  audio_streamer: ^4.0.0
```

### lib/services/audio_service.dart

As specified in `MOBILE_TECHNICAL_SPEC.md` Section 4.2.

Implementation:
- Use `audio_streamer` package (NOT the `record` package — `audio_streamer`
  provides real-time PCM sample streams needed for the sliding window approach)
- Configure: sample rate 16000 Hz, mono channel
- Expose `Stream<List<double>>` of audio samples
- `start()` — request mic permission via `permission_handler`, then start streaming
- `stop()` — stop the audio stream
- `dispose()` — clean up resources
- If mic permission is denied, throw a typed `MicPermissionDenied` exception

### lib/services/whisper_service.dart

As specified in `MOBILE_TECHNICAL_SPEC.md` Sections 4.3 and 8.

Implementation:

**Model loading:**
- On `loadModel()`, check if `ggml-small.bin` exists in app's documents directory
- If not, copy from Flutter assets to documents directory
- Initialize Whisper.cpp runtime with the model file path
- Set `isModelLoaded = true` in state via callback

**Audio buffering:**
- Maintain `List<double> _audioBuffer` — all captured audio since recording started
- Maintain `int _lastBoundary` — sample index where last transcription ended
- Maintain `String _previousTailText` — last ~20 words of previous transcription

**Live transcription (called during recording):**
- When `_audioBuffer.length - _lastBoundary >= 5 * 16000` (5 seconds of new audio):
  1. Calculate `overlapStart = max(0, _lastBoundary - 2 * 16000)` (2 second overlap)
  2. Extract window: `_audioBuffer.sublist(overlapStart)`
  3. Encode window to WAV bytes using `WavEncoder`
  4. Call `whisper.transcribe()` with parameters:
     - `language: 'cs'` (FORCE Czech — do not auto-detect)
     - `translate: false`
     - `noSpeechThreshold: 0.6`
     - `singleSegment: false`
  5. Deduplicate overlap: compare `_previousTailText` with head of new text,
     remove duplicated words (see Section 8.4 algorithm)
  6. Append deduplicated text to running transcript
  7. Update `_previousTailText` to last ~20 words of new transcription
  8. Update `_lastBoundary = _audioBuffer.length`
  9. Emit updated transcript via `_transcriptController.add(fullTranscript)`

**Full-pass transcription (called on recording stop):**
- `Future<String> transcribeFull()`:
  1. Encode entire `_audioBuffer` to WAV bytes
  2. Call `whisper.transcribe()` with same parameters
  3. Return full transcript text (this replaces the incremental version)

**Exposed interface:**
- `Future<void> loadModel()` — load Whisper model
- `void feedAudio(List<double> samples)` — accept samples from AudioService
- `Stream<String> get transcriptStream` — live transcript updates
- `Future<String> transcribeFull()` — final high-quality full pass
- `void reset()` — clear buffers and state
- `void dispose()` — release Whisper runtime

### lib/utils/wav_encoder.dart

Converts raw PCM float32 samples to WAV byte format for Whisper input.

```dart
class WavEncoder {
  /// Encode float32 PCM samples to WAV bytes.
  /// sampleRate: 16000, channels: 1, bitsPerSample: 16
  static Uint8List encode(List<double> samples, {int sampleRate = 16000});
}
```

Implementation:
- Convert float32 [-1.0, 1.0] to int16 [-32767, 32767]
- Write RIFF/WAV header (44 bytes): chunk ID, file size, format,
  subchunk1 (PCM format, 1 channel, 16000 Hz, 16 bit), subchunk2 (data)
- Append PCM data bytes (little-endian int16)
- Return `Uint8List`

### Modify lib/providers/session_provider.dart

Wire the full pipeline:

**`startRecording()`:**
1. Ensure Whisper model is loaded (call `loadModel()` if not)
2. Set status → `recording`
3. Clear previous transcript and report
4. Start AudioService → subscribe to audio stream
5. Pipe audio samples to WhisperService via `feedAudio()`
6. Subscribe to WhisperService `transcriptStream` → update state.transcript
7. Start a periodic timer (every ~15 seconds): if transcript is non-empty,
   call ReportService.generateReport() → update state.report
8. Catch and store errors in state.errorMessage

**`stopRecording()`:**
1. Set status → `processing`
2. Stop AudioService
3. Cancel periodic report timer
4. Call WhisperService `transcribeFull()` → update state.transcript with
   the full-pass (higher quality) version
5. Call ReportService.generateReport() with final transcript → update state.report
6. Set status → `idle`
7. On error: set status → `idle`, store error

**`resetSession()`:**
- Stop audio if running, cancel timers, call whisper.reset()
- Clear all state fields, set status → `idle`

**Remove** the temporary "Generate from text" button logic added in Phase 2
(the report now generates automatically during and after recording).

### Whisper model file

The Whisper model file (`ggml-small.bin`, ~244 MB) is too large for git.

Add to `.gitignore`:
```
mobile/assets/models/*.bin
```

Add to README instructions:
```
# Download the Whisper small model
cd mobile/assets/models/
curl -L -o ggml-small.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

Add the directory to pubspec.yaml assets:
```yaml
flutter:
  assets:
    - assets/demo_scenarios/
    - assets/models/
```

### Tests

**test/utils/wav_encoder_test.dart:**
- Test encoding 16000 samples (1 second) produces valid WAV file
- Output starts with `RIFF` header bytes
- Output length = 44 (header) + 16000 * 2 (int16 samples) = 32044 bytes
- Test encoding empty list produces valid (empty) WAV header
- Test values are clamped correctly (samples > 1.0 or < -1.0)

**test/services/whisper_service_test.dart:**
- Test overlap deduplication:
  - Previous tail: "bolest na hrudi trvající dva"
  - New text: "trvající dva dny s vyzařováním do levé ruky"
  - Expected deduplicated: "dny s vyzařováním do levé ruky"
- Test sliding window triggers after 5 seconds of audio (80000 samples at 16kHz)
- Test `reset()` clears all buffers
- Mock the Whisper.cpp package so tests run without the model file

### Verification checklist

- [ ] `flutter pub get` succeeds with new dependencies
- [ ] `flutter analyze` — no errors
- [ ] `flutter test` — all tests pass (including new and existing)
- [ ] Run app on physical device (emulator won't have real mic)
- [ ] Tap "Nahrávat" → mic permission requested
- [ ] Speak in Czech → transcript appears and updates live in transcript panel
- [ ] Report panel updates every ~15 seconds during recording
- [ ] Tap "Zastavit" → final high-quality transcript + final report generated
- [ ] "Vymazat vše" clears transcript and report

### What NOT to do in Phase 3

- Do NOT implement DemoService playback logic
- Do NOT implement offline queueing
- Do NOT modify backend/ files
- Do NOT change the UI layout (only wire existing widgets to real data)

---

## Phase 4 — Demo Mode, Offline Handling, and Polish

**Goal:** Complete feature parity — demo scenario playback works, app handles
offline gracefully, all error states have proper UI, and the app is release-ready.

**Prerequisite:** Phase 3 is complete and verified.

### Files to create or modify

```
mobile/lib/services/
└── demo_service.dart          (NEW)
mobile/lib/providers/
└── session_provider.dart      (MODIFY — wire demo service + offline logic)
mobile/lib/widgets/
├── demo_picker.dart           (MODIFY — wire to DemoService)
├── recording_controls.dart    (MODIFY — add offline indicator)
└── error_dialogs.dart         (NEW)
mobile/test/services/
└── demo_service_test.dart     (NEW)
```

### lib/services/demo_service.dart

As specified in `MOBILE_TECHNICAL_SPEC.md` Section 4.5.

Implementation:

**`listScenarios()`:**
- Read all `.txt` files from `assets/demo_scenarios/` via rootBundle
- For each file, parse metadata:
  - `id`: filename stem (e.g., `cz_otrava_jidlem`)
  - `name`: display name from the mapping (e.g., "🇨🇿 Otrava jídlem")
  - `preview`: first 120 characters of text
  - `wordCount`: total word count
- Return `List<DemoScenario>`

**`playScenario(String scenarioId)`:**
- Load the scenario text from assets
- Return a `Stream<DemoPlaybackEvent>` that emits events:
  - `DemoPlaybackEvent.word(String fullTextSoFar)` — emitted every ~100-150ms
    as each word is "typed" out
  - `DemoPlaybackEvent.reportReady(String report)` — emitted every ~20 words
    after ReportService returns a report for the partial transcript
  - `DemoPlaybackEvent.finished()` — emitted when all words are typed and
    final report is generated
- The stream must support cancellation: when the subscription is cancelled,
  stop typing and report generation immediately

**`cancel()`:**
- Cancel the current playback stream

### Wire DemoService into SessionNotifier

**`playDemo(String scenarioId)`:**
1. Set status → `demoPlaying`
2. Clear transcript and report
3. Show transcript panel
4. Subscribe to `DemoService.playScenario()` stream
5. On `word` events: update `state.transcript`
6. On `reportReady` events: update `state.report`
7. On `finished`: set status → `idle`, update transcript status to "Dokončeno"
8. On error: set status → `idle`, store error

**`cancelDemo()`:**
- Call `DemoService.cancel()`
- Set status → `idle`

### Modify demo_picker.dart

Wire the demo picker widget to use DemoService:
- On init, call `DemoService.listScenarios()` to populate the list
- On "▶ Spustit simulaci" tap, call `SessionNotifier.playDemo(selectedId)`
- Disable the button during `demoPlaying` status
- Add a "⬛ Zastavit" button visible during demo playback that calls `cancelDemo()`

### Offline handling

Add connectivity awareness:

- Use Dio interceptors to detect network failures
- During recording: if ReportService call fails due to network error,
  do NOT show an error dialog (don't interrupt the doctor). Instead:
  - Show a subtle "📡 Offline" chip next to the status pill
  - Continue recording and transcribing normally (Whisper is on-device)
  - Queue the report generation request
- When recording stops and network is available: retry report generation
- If network is still unavailable on stop: show the transcript with a
  "Generovat zprávu" retry button. Store the transcript in state so the
  doctor can retry later without re-recording.

### Error dialogs (lib/widgets/error_dialogs.dart)

Create reusable error dialog widgets for each scenario in
`MOBILE_TECHNICAL_SPEC.md` Section 10:

- **Mic permission denied:** AlertDialog explaining why mic access is needed.
  "Otevřít nastavení" button → `openAppSettings()` from permission_handler.
  "Zrušit" button → dismiss.
- **Whisper model failed to load:** Full-screen error with retry button.
  "Model se nepodařilo načíst. Zkuste to znovu." + "Znovu" button.
- **Backend auth error (401):** Snackbar "Neplatný API token. Zkontrolujte nastavení."
  with "Nastavení" action → navigate to SettingsScreen.
- **Backend server error (502):** AlertDialog "Generování zprávy selhalo."
  with "Zkusit znovu" retry button.
- **Audio stream error:** Snackbar "Chyba mikrofonu. Nahrávání zastaveno."
  Preserve any transcript gathered so far.

### Tests

**test/services/demo_service_test.dart:**
- Test `listScenarios()` returns 8 scenarios with correct IDs and names
- Test `playScenario()` emits word events matching the scenario word count
- Test `playScenario()` emits at least 1 `reportReady` event
- Test `cancel()` stops emission
- Mock ReportService for report generation during playback

### Verification checklist

- [ ] `flutter analyze` — no errors
- [ ] `flutter test` — all tests pass
- [ ] Demo mode: select "🇨🇿 Otrava jídlem" → words type out in transcript panel
      with blinking cursor → report updates periodically → finishes with full report
- [ ] Demo mode: tap "⬛ Zastavit" mid-demo → playback stops immediately
- [ ] Turn off WiFi → start recording → speak → transcript appears (Whisper works)
      → report shows "📡 Offline" indicator → stop recording → reconnect WiFi →
      tap "Generovat zprávu" → report generates
- [ ] Deny mic permission → dialog appears with "Otevřít nastavení" button
- [ ] All 8 demo scenarios play correctly with correct display names
- [ ] Light/dark theme looks correct on all screens
- [ ] App works on both iOS and Android

### What NOT to do in Phase 4

- Do NOT add analytics, crash reporting, or any third-party data collection
- Do NOT persist patient data to disk
- Do NOT modify backend/ files

---

## Summary

| Phase | Delivers | Key verification |
|-------|----------|-----------------|
| **1** | Backend API proxy (Python/FastAPI) | `pytest` passes, Docker builds, curl test works |
| **2** | Flutter UI shell + ReportService | App builds, UI renders, manual report generation works |
| **3** | Audio recording + on-device Whisper | Speak Czech → live transcript → auto-generated report |
| **4** | Demo mode + offline + error handling | Demo plays, offline works, all error states handled |

**Always attach `MOBILE_TECHNICAL_SPEC.md` alongside this file when prompting for any phase.**
