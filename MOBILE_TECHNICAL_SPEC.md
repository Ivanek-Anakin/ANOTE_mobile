# ANOTE Mobile — Technical Specification

## 1. Product Overview

**Name:** ANOTE Mobile
**Goal:** Cross-platform mobile app enabling doctors and nurses to generate structured Czech medical visit reports from dictated speech — with on-device transcription and GDPR-compliant cloud report generation.

**Key Design Principles:**
- Patient audio never leaves the device
- Only anonymized text is sent to the cloud
- Works partially offline (transcription works without internet)
- Lightweight, fast, pay-as-you-go cloud costs (~$0.001/report)
- Single codebase for iOS and Android via Flutter

---

## 2. Architecture Overview

```
┌──────────────────── Mobile Device ────────────────────┐
│                                                        │
│  Microphone                                            │
│    ↓                                                   │
│  AudioService (audio_streamer — raw PCM chunks)        │
│    ↓                                                   │
│  WhisperService (whisper_flutter_plus — on-device)     │
│    ↓                                                   │
│  Czech text transcript (local state)                   │
│    ↓ (periodic, ~10-15s intervals + final on stop)     │
│  ReportService → HTTPS POST to backend                 │
│    ↓                                                   │
│  Structured Czech medical report displayed in UI       │
│                                                        │
└────────────────────────────────────────────────────────┘
              │
              │ HTTPS (text only, bearer token auth)
              ▼
┌──── Azure Container Apps (West Europe) ───────────────┐
│                                                        │
│  FastAPI proxy (Python)                                │
│  POST /report → Azure OpenAI GPT-4o-mini               │
│    → returns structured Czech medical report           │
│                                                        │
└────────────────────────────────────────────────────────┘
              │
              │ Azure internal network
              ▼
┌──── Azure OpenAI Service (West Europe) ───────────────┐
│                                                        │
│  GPT-4o-mini deployment                                │
│  - No data retention (abuse monitoring opt-out)        │
│  - No model training on customer data                  │
│  - GDPR compliant, data stays in EU                    │
│                                                        │
└────────────────────────────────────────────────────────┘
```

---

## 3. Repository Structure (Monorepo)

```
medicalbot/
├── mobile/                          # Flutter application
│   ├── lib/
│   │   ├── main.dart                # App entry point, MaterialApp, theme
│   │   ├── config/
│   │   │   └── constants.dart       # API URLs, model config, intervals
│   │   ├── models/
│   │   │   └── session_state.dart   # Recording state, transcript, report
│   │   ├── services/
│   │   │   ├── audio_service.dart   # Mic capture via audio_streamer
│   │   │   ├── whisper_service.dart # On-device Whisper.cpp transcription
│   │   │   ├── report_service.dart  # HTTP calls to backend /report
│   │   │   └── demo_service.dart    # Demo scenario playback
│   │   ├── providers/
│   │   │   └── session_provider.dart # Riverpod state management
│   │   ├── screens/
│   │   │   ├── home_screen.dart     # Main recording + report screen
│   │   │   └── settings_screen.dart # API config, model selection, theme
│   │   ├── widgets/
│   │   │   ├── report_panel.dart    # Formatted medical report display
│   │   │   ├── transcript_panel.dart # Live transcript side panel
│   │   │   ├── recording_controls.dart # Start/stop/reset buttons
│   │   │   └── demo_picker.dart     # Demo scenario selection
│   │   └── utils/
│   │       └── wav_encoder.dart     # PCM float32 → WAV byte encoding
│   ├── assets/
│   │   ├── models/
│   │   │   └── ggml-small.bin       # Whisper small model (~244 MB)
│   │   └── demo_scenarios/
│   │       ├── cardiac_emergency.txt
│   │       ├── cz_detska_prohlidka.txt
│   │       ├── cz_kardialni_nahoda.txt
│   │       ├── cz_otrava_jidlem.txt
│   │       ├── cz_respiracni_infekce.txt
│   │       ├── food_poisoning.txt
│   │       ├── pediatric_checkup.txt
│   │       └── respiratory_infection.txt
│   ├── android/
│   │   └── app/src/main/AndroidManifest.xml  # RECORD_AUDIO permission
│   ├── ios/
│   │   └── Runner/Info.plist                  # NSMicrophoneUsageDescription
│   ├── pubspec.yaml
│   └── test/
│       ├── services/
│       │   ├── audio_service_test.dart
│       │   ├── whisper_service_test.dart
│       │   └── report_service_test.dart
│       ├── providers/
│       │   └── session_provider_test.dart
│       └── widgets/
│           └── recording_controls_test.dart
├── backend/                          # Python API proxy
│   ├── main.py                       # FastAPI app, single /report endpoint
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── .env.example
│   └── tests/
│       └── test_report_endpoint.py
├── .gitignore
└── README.md
```

