# ANOTE Mobile — Performance Investigation Report

**Date:** 14 March 2026  
**Scope:** UI freeze/lag during audio recording, transcription, and report generation

---

## Executive Summary

The app freezes because **all CPU-intensive speech processing (Whisper inference, Silero VAD, audio buffer manipulation) executes on the main Dart isolate — the same thread that drives the UI**. There are **zero uses of `Isolate`, `compute()`, or any background-thread mechanism** in the entire codebase. Every sherpa_onnx FFI call (model init, VAD `acceptWaveform`, recognizer `decode`) is a synchronous native operation that blocks the Dart event loop, preventing frame rendering and touch-event processing for seconds at a time.

Report generation (the network call to the backend) is properly async and is **not** a primary cause of the freeze, though it shares a minor architectural issue.

---

## Root Causes — Ranked by Probability & Impact

### 1. CRITICAL — Whisper Inference on the Main Thread

**Impact:** Freeze of 5–30+ seconds per transcription window  
**Probability:** Near-certain root cause

The transcriber lambda set in `loadModel()` (`whisper_service.dart` ~line 220) runs entirely on the main isolate:

```dart
_transcriber = (List<double> samples) async {
  final stream = _recognizer!.createStream();
  stream.acceptWaveform(
    samples: Float32List.fromList(samples),  // large alloc + copy
    sampleRate: _sampleRate,
  );
  _recognizer!.decode(stream);  // ← SYNCHRONOUS FFI: blocks UI for seconds
  final result = _recognizer!.getResult(stream);
  stream.free();
  return result.text.trim();
};
```

Despite being wrapped in an `async` function, `_recognizer!.decode(stream)` is a synchronous C++ FFI call through sherpa_onnx. The `async`/`await` does **not** move it off the main thread — it just allows the Dart scheduler to yield *between* await points, but `decode()` itself is one uninterruptible native call that can take 5–30 seconds depending on audio length.

This is called from two places:
- `_transcribeWindow()` — during live recording, every 10 seconds of accumulated speech. Each call transcribes a window of up to ~13 seconds of audio.
- `transcribeFull()` — at recording stop. For a 10-minute recording with multiple 30-second chunks, this runs **multiple sequential** decode calls on the main thread, each blocking for 10–30 seconds.

### 2. CRITICAL — VAD Processing in `feedAudio()` on Every Audio Buffer

**Impact:** Continuous micro-freezes (1–5 ms each, hundreds per second)  
**Probability:** Certain co-factor; aggregates to perceivable jank

`feedAudio()` (`whisper_service.dart` ~line 248) is called for every incoming audio buffer from the microphone:

```dart
void feedAudio(List<double> samples) {
  _rawAudioBuffer.addAll(samples);           // growing list copy
  final floatSamples = Float32List.fromList(  // alloc + copy
    samples.map((s) => s.toDouble()).toList(), // intermediate List<double>
  );
  _vad!.acceptWaveform(floatSamples);         // synchronous FFI call
  while (!_vad!.isEmpty()) {                  // more FFI calls
    final segment = _vad!.front();
    _vad!.pop();
    _speechBuffer.addAll(segment.samples.toList()); // copy
  }
}
```

Problems:
- `_rawAudioBuffer.addAll(samples)` — unbounded growing `List<double>`, causing GC pressure and O(n) reallocations.
- `samples.map((s) => s.toDouble()).toList()` — redundant: `samples` is already `List<double>`. Creates an unnecessary intermediate list.
- `Float32List.fromList(...)` — another copy.
- `_vad!.acceptWaveform()` — synchronous FFI into Silero VAD native code.
- At 16 kHz with typical buffer sizes of 512–4096 samples, this fires **4–31 times per second**, each time blocking the UI thread.

### 3. CRITICAL — Model Initialization Blocks UI at Recording Start

**Impact:** 2–10+ second freeze when pressing "Record" if model isn't preloaded  
**Probability:** High (race condition with preload)

In `_startRecordingAsync()` (`session_provider.dart` ~line 173), if the model isn't loaded yet:

```dart
if (!_whisperService.isModelLoaded) {
  if (!_isPreloading) {
    await _whisperService.loadModel();  // blocks main thread
  } else {
    while (_isPreloading && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
```

