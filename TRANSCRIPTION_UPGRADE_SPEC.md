# Transcription Quality & Performance Upgrade — Technical Spec

## Overview

Four improvements to transcription quality and speed, plus a model selector with three options (on-device Small, on-device Large-v3-Turbo, cloud Azure OpenAI Whisper).

**Current state**: Whisper Small INT8, ~358 MB on device, ~10s/30s chunk on Samsung S8. All transcription on-device via sherpa-onnx worker isolate. No hotwords, greedy search decoding, VAD threshold 0.5 for both passes.

---

## Phase 1: Medical Hotwords File

**Goal**: Reduce medical terminology errors by biasing the decoder toward Czech medical vocabulary.

### What Changes

1. **Create `mobile/assets/hotwords_cs_medical.txt`** — one term per line, ~200 Czech medical terms covering:
   - Body parts: srdce, játra, plíce, ledviny, mozek, žaludek, střevo, kloub, páteř...
   - Conditions: diagnóza, anamnéza, hypertenze, diabetes, fibrilace, pneumonie, bronchitida...
   - Procedures: EKG, RTG, CT, MRI, sono, ultrazvuk, endoskopie, biopsie, dialýza...
   - Medications: antibiotika, analgetika, antipyretika, ibuprofen, paracetamol, metformin...
   - Report structure terms: nález, závěr, doporučení, terapie, farmakoterapie, laboratorní vyšetření...
   - Multi-word terms: krevní tlak, tepová frekvence, tělesná teplota, dechová frekvence...

2. **Copy hotwords file to device on model init** — bundle in assets, copy to model directory alongside encoder/decoder.

3. **Wire into recognizer config** in `whisper_isolate_worker.dart`:
   ```dart
   sherpa.OfflineRecognizerConfig(
     model: ...,
     decodingMethod: 'modified_beam_search',  // was: 'greedy_search'
     maxActivePaths: 4,
     hotwordsFile: hotwordsFilePath,
     hotwordsScore: 1.5,  // default, may need tuning
   )
   ```

4. **Pass `hotwordsFilePath`** from main isolate to worker via the `init` message.

### Files Modified

| File | Change |
|---|---|
| `mobile/assets/hotwords_cs_medical.txt` | NEW — ~200 Czech medical terms |
| `mobile/lib/services/whisper_service.dart` | Copy hotwords file to model dir, pass path to worker |
| `mobile/lib/services/whisper_isolate_worker.dart` | Accept `hotwordsFilePath` param, set `decodingMethod: 'modified_beam_search'`, set `hotwordsFile` |
| `mobile/pubspec.yaml` | Add `assets/hotwords_cs_medical.txt` to assets section |

### Risks & Tradeoffs

- `modified_beam_search` with `maxActivePaths: 4` is **~1.5-2x slower** than `greedy_search`. On S8 a 30s chunk goes from ~10s → ~15-20s.
- Over-boosted hotwords could force medical terms where they don't belong (e.g., "srdce" instead of "srdečně"). `hotwordsScore: 1.5` is conservative; may need tuning to 1.0-2.0 range.
- Multi-word hotwords: sherpa-onnx supports them (space-separated on one line) but behaviour with Czech may need testing.

### Testing

- Record a ~3 min medical dialogue with specific terms (EKG, diagnóza, farmakoterapie).
- Compare transcript with and without hotwords.
- Measure decode time increase.
- Tune `hotwordsScore` if over/under-biasing observed.

---

## Phase 2: Re-VAD at 0.45 in transcribeFull()

**Goal**: Catch quiet speech that was filtered out by the live VAD (threshold 0.5).

### What Changes

1. **In `doTranscribeFull()` in `whisper_isolate_worker.dart`**: Instead of using the pre-filtered `speechBuffer`, re-run VAD with threshold **0.45** on the `rawAudioBuffer` to extract speech segments. This catches soft-spoken passages that the live VAD at 0.5 discarded.

2. **Use `extractSpeechSegments()`** — this function already exists in the worker file but is currently unused. It runs Silero VAD with threshold 0.45 on raw audio and returns a concatenated speech-only buffer.

### Current Code (simplified)

