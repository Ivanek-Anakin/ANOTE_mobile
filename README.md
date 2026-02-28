# ANOTE Mobile

Medical report generation from voice — on-device speech-to-text (Whisper + Silero VAD) with a Python/FastAPI backend for structured Czech medical report generation via GPT-4o-mini.

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
│  POST /report → OpenAI GPT-4o-mini                     │
│    → 13-section structured Czech medical report        │
│                                                        │
└────────────────────────────────────────────────────────┘
```

## Features

- **On-device transcription** — Whisper Small (INT8) via sherpa_onnx, no audio leaves the device
- **Voice Activity Detection** — Silero VAD filters silence to prevent hallucinations
- **Real-time transcription** — live transcript updates every ~3 seconds during recording
- **Structured medical reports** — GPT-4o-mini generates 13-section Czech medical report (NO, NA, RA, OA, FA, AA, GA, SA, objektivní nález, hodnocení, vyšetření, terapie, pokyny)
- **Model auto-download** — Whisper + VAD models download on first launch with progress UI
- **Collapsible panels** — report and transcript panels expand/collapse/fullscreen
- **Copy to clipboard** — one-tap copy for both report and transcript
- **Demo mode** — pre-recorded scenarios for testing without a microphone
- **Dark/light theme** toggle

## Repository Structure

```
ANOTE_mobile/
├── README.md
├── backend/
│   ├── main.py                  # FastAPI — /health and /report endpoints
│   ├── requirements.txt
│   ├── Dockerfile
│   └── tests/
│       └── test_report_endpoint.py
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
        ├── providers/
        │   └── session_provider_test.dart
        └── services/
            ├── report_service_test.dart
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

## Backend — Local Development

```bash
cd backend
pip install -r requirements.txt
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
python -m pytest tests/ -v
```
