# ANOTE Mobile — Architecture Overview

> Medical dictation app for Czech doctors. Records speech, transcribes it (on-device or cloud), generates structured medical reports via LLM.

---

## 1. High-Level System Architecture

```mermaid
graph TB
    subgraph Mobile["📱 Flutter Mobile App"]
        UI[Home Screen / Settings]
        RP[Riverpod Providers]
        AS[Audio Service]
        WS[Whisper Service<br/>sherpa-onnx]
        CS[Cloud Transcription<br/>Service]
        RS[Report Service]
        SS[Recording Storage<br/>Service]
    end

    subgraph Backend["☁️ FastAPI Backend<br/>Azure Container Apps"]
        API["/report endpoint"]
        LLM["Azure OpenAI<br/>GPT-5 / GPT-4.1-mini"]
    end

    subgraph Device["📦 On-Device Models"]
        VAD[Silero VAD<br/>Voice Activity Detection]
        WSM[Whisper Small INT8<br/>358 MB]
        WTM[Whisper Turbo INT8<br/>~1 GB]
    end

    subgraph Cloud["☁️ Azure OpenAI"]
        AW[Whisper API<br/>Cloud Transcription]
    end

    UI --> RP
    RP --> AS
    RP --> WS
    RP --> CS
    RP --> RS
    RP --> SS

    AS -->|PCM 16kHz mono| WS
    WS --> VAD
    WS --> WSM
    WS --> WTM

    CS -->|WAV upload| AW
    RS -->|POST /report| API
    API --> LLM

    SS -->|JSON files| LocalFS[(Local Filesystem<br/>recordings/*.json)]
```

---

## 2. Recording → Report Pipeline

```mermaid
flowchart TD
    A([🎙️ Doctor taps Record]) --> B[Request Mic Permission]
    B --> C[Load Whisper Model<br/>if on-device mode]
    C --> D[Start Audio Stream<br/>16 kHz mono PCM]
    D --> E[Enable Wake Lock +<br/>Foreground Service]

    E --> F{Audio Streaming Loop}

    F -->|Every audio buffer| G[Silero VAD<br/>Detect Speech]
    G -->|Speech segments| H[Whisper Transcriber<br/>on-device]
    H --> I[Update Transcript<br/>in SessionProvider]
    I --> J[UI shows live text]

    F -->|Every 15 seconds| K{Transcript<br/>changed?}
    K -->|Yes| L[POST /report<br/>to backend]
    L --> M[LLM generates<br/>preview report]
    M --> N[Update Report<br/>in SessionProvider]
    N --> O[UI shows live report]
    K -->|No| F

    F -->|Every 10 seconds| P[Auto-save transcript<br/>to local storage]

    Q([🛑 Doctor taps Stop]) --> R[Stop Audio Stream]
    R --> S{Transcription<br/>Model?}

    S -->|On-device| T[Final transcription pass<br/>WhisperService.transcribeTail]
    S -->|Cloud| U[Encode PCM → WAV<br/>Upload to Azure Whisper API]
    U -->|Fail?| T

    T --> V[Generate FINAL Report<br/>POST /report]
    U --> V

    V --> W[Save RecordingEntry<br/>transcript + report + metadata]
    W --> X[Update History Index]
    X --> Y([✅ Report Ready for Editing])
```

---

## 3. Module & Service Structure

```mermaid
graph LR
    subgraph Screens["🖥️ Screens"]
        HS[HomeScreen]
        SET[SettingsScreen]
    end

    subgraph Widgets["🧩 Widgets"]
        RC[RecordingControls<br/>Record / Stop / New]
        TP[TranscriptPanel<br/>Live text + copy]
        RPW[ReportPanel<br/>Editor + regenerate]
        RHL[RecordingHistoryList<br/>Load / delete entries]
    end

    subgraph Providers["⚙️ Riverpod Providers"]
        SP[sessionProvider<br/>SessionNotifier]
        TMP[transcriptionModelProvider]
        VTP[visitTypeProvider]
        RIP[recordingIndexProvider]
    end

    subgraph Services["🔧 Services"]
        AUS[AudioService<br/>Mic → PCM stream]
        WHS[WhisperService<br/>On-device STT]
        CTS[CloudTranscriptionService<br/>Azure Whisper API]
        RPS[ReportService<br/>HTTP → backend]
        RSS[RecordingStorageService<br/>JSON persistence]
    end

    subgraph Models["📐 Models"]
        SE[SessionState<br/>status, transcript, report]
        RE[RecordingEntry<br/>id, transcript, report, meta]
        EN[Enums: RecordingStatus<br/>TranscriptionModel, VisitType]
    end

    HS --> RC & TP & RPW & RHL
    RC --> SP
    TP --> SP
    RPW --> SP
    RHL --> RIP

    SP --> AUS & WHS & CTS & RPS & RSS
    SP --> SE
    RIP --> RSS
    RSS --> RE
```

