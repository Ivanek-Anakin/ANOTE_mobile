# UI Freeze Fix — Investigation & Implementation Plan

## Investigation Findings

### Root Cause

The app freezes because **all CPU-intensive speech processing runs on the main Dart isolate** — the same thread that drives the UI. Dart is single-threaded; synchronous native FFI calls block the event loop, preventing frame rendering and touch processing. There are **zero uses of `Isolate`, `compute()`, or any background-thread mechanism** in the entire codebase.

### Confirmed Freeze Sources (ranked by severity)

#### 1. CRITICAL — `decode()` on UI thread (5–30s freeze per call)

`whisper_service.dart` ~line 260, the `_transcriber` lambda:

```dart
_transcriber = (List<double> samples) async {
  final stream = _recognizer!.createStream();
  stream.acceptWaveform(
    samples: Float32List.fromList(samples),
    sampleRate: _sampleRate,
  );
  _recognizer!.decode(stream);        // ← SYNCHRONOUS C++ FFI — blocks UI 5-30s
  final result = _recognizer!.getResult(stream);
  stream.free();
  return result.text.trim();
};
```

Despite the `async` wrapper, `decode()` is a synchronous C++ FFI call with no yield point. It blocks the entire Dart event loop for 5–30 seconds depending on audio chunk length.

**Called from two places:**
- `_transcribeWindow()` — during live recording, every 10s of accumulated speech
- `transcribeFull()` — at recording stop, multiple sequential decode calls

#### 2. CRITICAL — `_extractSpeechSegments()` at stop (10–60s freeze)

`whisper_service.dart` ~line 448. A tight loop processes the entire raw audio buffer in 512-sample windows using synchronous VAD FFI. For a 5-minute recording (~4.8M samples), that's ~9,400 synchronous FFI calls on the UI thread, followed by multiple sequential `decode()` calls.

#### 3. CRITICAL — `transcribeFull()` chunked decoding

`whisper_service.dart` ~line 350. After VAD extraction, speech is chunked into 30s windows and each is decoded sequentially — multiple 10–30s synchronous blocks back-to-back on the UI thread.

#### 4. MODERATE — `feedAudio()` micro-jank

`whisper_service.dart` ~line 278. Every mic callback (~4-31 times/sec) runs:
- Redundant `samples.map((s) => s.toDouble()).toList()` — samples are already `List<double>`
- `Float32List.fromList(...)` — another copy
- `_vad!.acceptWaveform()` — synchronous FFI (~1-5ms each)
- Unbounded `_rawAudioBuffer.addAll(samples)` — growing list, GC pressure

#### 5. LOW — Synchronous file I/O in model verification

`file.existsSync()` and `file.lengthSync()` on multi-hundred-MB files in `_verifyAndCleanModel()` and `isModelDownloaded()`. Blocks 10–100ms per call.

#### 6. LOW — TextEditingController recreation

`report_panel.dart` ~line 97 creates a new `TextEditingController(text: session.report)` on every widget build, losing cursor position and creating GC churn.

### Not a Problem

- **Report generation** — `ReportService.generateReport()` is a proper async HTTP call via Dio. No freeze contribution.
- **Demo mode** — loads text from assets, no Whisper involved.

---

## Implementation Plan — 3 Phases

### Phase 1: Quick Wins (2–3 hours)

Safe, low-risk changes that reduce jank with no architectural change.

| # | Change | File | Lines |
|---|--------|------|-------|
| 1.1 | Remove redundant `.map((s) => s.toDouble()).toList()` in `feedAudio()` — samples are already `List<double>` | `lib/services/whisper_service.dart` | ~286-288 |
| 1.2 | Replace `existsSync()`/`lengthSync()` with async `exists()`/`length()` in `_verifyAndCleanModel()` and `isModelDownloaded()` | `lib/services/whisper_service.dart` | ~113-130, ~149-165 |
| 1.3 | Fix `TextEditingController` in `ReportPanel` — convert to `ConsumerStatefulWidget`, hold controller in state | `lib/widgets/report_panel.dart` | ~97 |
| 1.4 | Add `Stopwatch` timing instrumentation around `decode()`, `acceptWaveform()`, `_extractSpeechSegments()`, `loadModel()` | `lib/services/whisper_service.dart` | multiple |
| 1.5 | Reduce `_windowInterval` from 10s to 5s so each `decode()` processes less audio → shorter per-call freeze | `lib/services/whisper_service.dart` | ~30 |

### Phase 2: Isolate for `transcribeFull()` (4–6 hours)

Move the stop-recording freeze off the UI thread. Biggest user-visible improvement for least effort.

**Approach:**
- Create a top-level function `_transcribeFullInIsolate(Map<String, dynamic> params)` that:
  1. Calls `sherpa.initBindings()`
  2. Creates a fresh `VoiceActivityDetector` and `OfflineRecognizer` inside the isolate
  3. Runs `_extractSpeechSegments()` + chunked decoding (same algorithm, same parameters)
  4. Frees resources and returns the transcript string