```dart
Future<String> doTranscribeFull() {
  // CURRENT: trusts live-filtered speechBuffer
  final allSpeech = speechBuffer.isNotEmpty
      ? Float32List.fromList(speechBuffer)
      : Float32List.fromList(rawAudioBuffer);
  // ... chunk and transcribe allSpeech
}
```

### New Code (simplified)

```dart
Future<String> doTranscribeFull() {
  // NEW: re-extract speech from raw audio at lower threshold
  final allSpeech = rawAudioBuffer.isNotEmpty
      ? extractSpeechSegments(Float32List.fromList(rawAudioBuffer))
      : Float32List.fromList(speechBuffer);
  // ... chunk and transcribe allSpeech
}
```

### Files Modified

| File | Change |
|---|---|
| `mobile/lib/services/whisper_isolate_worker.dart` | In `doTranscribeFull()`, call `extractSpeechSegments()` on `rawAudioBuffer` instead of using `speechBuffer` directly |

### Risks & Tradeoffs

- More inclusive VAD means more audio to transcribe → the final pass is slightly slower (more speech segments).
- Lower threshold could include breathing, background noise → Whisper may produce hallucinated words on near-silent segments.
- The `extractSpeechSegments()` re-VAD pass itself takes ~100-500ms (lightweight, runs Silero VAD sequentially over the buffer).
- `rawAudioBuffer` is capped at 30 minutes. For very long recordings, older raw audio is discarded. If the recording is <30 min (typical), all audio is available for re-VAD.

### Testing

- Record with a passage where the speaker trails off quietly.
- Compare transcripts: current (missing quiet part) vs new (captures it).
- Check for any hallucinated words from noise segments.

---

## Phase 3: Model Selector (Small / Large-v3-Turbo / Azure Cloud)

**Goal**: Let the user choose their transcription engine in Settings.

### Three Options

| Option | Label (Czech) | Size | Speed (S8, 30s chunk) | Quality | Network |
|---|---|---|---|---|---|
| `small` | Whisper Small (výchozí) | 358 MB | ~10s (greedy) / ~20s (beam) | ⭐⭐⭐ | None |
| `turbo` | Whisper Large-v3-Turbo | ~860 MB | ~20s (greedy) / ~35s (beam) | ⭐⭐⭐⭐⭐ | Download only |
| `cloud` | Azure OpenAI Whisper | 0 MB | ~5-15s (network) | ⭐⭐⭐⭐⭐ | Always required |

### Data Model

```dart
// In mobile/lib/models/session_state.dart (or new file)
enum TranscriptionModel {
  small,   // On-device Whisper Small INT8
  turbo,   // On-device Whisper Large-v3-Turbo INT8
  cloud,   // Azure OpenAI Whisper API
}

extension TranscriptionModelApi on TranscriptionModel {
  String get label => switch (this) {
    TranscriptionModel.small => 'Whisper Small (358 MB)',
    TranscriptionModel.turbo => 'Whisper Large-v3-Turbo (860 MB)',
    TranscriptionModel.cloud => 'Azure OpenAI Whisper (online)',
  };

  String get shortLabel => switch (this) {
    TranscriptionModel.small => 'Small (on-device)',
    TranscriptionModel.turbo => 'Turbo (on-device)',
    TranscriptionModel.cloud => 'Cloud (Azure)',
  };

  String get prefValue => switch (this) {
    TranscriptionModel.small => 'small',
    TranscriptionModel.turbo => 'turbo',
    TranscriptionModel.cloud => 'cloud',
  };

  static TranscriptionModel fromString(String? value) => switch (value) {
    'turbo' => TranscriptionModel.turbo,
    'cloud' => TranscriptionModel.cloud,
    _ => TranscriptionModel.small,
  };
}
```

### Settings UI

Replace the current read-only "Rozpoznávání řeči" section with an interactive selector:

```
┌─ Rozpoznávání řeči ─────────────────────────────────┐
│                                                       │
│  Model:  [Small ▼]  [Turbo ▼]  [Cloud ▼]            │
│                                                       │
│  ── Small (výchozí) ──                               │
│  Velikost: 358 MB · On-device · Bez internetu        │
│  ✅ Staženo                                          │
│                                                       │
│  ── OR ──                                            │
│                                                       │
│  ── Turbo ──                                         │
│  Velikost: 860 MB · On-device · Bez internetu        │
│  📥 Stáhnout (860 MB)          [Stáhnout]            │
│  ▓▓▓▓▓▓▓▓░░░░░░ 55%                                 │
│                                                       │
│  ── OR ──                                            │
│                                                       │
│  ── Cloud (Azure OpenAI) ──                          │
│  Vyžaduje internet · ~0.006 $/min · Nejrychlejší     │
│  Klíč: [••••••••••]                                  │
│                                                       │
│  Jazyk: čeština (cs)                                 │
│  Inference: on-device / CPU                          │
└───────────────────────────────────────────────────────┘
```

Use `SegmentedButton<TranscriptionModel>` (matching existing theme/visit-type pattern).

### WhisperService Changes

**Refactor model config into a model registry:**

```dart
class WhisperModelConfig {
  final String dirName;
  final String encoderFile;
  final String decoderFile;
  final String tokensFile;
  final String baseUrl;
  final Map<String, int> expectedMinSizes;
  final String displayName;
  final String variant;

  const WhisperModelConfig({...});
}

static const smallConfig = WhisperModelConfig(
  dirName: 'sherpa-onnx-whisper-small',
  encoderFile: 'small-encoder.int8.onnx',
  decoderFile: 'small-decoder.int8.onnx',
  tokensFile: 'small-tokens.txt',
  baseUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main',
  expectedMinSizes: {
    'small-encoder.int8.onnx': 50 * 1024 * 1024,
    'small-decoder.int8.onnx': 50 * 1024 * 1024,
    'small-tokens.txt': 10 * 1024,
    'silero_vad.onnx': 300 * 1024,
  },
  displayName: 'Whisper Small',
  variant: 'INT8 (sherpa-onnx)',
);

static const turboConfig = WhisperModelConfig(
  dirName: 'sherpa-onnx-whisper-large-v3-turbo',
  encoderFile: 'large-v3-turbo-encoder.int8.onnx',
  decoderFile: 'large-v3-turbo-decoder.int8.onnx',
  tokensFile: 'large-v3-turbo-tokens.txt',
  baseUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-large-v3-turbo/resolve/main',
  expectedMinSizes: {
    'large-v3-turbo-encoder.int8.onnx': 200 * 1024 * 1024,
    'large-v3-turbo-decoder.int8.onnx': 400 * 1024 * 1024,
    'large-v3-turbo-tokens.txt': 10 * 1024,
    'silero_vad.onnx': 300 * 1024,
  },
  displayName: 'Whisper Large-v3-Turbo',
  variant: 'INT8 (sherpa-onnx)',
);
```

**Note**: The exact HuggingFace URL for large-v3-turbo INT8 needs verification. The repo is likely `csukuangfj/sherpa-onnx-whisper-large-v3-turbo` or similar — must confirm file names at implementation time.

**Model switching flow:**
1. User selects Turbo in settings → SharedPreferences saves `'turbo'`
2. If model not downloaded → show download button + progress bar
3. When ready → WhisperService reads pref on next `loadModel()` → picks appropriate config
4. If model already loaded with different config → kill worker isolate → re-init with new model
5. Hot-switching during recording is NOT supported — require idle state

### Cloud Transcription (Azure OpenAI Whisper)

**New service: `CloudTranscriptionService`**

```dart
class CloudTranscriptionService {
  /// Transcribe audio using Azure OpenAI Whisper API.
  /// Accepts raw PCM Float32 samples at 16kHz, converts to WAV,
  /// sends to Azure endpoint.
  Future<String> transcribe(
    Float32List samples, {
    String language = 'cs',
  }) async {
    final wavBytes = WavEncoder.encode(samples);  // Already have WavEncoder
    // POST to Azure OpenAI Whisper endpoint
    // multipart/form-data with file=audio.wav, language=cs
    // Returns JSON: { "text": "..." }
  }
}
```