---

## 4. Mobile App — Flutter

### 4.1 Dependencies

```yaml
# pubspec.yaml
name: anote_mobile
description: Medical report generation from voice — on-device transcription

environment:
  sdk: '>=3.2.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  whisper_flutter_plus: ^1.0.0     # On-device Whisper.cpp
  audio_streamer: ^4.0.0           # Real-time PCM audio stream from mic
  flutter_riverpod: ^2.4.0         # State management
  dio: ^5.4.0                      # HTTP client for backend calls
  flutter_secure_storage: ^9.0.0   # Secure API token storage
  path_provider: ^2.1.0            # Local file paths (model storage)
  permission_handler: ^11.0.0      # Mic permission requests

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0
  mockito: ^5.4.0
  build_runner: ^2.4.0

flutter:
  assets:
    - assets/models/
    - assets/demo_scenarios/
```

### 4.2 AudioService

Captures raw PCM audio from the microphone using `audio_streamer`, which provides a continuous stream of samples — matching the `sounddevice.InputStream` pattern from the original Python app.

**Responsibilities:**
- Request and manage microphone permissions
- Open audio stream at 16kHz, mono, float32
- Emit audio samples via a Dart `Stream<List<double>>`
- Handle audio session lifecycle (start/stop/dispose)

**Key parameters:**
- Sample rate: 16,000 Hz
- Channels: 1 (mono)
- Format: float32

```dart
// Conceptual interface
class AudioService {
  Stream<List<double>> get audioStream;
  Future<void> start();
  Future<void> stop();
  void dispose();
}
```

### 4.3 WhisperService

Runs Whisper.cpp on-device via `whisper_flutter_plus`. Converts incoming audio samples into Czech text transcription.

**Responsibilities:**
- Load Whisper model from app assets on first launch
- Accept audio samples from AudioService
- Maintain a sliding window audio buffer with overlap
- Run periodic transcription (~every 5 seconds of new audio)
- Run full-session re-transcription on recording stop (highest quality)
- Output transcription updates via a `Stream<String>`

**Sliding window strategy (fixes chunk-boundary quality problems):**

```
Audio buffer:  [==========|=====new audio=====]
                    ↑ overlap start (2s before last boundary)
                                               ↑ current end

Each transcription window starts 2 seconds before the previous
boundary, ensuring words at the cut point appear in both windows.
The overlapping text is deduplicated by comparing the tail of the
previous transcript with the head of the new one.
```

**Critical Whisper parameters for Czech:**
- `language: 'cs'` — force Czech, DO NOT auto-detect (short chunks get misidentified as Slovak/Polish)
- `translate: false` — do not translate to English
- `noSpeechThreshold: 0.6` — suppress hallucinations during silence
- `singleSegment: false` — allow natural sentence boundary segmentation

**Model selection:**
- Default: `ggml-small.bin` (~244 MB) — good Czech quality, real-time ×3 speed
- The model file is bundled in `assets/models/` and copied to the device's local storage on first launch
- Optional future enhancement: allow user to download `medium` model (~769 MB) for better quality

**Transcription modes:**
1. **Live mode (during recording):** Sliding window, ~5 second intervals, `small` model. Provides real-time-ish transcript updates for the UI.
2. **Final mode (on stop):** Full audio buffer, single pass, `small` model. This produces the highest quality transcript that gets sent to GPT for the definitive report.

```dart
// Conceptual interface
class WhisperService {
  Future<void> loadModel();
  void feedAudio(List<double> samples);
  Stream<String> get transcriptStream;       // live updates
  Future<String> transcribeFull();           // final full-pass
  void reset();
  void dispose();
}
```

### 4.4 ReportService

Sends the text transcript to the backend proxy for structured report generation.

