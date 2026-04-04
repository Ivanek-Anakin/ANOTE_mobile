# Production Checklist — ANOTE Mobile

**Goal:** Get the app into a real customer's hands on their Android phone.

**Current state (1 March 2026):**
- ✅ Azure OpenAI resource created: `anote-openai` (West Europe, Standard S0, resource group `ANOTE`)
- ✅ Model deployed: `gpt-4-1-mini` (gpt-4.1-mini, Standard SKU, 30K tokens/min)
- ✅ Model comparison done: gpt-4.1-mini vs gpt-5-mini → gpt-4.1-mini selected (see MODEL_COMPARISON_TEST.md)
- ✅ Report quality tested on 3 Hurvínek + 8 demo scenarios
- Backend code still uses plain `openai.OpenAI` (needs Azure OpenAI switch)
- iOS version tested on physical iPhone via USB cable
- Android SDK / Android Studio **not installed** on this MacBook
- No production backend deployed anywhere yet
- No .apk built yet

---

## Phase 1 — Azure OpenAI Setup

The backend currently uses plain `openai.OpenAI` with `OPENAI_API_KEY`. For production with GDPR compliance (medical data, EU data residency), switch to Azure OpenAI Service in West Europe.

### 1.1 Create Azure OpenAI Resource ✅ DONE

