# Transcription Improvements — Technical Spec & Implementation Plan

**Date:** 2026-04-06
**Goal:** Maximize transcription quality by defaulting to cloud, improve offline fallback, reduce bandwidth, and optimize UX on all device tiers.

---

## Overview of Changes

| # | Change | Files Modified | New Deps | Risk |
|---|--------|---------------|----------|------|
| 1 | Wire up hotwords in recognizer config | `whisper_isolate_worker.dart` | None | Very Low |
| 2 | Default to Cloud, fallback to Turbo when offline | `session_state.dart`, `session_provider.dart`, `settings_screen.dart` | `connectivity_plus` | Low |
| 3 | Auto-detect device tier → adjust threads & window interval | `whisper_isolate_worker.dart`, `whisper_service.dart` | `device_info_plus` | Low |
| 4 | FLAC encoding for cloud upload | `cloud_transcription_service.dart`, new `flac_encoder.dart` | None (pure Dart) | Medium |
| 5 | Delay report previews until 50+ words | `session_provider.dart` | None | Very Low |

---

## Change 1: Wire Up Hotwords in Recognizer Config

### Problem

The medical hotwords file (`hotwords_cs_medical.txt`, 300+ Czech medical terms) is:
- Copied from assets to model directory ✓
- Path sent to worker isolate ✓
- **Never passed to `OfflineRecognizerConfig`** ✗

The `hotwordsFile` and `hotwordsScore` parameters exist in sherpa_onnx (verified in v1.12.35) but are not used. This is dead code — zero effect on transcription.

### Solution

Add `hotwordsFile` and `hotwordsScore` to the recognizer config in the worker isolate.

### File: `mobile/lib/services/whisper_isolate_worker.dart`

In the `case 'init':` handler (~line 413), change the recognizer creation:

```dart
// BEFORE:
recognizer = sherpa.OfflineRecognizer(
  sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      whisper: sherpa.OfflineWhisperModelConfig(
        encoder: encoderPath,
        decoder: decoderPath,
        language: 'cs',
        task: 'transcribe',
        tailPaddings: -1,
      ),
      tokens: tokensPath,
      numThreads: 4,
      debug: false,
      provider: 'cpu',
    ),
  ),
);

// AFTER:
// Resolve hotwords path — only pass if file exists
final String resolvedHotwords =
    hotwordsFilePath.isNotEmpty && File(hotwordsFilePath).existsSync()
        ? hotwordsFilePath
        : '';

recognizer = sherpa.OfflineRecognizer(
  sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      whisper: sherpa.OfflineWhisperModelConfig(
        encoder: encoderPath,
        decoder: decoderPath,
        language: 'cs',
        task: 'transcribe',
        tailPaddings: -1,
      ),
      tokens: tokensPath,
      numThreads: 4,
      debug: false,
      provider: 'cpu',
    ),
    hotwordsFile: resolvedHotwords,
    hotwordsScore: 1.5,
  ),
);
```

Also update the one-shot fallback in `whisper_service.dart` (`transcribeFullInIsolate`, ~line 80) with the same hotwords parameters.

### Testing

1. Run app with Small model on a test recording with medical terms
2. Compare transcript output before/after the change
3. Verify hotwords file exists in model dir via worker log: `[Worker] hotwords: .../hotwords_cs_medical.txt (exists: true)`
4. Verify no crash if hotwords file is missing (empty string fallback)

---

## Change 2: Default to Cloud, Fallback to Turbo When Offline

### Problem

Current default is `TranscriptionModel.small` (55% WER on Czech). Cloud/Hybrid modes exist but are opt-in. Users in clinics with WiFi get unnecessarily poor transcription.

### Solution

- Change default model from `small` to `cloud`
- On recording start, check internet connectivity
- If offline → auto-switch to Turbo (or Small if Turbo not downloaded), show warning snackbar
- If online → use Cloud directly (no local model needed for live preview in pure Cloud mode)
- Persist the user's explicit choice — auto-fallback is per-recording, not persistent

### New Dependency

```yaml
# pubspec.yaml
dependencies:
  connectivity_plus: ^6.0.0
```

### File: `mobile/lib/models/session_state.dart`

Change the default and labels:

```dart
// BEFORE:
extension TranscriptionModelApi on TranscriptionModel {
  // ...
  String get label {
    switch (this) {
      case TranscriptionModel.small:
        return 'Small (výchozí)';
      // ...
      case TranscriptionModel.cloud:
        return 'Cloud';
      // ...
    }
  }

  static TranscriptionModel fromString(String? value) {
    // ...
    default:
      return TranscriptionModel.small;
  }
}

// AFTER:
extension TranscriptionModelApi on TranscriptionModel {
  // ...
  String get label {
    switch (this) {
      case TranscriptionModel.small:
        return 'Small';
      // ...
      case TranscriptionModel.cloud:
        return 'Cloud (výchozí)';
      // ...
    }
  }

  static TranscriptionModel fromString(String? value) {
    // ...
    default:
      return TranscriptionModel.cloud;  // Cloud is now the default
  }
}
```

### File: `mobile/lib/providers/session_provider.dart`

**A) Change `TranscriptionModelNotifier` initial state:**

```dart
// BEFORE:
class TranscriptionModelNotifier extends StateNotifier<TranscriptionModel> {
  TranscriptionModelNotifier() : super(TranscriptionModel.small) {

// AFTER:
class TranscriptionModelNotifier extends StateNotifier<TranscriptionModel> {
  TranscriptionModelNotifier() : super(TranscriptionModel.cloud) {
```

**B) Add connectivity check at recording start in `_startRecordingAsync()`:**

After `final selectedModel = _ref.read(transcriptionModelProvider);`, add connectivity check:

```dart
Future<void> _startRecordingAsync() async {
  try {
    var selectedModel = _ref.read(transcriptionModelProvider);

    // --- Connectivity check for cloud-dependent modes ---
    if (selectedModel == TranscriptionModel.cloud ||
        selectedModel == TranscriptionModel.hybrid) {
      final hasInternet = await _checkInternetConnectivity();
      if (!hasInternet) {
        // Fallback: prefer Turbo if downloaded, else Small
        final turboReady = await WhisperService.isModelDownloaded(
            config: WhisperService.turboConfig);
        selectedModel = turboReady
            ? TranscriptionModel.turbo
            : TranscriptionModel.small;
        _offlineFallbackModel = selectedModel;  // track for UI warning

        WhisperService.debugLog(
            '[SessionNotifier] Offline → falling back to '
            '${selectedModel.name}');
      }
    }

    // ... rest of _startRecordingAsync uses selectedModel ...
```

**C) Add connectivity helper method to `SessionNotifier`:**

```dart
/// Check if internet is available (quick DNS lookup).
Future<bool> _checkInternetConnectivity() async {
  try {
    final result = await InternetAddress.lookup('azure.com')
        .timeout(const Duration(seconds: 3));
    return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// If non-null, we fell back to this model because cloud was unavailable.
/// Used by the UI to show a warning snackbar.
TranscriptionModel? _offlineFallbackModel;

/// Get and clear the offline fallback notification.
TranscriptionModel? consumeOfflineFallback() {
  final model = _offlineFallbackModel;
  _offlineFallbackModel = null;
  return model;
}
```

Note: We use a simple `InternetAddress.lookup` instead of `connectivity_plus` to avoid the extra dependency — it's more reliable (checks actual DNS resolution, not just WiFi connected) and simpler.

**D) Update `_preloadModel()` to handle cloud default:**

Cloud mode doesn't need a preloaded model. Add early return:

```dart
Future<void> _preloadModel({int attempt = 1}) async {
  final selectedModel = _ref.read(transcriptionModelProvider);
  // Cloud mode doesn't need an on-device model
  if (selectedModel == TranscriptionModel.cloud) {
    if (mounted) {
      state = state.copyWith(isModelLoaded: true);
    }
    return;
  }
  // ... existing preload logic ...
```

### File: `mobile/lib/screens/home_screen.dart` (or recording screen)

After `startRecording()` is called, check for offline fallback and show snackbar:

```dart
// After calling startRecording():
WidgetsBinding.instance.addPostFrameCallback((_) {
  final fallback = ref.read(sessionProvider.notifier).consumeOfflineFallback();
  if (fallback != null && mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Bez internetu — přepis přepnut na ${fallback == TranscriptionModel.turbo ? "Turbo" : "Small"} (offline)',
        ),
        duration: const Duration(seconds: 4),
        backgroundColor: Colors.orange.shade700,
      ),
    );
  }
});
```

