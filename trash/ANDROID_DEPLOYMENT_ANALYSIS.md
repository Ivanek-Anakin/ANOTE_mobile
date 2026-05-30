# Android Deployment Analysis — ANOTE Mobile

**Date:** 1 March 2026  
**Status:** Android Studio installed, SDK ready, Android project Gradle files MISSING

---

## 1. Current Android SDK Installation Summary

| Component | Version | Path |
|-----------|---------|------|
| Android SDK | — | `/Users/ivananikin/Library/Android/sdk` |
| SDK Platform | Android 36.1 (API 36.1) | `platforms/android-36.1` |
| Build-Tools | 36.1.0 | `build-tools/36.1.0` |
| Platform-Tools | 36.0.2 | `platform-tools` |
| Emulator | installed | `emulator` |
| System Image | `google_apis_playstore;x86_64` (API 36.1) | `system-images/android-36.1` |
| Sources | Android 36.1 | `sources/android-36.1` |

**Total download size:** 2.48 GB  
**Virtual device:** x86_64 emulator with Google Play (API 36.1)

---

## 2. Critical Issue: Missing Gradle Build Files

The `mobile/android/` directory is **severely incomplete**. Only 3 files exist:

| File | Status |
|------|--------|
| `android/app/src/main/AndroidManifest.xml` | ✅ Present |
| `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` | ✅ Present (auto-generated) |
| `android/local.properties` | ✅ Present (points to Flutter SDK) |
| `android/build.gradle` | ❌ **MISSING** |
| `android/app/build.gradle` | ❌ **MISSING** |
| `android/settings.gradle` | ❌ **MISSING** |
| `android/gradle.properties` | ❌ **MISSING** |
| `android/gradle/wrapper/gradle-wrapper.properties` | ❌ **MISSING** |
| `android/gradle/wrapper/gradle-wrapper.jar` | ❌ **MISSING** |
| `android/gradlew` | ❌ **MISSING** |
| `android/gradlew.bat` | ❌ **MISSING** |

**Root cause:** The iOS project was regenerated via `flutter create --platforms ios .` during Phase 3, but the equivalent was never done for Android. The Gradle build system is completely absent — **no Android build is possible** until these files are regenerated.

---

