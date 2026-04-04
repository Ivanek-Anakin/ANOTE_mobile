# ANOTE Mobile

Medical report generation from voice — on-device speech-to-text (Whisper + Silero VAD) with a Python/FastAPI backend for structured Czech medical report generation via Azure OpenAI (gpt-5-mini).

## Architecture

```
┌──────────────────── Mobile Device ────────────────────┐
│                                                        │
│  Microphone (16 kHz mono PCM)                          │
│    ↓                                                   │
│  AudioService (audio_streamer — raw PCM chunks)        │
│    ↓                                                   │
│  WhisperService                                        │
│    ├─ Silero VAD — filters silence, extracts speech    │
│    └─ Whisper Small INT8 — on-device transcription     │
│    ↓                                                   │
│  Czech text transcript (local state)                   │
│    ↓ (periodic ~3s intervals + final on stop)          │
│  ReportService → HTTP POST to backend                  │
│    ↓                                                   │
│  Structured Czech medical report displayed in UI       │
│                                                        │
└────────────────────────────────────────────────────────┘
              │
              │ HTTP (text only)
              ▼
┌──────────── Backend Server ───────────────────────────┐
│                                                        │
│  FastAPI (Python)                                      │
│  POST /report → Azure OpenAI gpt-5-mini                │
│    → 13-section structured Czech medical report        │
│                                                        │
└────────────────────────────────────────────────────────┘
```

## Features

- **On-device transcription** — Whisper Small (INT8) via sherpa_onnx, no audio leaves the device
- **Voice Activity Detection** — Silero VAD filters silence to prevent hallucinations
- **Real-time transcription** — live transcript updates every ~3 seconds during recording
- **Structured medical reports** — Azure OpenAI gpt-5-mini generates 13-section Czech medical report (NO, NA, RA, OA, FA, AA, GA, SA, objektivní nález, hodnocení, vyšetření, terapie, pokyny)
- **GDPR-compliant** — Azure OpenAI in West Europe, no patient data leaves the EU
- **Model auto-download** — Whisper + VAD models download on first launch with progress UI
- **Collapsible panels** — report and transcript panels expand/collapse/fullscreen
- **Copy to clipboard** — one-tap copy for both report and transcript
- **Demo mode** — pre-recorded scenarios for testing without a microphone
- **Dark/light theme** toggle

## Repository Structure

```
ANOTE_mobile/
├── README.md
├── LLM_JUDGE_SPEC.md           # Report quality evaluation tech spec
├── MODEL_COMPARISON_TEST.md   # gpt-4.1-mini vs gpt-5-mini benchmark
├── PRODUCTION_CHECKLIST.md     # Step-by-step production deployment guide
├── backend/
│   ├── main.py                  # FastAPI — /health and /report endpoints
│   ├── evaluate_reports.py      # LLM-as-Judge report quality evaluation
│   ├── evaluate_transcription.py # Whisper+VAD transcription quality evaluation
│   ├── test_models.py           # Model comparison test script
│   ├── test_hurvinek.py         # Hurvínek scenario test script
│   ├── requirements.txt
│   ├── Dockerfile
│   └── tests/
│       ├── test_report_endpoint.py       # Core endpoint unit tests
│       ├── test_prompt_builder.py        # System prompt construction tests
│       ├── test_endpoints_comprehensive.py # Edge cases, GDPR, auth, Unicode
│       ├── test_report_quality.py        # Live report quality (structure, accuracy)
│       └── test_transcription_quality.py # Scenario integrity, CER/WER, eval infra
├── testing_hurvinek/            # Czech audio + ASR transcripts for testing
│   ├── *.mp3                    # Audio files (3 episodes)
│   └── *.txt                    # UniScribe transcriptions
└── mobile/
    ├── pubspec.yaml
    ├── lib/
    │   ├── main.dart                    # App entry, global error handlers
    │   ├── config/
    │   │   └── constants.dart           # Backend URL, app config
    │   ├── models/
    │   │   └── session_state.dart       # Recording status, session data
    │   ├── providers/
    │   │   └── session_provider.dart    # Riverpod state management
    │   ├── screens/
    │   │   ├── home_screen.dart         # Main UI with collapsible panels
    │   │   └── settings_screen.dart     # Backend URL configuration
    │   ├── services/
    │   │   ├── audio_service.dart       # Microphone capture (16 kHz PCM)
    │   │   ├── whisper_service.dart     # Whisper + Silero VAD transcription
    │   │   └── report_service.dart      # HTTP client for backend API
    │   ├── utils/
    │   │   └── wav_encoder.dart         # PCM → WAV encoding
    │   └── widgets/
    │       ├── recording_controls.dart  # Record/stop/generate buttons
    │       ├── report_panel.dart        # Collapsible report with fullscreen
    │       ├── transcript_panel.dart    # Collapsible transcript with copy
    │       └── demo_picker.dart         # Demo scenario selector
    ├── assets/
    │   ├── demo_scenarios/              # Pre-recorded text scenarios
    │   └── models/                      # Auto-downloaded on first launch
    └── test/
        ├── widget_test.dart
        ├── providers/
        │   ├── session_provider_test.dart
        │   └── session_provider_test.mocks.dart
        └── services/
            ├── report_service_test.dart
            ├── report_service_test.mocks.dart
            ├── whisper_service_test.dart
            └── wav_encoder_test.dart
```