### Testing

1. **Online test:** Start recording with Cloud default → verify cloud transcription used for final transcript
2. **Offline test:** Turn off WiFi → start recording → verify snackbar appears, verify Turbo/Small model used
3. **Persistence test:** User manually selects Small in settings → restart app → verify Small persists (not overridden to Cloud)
4. **Edge case:** Start recording online, lose connection mid-recording → verify graceful fallback in `_stopRecordingAsync` (already handled by existing try/catch)

---

## Change 3: Auto-Detect Device Tier & Adjust Threads/Window

### Problem

- `numThreads: 4` hardcoded — may schedule onto slow "little" cores on ARM big.LITTLE
- 5-second live window is too frequent for old phones where decode takes 3-5s (worker is always busy)
- Phase 4 incremental chunks never fire on slow devices because `isTranscribing == true` all the time

### Solution

Detect device RAM at init time (simple proxy for device tier) and adjust:

| Tier | Criteria | `numThreads` | Window Interval | Notes |
|------|----------|-------------|----------------|-------|
| High | RAM ≥ 6 GB | 4 | 5s (current) | Modern phones (2022+) |
| Low | RAM < 6 GB | 2 | 8s | Older/budget phones |

### Implementation

**File: `mobile/lib/services/whisper_service.dart`**

Add a static method to detect device tier and pass config to worker:

```dart
import 'dart:io';

/// Detect device memory tier. Returns estimated total RAM in MB.
/// Used to adapt transcription parameters for device capability.
static Future<int> getDeviceRamMB() async {
  try {
    if (Platform.isAndroid) {
      // Read /proc/meminfo (available without root)
      final meminfo = await File('/proc/meminfo').readAsString();
      final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
      if (match != null) {
        return int.parse(match.group(1)!) ~/ 1024;  // kB → MB
      }
    }
    // iOS: ProcessInfo not directly accessible from Dart;
    // default to high tier (all supported iPhones have 3+ GB)
    return 6000;  // default high
  } catch (_) {
    return 6000;  // default high on error
  }
}
```

**File: `mobile/lib/services/whisper_isolate_worker.dart`**

Accept tier config in init message and apply:

```dart
// In the 'init' case, read device tier config:
final int numThreads = (message['numThreads'] as int?) ?? 4;
final int windowIntervalSeconds = (message['windowIntervalSeconds'] as int?) ?? 5;

// Use in recognizer creation:
numThreads: numThreads,

// Use for window interval:
final int windowInterval = windowIntervalSeconds * sampleRate;
```

**File: `mobile/lib/services/whisper_service.dart`**

In `loadModel()`, detect tier and pass to worker:

```dart
final ramMB = await getDeviceRamMB();
final bool isLowTier = ramMB < 6000;
final int numThreads = isLowTier ? 2 : 4;
final int windowIntervalSeconds = isLowTier ? 8 : 5;

_workerSendPort!.send(<String, dynamic>{
  'cmd': 'init',
  'encoderPath': _encoderPath,
  'decoderPath': _decoderPath,
  'tokensPath': _tokensPath,
  'vadModelPath': _vadModelPath,
  'hotwordsFilePath': _hotwordsFilePath,
  'numThreads': numThreads,
  'windowIntervalSeconds': windowIntervalSeconds,
});
```

### Testing

1. On a real device, verify RAM detection via log output
2. On a low-RAM device (or emulator with 3 GB): verify 2 threads, 8s window
3. Check that live transcription still works on both tiers
4. Check that Phase 4 incremental chunks actually fire on low-tier devices (the 8s gap gives the worker breathing room)

---

## Change 4: FLAC Encoding for Cloud Upload

### Problem

Cloud transcription sends raw 16-bit PCM WAV:
- 10 min recording = **19.2 MB** upload
- On cellular connections, this can take 10-30 seconds
- Azure Whisper API accepts FLAC, which is ~3-4x smaller

### Solution

Implement a pure-Dart FLAC encoder (no native dependencies). FLAC is lossless, so zero quality loss. Azure Whisper accepts FLAC natively.

