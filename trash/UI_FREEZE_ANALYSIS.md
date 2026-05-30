# UI Freeze Analysis — ANOTE Mobile

## Problem

When recording starts, the app freezes for dozens of seconds — unable to navigate or tap anything. The root cause is that **all heavy CPU work (Whisper decode, VAD) runs on the main (UI) isolate**. Dart is single-threaded; synchronous native FFI calls block the event loop, preventing frame rendering and touch processing.

---

## Root Causes

### 1. Whisper `decode()` is synchronous FFI on the main thread — THE KILLER

In `mobile/lib/services/whisper_service.dart` (line ~253), the transcriber function:

```dart
_transcriber = (List<double> samples) async {
  final stream = _recognizer!.createStream();
  stream.acceptWaveform(
    samples: Float32List.fromList(samples),
    sampleRate: _sampleRate,
  );
  _recognizer!.decode(stream);        // ← SYNCHRONOUS native FFI call
  final result = _recognizer!.getResult(stream);
  stream.free();
  return result.text.trim();
};
```

Despite the `async` wrapper, **there is no `await` inside** — `decode()` is a synchronous C/C++ FFI call that blocks the Dart event loop entirely. Whisper Small INT8 decoding takes **5–30+ seconds** depending on chunk length and device. During this time, zero frames render and zero touch events process.

This is triggered in two places:

- **During recording**: `_transcribeWindow()` fires every time 10s of speech accumulates (line ~490), called directly from `feedAudio()` which runs on the main isolate's audio stream listener.
- **On stop**: `transcribeFull()` (line ~312) re-processes ALL audio with fresh VAD + multi-chunk Whisper decoding — multiple sequential synchronous decodes.

### 2. VAD processing in `feedAudio()` is synchronous on the main thread

In `feedAudio()` (line ~278), every audio buffer from the mic goes through:

```dart
_vad!.acceptWaveform(floatSamples);  // synchronous native FFI
while (!_vad!.isEmpty()) {
  final segment = _vad!.front();     // synchronous native FFI
  _vad!.pop();
  ...
}
```

VAD is lightweight (~1ms per call), but it runs on every mic callback (~every 50ms). This alone won't freeze the UI, but combined with other work it contributes to jank.

### 3. `_extractSpeechSegments()` in `transcribeFull()` — heavy synchronous loop

In `_extractSpeechSegments()` (line ~441), a fresh VAD instance processes the **entire raw audio buffer** in 512-sample windows, synchronously. For a 5-minute recording (~4.8M samples), that's ~9,400 synchronous FFI calls in a tight loop — all on the main thread.

### 4. Large memory copies on the main thread

Multiple `Float32List.fromList(samples)` calls create large buffer copies synchronously. For `transcribeFull()` with minutes of audio, this means allocating and copying tens of MB on the main isolate.

### 5. Report generation — NOT a freeze cause

`ReportService.generateReport()` is a proper async HTTP call via Dio. The periodic timer fires every 15s and the HTTP call awaits properly. Report generation is fine.

---

## Proposed Solutions

### Solution A: Dedicated Background Isolate for Whisper + VAD (RECOMMENDED)

Move all Whisper and VAD work to a **persistent long-lived background isolate**. This is the only real fix.

**Architecture:**

```
Main Isolate (UI)                  Background Isolate
──────────────────                 ──────────────────
feedAudio(samples) ──SendPort──→  VAD + buffer accumulation
                                  _transcribeWindow() → decode()
                   ←─SendPort──   transcript string result

transcribeFull()   ──SendPort──→  VAD extraction + chunk decode
                   ←─SendPort──   final transcript string
```

**Implementation approach:**

1. Create a `WhisperIsolate` class that spawns a long-lived isolate on `loadModel()`.
2. The background isolate loads the Whisper recognizer and VAD (model files are on disk — path strings transfer fine between isolates).
3. `feedAudio()` sends raw PCM samples to the background isolate via `SendPort`.
4. The background isolate runs VAD + buffering + transcription; sends transcript strings back.
5. `transcribeFull()` sends a command to the background isolate and awaits the result via a `Completer`.
6. The main isolate never touches sherpa_onnx FFI — it just sends audio and receives text.

**Key constraint:** `sherpa.OfflineRecognizer` and `sherpa.VoiceActivityDetector` are FFI objects with native pointers — they **cannot be passed between isolates**. They must be **created inside** the background isolate. This is why you need a persistent worker isolate, not `compute()` (which creates a new isolate each time).

**Dart API to use:** `Isolate.spawn()` + `SendPort`/`ReceivePort`, or the `IsolateChannel` pattern. No third-party packages needed.

### Solution B: `compute()` for `transcribeFull()` only (simpler, partial fix)

If Solution A is too complex for an initial fix, at minimum move `transcribeFull()` to a one-shot isolate via Flutter's `compute()`:

```dart
final transcript = await compute(_transcribeFullInIsolate, {
  'rawAudio': rawAudioBuffer,
  'encoderPath': _encoderPath,
  'decoderPath': _decoderPath,
  'tokensPath': _tokensPath,
  'vadModelPath': _vadModelPath,
});
```

The top-level function creates a fresh recognizer + VAD inside the isolate, processes audio, frees resources, and returns the string. This fixes the stop-recording freeze but **not** the live-recording freeze (since `_transcribeWindow()` still runs on main).

### Solution C: Throttle live transcription window size

Reduce the `_windowInterval` from 10s to something shorter (e.g., 5s) so each `decode()` call processes less audio and blocks for less time. This doesn't eliminate the freeze but shortens it. Combined with Solution A, this becomes irrelevant.

### Solution D: Show explicit "processing" UI state during decode

This doesn't fix the freeze but manages expectations — currently the UI gives no feedback during decode. Adding a processing indicator that renders *before* the synchronous call starts would at least communicate what's happening. However, since the main thread is blocked, even this indicator won't animate.

---

## Priority Recommendation

| Priority | What | Impact | Effort |
|----------|------|--------|--------|
| **P0** | Background isolate for all Whisper/VAD work (Solution A) | Eliminates all freezes | Medium-high (~1-2 days) |
| **P1** | `compute()` for `transcribeFull()` (Solution B) | Fixes stop-recording freeze | Low (~2-4 hours) |
| **P2** | Reduce window interval (Solution C) | Shortens live freeze | Trivial |

**Recommendation:** Implement Solution A — a persistent background isolate. It's the only approach that makes the app genuinely responsive during recording. The audio stream listener on the main isolate should do nothing but forward samples to the background isolate via `SendPort`. All VAD, buffering, and Whisper decoding happen off the UI thread.

The report generation path is already non-blocking and needs no changes.
