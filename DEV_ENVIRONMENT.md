# Development Environment

Last updated: 23 February 2026

## Mac Hardware

| Property | Value |
|---|---|
| Architecture | x86_64 (Intel) |
| macOS | 13.7.8 Ventura (Build 22H730) |

---

## Core Tools

| Tool | Version | Path | Status |
|---|---|---|---|
| Flutter | 3.27.4 (stable) | `~/Documents/development_flutter/flutter/bin` | ✅ |
| Dart | 3.6.2 | bundled with Flutter | ✅ |
| DevTools | 2.40.3 | bundled with Flutter | ✅ |
| Xcode (full) | ❌ not installed | — | needs install from App Store |
| Xcode CLI Tools | clang 14.0.3 (clang-1403.0.22.14.1) | `/Library/Developer/CommandLineTools` | ✅ |
| Android Studio | ❌ not installed | — | needs install |
| Android SDK / adb | ❌ not installed | — | needs install via Android Studio |

---

## Languages & Runtimes

| Tool | Version | Path | Status |
|---|---|---|---|
| Java (JDK) | OpenJDK 25.0.2 LTS (Temurin) | `/Library/Java/JavaVirtualMachines/temurin-25.jdk` | ⚠️ too new for Gradle — need JDK 17 |
| Ruby | 3.2.4 (2024-04-23) | `/Users/ivananikin/.rbenv/shims/ruby` | ✅ |
| Python | — | — | — |

---

## iOS / macOS Build Tools

| Tool | Version | Path | Status |
|---|---|---|---|
| CocoaPods | 1.16.2 | `/Users/ivananikin/.rbenv/shims/pod` | ✅ |
| rbenv | — | — | ✅ (managing Ruby) |

---

## Test Devices

| Device | OS | API | Notes |
|---|---|---|---|
| Samsung Galaxy S8 (SM-G950F) | Android 9 | API 28 | Serial: RF8JA3GBM9L · IMEI: 359042080544496 · USB debug needed |
| iPhone | iOS — | — | model TBD |

---

## Project — ANOTE Mobile (Phase 2)

| Check | Status |
|---|---|
| `flutter pub get` | ✅ 107 packages resolved |
| `flutter analyze` | ✅ No issues |
| `flutter test` | not yet run |
| `flutter run -d chrome` | not yet run |

---

## Pending Installs (to reach device testing)

- [x] ~~Flutter 3.27.4 stable (Intel/x86_64)~~ ✅ installed
- [ ] Xcode (full, from Mac App Store) — run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` after
- [ ] Android Studio + Android SDK Platform 28 + Build Tools
- [ ] JDK 17 (`brew install temurin@17`) — set as Gradle JDK in Android Studio
- [ ] Enable USB debugging on Galaxy S8

> ⚠️ Flutter 3.27.x is the last version supporting macOS 13 Ventura. Flutter 3.28+ requires macOS 14 Sonoma.

---

## Flutter Doctor Target (all green before device testing)

```
[✓] Flutter           ← done
[✓] Android toolchain
[✓] Xcode
[✓] CocoaPods         ← already ✅
[✓] Connected device
```