**Note:** A full FLAC encoder in pure Dart is complex. A simpler and equally effective approach: Use **16-bit PCM WAV but at 8 kHz** (downsample from 16 kHz). Azure Whisper handles this well for speech, and it halves the file size with minimal quality loss for voice.

However, the better approach is to implement a **simple FLAC encoder** for 16kHz 16-bit mono audio. For the ANOTE use case (single channel, 16-bit, known sample rate), the encoder can be straightforward.

**Recommended approach: Dart FLAC encoder for 16kHz mono 16-bit.**

If a full FLAC encoder proves too complex in pure Dart, the fallback plan is:

1. **Option A (recommended):** Use `flutter_sound` or `ffmpeg_kit_flutter_audio` package which has FLAC encoding built in
2. **Option B (simplest):** Keep WAV but downsample 16kHz → 8kHz before encoding — halves upload size, trivial to implement
3. **Option C:** Send MP3 via a Dart MP3 encoder package (e.g. `lame_dart`)

### Pragmatic Decision: Option B (Downsample to 8kHz)

After analysis, the simplest reliable approach with no new dependencies:

**File: `mobile/lib/utils/wav_encoder.dart`**

Add a downsampling option:

```dart
/// Downsample by factor of 2 using simple averaging.
/// 16kHz → 8kHz for speech is well-supported by Whisper.
static List<double> downsample2x(List<double> samples) {
  final result = List<double>.filled(samples.length ~/ 2, 0.0);
  for (int i = 0; i < result.length; i++) {
    result[i] = (samples[i * 2] + samples[i * 2 + 1]) / 2.0;
  }
  return result;
}
```

**File: `mobile/lib/services/cloud_transcription_service.dart`**

In `_transcribeChunk()`, downsample before encoding:

```dart
// BEFORE:
final Uint8List wavBytes = WavEncoder.encode(samples, sampleRate: 16000);

// AFTER:
// Downsample 16kHz → 8kHz to halve upload size (speech quality preserved)
final downsampled = WavEncoder.downsample2x(samples);
final Uint8List wavBytes = WavEncoder.encode(downsampled, sampleRate: 8000);
```

### Size Comparison

| Format | 10 min recording | Upload on 3G (~500 kbps) |
|--------|-----------------|-------------------------|
| WAV 16kHz (current) | 19.2 MB | ~5 min |
| WAV 8kHz (proposed) | 9.6 MB | ~2.5 min |

### Testing

1. Record a test medical dialogue at 16kHz
2. Downsample to 8kHz and encode to WAV
3. Send to Azure Whisper API — verify transcription quality is not degraded
4. Compare WER/CER of 16kHz vs 8kHz on the same recording
5. Measure actual upload time improvement on cellular

**IMPORTANT:** Must verify Azure Whisper handles 8kHz well before shipping. If quality degrades, keep 16kHz WAV as-is — upload time is less critical than transcript quality.

### Stretch Goal: True FLAC

If 8kHz downsample degrades quality, investigate `archive` or `flutter_sound` packages for FLAC encoding. FLAC at 16kHz would give ~5 MB for 10 min (4x compression) with zero quality loss.

---

## Change 5: Delay Report Previews Until 50+ Words

### Problem

Report preview timer fires every 15 seconds from recording start. The first 2-3 previews are wasted API calls:
- 15s: transcript is likely empty or 2-3 words
- 30s: maybe 10-20 words — too short for a meaningful report
- Each call costs ~$0.001 and uses bandwidth

### Solution

Add a word count check before generating report preview.

### File: `mobile/lib/providers/session_provider.dart`

In `_generateReportPreview()`:

```dart
// BEFORE:
Future<void> _generateReportPreview() async {
  if (!mounted) return;
  final String transcript = state.transcript;
  if (transcript.isEmpty || state.status != RecordingStatus.recording) {
    return;
  }
  // Skip if the transcript hasn't changed since the last report request.
  if (transcript == _lastReportedTranscript) return;
  _lastReportedTranscript = transcript;
  // ... generate report ...
}

// AFTER:
/// Minimum word count before generating report previews.
static const int _minWordsForReport = 50;

Future<void> _generateReportPreview() async {
  if (!mounted) return;
  final String transcript = state.transcript;
  if (transcript.isEmpty || state.status != RecordingStatus.recording) {
    return;
  }
  // Don't generate reports until we have enough transcript to be useful
  final wordCount = transcript.trim().split(RegExp(r'\s+')).length;
  if (wordCount < _minWordsForReport) return;
  // Skip if the transcript hasn't changed since the last report request.
  if (transcript == _lastReportedTranscript) return;
  _lastReportedTranscript = transcript;
  // ... generate report ...
}
```