**Responsibilities:**
- Send transcript text to `POST /report` on the backend
- Attach bearer token for authentication
- Return the structured Czech medical report
- Handle network errors gracefully (retry, offline queueing)

```dart
// Conceptual interface
class ReportService {
  final Dio _dio;
  final FlutterSecureStorage _storage;

  Future<String> generateReport(String transcript);
  Future<bool> isBackendReachable();
}
```

**When reports are generated:**
- **During recording:** After every live transcription update (~10-15 seconds), send accumulated transcript to backend. This gives the doctor a live-updating report preview.
- **On stop:** After the full-pass transcription completes, send the final transcript for the definitive report.

### 4.5 DemoService

Plays back bundled demo scenario text files with simulated word-by-word typing animation and incremental report generation — replicates the demo mode from the original web app.

**Responsibilities:**
- List available demo scenarios from bundled assets
- Parse scenario metadata (name, word count, language)
- Play back a scenario: emit words one-by-one via a stream with configurable delay (~80-150ms per word)
- Trigger periodic report generation during playback (every ~15-20 words)
- Support cancellation (AbortController equivalent via stream subscription cancellation)

```dart
// Conceptual interface
class DemoService {
  Future<List<DemoScenario>> listScenarios();
  Stream<DemoPlaybackEvent> playScenario(String scenarioId);
  void cancel();
}
```

### 4.6 State Management — Riverpod

```dart
// session_state.dart
enum RecordingStatus { idle, recording, processing, demoPlaying }

class SessionState {
  final RecordingStatus status;
  final String transcript;        // accumulated transcript text
  final String report;            // current structured report
  final String? errorMessage;
  final bool isModelLoaded;       // Whisper model loaded
}
```

```dart
// session_provider.dart — StateNotifier
class SessionNotifier extends StateNotifier<SessionState> {
  final AudioService _audio;
  final WhisperService _whisper;
  final ReportService _report;
  final DemoService _demo;

  Future<void> startRecording();
  Future<void> stopRecording();
  Future<void> resetSession();
  Future<void> playDemo(String scenarioId);
  void cancelDemo();
}
```

**State flow during recording:**
1. `startRecording()` → status = `recording`
2. AudioService starts → samples flow to WhisperService
3. WhisperService emits transcript updates → state.transcript updates
4. Every ~10-15s, ReportService generates report → state.report updates
5. `stopRecording()` → status = `processing`
6. WhisperService runs full-pass transcription
7. ReportService generates final report
8. status = `idle`, final transcript and report in state

### 4.7 UI Screens

#### HomeScreen — main screen

Layout (portrait):
```
┌──────────────────────────────┐
│  🩺 ANOTE          [⚙] [🌙] │  ← header: logo, settings, theme toggle
│  ● Připraveno                │  ← status pill
├──────────────────────────────┤
│                              │
│  📋 Lékařská zpráva          │  ← report panel (scrollable)
│  ┌──────────────────────────┐│
│  │ Structured report text   ││
│  │ updates live during      ││
│  │ recording...             ││
│  └──────────────────────────┘│
│                              │
├──────────────────────────────┤
│  🎤 Přepis řeči   [Probíhá] │  ← collapsible transcript panel
│  ┌──────────────────────────┐│
│  │ Live transcript text...  ││
│  └──────────────────────────┘│
├──────────────────────────────┤
│ [🔴 Nahrávat]  [⬛ Zastavit] │  ← recording controls
│ [🗑 Vymazat]                 │
│                              │
│  🎬 Demo / Prezentační režim │  ← demo mode toggle
└──────────────────────────────┘
```

**Behavior:**
- Report panel is the primary display (largest area)
- Transcript panel is collapsible, shown during recording/demo
- Report textarea is editable (doctor can manually correct the generated report)
- Dark/light theme toggle (persisted via SharedPreferences)
- Czech language UI throughout

#### SettingsScreen

- Backend URL configuration (default: the Azure Container Apps URL)
- API token input (stored in flutter_secure_storage)
- Whisper model info (loaded model name, size, option to download larger model)
- Theme preference
- About / version info

### 4.8 Permissions

