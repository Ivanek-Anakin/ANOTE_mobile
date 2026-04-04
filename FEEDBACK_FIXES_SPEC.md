# Technical Specification & Implementation Plan — Feedback Fixes

> Based on [feedback analysis](feedback_janbroz/FEEDBACK_ANALYSIS.md) from Dr. Jan Brož's 6 testing sessions.
> Each issue maps to concrete code changes with file paths, line numbers, and implementation details.

---

## Table of Contents

1. [FIX-1: Recording Start Delay — Audio Pre-Buffering](#fix-1-recording-start-delay--audio-pre-buffering)
2. [FIX-2: Recording End Cutoff — Audio Drain & Tail Capture](#fix-2-recording-end-cutoff--audio-drain--tail-capture)
3. [FIX-3: Hybrid Transcription Mode — On-Device Live + Cloud Final](#fix-3-hybrid-transcription-mode--on-device-live--cloud-final)
4. [FIX-4: Enhanced Cloud Whisper Prompt](#fix-4-enhanced-cloud-whisper-prompt)
5. [FIX-5: Backend Prompt Corrections (GA, RA, Terminology)](#fix-5-backend-prompt-corrections-ga-ra-terminology)
6. [FIX-6: Model Preloading on App Startup](#fix-6-model-preloading-on-app-startup)
7. [FIX-7: Lower VAD Threshold for Final Pass](#fix-7-lower-vad-threshold-for-final-pass)
8. [FIX-8: Chunked Cloud Transcription for Long Recordings](#fix-8-chunked-cloud-transcription-for-long-recordings)
9. [Implementation Priority & Sequencing](#implementation-priority--sequencing)

---

## FIX-1: Recording Start Delay — Audio Pre-Buffering

### Problem

When user presses Record, audio capture only begins **after** model loading completes (up to 30 seconds on cold start). Speech during this window is permanently lost.

**Evidence:**
- Feedback 1: "zase se to asi spustilo pár sekund po začátku, uvedl jsem jméno a věk"
- Feedback 6: "začalo brát rozhovor až po pár vteřinách, chybí začátek"

### Root Cause

In `session_provider.dart` `_startRecordingAsync()` (line ~477), the execution order is:

```
1. Model loading (0–30s)          ← BLOCKING — no audio captured
2. _audioService.start()           ← audio capture begins HERE
3. _audioSubscription = listen()   ← audio flows to whisper
```

All speech between pressing Record and step 2 completing is lost. There is no pre-buffer.

### Solution: Immediate Audio Capture with Pre-Buffer

Start audio capture **immediately** when the user presses Record, accumulate samples in a pre-buffer, then flush the pre-buffer into the Whisper worker once the model is ready.

### Files to Modify

| File | Changes |
|------|---------|
| `mobile/lib/providers/session_provider.dart` | Reorder `_startRecordingAsync()`: start audio before model load, add pre-buffer logic |
| `mobile/lib/services/whisper_service.dart` | Add `feedPreBuffer(List<double> samples)` method to flush buffered audio |
| `mobile/lib/services/audio_service.dart` | No changes needed — already supports immediate start |

### Implementation Detail

**`session_provider.dart` — `_startRecordingAsync()`:**

```dart
Future<void> _startRecordingAsync() async {
  try {
    // ===== STEP 1: Start audio capture IMMEDIATELY =====
    await _audioService.start();
    if (!mounted || state.status != RecordingStatus.recording) return;

    // Pre-buffer: collect audio while model loads
    final List<List<double>> preBuffer = [];
    StreamSubscription<List<double>>? preBufferSub;
    
    preBufferSub = _audioService.audioStream.listen(
      (List<double> samples) => preBuffer.add(samples),
    );

    // ===== STEP 2: Load model (if needed) =====
    final selectedModel = _ref.read(transcriptionModelProvider);
    if (selectedModel != TranscriptionModel.cloud) {
      // ... existing model loading logic (unchanged) ...
    }

    // ===== STEP 3: Cancel pre-buffer, flush into whisper, set up real pipeline =====
    await preBufferSub.cancel();
    
    // Flush pre-buffered audio into whisper service
    for (final samples in preBuffer) {
      _whisperService.feedAudio(samples);
    }
    preBuffer.clear();

    // Set up real-time audio subscription (existing code)
    _audioSubscription = _audioService.audioStream.listen(
      (List<double> samples) => _whisperService.feedAudio(samples),
      // ...
    );

    // ... rest of existing setup (transcript sub, timers, wake lock) ...
  }
}
```

**Key design decisions:**
- Pre-buffer is a simple `List<List<double>>` — no processing during model load, just accumulating raw PCM chunks
- After model loads, pre-buffer is flushed into `feedAudio()` sequentially (maintains temporal order)
- If model load fails, pre-buffer is discarded (acceptable — recording fails anyway)
- Memory impact: ~30s of audio at 16kHz = ~1.9MB — negligible

### Edge Cases

| Case | Handling |
|------|----------|
| Model already loaded (warm start) | Pre-buffer has ~0 samples, flush is instant |
| Model load fails | Pre-buffer discarded, recording aborted as before |
| `stopRecording()` called during model load | Pre-buffer sub cancelled in `stopRecording()`, no leak |
| Cloud mode (no model load) | Pre-buffer phase is instant (~0ms), no behavior change |

### Testing

- Unit test: Start recording with cold model, speak during load, verify transcript includes first words
- Integration test: Measure time from button press to first audio sample arriving at whisper worker — should be <200ms
- Regression test: Existing on-device and cloud modes still work

---

## FIX-2: Recording End Cutoff — Audio Drain & Tail Capture

### Problem

Last 10–20 seconds of recording sometimes missing from transcript. Multiple contributing causes.

### Root Cause Analysis

In `stopRecording()` (line 591):

```dart
void stopRecording() {
  _reportTimer?.cancel();        // 1. cancel report timer
  _autoSaveTimer?.cancel();      // 2. cancel auto-save timer
  _audioSubscription?.cancel();  // 3. ⚠️ CANCEL AUDIO — stops feeding whisper
  _transcriptSubscription?.cancel();
  state = state.copyWith(status: RecordingStatus.processing);
  _stopRecordingAsync();         // 4. stop mic, run final transcription
}
```

Then in `_stopRecordingAsync()`:

```dart
Future<void> _stopRecordingAsync() async {
  await _audioService.stop();    // 5. actually stop the microphone
  // ... final transcription ...
}
```

**Problem 1: Audio subscription cancelled (step 3) before mic stopped (step 5).** Any audio buffers emitted by the mic between steps 3 and 5 are silently dropped — never reach the whisper worker.

**Problem 2: `_audioService.stop()` doesn't drain.** It just calls `_subscription?.cancel()` — no flush, no await for pending buffers.

**Problem 3: VAD may filter out quiet trailing speech.** Doctor often speaks more softly when wrapping up. Live VAD threshold (0.5) may miss this.

**Problem 4: Live window requires 5s of new speech to trigger.** If the last segment is <5s, it only gets captured in `transcribeTail()` — but `transcribeTail()` uses the speech buffer which depends on VAD having passed the audio in step 3.

### Solution: Three-Part Fix

#### Part A: Drain audio before stopping subscription

```dart
void stopRecording() {
  _reportTimer?.cancel();
  _reportTimer = null;
  _autoSaveTimer?.cancel();
  _autoSaveTimer = null;
  
  // DON'T cancel audio subscription yet — let it drain
  _transcriptSubscription?.cancel();
  _transcriptSubscription = null;
  
  state = state.copyWith(status: RecordingStatus.processing);
  _stopRecordingAsync();
}
```

Then in `_stopRecordingAsync()`:

```dart
Future<void> _stopRecordingAsync() async {
  // Step 1: Stop the microphone (no new audio will be generated)
  await _audioService.stop();
  
  // Step 2: Small delay to let in-flight audio buffers arrive
  await Future<void>.delayed(const Duration(milliseconds: 300));
  
  // Step 3: NOW cancel the audio subscription (all pending buffers processed)
  await _audioSubscription?.cancel();
  _audioSubscription = null;
  
  // ... rest of final transcription ...
}
```

#### Part B: Force-include last raw audio in final pass

In `whisper_isolate_worker.dart`, modify `doTranscribeTail()` to always include the last N seconds of raw audio even if VAD didn't flag it as speech:

```dart
String doTranscribeTail() {
  // Existing: transcribe finalized chunks + remaining speechBuffer tail
  // ... existing code ...

  // NEW: Safety pass — transcribe last 15s of raw audio regardless of VAD
  const int safetyTailSamples = 15 * sampleRate;  // 15 seconds
  if (rawAudioBuffer.length > safetyTailSamples) {
    final safetyTail = rawAudioBuffer.sublist(
      rawAudioBuffer.length - safetyTailSamples,
    );
    final safetyText = transcribe(safetyTail);
    if (safetyText.isNotEmpty) {
      // Deduplicate against existing tail
      final deduped = WhisperService.removeOverlap(
        WhisperService.lastWords(result, 20), safetyText,
      );
      if (deduped.isNotEmpty && deduped.split(' ').length > 3) {
        // Only append if safety pass found meaningful new content
        result = '$result $deduped';
      }
    }
  }
  
  return result;
}
```

#### Part C: Notify worker to flush VAD before final transcription

Add a `'flush'` command to the worker that calls `vad!.flush()` to push any pending speech segments from VAD's internal buffer into `speechBuffer` before the final transcription pass:

```dart
// In whisper_isolate_worker.dart message handler:
case 'flush':
  if (vad != null) {
    vad!.flush();
    while (!vad!.isEmpty()) {
      final segment = vad!.front();
      vad!.pop();
      if (segment.samples.isNotEmpty) {
        speechBuffer.addAll(segment.samples);
      }
    }
  }
  mainSendPort.send({'type': 'flushDone'});
  break;
```

Call this from `_stopRecordingAsync()` before `transcribeTail()`.

### Files to Modify

| File | Changes |
|------|---------|
| `mobile/lib/providers/session_provider.dart` | Reorder stop sequence: stop mic first, drain, then cancel subscription |
| `mobile/lib/services/audio_service.dart` | Optionally add `drain()` method that awaits pending stream events |
| `mobile/lib/services/whisper_service.dart` | Add `flushVad()` async method that sends flush command to worker |
| `mobile/lib/services/whisper_isolate_worker.dart` | Add `'flush'` command handler; modify `doTranscribeTail()` with safety pass |

### Testing

- Record a 30-second session, speak a distinct keyword in the last 3 seconds — verify it appears in transcript
- Record and whisper softly at the end — verify the quiet speech is captured
- Measure total stop time — should add <500ms to existing latency

---

## FIX-3: Hybrid Transcription Mode — On-Device Live + Cloud Final

### Problem

On-device Whisper Small produces heavily garbled Czech transcripts. Cloud Whisper (Azure OpenAI) produces much better quality but currently has no live preview — user sees nothing during recording.

### Solution: Hybrid Mode

Use on-device Whisper for **live preview** during recording (garbled quality is acceptable for real-time feedback), then use cloud Whisper for the **final high-quality transcript** when recording stops.

### Architecture

```
Recording Phase:
  Mic → AudioService → WhisperService (on-device Small/Turbo) → Live preview in UI
  Mic → AudioService → rawAudioBuffer accumulation (in worker isolate)

Stop Phase:
  rawAudioBuffer → WAV encoding → Azure OpenAI Whisper API → Final transcript
  Final transcript → POST /report → Structured medical report
```

### Files to Modify

| File | Changes |
|------|---------|
| `mobile/lib/models/enums.dart` | Add `TranscriptionModel.hybrid` enum value |
| `mobile/lib/providers/session_provider.dart` | Handle hybrid mode in `_startRecordingAsync()` and `_stopRecordingAsync()` |
| `mobile/lib/services/whisper_service.dart` | Add `getRawAudioBufferFromWorker()` async method that retrieves raw audio from the worker isolate |
| `mobile/lib/services/whisper_isolate_worker.dart` | Add `'getRawAudio'` command to export raw buffer to main isolate |
| `mobile/lib/services/cloud_transcription_service.dart` | No changes needed — already accepts raw audio samples |
| `mobile/lib/screens/settings_screen.dart` | Add hybrid option to transcription model picker |

### Implementation Detail

**`enums.dart` — Add hybrid mode:**

```dart
enum TranscriptionModel {
  small,
  turbo,
  cloud,
  hybrid,  // NEW: on-device live + cloud final
}
```

**`session_provider.dart` — `_startRecordingAsync()` for hybrid mode:**

```dart
// Hybrid mode: load on-device model for live preview
if (selectedModel == TranscriptionModel.hybrid ||
    selectedModel != TranscriptionModel.cloud) {
  final config = (selectedModel == TranscriptionModel.turbo)
      ? WhisperService.turboConfig
      : WhisperService.smallConfig;  // hybrid uses small for live
  // ... existing model loading ...
}
```

**`session_provider.dart` — `_stopRecordingAsync()` for hybrid mode:**

```dart
if (selectedModel == TranscriptionModel.hybrid) {
  // Step 1: Get raw audio from worker isolate
  final rawAudio = await _whisperService.getRawAudioBufferFromWorker();
  
  if (rawAudio.isNotEmpty) {
    try {
      // Step 2: Cloud transcription for final quality
      final cloudService = _ref.read(cloudTranscriptionServiceProvider);
      fullTranscript = await cloudService.transcribe(rawAudio);
    } catch (e) {
      // Fallback to on-device transcribeTail if cloud fails
      WhisperService.debugLog('[SessionNotifier] Hybrid cloud failed: $e');
      try {
        fullTranscript = await _whisperService.transcribeTail();
      } catch (e2) {
        WhisperService.debugLog('[SessionNotifier] On-device fallback: $e2');
      }
    }
  }
}
```

**`whisper_isolate_worker.dart` — Export raw audio buffer:**

```dart
case 'getRawAudio':
  // Send raw audio buffer back to main isolate via TransferableTypedData
  final float32 = Float32List.fromList(rawAudioBuffer.cast<double>());
  mainSendPort.send({
    'type': 'rawAudioData',
    'samples': TransferableTypedData.fromList([float32]),
  });
  break;
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Use Small (not Turbo) for hybrid live preview | Faster loading, lower memory; live preview quality doesn't matter much |
| Always accumulate rawAudioBuffer in hybrid mode | Cloud transcription needs unfiltered audio for best results |
| Fallback to on-device `transcribeTail()` if cloud fails | Network resilience — worst case is current on-device quality |
| Raw audio transfer via `TransferableTypedData` | Zero-copy between isolates, efficient for large buffers |

### Memory Considerations

- Raw audio buffer: 30 min max = ~230 MB (Float32 at 16 kHz)
- WAV encoding: additional ~115 MB (Int16 encoding is 2 bytes/sample)
- **Peak memory: ~345 MB during cloud upload phase** — acceptable on modern devices (3+ GB RAM)
- After upload, WAV bytes are released

### Azure Whisper File Size Limits

Azure OpenAI Whisper API has a **25 MB file size limit**. At 16 kHz Int16 WAV:
- 25 MB ÷ (16000 × 2 bytes/sample) = ~13 minutes of audio per request

For recordings >13 minutes, chunking is needed (see FIX-8). For typical doctor visits (5–15 min), single request usually works.

### Testing

- Record 2-minute session in hybrid mode: verify live preview appears during recording, final transcript (cloud quality) replaces it after stop
- Disconnect network after recording, press stop: verify fallback to on-device transcript
- Compare hybrid final transcript vs pure on-device transcript for same recording — hybrid should be noticeably better

---

## FIX-4: Enhanced Cloud Whisper Prompt

### Problem

Current Azure Whisper API prompt is minimal (1 sentence). Not leveraging the ~224 token prompt capacity to guide Czech medical terminology recognition.

### Current Prompt

```
Lékařská prohlídka, anamnéza pacienta. Diagnóza, terapie, medikace, vyšetření.
Krevní tlak, saturace, EKG, glykémie, BMI. Pacient, pacientka, doktor, ordinace.
```

### Analysis of Transcription Errors from Feedback

| Garbled Text | Correct Text | Category |
|-------------|-------------|----------|
| "homa odsobo zdramení" | "Homansovo znamení" | Clinical sign |
| "hlbokážený trhůz" | "hluboká žilní trombóza" | Diagnosis |
| "cté angliou" | "CT angiografie" | Procedure |
| "círhozu" | "cirhózu" | Diagnosis |
| "podže brama" | "pod žeberním obloukem" | Anatomy |
| "olegický" | "alergický" | Medical term |
| "kapitus, kapitace" | "krepitus, krepitace" | Auscult. finding |
| "prestarium" | "Prestarium" | Drug name |
| "malý ovanů" | "marihuanu" | Substance |

### Proposed Enhanced Prompt

The Whisper API `prompt` parameter works best as **example text in the style the model should expect** — not instructions. We should craft it as a realistic snippet of transcribed medical Czech:

```
Lékařská prohlídka, anamnéza pacienta, nynější onemocnění.
Homansovo znamení, Murphyho znamení, Lasègueovo znamení.
Hluboká žilní trombóza, plicní embolie, infarkt myokardu, fibrilace síní.
CT angiografie, RTG plic, EKG, echokardiografie, gastroskopie, kolonoskopie.
Chrůpky, krepitace, vrzoty, dýchání sklípkové, poklep plný jasný.
Krevní tlak, tepová frekvence, saturace kyslíkem, dechová frekvence.
Metformin, Prestarium, bisoprolol, atorvastatin, warfarin, heparin, furosemid.
Cirhóza, pneumonie, cholecystitida, appendicitida, pankreatitida.
Alergická anamnéza, farmakologická anamnéza, rodinná anamnéza.
Hypertenze, diabetes mellitus, hypercholesterolémie.
Objektivní nález, subjektivní potíže, pracovní diagnóza.
```

### File to Modify

| File | Changes |
|------|---------|
| `mobile/lib/services/cloud_transcription_service.dart` | Update prompt field in multipart request (~line 68) |

### Implementation

Replace the prompt field assembly (around line 67–72):

```dart
// Prompt field — guides Whisper toward Czech medical terminology
bodyParts.add(utf8.encode('--$boundary\r\n'));
bodyParts.add(utf8.encode(
    'Content-Disposition: form-data; name="prompt"\r\n\r\n'
    'Lékařská prohlídka, anamnéza pacienta, nynější onemocnění. '
    'Homansovo znamení, Murphyho znamení, Lasègueovo znamení. '
    'Hluboká žilní trombóza, plicní embolie, infarkt myokardu, fibrilace síní. '
    'CT angiografie, RTG plic, EKG, echokardiografie, gastroskopie, kolonoskopie. '
    'Chrůpky, krepitace, vrzoty, dýchání sklípkové, poklep plný jasný. '
    'Krevní tlak, tepová frekvence, saturace kyslíkem, dechová frekvence. '
    'Metformin, Prestarium, bisoprolol, atorvastatin, warfarin, heparin, furosemid. '
    'Cirhóza, pneumonie, cholecystitida, appendicitida, pankreatitida. '
    'Alergická anamnéza, farmakologická anamnéza, rodinná anamnéza. '
    'Hypertenze, diabetes mellitus, hypercholesterolémie. '
    'Objektivní nález, subjektivní potíže, pracovní diagnóza.\r\n'));
```

### Token Budget

Azure Whisper accepts ~224 tokens in the prompt field. The proposed prompt is ~130 tokens — well within limits, with room for future additions.

### Testing

- Transcribe a recording containing "Homansovo znamení" — verify correct spelling
- Transcribe a recording with drug names (Prestarium, Metformin) — verify correct capitalization
- Compare CER (Character Error Rate) before/after on same audio files
- A/B test with Dr. Brož: same scenario, old prompt vs new prompt

---

## FIX-5: Backend Prompt Corrections (GA, RA, Terminology)

### Problems from Feedback

1. **GA section for male patients** (Feedback 3): "Gynek. ani urologická anamnéza u mužů není"
2. **Children in wrong section** (Feedback 1): "Děti patří do RA, schválně jsem je zmínil u zaměstnání"
3. **Terminology preferences** (Feedback 3): "chrůpky" preferred over "chropy"
4. **Allergy vs intolerance** (Feedback 3): "Alergie je alergie a intolerance je něco jiného"
5. **Explicit negation vs "neuvedeno"** (Feedback 2): Patient explicitly denied medications → should be "bez pravidelné medikace" not "neuvedeno"
6. **Missing information** (Feedback 3, 4, 5): Facts present in transcript but absent from report

### File to Modify

| File | Changes |
|------|---------|
| `backend/main.py` | Update `_build_base_rules()` and `_build_sections_initial()` |

### Implementation — `_build_base_rules()` additions

Add these rules to the end of the existing `_build_base_rules()` function (after the last existing rule, before the closing `\n)`):

```python
# ADD to _build_base_rules():

"- Rozlišuj ALERGII (imunitní reakce: anafylaxe, angioedém, urtikarie, bronchospasmus) "
"a INTOLERANCI / nesnášenlivost (nežádoucí účinek bez imunitní reakce: "
"GIT potíže, bolest hlavy). V AA uváděj pouze alergie. Intolerance uveď v OA nebo FA.\n"

"- Preferovaná terminologie u poslechového nálezu plic: „chrůpky" (nikoli „chropy").\n"

"- Děti pacienta patří do RA (Rodinná anamnéza), NE do SA (Sociální anamnéza). "
"V RA uveď počet dětí, věk a zdravotní stav, pokud bylo zmíněno.\n"

"- Potíže s močením (dysurie, polakisurie, nykturie, hematurie) patří do NO "
"(Nynější onemocnění), NE do GA. To platí pro obě pohlaví.\n"

"- DŮKLADNĚ projdi celý přepis. Pokud je v přepisu zmíněna informace (rodinný "
"příslušník, lék, symptom, event), MUSÍ se objevit ve zprávě. Raději uveď "
"informaci navíc, než aby chyběla.\n"
```

### Implementation — `_build_sections_initial()` GA section update

Replace the GA section definition:

```python
# CURRENT:
"GA (Gynekologická/urologická anamnéza – jen pokud relevantní a zmíněno):\n"
"- Dle přepisu (cyklus, gravidita, antikoncepce / urologické potíže atd.).\n"
"- Pokud výslovně popřeno: uveď negaci relevantního symptomu.\n"
"- Jinak „neuvedeno".\n\n"

# REPLACE WITH:
"GA (Gynekologická anamnéza — pouze u žen):\n"
"- Menstruace (menarché, pravidelnost), gravidity, porody, potraty, "
"menopauza, antikoncepce, gynekologické operace.\n"
"- Pokud je pacient muž: sekci GA VYNECHEJ (nepiš ji vůbec, ani „neuvedeno").\n"
"- Pohlaví urči z přepisu (oslovení, koncovky, kontext).\n"
"- Potíže s močením NEPATŘÍ do GA — uveď je v NO.\n"
"- Pokud se neřešilo: „neuvedeno".\n\n"
```

### Testing

- Scenario: Male patient transcript → verify GA section is omitted entirely
- Scenario: Children mentioned in SA context → verify they appear in RA
- Scenario: Patient explicitly denies medications → verify "bez pravidelné medikace" (not "neuvedeno")
- Scenario: Transcript contains "chropy" → verify report uses "chrůpky"
- Scenario: Ibuprofen causes GI upset (intolerance) vs anaphylaxis (allergy) → verify correct classification
- Run existing `backend/tests/test_prompt_builder.py` to verify prompt structure unchanged
- Run `backend/tests/test_report_quality.py` to verify report quality maintained

---

## FIX-6: Model Preloading on App Startup

### Problem

First recording after app launch has a delay because Whisper model isn't loaded until user presses Record. This is separate from FIX-1 (which handles the delay by buffering audio) — FIX-6 **eliminates** the delay entirely.

### Solution

Preload the user's selected transcription model during app initialization (after UI renders, in background). By the time the user navigates to the recording screen and presses Record, the model is already loaded.

### Files to Modify

| File | Changes |
|------|---------|
| `mobile/lib/providers/session_provider.dart` | Add `preloadModel()` method; call from `build()` or initialization |
| `mobile/lib/services/whisper_service.dart` | No changes — `loadModel()` already works for preloading |
| `mobile/lib/screens/home_screen.dart` | Trigger preload after first frame renders |

### Implementation

**`session_provider.dart` — Add preload method:**

```dart
/// Preload the Whisper model in background so first recording starts instantly.
/// Safe to call multiple times — no-op if model already loaded.
Future<void> preloadModel() async {
  final selectedModel = _ref.read(transcriptionModelProvider);
  if (selectedModel == TranscriptionModel.cloud) return;  // cloud mode doesn't need on-device model
  
  // Hybrid mode uses small model for live preview
  final config = (selectedModel == TranscriptionModel.turbo)
      ? WhisperService.turboConfig
      : WhisperService.smallConfig;
  
  if (_whisperService.isModelLoaded &&
      _whisperService.modelConfig.dirName == config.dirName) {
    return;  // Already loaded
  }
  
  if (_isPreloading) return;  // Already in progress
  
  _isPreloading = true;
  _whisperService.onDownloadProgress = (String fileName, double progress) {
    if (!mounted) return;
    state = state.copyWith(
      modelDownloadProgress: progress,
      modelDownloadFileName: fileName,
    );
  };
  
  try {
    await _whisperService.loadModel(config: config);
    if (mounted) {
      state = state.copyWith(isModelLoaded: true, clearDownload: true);
    }
  } catch (e) {
    // Non-fatal — model will be loaded on first recording attempt
    WhisperService.debugLog('[SessionNotifier] Preload failed: $e');
  } finally {
    _whisperService.onDownloadProgress = null;
    _isPreloading = false;
  }
}
```

**`home_screen.dart` — Trigger preload:**

```dart
@override
void initState() {
  super.initState();
  // Preload model after first frame to avoid blocking UI
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ref.read(sessionProvider.notifier).preloadModel();
  });
}
```

### Interaction with FIX-1

FIX-1 (audio pre-buffering) and FIX-6 (preloading) are complementary:
- **FIX-6 eliminates the delay in most cases** (model loaded before user presses Record)
- **FIX-1 is the safety net** for edge cases: first-ever launch (model download), model switch in settings, memory pressure causing model eviction

Both should be implemented. FIX-6 reduces the window where FIX-1 matters.

### Testing

- Cold launch: verify model is loaded within ~10s of app startup (visible in debug logs)
- Press Record after preload: verify immediate audio capture (no delay)
- Switch transcription model in settings, return to home: verify new model preloads

---

## FIX-7: Lower VAD Threshold for Final Pass

### Problem

Live VAD threshold (0.5) is appropriate for real-time (avoid transcribing silence), but the final transcription pass uses 0.45 which may still miss quiet speech — especially doctor's soft instructions at the end of consultations.

### Current Values

| Context | Threshold | Purpose |
|---------|-----------|---------|
| Live VAD | 0.5 | Real-time speech detection |
| Final VAD (`extractSpeechSegments`) | 0.45 | Catches quieter speech on final pass |

### Proposed Change

| Context | Current | Proposed | Rationale |
|---------|---------|----------|-----------|
| Live VAD | 0.5 | **0.45** | Slightly more sensitive; catches more speech during live |
| Final VAD | 0.45 | **0.35** | Significantly more sensitive; catches whispered trailing speech |

### Files to Modify

| File | Changes |
|------|---------|
| `mobile/lib/services/whisper_isolate_worker.dart` | Change live VAD threshold (line ~118) from 0.5 to 0.45; change final VAD threshold (line ~178) from 0.45 to 0.35 |

### Risk Assessment

Lower thresholds → more false positives (background noise detected as speech) → more audio sent to Whisper → potentially more hallucinated text (Whisper can hallucinate on silence).

**Mitigation:** Whisper's own internal confidence scoring will produce empty or low-quality text from noise segments, and the LLM (GPT-5-mini) is already trained to handle noisy transcripts. The benefit (capturing real speech) outweighs the risk (occasional noise words).

### Testing

- Record with quiet trailing speech — compare transcript before/after threshold change
- Record in noisy environment — verify no excessive hallucination
- Benchmark on all 6 feedback scenarios — measure CER improvement

---

## FIX-8: Chunked Cloud Transcription for Long Recordings

### Problem

Azure OpenAI Whisper API has a ~25 MB file size limit. At 16 kHz Int16 WAV encoding:
- 25 MB ÷ (16000 samples × 2 bytes) = **~13 minutes** maximum per request
- Medical consultations can run 15–30+ minutes
- Currently the entire audio buffer is sent as a single WAV file — fails silently for long recordings

### Solution

Split long audio into overlapping chunks, transcribe each chunk via cloud API, and deduplicate overlaps.

### Files to Modify

| File | Changes |
|------|---------|
| `mobile/lib/services/cloud_transcription_service.dart` | Add chunked transcription logic with overlap |
| `mobile/lib/services/whisper_service.dart` | Use `removeOverlap()` for chunk boundary deduplication (already exists) |

### Implementation

```dart
/// Max chunk duration in samples (10 minutes to stay well under 25 MB limit)
static const int _maxChunkSamples = 10 * 60 * 16000;  // 9,600,000 samples

/// Overlap between chunks (10 seconds)
static const int _overlapSamples = 10 * 16000;  // 160,000 samples

Future<String> transcribe(List<double> samples) async {
  if (samples.length <= _maxChunkSamples) {
    // Short recording — single request (existing behavior)
    return _transcribeChunk(samples);
  }
  
  // Long recording — chunked transcription
  final parts = <String>[];
  String previousTail = '';
  
  for (int start = 0; start < samples.length; start += _maxChunkSamples - _overlapSamples) {
    final int end = min(start + _maxChunkSamples, samples.length);
    final chunk = samples.sublist(start, end);
    
    final text = await _transcribeChunk(chunk);
    if (text.isEmpty) continue;
    
    final deduped = WhisperService.removeOverlap(previousTail, text);
    if (deduped.isNotEmpty) parts.add(deduped);
    previousTail = WhisperService.lastWords(text, 30);
  }
  
  return parts.join(' ');
}

/// Transcribe a single chunk via Azure OpenAI Whisper API.
Future<String> _transcribeChunk(List<double> samples) async {
  // ... existing transcribe() logic moved here ...
}
```

### Overlap Strategy

10-second overlap between chunks ensures no words are lost at boundaries. `WhisperService.removeOverlap()` (already implemented and battle-tested for on-device transcription) handles deduplication.

### Parallelization Opportunity

Chunks are independent and can be transcribed in parallel using `Future.wait()`:

```dart
// Parallel version (optional optimization):
final futures = <Future<String>>[];
for (int start = 0; start < samples.length; start += _maxChunkSamples - _overlapSamples) {
  final int end = min(start + _maxChunkSamples, samples.length);
  final chunk = samples.sublist(start, end);
  futures.add(_transcribeChunk(chunk));
}
final results = await Future.wait(futures);
// Then deduplicate sequentially
```

**Caution:** Azure OpenAI may rate-limit parallel requests. Start with sequential, add parallelization later if needed.

### Testing

- Record a 20-minute session → verify complete transcript (no truncation)
- Record a 5-minute session → verify single-request path still works
- Verify chunk boundaries don't produce duplicate text
- Measure total latency: sequential chunks vs parallel

---

## Implementation Priority & Sequencing

### Phase 1: Quick Wins (1–2 days)

| Fix | Effort | Impact | Dependencies |
|-----|--------|--------|--------------|
| **FIX-5** Backend prompt corrections | ~1 hour | High — immediate report quality improvement | None |
| **FIX-4** Enhanced cloud Whisper prompt | ~30 min | Medium — better cloud transcription | None |
| **FIX-7** Lower VAD thresholds | ~30 min | Medium — fewer missed segments | None |

These are all configuration/prompt changes — no architectural modifications. Can be deployed independently and tested immediately with Dr. Brož.

### Phase 2: Recording Reliability (2–3 days)

| Fix | Effort | Impact | Dependencies |
|-----|--------|--------|--------------|
| **FIX-1** Audio pre-buffering | ~4 hours | Critical — fixes start delay | None |
| **FIX-2** Audio drain & tail capture | ~4 hours | Critical — fixes end cutoff | None |
| **FIX-6** Model preloading | ~2 hours | High — eliminates cold start | None (complements FIX-1) |

These are the highest-impact code changes. FIX-1 and FIX-2 directly address the two most reported bugs. FIX-6 makes the start delay invisible in normal use.

### Phase 3: Transcription Quality (3–5 days)

| Fix | Effort | Impact | Dependencies |
|-----|--------|--------|--------------|
| **FIX-3** Hybrid transcription mode | ~8 hours | Critical — best quality final transcript | FIX-1 (pre-buffer), FIX-2 (drain) |
| **FIX-8** Chunked cloud transcription | ~4 hours | Medium — supports long recordings | FIX-3 (hybrid mode uses cloud) |

FIX-3 is the biggest architectural change but delivers the most transformative improvement. FIX-8 is needed to support recordings over ~13 minutes in hybrid/cloud mode.

### Deployment Order

```
Day 1:  FIX-5 (backend prompt) + FIX-4 (whisper prompt) + FIX-7 (VAD thresholds)
        → Deploy backend, rebuild mobile app
        → Send to Dr. Brož for quick feedback

Day 2:  FIX-6 (preload) + FIX-1 (pre-buffer) + FIX-2 (drain/tail)
        → Rebuild mobile app
        → Test recording start/stop thoroughly

Day 3-4: FIX-3 (hybrid mode) + FIX-8 (chunked cloud)
          → Full integration testing
          → Send to Dr. Brož for comprehensive feedback
```

### Rollback Strategy

All mobile changes are feature-flagged by transcription model selection:
- Existing `small`, `turbo`, `cloud` modes remain unchanged in behavior
- `hybrid` mode is additive — users can fall back to existing modes
- Backend prompt changes can be reverted by redeploying previous version
- VAD threshold changes can be reverted by changing two constants