## 3. Existing AndroidManifest.xml Analysis

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />   ✅ Required for microphone
<uses-permission android:name="android.permission.INTERNET" />        ✅ Required for backend API
android:label="anote_mobile"                                          ⚠️ Should be "ANOTE" for production
```

**Good:** Core permissions (`RECORD_AUDIO`, `INTERNET`) are already declared.  
**Needs fix:** App label should be changed from `anote_mobile` to `ANOTE` for customer-facing builds.

---

## 4. SDK Version Compatibility Analysis

| Parameter | Recommended Value | Reason |
|-----------|-------------------|--------|
| `minSdkVersion` | **24** (Android 7.0) | `sherpa_onnx` native C++ bindings require API 24+; covers 97%+ of active Android devices |
| `targetSdkVersion` | **34** (Android 14) | Google Play requires targeting API 34+ for new apps (as of Aug 2024); API 36.1 is bleeding edge and may cause compatibility issues |
| `compileSdkVersion` | **34** or **36** | Must be ≥ `targetSdkVersion`; using 34 is safer |
| `buildToolsVersion` | **36.1.0** | Already installed; works with compileSdk 34+ |

**Note on installed SDK Platform (36.1):** This is fine for the emulator and build tools, but you should also install **Android SDK Platform 34** for a stable `targetSdkVersion`/`compileSdkVersion`. Alternatively, target 36 if you want to use the latest, but 34 is the safe production choice.

### Recommended additional SDK install (via SDK Manager)

- **Android SDK Platform 34** — for stable `compileSdkVersion`/`targetSdkVersion`
- **Android NDK (latest)** — required by `sherpa_onnx` (native C++ code via CMake/ndk-build)
- **Android SDK Command-line Tools (latest)** — for `flutter doctor` Android license acceptance

---

## 5. JDK Compatibility

From the Phase 3 report, JDK 25 was installed (too new for Gradle). Status needs verification.

| Scenario | Impact |
|----------|--------|
| JDK 25 only installed | ❌ Gradle will fail — requires JDK 17 |
| JDK 17 installed alongside | ✅ Need to set `JAVA_HOME` correctly |

**Action required:** Verify `java -version` and install JDK 17 if needed (`brew install --cask temurin@17`). Android Studio's bundled JDK may also work — check Android Studio → Settings → Build → Gradle → Gradle JDK.

---

## 6. Flutter SDK Compatibility

| Item | Value |
|------|-------|
| Flutter SDK path | `/Users/ivananikin/Documents/development_flutter/flutter` |
| Flutter version (Phase 3) | 3.27.4 (Dart 3.6.2) |
| pubspec SDK constraint | `>=3.2.0 <4.0.0` |

Should be compatible. Run `flutter --version` to confirm current version.

---

## 7. Native Dependencies — sherpa_onnx Considerations

The app uses `sherpa_onnx: ^1.12.26` for on-device Whisper transcription. This package includes native C++ code that must be compiled for Android via the **NDK**.

| Requirement | Details |
|-------------|---------|
| NDK | Must be installed via SDK Manager |
| CMake | Usually bundled with NDK; needed for native build |
| ABI targets | `arm64-v8a` (most modern phones), `armeabi-v7a` (older), `x86_64` (emulator) |
| Model files | Downloaded at runtime from HuggingFace (~42 MB), not bundled in APK |

**Risk:** First build with NDK may take significantly longer (10–20 min) due to native compilation.

---

## 8. Emulator vs Physical Device Strategy

### Emulator (x86_64, API 36.1 with Google Play)

| Pros | Cons |
|------|------|
| No physical device required | Microphone simulation is tricky (no real audio input by default) |
| Quick iteration for UI testing | sherpa_onnx x86_64 compatibility not verified |
| Google Play for installing test dependencies | Performance may differ from real device |

### Physical Device (Samsung Galaxy S8 — mentioned in checklist)

| Pros | Cons |
|------|------|
| Real microphone, real audio quality | Requires USB debugging setup |
| Actual performance benchmarking | Samsung S8 runs Android 9 (API 28) — old |
| True customer-representative testing | May have storage limitations for model download |

**Recommendation:** Use emulator for UI development/iteration, physical device for final audio + performance validation.

---

## 9. Build, Deploy, Run & Test Plan

### Phase A — Regenerate Android Project (15 min)

1. **Back up existing Android files:**
   ```bash
   cp mobile/android/app/src/main/AndroidManifest.xml /tmp/AndroidManifest.xml.bak
   ```

2. **Regenerate Gradle files:**
   ```bash
   cd mobile
   flutter create --platforms=android .
   ```
   This regenerates all missing Gradle files (`build.gradle`, `settings.gradle`, `gradle.properties`, Gradle wrapper) without overwriting `lib/` or `pubspec.yaml`.

3. **Verify AndroidManifest.xml** still has `RECORD_AUDIO` and `INTERNET` permissions. Restore from backup if overwritten.

4. **Configure build.gradle** (`android/app/build.gradle`):
   - Set `minSdkVersion 24`
   - Set `targetSdkVersion 34`
   - Set `compileSdkVersion 34`
   - Set `applicationId "com.anote.mobile"` (or your desired package name)

5. **Update `local.properties`** — add SDK path:
   ```properties
   sdk.dir=/Users/ivananikin/Library/Android/sdk
   flutter.sdk=/Users/ivananikin/Documents/development_flutter/flutter
   ```

### Phase B — Environment Verification (10 min)

1. **Install additional SDK components** (via Android Studio SDK Manager or CLI):
   ```bash
   sdkmanager "platforms;android-34" "ndk;27.0.12077973" "cmdline-tools;latest"
   ```

2. **Verify JDK:**
   ```bash
   java -version   # Should be 17.x
   ```
   If not JDK 17:
   ```bash
   brew install --cask temurin@17
   export JAVA_HOME=$(/usr/libexec/java_home -v 17)
   ```

3. **Set environment variables** (add to `~/.zshrc` if not already there):
   ```bash
   export ANDROID_HOME=$HOME/Library/Android/sdk
   export PATH=$PATH:$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin
   export JAVA_HOME=$(/usr/libexec/java_home -v 17)
   ```

4. **Accept Android licenses:**
   ```bash
   flutter doctor --android-licenses
   ```

5. **Run Flutter doctor:**
   ```bash
   flutter doctor -v
   ```
   Target: All Android toolchain checks green.

### Phase C — Build Debug APK (10–20 min)

1. **Get dependencies:**
   ```bash
   cd mobile
   flutter pub get
   ```

2. **Build debug APK:**
   ```bash
   flutter build apk --debug
   ```

3. **Expected output:** `build/app/outputs/flutter-apk/app-debug.apk`

4. **Troubleshooting checklist:**
   - If NDK errors → install NDK via SDK Manager
   - If Gradle version errors → ensure JDK 17 and update `gradle-wrapper.properties` distributionUrl
   - If `sherpa_onnx` build fails → check NDK is installed; it needs CMake support
   - If `minSdkVersion` conflict → ensure all plugins support API 24

### Phase D — Run on Emulator (10 min)

1. **Create/start emulator** (if not already created via Android Studio):
   ```bash
   emulator -avd <your_avd_name> &
   ```
   Or launch from Android Studio → Device Manager.

2. **Run app on emulator:**
   ```bash
   flutter run
   ```

3. **Verify on emulator:**
   - [ ] App launches without crashes
   - [ ] UI renders correctly (home screen, settings, demo scenarios)
   - [ ] Theme toggle works (light/dark)
   - [ ] Demo scenario selection and display works
   - [ ] Settings screen — can enter backend URL and token
   - [ ] Network connectivity — backend health check (if backend is running)

4. **Limitations on emulator:**
   - Real microphone recording won't work well → use demo scenarios instead
   - Model download (~42 MB) will work over emulated WiFi

### Phase E — Run on Physical Device (15 min)

1. **Enable USB debugging on device:**
   - Settings → About Phone → tap "Build number" 7× → Developer Mode
   - Settings → Developer Options → enable USB Debugging

2. **Connect device and verify:**
   ```bash
   adb devices
   ```

3. **Run on device:**
   ```bash
   flutter run -d <device_id>
   ```

4. **Full test suite on physical device:**
   - [ ] App launches
   - [ ] Model download completes (needs WiFi, ~42 MB)
   - [ ] Microphone permission prompt appears and grants access
   - [ ] Recording produces Czech transcript (speak Czech into mic)
   - [ ] Report generation sends transcript to backend and returns structured report
   - [ ] Demo scenarios work end-to-end
   - [ ] Copy/paste report text
   - [ ] Fullscreen transcript/report views
   - [ ] App survives backgrounding and returning
   - [ ] Graceful error when backend is unreachable

### Phase F — Build Release APK (10 min)

1. **Build release:**
   ```bash
   flutter build apk --release
   ```

2. **Output:** `build/app/outputs/flutter-apk/app-release.apk`

3. **Expected APK size:** ~30–50 MB (model downloads at runtime, not bundled)

4. **Install and test release build:**
   ```bash
   adb install build/app/outputs/flutter-apk/app-release.apk
   ```

5. **Release-specific checks:**
   - [ ] No debug banner
   - [ ] No console logging visible
   - [ ] Performance is smooth (release mode uses AOT compilation)
   - [ ] Full recording → report flow works

### Phase G — Distribution to Customer (15 min)

Three options ranked by ease:

| Method | Setup Time | Customer Effort | Best For |
|--------|------------|-----------------|----------|
| **Direct transfer** (email/USB/AirDrop) | 0 min | Must enable "unknown sources" | In-person handoff |
| **GitHub Release** (private repo) | 5 min | Download link + enable "unknown sources" | Remote, simple |
| **Firebase App Distribution** | 15 min | Gets email invite, one-tap install | Remote, professional |

---

## 10. Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | `flutter create` overwrites customized `AndroidManifest.xml` | Medium | Low | Back up before running; restore permissions after |
| 2 | `sherpa_onnx` native build fails (NDK/CMake issues) | Medium | High | Ensure NDK is installed; check sherpa_onnx Android compatibility docs |
| 3 | JDK version mismatch causes Gradle failures | High | High | Install JDK 17; set `JAVA_HOME` explicitly |
| 4 | API 36.1 is too bleeding-edge; plugin incompatibilities | Low | Medium | Target/compile against API 34 instead |
| 5 | Samsung Galaxy S8 (API 28) below `minSdkVersion` | Low | High | `minSdkVersion 24` covers it; verify no plugin requires higher |
| 6 | Large model download fails on slow network | Medium | Medium | Model is only ~42 MB; app shows download progress |
| 7 | Emulator audio input limitations hide real bugs | Medium | Medium | Always final-test on physical device with real microphone |
| 8 | `audio_streamer` plugin has Android-specific issues | Low | Medium | Test early on device; check plugin's Android support matrix |

---

## 11. Estimated Timeline

| Phase | Task | Duration |
|-------|------|----------|
| A | Regenerate Android project + configure Gradle | 15 min |
| B | Environment verification (JDK, NDK, licenses, flutter doctor) | 10 min |
| C | Debug APK build (includes native compilation) | 10–20 min |
| D | Emulator testing (UI, demo scenarios) | 10 min |
| E | Physical device testing (full audio pipeline) | 15 min |
| F | Release APK build + verification | 10 min |
| G | Distribution setup | 5–15 min |
| — | **Total (optimistic)** | **~1.5 hours** |
| — | **Total (with troubleshooting)** | **~2.5–3 hours** |

---

## 12. Pre-Build Checklist Summary

Before running any build commands, verify:

- [ ] Android Studio installed and launched at least once
- [ ] `ANDROID_HOME` set to `/Users/ivananikin/Library/Android/sdk`
- [ ] `JAVA_HOME` points to JDK 17
- [ ] Android SDK Platform 34 installed (for target/compile SDK)
- [ ] Android NDK installed (for sherpa_onnx native build)
- [ ] Android SDK Command-line Tools installed (for license acceptance)
- [ ] `flutter doctor -v` shows all Android checks green
- [ ] `mobile/android/` Gradle files regenerated via `flutter create --platforms=android .`
- [ ] `minSdkVersion 24` set in `android/app/build.gradle`
- [ ] `AndroidManifest.xml` has `RECORD_AUDIO` + `INTERNET` permissions
- [ ] `local.properties` has both `sdk.dir` and `flutter.sdk` paths

---

## 13. Key Files Reference

| File | Purpose |
|------|---------|
| `mobile/android/app/build.gradle` | minSdk, targetSdk, compileSdk, applicationId, dependencies |
| `mobile/android/build.gradle` | Top-level Gradle config, repositories, Kotlin version |
| `mobile/android/settings.gradle` | Project includes, plugin management |
| `mobile/android/gradle.properties` | Gradle JVM args, AndroidX opt-in |
| `mobile/android/app/src/main/AndroidManifest.xml` | Permissions, app label, activity config |
| `mobile/android/local.properties` | Local SDK paths (not committed to git) |
| `mobile/lib/config/constants.dart` | Backend URL + token (update for production) |
| `mobile/pubspec.yaml` | App version, dependencies |