**Azure OpenAI Whisper API:**
- Endpoint: `https://{resource}.openai.azure.com/openai/deployments/{deployment}/audio/transcriptions?api-version=2024-06-01`
- Auth: `api-key` header
- Body: multipart form with `file` (WAV/MP3), `language`, `response_format`
- Model: `whisper-1` (Azure's optimized Large-v2)

**Settings for cloud mode:**
- Azure endpoint URL (stored in FlutterSecureStorage, like backend URL)
- Azure API key (stored in FlutterSecureStorage)
- Both configured in Settings screen under the Cloud model section

**Integration into session flow:**
- When `cloud` is selected, `SessionNotifier._stopRecordingAsync()` skips on-device `transcribeFull()` entirely
- Instead calls `CloudTranscriptionService.transcribe()` with the raw audio buffer
- Live transcription during recording still uses on-device Small model (no live cloud streaming — too expensive and latency-heavy)
- The final transcript comes from the cloud and overwrites the live one

### Provider Changes

```dart
// New provider in session_provider.dart or new file
final transcriptionModelProvider =
    StateNotifierProvider<TranscriptionModelNotifier, TranscriptionModel>((ref) {
  return TranscriptionModelNotifier();
});

class TranscriptionModelNotifier extends StateNotifier<TranscriptionModel> {
  TranscriptionModelNotifier() : super(TranscriptionModel.small) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('transcription_model');
    state = TranscriptionModelApi.fromString(value);
  }

  Future<void> setModel(TranscriptionModel model) async {
    state = model;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('transcription_model', model.prefValue);
  }
}
```

### Files Modified / Created

| File | Change |
|---|---|
| `mobile/lib/models/session_state.dart` | Add `TranscriptionModel` enum + extension |
| `mobile/lib/config/constants.dart` | Add `transcriptionModelPrefKey`, Azure secure storage keys |
| `mobile/lib/services/whisper_service.dart` | Refactor into model config registry, accept `WhisperModelConfig` param, model switching |
| `mobile/lib/services/cloud_transcription_service.dart` | NEW — Azure OpenAI Whisper client |
| `mobile/lib/providers/session_provider.dart` | Add `transcriptionModelProvider`, use it in `_stopRecordingAsync()` to choose on-device vs cloud |
| `mobile/lib/screens/settings_screen.dart` | Replace read-only model info with interactive `SegmentedButton`, download/progress UI, Azure key input |

### Risks & Tradeoffs

- **Large-v3-Turbo memory**: ~860 MB model + ~260 MB loaded into memory. On S8 (4 GB RAM), may be tight. Need to test if the phone can handle it or if we need to unload the model when not in use.
- **Cloud mode privacy**: Medical audio leaves the device. Must inform the user. Azure OpenAI Whisper is HIPAA-eligible but depends on the customer's Azure setup.
- **Cloud mode reliability**: Requires internet. Needs offline fallback — if cloud fails, offer to use on-device model.
- **Hot-switching**: Changing model while a recording is in progress would be dangerous. Disable model switching when `status != idle`.
- **Download management**: User may switch to Turbo, start download, then switch back. Need clean cancellation of in-progress downloads.

---

## Phase 4: Incremental 30s Chunks During Recording

**Goal**: Shift transcription work from "after stop" to "during recording", reducing the stop-to-report wait from 50-100s to 5-10s.

### Current Architecture

```
Recording:  5s live windows → live transcript (fast, lower quality)
After Stop: 30s final chunks → final transcript (slow, higher quality)
```

All final-quality transcription happens AFTER the user stops → long wait.

### New Architecture

```
Recording:  5s live windows → live transcript (displayed to user)
            + 30s final chunks → queued as they become available
After Stop: Only last partial chunk → final transcript (fast!)
```

### Worker Isolate Message Queue

The worker isolate processes messages sequentially. New message types:

```
Current messages:
  - init          → load model
  - feedAudio     → buffer audio, run live VAD + transcription
  - transcribeFull → process all audio in final-quality chunks
  - reset         → clear buffers

New messages:
  - feedAudio     → same as before + track finalized chunk boundaries
  - finalChunk    → transcribe a specific 30s segment at final quality
  - transcribeTail → transcribe only the last partial chunk (replaces transcribeFull)
```

### Detailed Flow

**During recording:**

1. Audio flows in via `feedAudio()` as before. Live 5s windows fire as before.
2. A `_finalizedBoundary` counter tracks how many samples have been transcribed at final quality.
3. When `speechBuffer.length - _finalizedBoundary >= 30 seconds`:
   - Worker extracts the 30s chunk (with 5s overlap from previous)
   - Transcribes it at final quality
   - Saves the result in `_finalizedChunks: List<String>`
   - Advances `_finalizedBoundary`
   - Sends `finalChunkDone` message to main isolate (for optional UI indicator)
4. Final-quality chunks **only run between live windows** — if a live 5s window is due, it takes priority to keep the UI responsive.

**After user stops:**

1. Main isolate sends `transcribeTail` instead of `transcribeFull`
2. Worker only needs to transcribe `speechBuffer[_finalizedBoundary..]` — the un-finalized tail
3. Concatenates `_finalizedChunks.join(' ') + tailTranscript`
4. Returns complete high-quality transcript

**Time savings:**

| Recording Length | Current Wait (after Stop) | New Wait (after Stop) |
|---|---|---|
| 2 minutes | ~20-40s | ~5-10s |
| 5 minutes | ~50-100s | ~5-10s |
| 15 minutes | ~150-300s | ~5-10s |
| 30 minutes | ~300-600s | ~5-10s |

The wait is always just 1 chunk (~5-10s) regardless of recording length.

### Priority Queue Logic

Critical: live windows must not be delayed by final chunk processing.

```
State machine in worker:
  IDLE          → ready for any work
  LIVE_DECODE   → processing 5s live window (priority)
  FINAL_DECODE  → processing 30s final chunk

Rules:
  - If IDLE and live window ready → LIVE_DECODE
  - If IDLE and final chunk ready → FINAL_DECODE
  - If FINAL_DECODE and live window becomes ready → finish current decode, then LIVE_DECODE
    (can't interrupt mid-decode, but next message is handled ASAP)
  - feedAudio messages always processed immediately (just buffer append + VAD)
```

Since sherpa-onnx `decode()` is **blocking** within the isolate, we can't interrupt a 30s chunk decode when a live window is needed. Worst case: a live window update is delayed by the remaining time of the current final chunk decode (~10-20s). This is acceptable since the user sees live text updates every 5s on average, and an occasional 15-20s gap during a final chunk decode is not disruptive.

### Interaction with Cloud Mode

When cloud transcription is selected:
- No incremental chunks needed — cloud processes everything in one shot after stop
- Live on-device windows still run for real-time preview
- After stop: audio sent to cloud → response in ~5-15s

### Files Modified

| File | Change |
|---|---|
| `mobile/lib/services/whisper_isolate_worker.dart` | Add `_finalizedBoundary`, `_finalizedChunks`, priority-aware message loop, `transcribeTail` handler, `finalChunk` processing during `feedAudio` gaps |
| `mobile/lib/services/whisper_service.dart` | New `transcribeTail()` method alongside existing `transcribeFull()`, handle `finalChunkDone` worker messages |
| `mobile/lib/providers/session_provider.dart` | In `_stopRecordingAsync()`, call `transcribeTail()` instead of `transcribeFull()` |

### Risks & Tradeoffs

- **Highest complexity** of all four phases. The worker isolate's message handling becomes a priority queue.
- **Live transcript delays**: During a 30s final chunk decode (~10-20s), the live transcript won't update. User may notice a gap in live text.
- **Memory**: Must store all `_finalizedChunks` text in memory. For a 30-min recording, this is ~5-10 KB — negligible.
- **Overlap handling**: The 5s overlap between final chunks is the same as current `transcribeFull()`. The deduplication logic (`removeOverlap(prevTail, newText)`) is reused.
- **Testing complexity**: Timing-sensitive behavior. Need tests with mocked timing to verify priority ordering and chunk boundaries.

---

## Implementation Plan

### Session A — Hotwords + Re-VAD (quick wins)

| Step | Task | Estimate |
|---|---|---|
| A1 | Create `hotwords_cs_medical.txt` (200 terms) | 30 min |
| A2 | Add to `pubspec.yaml` assets, copy to model dir in `loadModel()` | 15 min |
| A3 | Pass `hotwordsFilePath` to worker init message | 10 min |
| A4 | Worker: add `hotwordsFile`, switch to `modified_beam_search` | 15 min |
| A5 | Worker: change `doTranscribeFull()` to use `extractSpeechSegments()` on `rawAudioBuffer` | 30 min |
| A6 | Test on device with medical dialogue recording | 30 min |
| A7 | Tune `hotwordsScore` if needed | 15 min |
| A8 | Run `flutter test` + `flutter analyze` | 15 min |

**Total: ~2.5 hours**

### Session B — Model Selector

| Step | Task | Estimate |
|---|---|---|
| B1 | Add `TranscriptionModel` enum + extension in `session_state.dart` | 15 min |
| B2 | Add `TranscriptionModelNotifier` provider | 20 min |
| B3 | Refactor `WhisperService` to use `WhisperModelConfig` registry | 45 min |
| B4 | Add download-on-demand + progress for Turbo model | 30 min |
| B5 | Create `CloudTranscriptionService` (Azure OpenAI Whisper client) | 45 min |
| B6 | Integrate cloud mode into `SessionNotifier._stopRecordingAsync()` | 30 min |
| B7 | Update `settings_screen.dart` — interactive model picker, download UI, Azure key fields | 60 min |
| B8 | Verify large-v3-turbo HuggingFace URLs + file names | 15 min |
| B9 | Test model switching, download, cloud transcription | 30 min |
| B10 | Run `flutter test` + `flutter analyze` | 15 min |

**Total: ~5 hours**

### Session C — Incremental Chunks

| Step | Task | Estimate |
|---|---|---|
| C1 | Design worker state machine (IDLE / LIVE_DECODE / FINAL_DECODE) | 30 min |
| C2 | Add `_finalizedBoundary`, `_finalizedChunks`, chunk scheduling in `feedAudio` handler | 60 min |
| C3 | Implement `finalChunk` processing in worker isolate | 45 min |
| C4 | Implement `transcribeTail` handler (replaces `transcribeFull` for incremental mode) | 30 min |
| C5 | Add `transcribeTail()` to `WhisperService` main isolate interface | 20 min |
| C6 | Update `SessionNotifier` to use `transcribeTail()` | 15 min |
| C7 | Handle `finalChunkDone` messages (optional progress indicator) | 15 min |
| C8 | Test with varied recording lengths (1 min, 5 min, 15 min) | 45 min |
| C9 | Test priority ordering — verify live windows aren't starved | 30 min |
| C10 | Run `flutter test` + `flutter analyze` | 15 min |

**Total: ~5.5 hours**

### Execution Order

```
Session A (hotwords + re-VAD)  ←  do first, immediate quality improvement
    ↓
Session B (model selector)     ←  builds on Session A, adds model configs
    ↓
Session C (incremental chunks) ←  biggest architecture change, do last
```

Each session is independently deployable and testable. Session B depends on Session A only in that the hotwords file path needs to be part of the model config. Session C is fully independent.

---

## SharedPreferences Keys Summary

| Key | Type | Default | Purpose |
|---|---|---|---|
| `visit_type` | String | `'default'` | Visit type for report structure (existing) |
| `theme_mode` | String | `'system'` | App theme (existing) |
| `transcription_model` | String | `'small'` | Selected model: small/turbo/cloud (NEW) |

## FlutterSecureStorage Keys Summary

| Key | Purpose |
|---|---|
| `api_bearer_token` | Backend report API token (existing) |
| `backend_url` | Backend report API URL (existing) |
| `azure_whisper_url` | Azure OpenAI Whisper endpoint (NEW) |
| `azure_whisper_key` | Azure OpenAI Whisper API key (NEW) |

---

## Cost Estimates (Cloud Mode)

| Usage | Monthly Recordings | Audio Minutes | Azure Cost |
|---|---|---|---|
| Light | 20 | 100 min | $0.60 (~14 Kč) |
| Medium | 50 | 375 min | $2.25 (~53 Kč) |
| Heavy | 100 | 750 min | $4.50 (~106 Kč) |
| Intensive | 200 | 1500 min | $9.00 (~212 Kč) |

Based on $0.006/minute Azure OpenAI Whisper pricing, average 7.5 min recording.