## On-Device Models

All models are auto-downloaded on first launch (~250 MB total):

| Model | Size | Purpose |
|-------|------|---------|
| `small-encoder.int8.onnx` | ~120 MB | Whisper Small encoder (INT8 quantized) |
| `small-decoder.int8.onnx` | ~120 MB | Whisper Small decoder (INT8 quantized) |
| `small-tokens.txt` | ~500 KB | Whisper tokenizer vocabulary |
| `silero_vad.onnx` | ~640 KB | Silero Voice Activity Detection |

## Azure Deployment

The backend runs on **Azure Container Apps** (Consumption tier, West Europe).

### Prerequisites

```bash
# Azure CLI is installed in the project's .venv
source /Users/ivananikin/Documents/Ivanek-Anakin/ANOTE_mobile/.venv/bin/activate
az login
# Select: Visual Studio Ultimate with MSDN (8a3849cc-c762-4a9c-8874-6487046bc245)
```

### Azure Resources

| Resource | Name | Details |
|----------|------|---------|
| Resource Group | `anote-rg` | Container Apps |
| Resource Group | `ANOTE` | Azure OpenAI |
| Azure OpenAI | `anote-openai` | West Europe, Standard SKU |
| Model Deployment | `gpt-5-mini` | gpt-5-mini (version 2025-08-07) |
| Container App | `anote-api` | 0.5 CPU / 1 GB RAM, Consumption tier |
| Container Registry | `ca859739e5daacr` | Auto-created by `az containerapp up` |
| Container App Env | `anote-api-env` | West US 2 |

### Production URL

```
https://anote-api.gentleriver-a61d304a.westus2.azurecontainerapps.io
```

### Deploy / Redeploy

> **az CLI**: We use the Azure CLI installed via pip in the project venv
> (`.venv/bin/az`). Activate the venv first: `source .venv/bin/activate`.
> Do **not** use a system-level `az` — the pip version is pinned in the venv.

```bash
# 0. Make sure you're in the repo root with venv active
source .venv/bin/activate

# 1. Build & push new image (backend only — uses backend/.dockerignore)
az containerapp up \
  --name anote-api \
  --resource-group anote-rg \
  --source ./backend

# 2. Rebind env vars + secrets (az containerapp up overwrites them)
az containerapp update \
  --name anote-api \
  --resource-group anote-rg \
  --set-env-vars \
    MOCK_MODE=false \
    AZURE_OPENAI_ENDPOINT=https://anote-openai.openai.azure.com \
    AZURE_OPENAI_DEPLOYMENT=gpt-5-mini \
    AZURE_OPENAI_KEY=secretref:azure-openai-key \
    APP_API_TOKEN=secretref:app-api-token
```

### Secrets (persisted across redeployments)

| Secret Name | Env Var | Description |
|-------------|---------|-------------|
| `azure-openai-key` | `AZURE_OPENAI_KEY` | Azure OpenAI API key |
| `app-api-token` | `APP_API_TOKEN` | Bearer token for mobile app auth |

To update a secret value:
```bash
az containerapp secret set --name anote-api --resource-group anote-rg \
  --secrets azure-openai-key=NEW_KEY_VALUE
```