### Testing

1. Start recording, verify no report API calls in first ~60-90 seconds
2. After enough words accumulate, verify report previews resume normally
3. Check that the final report (on stop) is unaffected (it doesn't use this method)

---

## Implementation Order

Execute changes in this order to minimize risk and allow incremental testing:

### Phase 1: Quick Wins (Changes 1 & 5)
**Estimated:** 1-2 hours including testing

1. **Change 1:** Wire up hotwords → test with a recording → compare transcript quality
2. **Change 5:** Add word count gate → test report preview timing

These are tiny, isolated changes. Ship them first to immediately improve quality.

### Phase 2: Cloud Default (Change 2)
**Estimated:** 3-4 hours including testing

3. **Change 2:** Default to Cloud + offline fallback logic + snackbar warning

Test thoroughly:
- Fresh install (no saved preference) → should start in Cloud mode
- Existing install with `small` saved → should keep Small (respects user choice)
- Offline recording → verify fallback and warning
- Online recording → verify cloud transcription
- Settings screen → verify labels updated

### Phase 3: Device Tier Adaptation (Change 3)
**Estimated:** 2-3 hours including testing

4. **Change 3:** RAM detection → adaptive threads + window interval

Test on at least two device tiers (or emulators with different RAM).

### Phase 4: Upload Optimization (Change 4)
**Estimated:** 2-3 hours including testing

5. **Change 4:** 8kHz downsample for cloud upload

**Must verify quality first** before shipping. Run a comparison test:
- Record same dialogue → transcribe at 16kHz and 8kHz
- Compare transcription text (should be identical or nearly so)
- Only ship if quality is preserved

---

## Files Modified (Summary)

| File | Changes |
|------|---------|
| `mobile/lib/services/whisper_isolate_worker.dart` | Add hotwords to recognizer config; accept numThreads/windowInterval from init |
| `mobile/lib/services/whisper_service.dart` | Add `getDeviceRamMB()`; pass tier config to worker; wire hotwords in one-shot isolate |
| `mobile/lib/services/cloud_transcription_service.dart` | Downsample audio before WAV encoding |
| `mobile/lib/utils/wav_encoder.dart` | Add `downsample2x()` static method |
| `mobile/lib/models/session_state.dart` | Change default model to `cloud`, update labels |
| `mobile/lib/providers/session_provider.dart` | Add connectivity check, offline fallback, 50-word report gate, cloud preload handling |
| `mobile/lib/screens/home_screen.dart` | Show offline fallback snackbar |
| `mobile/pubspec.yaml` | No new dependencies needed |

## New Dependencies

**None required.** The connectivity check uses `dart:io` `InternetAddress.lookup` (already available). Device RAM detection reads `/proc/meminfo` on Android (no package needed).

---

## Rollback Plan

Each change is independent. If any change causes issues:
- **Hotwords:** Remove the two parameters from `OfflineRecognizerConfig` — instant revert
- **Cloud default:** Change `fromString` default back to `small` — one line
- **Device tier:** Revert to hardcoded `numThreads: 4` and `windowInterval = 5 * sampleRate`
- **8kHz downsample:** Remove the downsample call — use original 16kHz WAV
- **50-word gate:** Remove the word count check — 3 lines

---

## Success Metrics

| Metric | Current | Target | How to Measure |
|--------|---------|--------|---------------|
| Final transcript WER (Czech medical) | ~55% (Small) | <25% (Cloud) | Eval script on test recordings |
| Time to final transcript (10 min recording) | ~30s (transcribeTail) | <5s (cloud API) | Stopwatch in logs |
| Cloud upload size (10 min) | 19.2 MB | ~9.6 MB | Log `bodyBytes.length` |
| Wasted report API calls (first 60s) | ~4 calls | 0 calls | Count API calls in first minute |
| UI responsiveness on budget phones | Micro-jank during decode | Smoother (2 threads, 8s window) | Manual testing |