**Android** (`AndroidManifest.xml`):
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
```

**iOS** (`Info.plist`):
```xml
<key>NSMicrophoneUsageDescription</key>
<string>ANOTE potřebuje přístup k mikrofonu pro nahrávání lékařských konzultací.</string>
```

Permission is requested at runtime via `permission_handler` before the first recording attempt. If denied, show an explanation dialog and a button to open system settings.

---

## 5. Backend — Python FastAPI Proxy

### 5.1 Overview

A minimal proxy that receives transcript text and returns a structured Czech medical report via Azure OpenAI. Single endpoint. No audio handling. No data storage.

### 5.2 Implementation

```python
# backend/main.py
import os
from datetime import date
from fastapi import FastAPI, HTTPException, Depends, Header
from pydantic import BaseModel
from openai import AzureOpenAI
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(title="ANOTE Backend", version="2.0.0")

client = AzureOpenAI(
    api_key=os.environ["AZURE_OPENAI_KEY"],
    api_version="2024-10-21",
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
)

CHAT_MODEL = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4o-mini")
API_TOKEN = os.environ["APP_API_TOKEN"]


def verify_token(authorization: str = Header(...)):
    if authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid token")


class ReportRequest(BaseModel):
    transcript: str
    language: str = "cs"


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/report")
async def generate_report(data: ReportRequest, _=Depends(verify_token)):
    transcript = data.transcript.strip()
    if not transcript:
        raise HTTPException(status_code=400, detail="Empty transcript")

    today = date.today().strftime("%d. %m. %Y")

    system_prompt = f"""Jsi specialista na lékařskou dokumentaci. Tvým úkolem je převést přepis návštěvy pacienta do strukturované lékařské zprávy v ČESKÉM jazyce s následujícími sekcemi:

1. **Identifikace pacienta** – Jméno, věk, datum návštěvy (dnešní datum je {today})
2. **Hlavní obtíže / Důvod návštěvy** – Proč pacient přišel
3. **Anamnéza nynějšího onemocnění** – Podrobnosti o aktuálních příznacích
4. **Osobní anamnéza / Alergie / Léky** – Relevantní historie a současná medikace
5. **Objektivní nález** – Vitální funkce, vyšetřovací nálezy
6. **Hodnocení** – Klinický dojem a diagnóza
7. **Plán** – Léčebný plán a kontroly

Pravidla:
- NEVYMÝŠLEJ informace, které nejsou v přepisu
- Datum návštěvy VŽDY vyplň jako {today}
- Pokud informace pro danou sekci chybí, napiš: "Nezmíněno v přepisu"
- Používej stručný, klinický jazyk v češtině
- Formátuj přehledně s nadpisy sekcí
- Celá zpráva MUSÍ být v češtině, i když je přepis v angličtině

Vrať pouze strukturovanou zprávu, žádný další komentář."""

    try:
        response = client.chat.completions.create(
            model=CHAT_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": f"Převeď tento přepis do strukturované lékařské zprávy v češtině:\n\n{transcript}"},
            ],
            temperature=0.3,
            max_tokens=2000,
        )
        return {"report": response.choices[0].message.content}
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Azure OpenAI error: {str(e)}")
```

### 5.3 Dependencies

```
# backend/requirements.txt
fastapi==0.115.0
uvicorn[standard]==0.30.0
openai==1.50.0
python-dotenv==1.0.1
pydantic==2.9.0
```

### 5.4 Docker

```dockerfile
# backend/Dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### 5.5 Environment Variables

```bash
# backend/.env.example
AZURE_OPENAI_KEY=your-azure-openai-key
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com
AZURE_OPENAI_DEPLOYMENT=gpt-4o-mini
APP_API_TOKEN=your-secret-bearer-token
```

### 5.6 Deployment — Azure Container Apps

```bash
# One-time setup
az containerapp up \
  --name anote-api \
  --resource-group anote-rg \
  --location westeurope \
  --source ./backend \
  --ingress external \
  --target-port 8000 \
  --env-vars \
    AZURE_OPENAI_KEY=secretref:azure-openai-key \
    AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com \
    AZURE_OPENAI_DEPLOYMENT=gpt-4o-mini \
    APP_API_TOKEN=secretref:app-api-token
```

**Properties:**
- Region: West Europe (Netherlands) — data stays in EU
- Min replicas: 0 (scales to zero when idle — zero cost)
- Max replicas: 2 (handles concurrent requests)
- HTTPS: Automatically provisioned by Azure Container Apps

---

## 6. Data Flow — Detailed

### 6.1 Recording Flow