### Verify Deployment

```bash
# Health check
curl https://anote-api.gentleriver-a61d304a.westus2.azurecontainerapps.io/health

# Test report generation
curl -X POST https://anote-api.gentleriver-a61d304a.westus2.azurecontainerapps.io/report \
  -H "Authorization: Bearer <APP_API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"transcript": "Pacient přišel s bolestí hlavy.", "visit_type": "ambulance"}'
```

## Backend — Local Development

```bash
cd backend
pip install -r requirements.txt

# Azure OpenAI (production)
AZURE_OPENAI_KEY="..." \
AZURE_OPENAI_ENDPOINT="https://anote-openai.openai.azure.com" \
AZURE_OPENAI_DEPLOYMENT="gpt-5-mini" \
uvicorn main:app --host 0.0.0.0 --port 8000 --reload

# Plain OpenAI (dev fallback)
OPENAI_API_KEY="sk-..." uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

The API will be available at `http://localhost:8000`.

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/report` | Generate structured Czech medical report from transcript |

### Request example

```bash
curl -X POST http://localhost:8000/report \
  -H "Content-Type: application/json" \
  -d '{"transcript": "Pacient přišel s bolestí hlavy trvající tři dny."}'
```

## Mobile App — Setup

### Prerequisites

- Flutter 3.27+ / Dart 3.6+
- Xcode 15+ (for iOS)
- CocoaPods

### Run the Flutter app

```bash
cd mobile
flutter pub get
flutter run
```

Models download automatically on first launch — no manual setup needed.

### Run tests

```bash
cd mobile
dart run build_runner build --delete-conflicting-outputs
flutter test
```

### Integration Tests (E2E on Android Emulator)

The project includes end-to-end integration tests that run on an Android emulator (or device). All heavy services (audio, whisper, report) are replaced with fakes — no microphone, model files, or network access required.

#### Test Files

| File | Tests | Description |
|------|-------|-------------|
| `integration_test/app_e2e_test.dart` | 15 | Full app flow — launch, recording, clear, settings, errors, theme, performance |
| `integration_test/recording_history_test.dart` | 2 | Recording history — empty state, record→save→load→edit |

#### What They Cover

**app_e2e_test.dart:**
- **App Launch** (3) — home screen UI elements, report placeholder, transcript hidden when empty
- **Recording History** (1) — empty state message visible on home screen
- **Recording Flow** (3) — start→live transcript→stop→report, stop button disabled when idle, record button disabled while recording
- **Clear Session** (2) — clear resets transcript/report, clear button disabled when no content
- **Settings Screen** (1) — navigate to settings, verify UI fields (URL, token, visit type), navigate back
- **Performance** (2) — report generation under 10s, first frame render under 3s
- **Error Handling** (1) — network error during report generation shows error message
- **Theme Toggle** (1) — dark/light mode switch
- **Transcript Panel** (1) — "Probíhá..." status badge during recording

**recording_history_test.dart:**
- **Full flow** (1) — empty state → record → stop → history entry appears with preview
- **Load & edit** (1) — pre-populated entry loads transcript + report into panels

#### Setup: Samsung Galaxy S8 Emulator (API 28)

The emulator matches Jan Brož's physical device (Samsung Galaxy S8, Android 9, API 28).

```bash
# 1. Install API 28 system image (one-time)
yes | sdkmanager "platforms;android-28" "system-images;android-28;google_apis;x86_64"

# 2. Create AVD (one-time)
echo "no" | avdmanager create avd \
  --name "Samsung_Galaxy_S8_API28" \
  --package "system-images;android-28;google_apis;x86_64" \
  --device "pixel" --force

# 3. (Optional) Customize config to match S8 hardware:
#    ~/.android/avd/Samsung_Galaxy_S8_API28.avd/config.ini
#    hw.lcd.density=320, hw.lcd.width=720, hw.lcd.height=1480, hw.ramSize=4096M

# 4. Boot emulator
$HOME/Library/Android/sdk/emulator/emulator -avd Samsung_Galaxy_S8_API28 -gpu host -no-audio &

# 5. Wait for boot
adb wait-for-device && adb shell 'while [ "$(getprop init.svc.bootanim)" != "stopped" ]; do sleep 2; done'
```

#### Run Tests

```bash
cd mobile