`loadModel()` (`whisper_service.dart` ~line 170) performs:
1. `sherpa.initBindings()` — native library initialization (FFI)
2. `_verifyAndCleanModel()` — synchronous `File.existsSync()` and `file.lengthSync()` calls (blocking I/O!)
3. `sherpa.OfflineRecognizer(config)` — allocates native model memory (~250 MB, FFI)
4. `testRecognizer.free()` — native deallocation
5. `sherpa.VoiceActivityDetector(config)` — another FFI allocation
6. Creates the final persistent `_recognizer`

Even when preloading succeeds on app start via `Future.microtask(() => _preloadModel())`, the preload itself runs on the main isolate. If the user taps "Record" before preload finishes, the polling loop introduces a tight 200ms poll, and the preload's heavy FFI work still blocks UI frames.

### 4. HIGH — `_extractSpeechSegments()` + `transcribeFull()` at Stop

**Impact:** Freeze of 10–60+ seconds when stopping a recording  
**Probability:** Certain for recordings > 30 seconds

When the user stops recording, `_stopRecordingAsync()` (`session_provider.dart` ~line 266) calls `_whisperService.transcribeFull()`, which:

1. Calls `_extractSpeechSegments()` (`whisper_service.dart` ~line 432) — creates a **new** `VoiceActivityDetector`, then iterates through the **entire** raw audio buffer in 512-sample windows. For a 10-minute recording (9.6M samples), that's **~18,750 synchronous FFI calls** in a tight loop on the UI thread.
2. Concatenates all speech into a single `List<double>` (massive allocation).
3. Chunks the speech into 30-second windows and calls `_runTranscriber()` on each — **multiple sequential synchronous `decode()` calls** on the main thread.

### 5. MODERATE — Synchronous File I/O in Model Verification

**Impact:** 10–100 ms freeze per call  
**Probability:** Confirmed — `existsSync()` and `lengthSync()` used

In `_verifyAndCleanModel()` and `isModelDownloaded()` (`whisper_service.dart`):

```dart
if (!file.existsSync()) { ... }
final size = file.lengthSync();
```

These are synchronous I/O calls on multi-hundred-megabyte files. While individually small, they add to the blocking chain during `loadModel()`.

### 6. MODERATE — Unbounded Buffer Growth and GC Pressure

**Impact:** Progressive jank over long recordings  
**Probability:** High for recordings > 5 minutes

- `_rawAudioBuffer` in WhisperService is a `List<double>` that grows unboundedly. A 10-minute recording at 16 kHz = 9.6 million doubles = ~77 MB. Each `addAll()` may trigger list reallocation and GC.
- `_speechBuffer` also grows unboundedly.
- `Float32List.fromList(samples)` in `_transcriber` creates a copy of potentially large audio windows (13 seconds = 208K samples = ~832 KB per copy).

### 7. LOW-MODERATE — `TextEditingController` Recreated Every Build

**Impact:** Minor widget inefficiency, possible frame drops  
**Probability:** Observed in code

In `ReportPanel.build()` (`report_panel.dart` ~line 97):

```dart
controller: TextEditingController(text: session.report),
```

A new `TextEditingController` is created on every rebuild. This loses cursor position, selection state, and creates GC churn.

### 8. LOW — Periodic Report Generation Timer During Recording