```
1. Doctor taps "Nahrávat"
2. App requests mic permission (if not yet granted)
3. AudioService opens PCM stream (16kHz, mono, float32)
4. SessionNotifier status → recording
5. Audio samples stream into WhisperService buffer continuously

6. Every ~5 seconds of new audio:
   a. WhisperService takes sliding window (2s overlap with previous boundary)
   b. Whisper.cpp processes audio → Czech text
   c. Deduplicate overlapping words with previous transcript
   d. SessionNotifier updates state.transcript
   e. UI renders updated transcript in transcript panel

7. Every ~10-15 seconds (or after 2 consecutive transcript updates):
   a. ReportService sends accumulated transcript to POST /report
   b. Backend proxies to Azure OpenAI GPT-4o-mini
   c. Returns structured Czech report
   d. SessionNotifier updates state.report
   e. UI renders updated report in report panel

8. Doctor taps "Zastavit"
9. AudioService stops mic stream
10. WhisperService runs full-pass transcription on entire audio buffer
    (no windowing — single pass for highest quality)
11. ReportService sends final transcript to POST /report
12. SessionNotifier status → idle, final report displayed
```

### 6.2 Demo Flow

```
1. Doctor taps "Demo / Prezentační režim"
2. App lists bundled scenarios from assets/demo_scenarios/
3. Doctor selects a scenario and taps "Spustit simulaci"
4. DemoService reads scenario text
5. SessionNotifier status → demoPlaying

6. Words are emitted one-by-one (~100-150ms per word):
   a. Transcript panel shows typing animation with blinking cursor
   b. Auto-scrolls to keep latest text visible

7. Every ~20 words of typed text:
   a. ReportService sends partial transcript to POST /report
   b. Report panel updates with evolving report

8. After all words typed:
   a. Final report generation
   b. SessionNotifier status → idle
   c. Remove typing cursor, show "Dokončeno" status
```

### 6.3 Offline Behavior

```
1. Doctor starts recording — works fully (Whisper is on-device)
2. Transcript accumulates locally
3. Report generation calls fail (no internet) — show subtle indicator,
   do NOT block recording
4. Doctor stops recording — full transcript available locally
5. When connectivity returns, doctor taps "Generovat zprávu" to retry
6. Report generates successfully
```

---

## 7. Security & Privacy

### 7.1 Data Classification

| Data | Where it exists | Leaves device? | Stored? |
|------|----------------|----------------|---------|
| Patient voice audio | Phone RAM only (during recording) | **Never** | Not persisted after session |
| Text transcript | Phone RAM, sent to backend | **Yes** (text only, HTTPS) | Not stored on backend |
| Medical report | Phone display, returned from backend | Received from backend | Not stored on backend |
| API bearer token | flutter_secure_storage (encrypted) | Sent in HTTP header | Stored encrypted on device |

### 7.2 Backend Security

- **Authentication:** Bearer token in `Authorization` header. Token stored in Azure Container Apps secrets.
- **Transport:** HTTPS only (TLS 1.2+ enforced by Azure Container Apps)
- **No logging of request bodies:** The backend must NOT log transcript content or report content. Only log metadata (request count, latency, errors).
- **No data persistence:** The backend is stateless. No database. No file storage. Requests are processed and immediately discarded.

### 7.3 Azure OpenAI Data Handling