# Run main e2e tests
flutter test integration_test/app_e2e_test.dart -d emulator-5554

# Run recording history tests
flutter test integration_test/recording_history_test.dart -d emulator-5554
```

#### Results (26 March 2026 — Samsung Galaxy S8 emulator, API 28)

```
app_e2e_test.dart:            15/15 passed ✅
recording_history_test.dart:   2/2  passed ✅
```

Performance metrics (on emulator, Intel Mac):

| Metric | Time |
|--------|------|
| App launch | 2,313 ms |
| First frame render | 268 ms |
| Recording flow (record→stop→report) | 5,345 ms |
| Report generation (fast fake) | 4,582 ms |
| Settings navigation | 759 ms |

### Build for physical iPhone

```bash
cd mobile/ios
xcodebuild archive \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -archivePath /tmp/Runner.xcarchive \
  -configuration Release \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates

xcrun devicectl device install app \
  --device DEVICE_UDID \
  /tmp/Runner.xcarchive/Products/Applications/Runner.app
```

## Backend — Testing

```bash
cd backend

# Unit tests only (fast, no network)
python -m pytest tests/ -v --ignore=tests/test_report_quality.py

# Full suite including live API quality tests (~3 min)
python -m pytest tests/ -v

# Skip live tests via env var
SKIP_LIVE_TESTS=1 python -m pytest tests/ -v
```

### Test Files

| File | Tests | Description |
|------|-------|-------------|
| `test_report_endpoint.py` | 7 | Core endpoint unit tests (mocked OpenAI) |
| `test_prompt_builder.py` | 25 | System prompt construction, sections, visit types |
| `test_endpoints_comprehensive.py` | 20 | Edge cases, GDPR, auth, Unicode, visit routing |
| `test_transcription_quality.py` | 24 | Scenario file integrity, CER/WER metrics, eval infra |
| `test_report_quality.py` | 20 | **Live** report quality (structure, accuracy, negation, neuvedeno) |

## Azure OpenAI Model Comparison

Both gpt-4.1-mini and gpt-5-mini were benchmarked on a Czech cardiac emergency scenario. See [MODEL_COMPARISON_TEST.md](MODEL_COMPARISON_TEST.md) for full details.

| Metric | gpt-4.1-mini | gpt-5-mini |
|--------|-------------|------------|
| Latency | **4–6 s** | 15–20 s |
| Cost/report | **~$0.001** | ~$0.004 |
| Quality | Excellent | Slightly better |
| GDPR (EU data) | Standard SKU ✅ | GlobalStandard ❌ |
| Temperature control | Yes | No |

**Decision:** gpt-4.1-mini selected for production — fast enough for 15s update cycle, GDPR-compliant, 4× cheaper.

## Transcription Evaluation

`backend/evaluate_transcription.py` benchmarks the on-device Whisper + Silero VAD pipeline against reference transcripts. It mirrors the Dart `transcribeFull()` pipeline exactly (VAD → concatenate speech → 15s chunking with 3s overlap and word deduplication) and computes WER/CER via [jiwer](https://github.com/jitsi/jiwer).

### Run

```bash
cd backend
pip install sherpa-onnx jiwer numpy

# Single config (quick check)
python evaluate_transcription.py --threshold 0.45 --min-silence 0.5 --min-speech 0.25 --tail-paddings 800

# Smart sweep (finds best VAD params)
python evaluate_transcription.py
```

Models are auto-downloaded to `backend/models/` on first run (~360 MB). Audio files are read from `testing_hurvinek/` (Czech children's puppet show — 3 episodes, ~10 min each).

### Results (Whisper Small INT8, single config)

| Scenario | WER | CER | Speech% | Segments |
|----------|-----|-----|---------|----------|
| Nachlazení | 53.4% | 39.3% | 90.7% | 36 |
| Zlomenina | 56.6% | 31.8% | 82.5% | 48 |
| Angína | 56.8% | 32.5% | 91.6% | 35 |
| **Mean** | **55.6%** | **34.5%** | **88.3%** | — |

WER/CER are measured on challenging Czech audio with multiple speakers, music, and sound effects. Medical dictation (single speaker, quiet room) is expected to perform significantly better.