---

## 4. Transcription Modes

```mermaid
flowchart LR
    MIC[🎙️ Microphone<br/>16 kHz PCM]

    subgraph OnDevice["On-Device Path"]
        direction TB
        VAD[Silero VAD<br/>Filter silence]
        SM[Whisper Small<br/>INT8 · 358 MB]
        TM[Whisper Turbo<br/>INT8 · ~1 GB]
    end

    subgraph CloudPath["Cloud Path"]
        direction TB
        WAV[WAV Encoder<br/>PCM → WAV]
        AZ[Azure OpenAI<br/>Whisper API]
    end

    MIC -->|small / turbo| VAD
    VAD --> SM
    VAD --> TM
    MIC -->|cloud mode| WAV
    WAV --> AZ

    SM --> OUT[📝 Transcript Text]
    TM --> OUT
    AZ --> OUT
    AZ -.->|Fallback on failure| VAD
```

| Mode | Size | Internet | Speed | Use Case |
|------|------|----------|-------|----------|
| **Small** | 358 MB | ❌ No | Good | Default, works offline |
| **Turbo** | ~1 GB | ❌ No | Better | Higher quality offline |
| **Cloud** | — | ✅ Yes | Fast | Best accuracy, needs connection |

---

## 5. State Management (Riverpod)

```mermaid
stateDiagram-v2
    [*] --> idle

    idle --> recording : startRecording()
    recording --> processing : stopRecording()
    processing --> idle : report generated + saved

    state recording {
        [*] --> streaming_audio
        streaming_audio --> live_transcribing : audio buffer
        live_transcribing --> streaming_audio : update transcript
        streaming_audio --> generating_preview : every 15s
        generating_preview --> streaming_audio : update report preview
        streaming_audio --> auto_saving : every 10s
        auto_saving --> streaming_audio
    }

    state processing {
        [*] --> final_transcription
        final_transcription --> final_report : transcript complete
        final_report --> saving : report complete
        saving --> [*]
    }
```

### Provider Dependency Graph

```mermaid
graph TD
    SP[sessionProvider<br/>SessionNotifier] --> RSP[reportServiceProvider]
    SP --> ASP[audioServiceProvider]
    SP --> WSP[whisperServiceProvider]
    SP --> RSSP[recordingStorageServiceProvider]
    SP --> RHP[recordingIndexProvider]

    TMP[transcriptionModelProvider] -.->|read by| SP
    VTP[visitTypeProvider] -.->|read by| SP

    RIP[recordingIndexProvider] --> RSSP

    style SP fill:#4a9eff,color:#fff
    style TMP fill:#ff9f43,color:#fff
    style VTP fill:#ff9f43,color:#fff
```

---

## 6. Backend API & Report Generation

```mermaid
sequenceDiagram
    participant App as 📱 Mobile App
    participant API as ☁️ FastAPI Backend
    participant LLM as 🤖 Azure OpenAI

    App->>API: POST /report<br/>{transcript, language, visit_type}
    Note over API: Validate Bearer token
    API->>API: Build system prompt<br/>based on visit_type

    alt Primary model available
        API->>LLM: ChatCompletion (GPT-5)
        LLM-->>API: Structured medical report
    else Fallback
        API->>LLM: ChatCompletion (GPT-4.1-mini)
        LLM-->>API: Structured medical report
    end

    API-->>App: { "report": "..." }
```