- **Region:** West Europe — all processing within EU borders
- **Abuse monitoring opt-out:** Submitted via [Microsoft Modified Access form](https://aka.ms/oai/modifiedaccess). Once approved, Azure retains zero prompt data.
- **No training:** Microsoft contractually guarantees customer data is not used for model training.
- **DPA:** Microsoft's standard Data Processing Agreement applies automatically with Azure subscription.

### 7.4 Mobile App Security

- API token stored using platform-native encrypted storage (Keychain on iOS, EncryptedSharedPreferences on Android) via `flutter_secure_storage`
- No patient data written to disk at any point
- Audio buffer cleared from memory on session reset
- Transcript and report cleared from state on session reset
- App does not use analytics, crash reporting, or third-party SDKs that transmit data

---

## 8. Whisper On-Device — Configuration Detail

### 8.1 Model Management

On first app launch:
1. Check if model exists in app's local documents directory
2. If not, copy `ggml-small.bin` from Flutter assets to local storage
3. Load model into Whisper.cpp runtime
4. Set `isModelLoaded = true` in state

The model is bundled in the app binary (~244 MB). This increases initial download size but ensures the app works immediately without a separate model download step.

### 8.2 Transcription Parameters

```dart
WhisperConfig(
  language: 'cs',             // Force Czech — critical for accuracy
  translate: false,            // Do not translate to English
  noSpeechThreshold: 0.6,     // Suppress hallucinations during silence
  singleSegment: false,        // Allow natural segmentation
  maxLen: 0,                   // No max segment length (let model decide)
  nThreads: 4,                 // Use 4 CPU threads
)
```

### 8.3 Sliding Window Algorithm

```
Constants:
  SAMPLE_RATE        = 16000
  WINDOW_INTERVAL    = 5 * SAMPLE_RATE    (5 seconds of new audio triggers transcription)
  OVERLAP            = 2 * SAMPLE_RATE    (2 seconds of overlap with previous window)

State:
  audioBuffer        = []                  (all captured audio samples)
  lastBoundary       = 0                   (sample index where last transcription ended)
  previousTailText   = ""                  (last ~20 words of previous transcription)

On new audio samples:
  1. Append samples to audioBuffer
  2. If (audioBuffer.length - lastBoundary) >= WINDOW_INTERVAL:
     a. overlapStart = max(0, lastBoundary - OVERLAP)
     b. window = audioBuffer[overlapStart .. audioBuffer.length]
     c. rawText = whisper.transcribe(window)
     d. deduplicatedText = removeOverlap(previousTailText, rawText)
     e. Append deduplicatedText to running transcript
     f. previousTailText = last ~20 words of rawText
     g. lastBoundary = audioBuffer.length

On recording stop:
  1. fullText = whisper.transcribe(audioBuffer)  // single pass, no windowing
  2. Replace running transcript with fullText     // highest quality version
```

### 8.4 Overlap Deduplication

Compare the tail of the previous transcription with the head of the new transcription to find and remove duplicated words caused by the overlapping window:

```
Previous tail: "... bolest na hrudi trvající dva"
New raw text:  "trvající dva dny s vyzařováním do levé ruky"
                ↑ overlap match ↑
Result:        "dny s vyzařováním do levé ruky"
```

Use normalized string comparison (lowercase, stripped diacritics for matching, but preserve original text in output).

---

## 9. UI Specification

### 9.1 Theme

- **Light mode** (default): matches existing web app light palette
- **Dark mode**: matches existing web app dark palette
- Toggle persisted via SharedPreferences
- System-default detection on first launch

**Color tokens (matching existing web app):**

```dart
// Light
static const bg = Color(0xFFF1F5F9);
static const card = Color(0xFFFFFFFF);
static const border = Color(0xFFCBD5E1);
static const text = Color(0xFF1E293B);
static const accent = Color(0xFF0891B2);
static const danger = Color(0xFFDC2626);
static const success = Color(0xFF059669);

// Dark
static const bgDark = Color(0xFF0F172A);
static const cardDark = Color(0xFF1E293B);
static const borderDark = Color(0xFF334155);
static const textDark = Color(0xFFF1F5F9);
static const accentDark = Color(0xFF06B6D4);
```

### 9.2 Status Pill States

| State | Label | Color |
|-------|-------|-------|
| Idle | "Připraveno" | green (success) |
| Recording | "Nahrávání & generování..." | red + pulse animation |
| Processing | "Dokončování..." | red (no pulse) |
| Demo | "Simulace..." | red + pulse animation |
| Error | "Chyba" | red |

### 9.3 Responsive Layout

- **Portrait:** Single column — report panel, transcript panel (collapsible), controls
- **Landscape / tablet:** Two columns — report panel (left, 2/3), transcript panel (right, 1/3) — matching the original web app layout

### 9.4 Localization

The app UI is in Czech. All button labels, status messages, and system text are Czech.

Key UI strings:
```
Spustit nahrávání / Zastavit nahrávání / Vymazat vše
Lékařská zpráva / Přepis řeči
Připraveno / Nahrávání & generování... / Dokončování...
Demo / Prezentační režim / Spustit simulaci
Nastavení / Tmavý / Světlý
```

---

## 10. Error Handling

| Scenario | Behavior |
|----------|----------|
| Mic permission denied | Show dialog explaining need, button to open system settings |
| Whisper model failed to load | Show error on home screen, disable recording. Offer retry. |
| Backend unreachable during recording | Continue recording and transcribing. Show subtle "offline" indicator. Report generation retries when connectivity returns. |
| Backend returns 401 | Show "Invalid API token" error. Direct user to Settings. |
| Backend returns 502 (Azure OpenAI error) | Show "Report generation failed. Retry?" with retry button. |
| Audio stream error | Stop recording gracefully, preserve transcript gathered so far. Show error. |

---

## 11. Testing Strategy

### 11.1 Mobile Tests

| Layer | What to test | Approach |
|-------|-------------|----------|
| WhisperService | Sliding window logic, overlap deduplication, model loading | Unit tests with mock Whisper results |
| ReportService | HTTP calls, auth header, error handling | Unit tests with mock Dio |
| SessionNotifier | State transitions, recording lifecycle | Unit tests with mocked services |
| AudioService | Stream lifecycle, start/stop | Integration tests on device |
| UI Widgets | Button states, panel visibility | Widget tests |
| Full pipeline | Record → transcribe → report | Manual E2E test on device |

### 11.2 Backend Tests

| What to test | Approach |
|-------------|----------|
| POST /report with valid transcript | Mock Azure OpenAI client, verify response format |
| POST /report with empty transcript | Verify 400 response |
| POST /report without auth token | Verify 401 response |
| POST /report with invalid token | Verify 401 response |
| GET /health | Verify 200 response |

---

## 12. Build & Deployment

### 12.1 Mobile

```bash
# Development
cd mobile
flutter pub get
flutter run               # Debug on connected device

# Build release
flutter build apk --release          # Android APK
flutter build appbundle --release     # Android App Bundle (for Play Store)
flutter build ios --release           # iOS (requires macOS + Xcode)
```

**Note:** The Whisper model (~244 MB) significantly increases the app binary size. For distribution, consider:
- Android: App Bundle with on-demand asset delivery (model downloads after install)
- iOS: On-demand resource via ODR (model downloads on first launch)

### 12.2 Backend

```bash
# Local development
cd backend
pip install -r requirements.txt
cp .env.example .env     # fill in real values
uvicorn main:app --reload --port 8000

# Deploy to Azure
az containerapp up \
  --name anote-api \
  --resource-group anote-rg \
  --location westeurope \
  --source ./backend \
  --ingress external \
  --target-port 8000
```

---

## 13. Migration from Current Web App

| Original component | Mobile equivalent | Migration notes |
|-------------------|-------------------|-----------------|
| `app/state.py` (AppState with threading.Lock) | `session_state.dart` + Riverpod StateNotifier | No locks needed — Dart is single-threaded event loop |
| `app/audio_manager.py` (sounddevice) | `audio_service.dart` (audio_streamer) | Different API surface, same concept: continuous PCM stream |
| `app/openai_client.py` — Whisper calls | `whisper_service.dart` (on-device Whisper.cpp) | Eliminates cloud transcription entirely |
| `app/openai_client.py` — GPT report calls | `report_service.dart` → backend `/report` | Indirect via proxy instead of direct API call |
| `app/openai_client.py` — Czech system prompt | `backend/main.py` | Copy verbatim, change `OpenAI` to `AzureOpenAI` |
| `main.py` (FastAPI server + all endpoints) | Eliminated on mobile. Backend is just `/report`. | Most server logic replaced by on-device services |
| `templates/index.html` (UI + JS polling) | Flutter widgets + Riverpod streams | Reactive streams replace HTTP polling |
| `demo_scenarios/*.txt` | `assets/demo_scenarios/*.txt` | Copy files directly, load via rootBundle |
| `tests/` | `mobile/test/` + `backend/tests/` | Rewrite tests for Flutter/Dart and slimmer backend |

---

## 14. Cost Estimate

| Component | Cost |
|-----------|------|
| Azure Container Apps (backend) | Free tier: 180k vCPU-s/month. Effectively $0 at low volume. Scales to zero. |
| Azure OpenAI GPT-4o-mini | ~$0.001 per report. 50 reports/day = ~$1.50/month |
| On-device Whisper | $0 (runs locally) |
| Apple Developer Program (iOS) | $99/year |
| Google Play Developer (Android) | $25 one-time |
| **Total monthly operating cost** | **~$1.50/month** (at 50 reports/day) |