- In `transcribeFull()`, call `Isolate.run()` passing model file paths + raw audio as `Float32List`
- The new isolate does all heavy work; UI thread stays responsive

**Key constraint:** `sherpa.OfflineRecognizer` uses native FFI pointers that cannot cross isolate boundaries — the recognizer must be created **inside** the spawned isolate. This means a fresh model load (~2-3s overhead), but only happens once at recording stop.

**What this fixes:** The 10–60+ second freeze when stopping a recording.
**What this doesn't fix:** Live recording freezes (every 10s when `_transcribeWindow()` fires).

### Phase 3: Persistent Worker Isolate for ALL Whisper/VAD (1–2 days)

The definitive fix. All sherpa_onnx operations move to a long-lived background isolate.

**Architecture:**
```
Main Isolate (UI)                     Worker Isolate
──────────────────                    ──────────────────
                  ── "init" ────────► sherpa.initBindings()
                                      create recognizer + VAD
                  ◄── "ready" ──────

feedAudio(samples)── audio ─────────► vad.acceptWaveform()
                                      buffer speech
                                      if enough speech: decode()
                  ◄── transcript ───  send text back

transcribeFull()  ── "fullPass" ────► extractSpeechSegments()
                                      chunk + decode all
                  ◄── finalText ────  send text back

dispose()         ── "dispose" ─────► recognizer.free(), vad.free()
                                      isolate exits
```

**Implementation steps:**

1. **Create `WhisperIsolateWorker` class** — manages `Isolate.spawn()`, `SendPort`/`ReceivePort` pair, message protocol.

2. **Define message types:**
   ```dart
   enum WorkerCommand { init, feedAudio, transcribeFull, reset, dispose }
   ```

3. **Worker isolate entry point** (top-level function):
   - Receives `SendPort` from main isolate
   - Creates its own `ReceivePort`, sends it back
   - Listens for messages
   - Owns `_recognizer`, `_vad`, all audio buffers (`_speechBuffer`, `_rawAudioBuffer`)
   - Sends transcript strings back to main isolate
   - All VAD processing, buffering, `_transcribeWindow()`, and `transcribeFull()` run here

4. **Modify `WhisperService` to be a thin facade:**
   - `loadModel()` → spawns worker isolate, sends "init" command with model paths, awaits "ready"
   - `feedAudio()` → sends audio samples via `SendPort` (fire-and-forget; worker sends transcript updates back when ready)
   - `transcribeFull()` → sends command, awaits response via `Completer`
   - `reset()` → sends "reset" command
   - `dispose()` → sends "dispose", kills isolate

5. **Handle transcript stream** — worker sends transcript updates via `SendPort`; main isolate forwards to `_transcriptController`

6. **Use `TransferableTypedData`** for zero-copy `Float32List` transfer between isolates

**Key technical details:**
- `Float32List` transfers efficiently between isolates via `TransferableTypedData`
- Model paths are plain strings — transfer fine
- Worker isolate must be **long-lived** (not `compute()`), because creating a fresh recognizer each time costs 2-3s
- `SendPort` guarantees FIFO ordering — no message reordering risk
- Worker processes messages sequentially — natural guard against concurrent `_transcribeWindow()` calls

**What this fixes:** ALL freezing — during recording, at stop, and during model load.

---

## Quality Preservation Guarantee

This is a **mechanical refactoring** — moving computation to a different thread. The algorithm, models, parameters, and data flow are unchanged:

- Same Whisper model files, same `OfflineRecognizerConfig`
- Same VAD parameters (threshold 0.5/0.45, minSilence 0.5, minSpeech 0.25, windowSize 512)
- Same chunking logic (30s windows, 5s overlap for `transcribeFull`; 10s windows, 3s overlap for live)
- Same `removeOverlap()` deduplication
- Same `transcribeFull()` as final authoritative transcript
- Report generation untouched (already async HTTP)
- Demo mode untouched

**Verification:** Record the same audio before and after — `transcribeFull()` output should be character-for-character identical (same input → same model → same output).

---

## Files to Modify

| File | Phase | Changes |
|------|-------|---------|
| `mobile/lib/services/whisper_service.dart` | 1, 2, 3 | Main target — quick wins, then isolate refactor |
| `mobile/lib/widgets/report_panel.dart` | 1 | TextEditingController fix |
| `mobile/lib/providers/session_provider.dart` | 3 | Minor — adapt to async `loadModel()` if needed |
| `mobile/lib/services/audio_service.dart` | — | No changes needed |
| `mobile/lib/services/report_service.dart` | — | No changes needed |

## Tests to Update

| File | Why |
|------|-----|
| `mobile/test/services/whisper_service_test.dart` | May need to mock isolate communication |
| `mobile/test/providers/session_provider_test.dart` | May need to await async model load |