- [x] Log in to [Azure Portal](https://portal.azure.com)
- [x] Create resource: **Azure OpenAI** `anote-openai` in **West Europe** region (Standard S0)
- [x] Deploy model: **gpt-4.1-mini** (deployment name: `gpt-4-1-mini`, Standard SKU, 30K tokens/min)
- [x] Note down:
  - `AZURE_OPENAI_KEY` — from Keys and Endpoint page
  - `AZURE_OPENAI_ENDPOINT` — `https://anote-openai.openai.azure.com`
  - `AZURE_OPENAI_DEPLOYMENT` — `gpt-4-1-mini`
- [ ] (Optional) Submit [Modified Access form](https://aka.ms/oai/modifiedaccess) to opt out of abuse monitoring → zero data retention

### 1.2 Switch Backend Code to Azure OpenAI

File: `backend/main.py`

**Current (dev):**
```python
from openai import OpenAI
client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
CHAT_MODEL = os.environ.get("OPENAI_CHAT_MODEL", "gpt-4o-mini")
```

**Target (production):**
```python
from openai import AzureOpenAI
client = AzureOpenAI(
    api_key=os.environ["AZURE_OPENAI_KEY"],
    api_version="2025-04-01-preview",
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
)
CHAT_MODEL = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4-1-mini")
```

- [ ] Update `from openai import OpenAI` → `from openai import AzureOpenAI`
- [ ] Update client initialization to use `AzureOpenAI(...)` with endpoint + api_version
- [ ] Update env var names: `OPENAI_API_KEY` → `AZURE_OPENAI_KEY`, add `AZURE_OPENAI_ENDPOINT`
- [ ] Update `CHAT_MODEL` env var to `AZURE_OPENAI_DEPLOYMENT`
- [ ] Create a `.env` file with the real Azure values for local testing
- [ ] Generate a real `APP_API_TOKEN` (not `dev-token`) — e.g. `python -c "import secrets; print(secrets.token_urlsafe(32))"`
- [ ] Test locally: `uvicorn main:app --port 8000` → `curl -X POST http://localhost:8000/report ...`

---

## Phase 2 — Deploy Backend to Azure Container Apps

### 2.1 Prerequisites

- [ ] Install Azure CLI: `brew install azure-cli`
- [ ] Login: `az login`
- [ ] Create resource group: `az group create --name anote-rg --location westeurope`

### 2.2 Deploy

```bash
cd backend

az containerapp up \
  --name anote-api \
  --resource-group anote-rg \
  --location westeurope \
  --source . \
  --ingress external \
  --target-port 8000 \
  --env-vars \
    AZURE_OPENAI_KEY=secretref:azure-openai-key \
    AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com \
    AZURE_OPENAI_DEPLOYMENT=gpt-4-1-mini \
    APP_API_TOKEN=secretref:app-api-token
```

- [ ] Run the deploy command
- [ ] Note the assigned URL (e.g. `https://anote-api.westeurope.azurecontainerapps.io`)
- [ ] Set secrets: `az containerapp secret set --name anote-api --resource-group anote-rg --secrets azure-openai-key=YOUR_KEY app-api-token=YOUR_TOKEN`
- [ ] Test health: `curl https://anote-api.westeurope.azurecontainerapps.io/health` → `{"status":"ok"}`
- [ ] Test report endpoint with Bearer token and a sample transcript
- [ ] Restrict CORS origins from `*` to the app only (or remove CORS — mobile apps don't need it)

---

## Phase 3 — Install Android Dependencies on MacBook

Current state: Android Studio and SDK are **not installed**.

### 3.1 Install Android Studio

- [ ] Download Android Studio from https://developer.android.com/studio
- [ ] Install and launch Android Studio
- [ ] Complete the setup wizard (installs Android SDK, SDK Platform-Tools, Emulator)
- [ ] In SDK Manager, install:
  - **Android SDK Platform 28** (Android 9 — matches Samsung Galaxy S8)
  - **Android SDK Platform 34** (latest stable — for targeting)
  - **Android SDK Build-Tools** (latest)
  - **Android SDK Command-line Tools** (latest)
  - **Android NDK** (required by `sherpa_onnx` native code)

### 3.2 Install JDK 17

Current JDK is 25 (too new for Gradle).

```bash
brew install --cask temurin@17
```

- [ ] Install JDK 17
- [ ] Set `JAVA_HOME` in shell config:
  ```bash
  export JAVA_HOME=$(/usr/libexec/java_home -v 17)
  ```
- [ ] Configure Android Studio → Settings → Build → Gradle → Gradle JDK → temurin-17

### 3.3 Set Environment Variables

Add to `~/.zshrc`:
```bash
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/emulator
export PATH=$PATH:$ANDROID_HOME/platform-tools
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
```

- [ ] Add env vars to `~/.zshrc`
- [ ] Run `source ~/.zshrc`

### 3.4 Fix Flutter Android Configuration

The `mobile/android/` directory is incomplete — it's missing Gradle wrapper files, `build.gradle`, `settings.gradle`, etc. These are normally generated by `flutter create`.

- [ ] Regenerate Android project files:
  ```bash
  cd mobile
  flutter create --platforms=android .
  ```
  This will regenerate missing Gradle files without overwriting existing files (`AndroidManifest.xml`, `main.dart`, etc.)
- [ ] Re-add any permissions if overwritten (check `AndroidManifest.xml` still has `RECORD_AUDIO` and `INTERNET`)
- [ ] Set `minSdkVersion` to 24 in `android/app/build.gradle` (sherpa_onnx requires API 24+)
- [ ] Set `targetSdkVersion` to 34

### 3.5 Verify Flutter Doctor

```bash
flutter doctor -v
```

- [ ] All checks green for Android toolchain
- [ ] `flutter doctor` shows Android SDK found
- [ ] `flutter doctor` shows JDK 17

### 3.6 Enable USB Debugging on Samsung Galaxy S8

- [ ] On the phone: Settings → About Phone → tap "Build number" 7 times → Developer Mode enabled
- [ ] Settings → Developer Options → enable **USB Debugging**
- [ ] Connect via USB cable to Mac
- [ ] Accept the RSA key fingerprint dialog on the phone
- [ ] Verify: `adb devices` shows the device (serial: RF8JA3GBM9L)

---

## Phase 4 — Build, Run, Test & Polish Android Version

### 4.1 Run in Debug Mode

```bash
cd mobile
flutter pub get
flutter run -d RF8JA3GBM9L
```

- [ ] App launches on Samsung Galaxy S8
- [ ] Model download works (needs WiFi — ~250 MB)
- [ ] Microphone permission prompt appears and works
- [ ] Recording produces a transcript
- [ ] Report generation works against the production backend

### 4.2 Test Core Flows

- [ ] **Recording flow:** Tap Nahrávat → speak Czech → tap Zastavit → report appears
- [ ] **Demo flow:** Open Demo section → select a Czech scenario → tap Spustit → report generates
- [ ] **Settings:** Change backend URL → save → verify connection test works
- [ ] **Copy/paste:** Copy report → paste elsewhere
- [ ] **Fullscreen views:** Report fullscreen, transcript fullscreen
- [ ] **Theme toggle:** Light ↔ Dark
- [ ] **Error handling:** Turn off WiFi → record → transcript works locally → report shows error gracefully → turn WiFi back on → report generates

### 4.3 Polish for Production

- [ ] Update app name from `anote_mobile` to `ANOTE` in `AndroidManifest.xml` (`android:label`)
- [ ] Create a proper app icon (replace the default Flutter icon)
  - Use [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons) package or manually replace `mipmap` resources
- [ ] Update `defaultBackendUrl` in `lib/config/constants.dart` to the Azure Container Apps URL
- [ ] Update `defaultToken` to the production bearer token
- [ ] Set version in `pubspec.yaml` to `1.0.0+1`
- [ ] Test the full pipeline one more time with production backend

### 4.4 Run Tests

```bash
cd mobile
flutter test
flutter analyze
```

- [ ] All unit tests pass
- [ ] No analyzer warnings

---

## Phase 5 — Build Release .apk & Distribute

### 5.1 Build Release APK

```bash
cd mobile
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

- [ ] Build completes without errors
- [ ] APK size is reasonable (~30–50 MB without bundled model, model downloads on first launch)

### 5.2 Test the Release APK

```bash
adb install build/app/outputs/flutter-apk/app-release.apk
```

- [ ] Install on Samsung Galaxy S8 via adb
- [ ] Full recording → report flow works in release mode
- [ ] No debug banners, no crashes

### 5.3 Upload for Customer Download

**Option A — Firebase App Distribution (recommended)**

Gives you a download link you can share. Free tier is sufficient.

- [ ] Create a Firebase project at https://console.firebase.google.com
- [ ] Install Firebase CLI: `npm install -g firebase-tools` (or `curl -sL https://firebase.tools | bash`)
- [ ] Login: `firebase login`
- [ ] Install the Firebase App Distribution plugin:
  ```bash
  firebase apps:create ANDROID com.anote.mobile --project YOUR_PROJECT_ID
  ```
- [ ] Upload APK:
  ```bash
  firebase appdistribution:distribute build/app/outputs/flutter-apk/app-release.apk \
    --app YOUR_FIREBASE_APP_ID \
    --groups "testers" \
    --release-notes "ANOTE v1.0.0 — first customer test"
  ```
- [ ] Add customer's email to the testers group
- [ ] Customer gets email with download link → taps → installs

**Option B — Direct link via GitHub Releases (simplest)**

- [ ] Create a private GitHub repo (or use existing one)
- [ ] Create a GitHub Release, attach the `app-release.apk` as a release asset
- [ ] Share the direct download link with the customer
- [ ] Customer opens link on phone → downloads .apk → taps to install
- [ ] ⚠️ Customer must enable "Install from unknown sources" in Android settings when prompted

**Option C — Direct sharing (quickest for in-person visit)**

- [ ] Send the `.apk` file via email, WhatsApp, Google Drive, or USB cable
- [ ] Customer opens the file on their Android phone → taps Install
- [ ] ⚠️ Customer must accept "Install from unknown sources" prompt

### 5.4 Customer's Phone Setup (one-time)

When the customer installs for the first time:

1. They'll be prompted to allow "Install from unknown sources" (for Options B/C) — accept
2. App opens → Whisper model starts downloading (~250 MB) → needs WiFi
3. Once model is downloaded, app is fully ready
4. Settings are pre-configured with production backend URL and token

---

## Phase 6 — Pre-Visit Checklist

The day before visiting the customer:

- [ ] Verify Azure backend is running: `curl https://anote-api.westeurope.azurecontainerapps.io/health`
- [ ] Verify a full report generation works end-to-end from your phone
- [ ] Have the .apk ready on your laptop (USB cable as backup install method)
- [ ] Have the download link ready (Firebase/GitHub) to send to customer
- [ ] Ensure customer's phone is Android with Android 7+ (API 24+)
- [ ] Prepare a Czech demo scenario to show if the room is too noisy for live recording
- [ ] Bring USB-C cable (or micro-USB depending on customer's phone) as fallback

---

## Quick Reference — Key Files to Modify

| File | What to change |
|------|----------------|
| `backend/main.py` | Switch `OpenAI` → `AzureOpenAI`, update env vars |
| `backend/.env` | Add real Azure credentials and production token |
| `mobile/lib/config/constants.dart` | Update `defaultBackendUrl` and `defaultToken` |
| `mobile/pubspec.yaml` | Update version to `1.0.0+1` |
| `mobile/android/app/src/main/AndroidManifest.xml` | Update `android:label` to `ANOTE` |
| `mobile/android/app/build.gradle` | Set `minSdkVersion 24`, `targetSdkVersion 34` |

---

## Estimated Time

| Phase | Time |
|-------|------|
| 1. Azure OpenAI setup | 1 hour |
| 2. Deploy backend to Azure | 30 min |
| 3. Install Android dependencies | 1–2 hours (downloads are big) |
| 4. Build, test & polish Android | 2–3 hours |
| 5. Build .apk & upload | 30 min |
| 6. Pre-visit prep | 30 min |
| **Total** | **~6–8 hours** |
