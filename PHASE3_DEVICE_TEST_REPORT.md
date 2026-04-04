# Phase 3 — Local Device Test Report

**Date:** 2025-01-27  
**Branch:** `copilot/implement-phase-3-audio-transcription`  
**Target:** iOS Simulator (iPhone 15 Pro)  

---

## 1. Toolchain Versions

| Tool            | Version                              |
|-----------------|--------------------------------------|
| Flutter         | 3.27.4 (stable, Dart 3.6.2)         |
| Xcode           | 15.2 (Build 15C500b)                |
| CocoaPods       | 1.16.2                               |
| Ruby            | 3.2.4                                |
| macOS           | 13.7.8 (Intel x86_64)               |
| Android SDK     | Not installed (skipped)              |

## 2. Changes Made

All changes are minimal "make it run / fix bugs" — no new features added.

### 2.1 Dependency Fix (`pubspec.yaml`)

- **Removed** `whisper_flutter_plus: ^1.0.0` — depends on `ffmpeg_dart` which does not exist on pub.dev; `flutter pub get` fails with the remote code.
- **Added** `sherpa_onnx: ^1.12.26` — provides Whisper ONNX inference via native C++ bindings on iOS/Android/desktop.
- **Added** `version: 0.3.0+1` — required by Xcode build (was missing, causing warning).

### 2.2 Whisper Service Rewrite (`whisper_service.dart`)

Rewrote the `loadModel()` and transcriber function to use `sherpa_onnx` instead of the broken `whisper_flutter_plus`:

- **Model:** `sherpa-onnx-whisper-tiny` (int8, ~42 MB total) — downloaded at runtime from HuggingFace, not bundled in assets.
- **Files:** `tiny-encoder.int8.onnx`, `tiny-decoder.int8.onnx`, `tiny-tokens.txt`
- **API used:** `sherpa.OfflineRecognizer` with `OfflineWhisperModelConfig` (language: `cs`, task: `transcribe`, tailPaddings: `800`).
- **Web fallback:** Returns empty string (no native bindings on web).
- **All existing logic preserved:** sliding-window buffering, `feedAudio`, `transcribeFull`, `removeOverlap`, `reset`, `dispose`, test constructor `WhisperService.withTranscriber`.
- **No changes** to `session_provider.dart`, `audio_service.dart`, or any other file in `lib/`.

### 2.3 iOS Configuration

- **Podfile:** Changed deployment target from `12.0` → `13.0` (required by `sherpa_onnx_ios`).
- **iOS project regenerated** via `flutter create --org io.flutter --project-name anote_mobile --platforms ios .` (the `Runner.xcodeproj` and workspace were missing from the repo).
- **Info.plist** already had `NSMicrophoneUsageDescription` and `UIBackgroundModes: [audio]`.

### 2.4 Environment Fixes

- **CocoaPods SSL:** Symlinked `/usr/local/etc/ca-certificates/cert.pem` → `/usr/local/etc/openssl@3/cert.pem` to fix Ruby OpenSSL certificate lookup failure.

## 3. Static Analysis

```
$ flutter analyze
Analyzing anote_mobile...

   info • Prefer const with constant constructors • ... • prefer_const_constructors
   info • Prefer const with constant constructors • ... • prefer_const_constructors
   info • Prefer const with constant constructors • ... • prefer_const_constructors
   info • Prefer const with constant constructors • ... • prefer_const_constructors

4 issues found. (ran in 6.4s)
```

**0 errors, 0 warnings** — only 4 info-level `prefer_const_constructors` hints.

## 4. Unit Tests

```
$ flutter test
00:16 +30: All tests passed!
```

All **30 tests pass** (whisper_service, session_provider, report_service, wav_encoder).

## 5. Build & Run

| Step                    | Result               |
|-------------------------|----------------------|
| `flutter pub get`       | ✅ Resolved          |
| `pod install`           | ✅ 7 pods installed  |
| `flutter run` (debug)   | ✅ Built in ~29 s    |
| App launch on Simulator | ✅ Running           |

**Device:** iPhone 15 Pro Simulator (`DBDB3AC8-057A-4E60-8EDB-4EA06A35A213`)

## 6. Runtime Limitations (Simulator)

The iOS Simulator **does not provide real microphone input**, so the full Phase 3 flow (Record → live transcript → Stop → final transcript → Generate report) cannot be end-to-end tested on simulator. What is confirmed:

- ✅ App compiles and launches without runtime crashes
- ✅ UI renders correctly (Home screen with controls, transcript panel, report panel)
- ✅ Model download logic is in place (will trigger on first "Start Recording")
- ⚠️ Microphone capture requires a physical device
- ⚠️ Whisper transcription quality requires physical device testing

## 7. Files Changed (vs remote HEAD)

```
 mobile/android/app/src/main/java/.../GeneratedPluginRegistrant.java | 5 +
 mobile/ios/Runner/Info.plist                                         | 4 +
 mobile/lib/services/whisper_service.dart                             | 144 +++---
 mobile/pubspec.yaml                                                  | 4 +-
```

Plus untracked iOS project files (regenerated `Runner.xcodeproj`, `Pods/`, etc.).

## 8. Next Steps

1. **Physical iPhone test** — connect a real device to validate microphone capture + Whisper transcription + report generation end-to-end.
2. **Android setup** — install Android SDK + NDK, configure `build.gradle`, test on physical Android device.
3. **Model language config** — currently hardcoded to `cs` (Czech). Consider making language configurable via settings.
4. **Commit & push** the working changes.