**Impact:** Potential async contention every 15 seconds  
**Probability:** Low direct impact (it's a network call)

The 15-second `_reportTimer` in `session_provider.dart` (~line 240) triggers `_generateReportPreview()`. The Dio HTTP call is properly async, but each call reads `SharedPreferences` and `FlutterSecureStorage` (both involve platform channels that briefly touch the main thread). Minor but adds up when the main thread is already saturated.

---

## Why the UI Freezes — Technical Explanation

Flutter's UI runs on a single Dart isolate. The Dart event loop must process microtasks, timers, and render frames at 60 fps (16.6 ms per frame). When `_recognizer!.decode(stream)` executes, it calls into native C++ code via FFI. This is not an "async" operation that yields — it occupies the Dart thread synchronously for the entire duration of the Whisper inference (typically 5–30 seconds). During this time:

- No frames are rendered → screen appears frozen
- No touch events are processed → taps are ignored
- No animation callbacks fire → progress indicators stop
- No stream events are handled → audio buffers queue up

The same mechanism applies to VAD calls in `feedAudio()`, but at a smaller scale (each call blocks for 1–5 ms, but they fire 4–31 times per second, consuming 4–155 ms of every second just for VAD).

---

## Files and Functions to Inspect First

| Priority | File | Function/Area | Issue |
|----------|------|--------------|-------|
| P0 | `lib/services/whisper_service.dart` ~line 220 | `_transcriber` lambda | `decode()` FFI blocks UI |
| P0 | `lib/services/whisper_service.dart` ~line 500 | `_transcribeWindow()` | Calls `_runTranscriber` on main thread |
| P0 | `lib/services/whisper_service.dart` ~line 314 | `transcribeFull()` | Multiple sequential `decode()` on main thread |
| P0 | `lib/services/whisper_service.dart` ~line 248 | `feedAudio()` | VAD FFI + buffer copies on every audio callback |
| P0 | `lib/services/whisper_service.dart` ~line 432 | `_extractSpeechSegments()` | Thousands of VAD FFI calls in tight loop |
| P1 | `lib/services/whisper_service.dart` ~line 170 | `loadModel()` | Heavy FFI init on main isolate |
| P1 | `lib/providers/session_provider.dart` ~line 173 | `_startRecordingAsync()` | Awaits model load on main thread |
| P2 | `lib/providers/session_provider.dart` ~line 266 | `_stopRecordingAsync()` | Calls `transcribeFull()` → long UI block |
| P3 | `lib/widgets/report_panel.dart` ~line 97 | `build()` | TextEditingController recreation |

---

## Concrete Fix Strategies

### Strategy A — Move Whisper Inference to a Background Isolate (Primary Fix)

**What:** Use `Isolate.spawn` or Flutter's `compute()` to run all sherpa_onnx operations (model init, VAD, decode) in a separate isolate. Communication via `SendPort`/`ReceivePort` or a message-passing wrapper.

**Challenge:** sherpa_onnx native pointers can't be sent between isolates. The entire recognizer lifecycle must live within the background isolate. This requires an "inference worker" pattern:

```
Main Isolate                   Worker Isolate
─────────────                  ──────────────
SendPort ──── "init" ────────► loadModel(), create recognizer
SendPort ──── audio samples ──► feedAudio() + VAD + transcribeWindow()
ReceivePort ◄──── transcript ── send back text
SendPort ──── "transcribeFull"► run full pass
ReceivePort ◄──── final text ── send back text
SendPort ──── "dispose" ──────► free resources
```

**Impact:** Eliminates all UI freezing during recording, transcription, and model loading. This is the **single most impactful change**.

### Strategy B — Isolate for `transcribeFull()` Only (Quick Win)

**What:** At minimum, move `transcribeFull()` to a separate isolate. Since it creates its own VAD instance and could create a fresh recognizer, it can work independently.

**Implementation:** Create a top-level function that accepts model file paths and raw audio bytes, initializes a fresh recognizer inside the new isolate, and returns the transcript string.

**Impact:** Fixes the freeze at recording stop. Does not fix live recording jank.

### Strategy C — Debounce/Batch `feedAudio()` (Quick Win)

**What:** Instead of calling VAD on every audio buffer, accumulate buffers and process them in batches (e.g., every 500 ms) using a `Timer` or similar debounce. This reduces the number of main-thread FFI calls from ~30/sec to ~2/sec.

**Implementation:**
```dart
Timer? _batchTimer;
final List<double> _pendingAudio = [];

void feedAudio(List<double> samples) {
  _pendingAudio.addAll(samples);
  _batchTimer ??= Timer(Duration(milliseconds: 500), _processBatch);
}
```

**Impact:** Reduces continuous micro-jank during recording. Still blocks the UI during actual `decode()`.

### Strategy D — Pre-allocated Ring Buffer for Audio (Medium)

**What:** Replace the unbounded `_rawAudioBuffer` and `_speechBuffer` with pre-allocated `Float32List` ring buffers sized for maximum recording duration. Eliminates GC pressure from list growth.

**Impact:** Reduces GC-induced frame drops during long recordings.

### Strategy E — Fix Synchronous I/O (Quick Win)

**What:** Replace `file.existsSync()` and `file.lengthSync()` with `await file.exists()` and `await file.length()` throughout model verification.

**Impact:** Eliminates 10–100 ms blocking during model init path.

### Strategy F — Fix `TextEditingController` in ReportPanel (Quick Win)

**What:** Make `ReportPanel` a `ConsumerStatefulWidget`, hold the controller in state, and update it when the report changes via `didChangeDependencies` or a `ref.listen`.

**Impact:** Eliminates minor widget rebuild waste.

---

## Quick Wins vs Deeper Architectural Improvements

### Quick Wins (hours, no architecture change)

| Fix | Effort | Impact |
|-----|--------|--------|
| Replace `existsSync`/`lengthSync` with async variants | 30 min | Removes file I/O blocking |
| Eliminate redundant `.map((s) => s.toDouble()).toList()` in `feedAudio` | 15 min | Removes unnecessary allocation |
| Batch/debounce `feedAudio` VAD calls | 1–2 hours | Reduces micro-jank during recording |
| Fix TextEditingController in ReportPanel | 30 min | Eliminates minor rebuild waste |
| Add timing instrumentation (see below) | 1 hour | Enables data-driven optimization |

### Medium Effort (1–2 days)

| Fix | Effort | Impact |
|-----|--------|--------|
| Move `transcribeFull()` to a spawned isolate | 1 day | Eliminates freeze at recording stop |
| Pre-allocated audio buffers | 4 hours | Reduces GC pressure |
| Throttle transcript stream updates to 1/sec | 1 hour | Fewer state rebuilds during recording |

### Deep Architectural (3–5 days)

| Fix | Effort | Impact |
|-----|--------|--------|
| Full worker-isolate for all sherpa_onnx operations | 3–5 days | **Eliminates all freezing completely** |
| Model preload in isolate at app start | Part of above | No freeze if model needed at record start |

---

## Missing Observability / Debugging to Add

### 1. Timing Instrumentation

Add `Stopwatch` measurements at these critical points:

```dart
// In _transcriber lambda:
final sw = Stopwatch()..start();
_recognizer!.decode(stream);
debugLog('[PERF] decode() took ${sw.elapsedMilliseconds}ms for ${samples.length} samples');

// In feedAudio():
final sw = Stopwatch()..start();
_vad!.acceptWaveform(floatSamples);
debugLog('[PERF] VAD acceptWaveform took ${sw.elapsedMilliseconds}ms');

// In _extractSpeechSegments():
final sw = Stopwatch()..start();
// ... loop ...
debugLog('[PERF] extractSpeechSegments took ${sw.elapsedMilliseconds}ms for ${rawAudio.length} samples');

// In loadModel():
final sw = Stopwatch()..start();
_recognizer = sherpa.OfflineRecognizer(_buildRecognizerConfig());
debugLog('[PERF] recognizer creation took ${sw.elapsedMilliseconds}ms');
```

### 2. Frame Timing / Jank Detection

```dart
// In main.dart:
WidgetsBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
  for (final t in timings) {
    final buildMs = t.buildDuration.inMilliseconds;
    final rasterMs = t.rasterDuration.inMilliseconds;
    if (buildMs > 16 || rasterMs > 16) {
      print('[JANK] build=${buildMs}ms raster=${rasterMs}ms');
    }
  }
});
```

### 3. Buffer Size Monitoring

```dart
// Periodically log buffer sizes during recording:
debugLog('[MEM] rawAudioBuffer: ${_rawAudioBuffer.length} samples '
    '(${(_rawAudioBuffer.length * 8 / 1024 / 1024).toStringAsFixed(1)} MB)');
```

### 4. Flutter DevTools Profiling

- Run with `flutter run --profile` on a physical device
- Use the **Timeline** view to see exact frame durations
- Use the **CPU Profiler** to confirm which FFI calls dominate

### 5. State Rebuild Counter

```dart
// Temporarily in HomeScreen.build():
debugLog('[REBUILD] HomeScreen build #${++_buildCount}');
```

---

## Summary

The app has a **single-threaded architecture** for what is fundamentally a **multi-threaded workload**. All three heavy operations (VAD, Whisper decode, model init) are C++ FFI calls that block the Dart event loop. The `async`/`await` keywords provide no relief because the actual native computation is synchronous — there are no yield points within the FFI calls.

Report generation itself is not a separate bottleneck — it's a standard HTTP call via `Dio` that works correctly. However, when `_stopRecordingAsync()` runs `transcribeFull()` *then* `generateReport()` sequentially, the combined freeze (transcription blocking + network latency) can exceed 60 seconds.

The **single highest-impact fix** is moving sherpa_onnx operations (model loading, VAD, decode) to a dedicated worker isolate. This one change would eliminate all observed freezing without altering any functionality.