### Visit Type → Report Template

```mermaid
graph TD
    VT{visit_type}

    VT -->|default| AUTO[Auto-detect from transcript<br/>Initial or Follow-up]
    VT -->|initial| INIT["13-Section Structure<br/>NO, RA, OA, FA, AA, GA, SA<br/>Adherence, Objective, Assessment<br/>Exams, Therapy, Plan"]
    VT -->|followup| FU["Compact Control Report<br/>Subjective, Changes, Compliance<br/>Comorbidities, Assessment, Plan"]
    VT -->|gastroscopy| GAST["Endoscopy Report<br/>Indication, Premedication<br/>Equipment, Findings, Conclusion"]
    VT -->|colonoscopy| COL["Colonoscopy Report<br/>Same structure as gastroscopy"]
    VT -->|ultrasound| US["Ultrasound Report<br/>Liver, Gallbladder, Kidneys<br/>Pancreas, Spleen, Ascites"]
```

---

## 7. Data Persistence & Storage

```mermaid
graph TD
    subgraph Runtime["Runtime State"]
        SS[SessionState<br/>transcript + report + status]
    end

    subgraph Secure["🔒 Secure Storage"]
        TOK[API Bearer Token]
        URL[Backend URL]
        AZK[Azure Whisper Key]
        AZU[Azure Whisper URL]
    end

    subgraph Prefs["⚙️ SharedPreferences"]
        TM[Transcription Model]
        VT[Visit Type]
        TH[Theme Mode]
    end

    subgraph Files["📁 Local Filesystem"]
        IDX["recordings/_index.json<br/>Lightweight list<br/>(id, date, visitType, preview)"]
        ENT["recordings/{uuid}.json<br/>Full entry<br/>(transcript, report, metadata)"]
    end

    SS -->|auto-save 10s| ENT
    SS -->|on stop| ENT
    ENT --> IDX

    style Secure fill:#e74c3c,color:#fff
    style Files fill:#2ecc71,color:#fff
```

### Storage Safety

- **Atomic writes**: write to temp file → rename (prevents corruption)
- **Index auto-rebuild**: if `_index.json` is corrupted, scans all `*.json` files
- **No audio stored**: only text (transcript + report) — GDPR-friendly
- **Sorted newest-first**

---

## 8. UI Layout

```mermaid
graph TD
    subgraph Wide["Wide Layout (>900px)"]
        direction LR
        LP["Left Panel (2/3)<br/>━━━━━━━━━━━━━━<br/>📋 Report Editor<br/>Edit / Copy / Fullscreen<br/>Regenerate button"]
        RightP["Right Panel (1/3)<br/>━━━━━━━━━━━━━━<br/>📝 Transcript Panel<br/>🎙️ Recording Controls<br/>📂 Recording History"]
    end

    subgraph Narrow["Narrow Layout (Mobile)"]
        direction TB
        RP2["📋 Collapsible Report Panel"]
        TP2["📝 Transcript Panel"]
        RC2["🎙️ Recording Controls"]
        RH2["📂 Recording History List"]
    end
```

### Navigation

```mermaid
graph LR
    HOME["/ — HomeScreen<br/>Main recording interface"] -->|Settings icon| SETTINGS["/settings — SettingsScreen<br/>Backend URL, Token, Theme<br/>Transcription Model"]
    SETTINGS -->|Back| HOME
```

---

## 9. Key Technology Stack

| Layer | Technology |
|-------|-----------|
| **Framework** | Flutter (Dart) |
| **State** | Riverpod (StateNotifier) |
| **Audio** | `audio_streamer` (16 kHz PCM) |
| **On-device STT** | `sherpa_onnx` (Whisper INT8 + Silero VAD) |
| **Cloud STT** | Azure OpenAI Whisper API |
| **HTTP** | `dio` |
| **Storage** | JSON files (`path_provider`) |
| **Secrets** | `flutter_secure_storage` |
| **Background** | `flutter_foreground_task` + `wakelock_plus` |
| **Backend** | FastAPI (Python) on Azure Container Apps |
| **LLM** | Azure OpenAI (GPT-5 → GPT-4.1-mini fallback) |
