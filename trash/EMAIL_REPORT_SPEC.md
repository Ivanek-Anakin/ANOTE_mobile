# Automatic Email Report — Technical Specification & Implementation Plan

> Send generated medical reports to a configured email address automatically after report completion or regeneration with a new visit type.

---

## 1. Feature Overview

**Goal:** After a medical report is fully generated (on stop-recording or on regenerate with changed visit type), the backend automatically sends the report text to the doctor's configured email address.

**Key Behaviors:**
- First complete report after stop-recording → email sent
- User changes visit type → regenerate → new email sent
- User manually edits report text → no email
- Periodic live preview reports during recording → no email
- Feature is opt-in via a toggle switch in Settings
- Email address is configured in Settings with a text input field

---

## 2. Architecture Decision

**Email is sent by the backend (FastAPI)**, not the mobile app.

Rationale:
- More reliable — no dependency on foreground app state
- SMTP credentials stay server-side, not on device
- Works consistently across iOS and Android
- Backend already receives the final report content via `/report` endpoint

**Flow:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    MOBILE APP                                    │
│                                                                  │
│  1. Report generated (stop or regenerate)                        │
│  2. If email enabled & address configured:                       │
│     POST /send-report-email                                      │
│        { report, visit_type, email }                             │
│                                                                  │
└────────────────────────┬────────────────────────────────────────┘
                         │ HTTPS (Bearer token auth)
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    BACKEND (FastAPI)                              │
│                                                                  │
│  POST /send-report-email                                         │
│  1. Validate request                                             │
│  2. Compose email (plain text, subject with date)                │
│  3. Send via SMTP (env-configured)                               │
│  4. Return { status: "sent" } or error                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                         │ SMTP
                         ▼
                   ┌───────────┐
                   │ Mail      │
                   │ Server    │
                   │ (SMTP)    │
                   └───────────┘
```

---

## 3. Email Trigger Logic

### 3.1 When to Send

The mobile app calls the email endpoint in exactly two scenarios:

| Trigger | Location in Code | Condition |
|---|---|---|
| **Final report on stop** | `_stopRecordingAsync()` in `session_provider.dart` | Report generated successfully AND email enabled AND email address non-empty |
| **Regenerate with new visit type** | `regenerateReport()` in `session_provider.dart` | Report regenerated successfully AND email enabled AND email address non-empty |

### 3.2 When NOT to Send

- During periodic 15-second live preview reports (`_generateReportPreview()`)
- When user manually edits report text in ReportPanel
- When loading a report from recording history
- When email is disabled in settings
- When email address is empty/not configured
- When report generation fails (all 3 retries exhausted)

### 3.3 Deduplication

No deduplication logic needed — the trigger points are naturally exclusive:
- Stop-recording fires once per recording session
- Regenerate fires once per explicit user action (visit type change → tap regenerate)

---

## 4. Backend API

### 4.1 New Endpoint: `POST /send-report-email`

**Request:**
```python
class SendReportEmailRequest(BaseModel):
    report: str              # The full report text
    email: str               # Recipient email address
    visit_type: str = "default"  # For subject line context
```

**Response (success):**
```json
{ "status": "sent" }
```

**Response (errors):**
| Status | Detail |
|---|---|
| 400 | `"Empty report"` — report text is blank |
| 400 | `"Invalid email address"` — basic format validation failed |
| 401 | `"Invalid token"` — auth failure |
| 502 | `"Email delivery failed: {error}"` — SMTP error |

**Authentication:** Same Bearer token as `/report` endpoint.

### 4.2 Email Composition

**Subject:** `ANOTE – Lékařská zpráva – {DD. MM. YYYY}`

**Body:** Plain text — the report content as-is, with a brief header:

```
Lékařská zpráva vygenerovaná aplikací ANOTE
Datum: {DD. MM. YYYY}
Typ návštěvy: {visit type label}

---

{full report text}

---
Tato zpráva byla automaticky odeslána aplikací ANOTE.
```

**Sender:** Configured via environment variable `SMTP_FROM_EMAIL` (e.g., `noreply@anote.cz`).

### 4.3 SMTP Configuration (Environment Variables)

```
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=noreply@anote.cz
SMTP_PASSWORD=secret
SMTP_FROM_EMAIL=noreply@anote.cz
SMTP_USE_TLS=true
```

All SMTP env vars are optional — if `SMTP_HOST` is not set, the endpoint returns `502` with `"Email not configured on server"`. This lets the backend run without email in dev/test environments.

### 4.4 Visit Type Labels (for email subject/body)

```python
VISIT_TYPE_LABELS = {
    "default": "Automatická detekce",
    "initial": "Vstupní vyšetření",
    "followup": "Kontrolní návštěva",
    "gastroscopy": "Gastroskopie",
    "colonoscopy": "Koloskopie",
    "ultrasound": "Ultrazvuk",
}
```

---

## 5. Mobile App Changes

### 5.1 New Settings Fields

Two new fields added to the Settings screen, in a new **"Automatické odesílání zprávy"** section (placed after the Visit Type section):

1. **Switch (toggle):** "Odesílat zprávu e-mailem" — enables/disables the feature
2. **Text input:** "E-mailová adresa" — recipient email address, shown only when switch is ON

**Persistence:** Both stored in `SharedPreferences`:
- `email_report_enabled` → `bool` (default: `false`)
- `email_report_address` → `String` (default: `''`)

SharedPreferences is appropriate here (not FlutterSecureStorage) because an email address is not a secret credential.

### 5.2 New Constants

```dart
// In AppConstants (constants.dart)
static const String emailReportEnabledPrefKey = 'email_report_enabled';
static const String emailReportAddressPrefKey = 'email_report_address';
```

### 5.3 New Riverpod Providers

Two new providers in `session_provider.dart`:

```dart
/// Whether automatic email sending is enabled.
final emailReportEnabledProvider =
    StateNotifierProvider<EmailReportEnabledNotifier, bool>((ref) {
  return EmailReportEnabledNotifier();
});

/// The email address to send reports to.
final emailReportAddressProvider =
    StateNotifierProvider<EmailReportAddressNotifier, String>((ref) {
  return EmailReportAddressNotifier();
});
```

Each notifier loads from and saves to `SharedPreferences`, same pattern as `TranscriptionModelNotifier` and `VisitTypeNotifier`.

### 5.4 New Method in ReportService

```dart
/// Send a generated report to the configured email address.
/// Fire-and-forget — errors are logged but do not block the user.
Future<void> sendReportEmail({
  required String report,
  required String email,
  String visitType = 'default',
}) async {
  final baseUrl = await _getBaseUrl();
  final token = await _getToken();

  await _dio.post(
    '$baseUrl/send-report-email',
    data: {
      'report': report,
      'email': email,
      'visit_type': visitType,
    },
    options: Options(
      headers: {'Authorization': 'Bearer $token'},
    ),
  );
}
```

### 5.5 Email Sending Integration in SessionNotifier

A new private helper method:

```dart
/// Send report via email if the feature is enabled and configured.
/// Fire-and-forget — errors are logged, never shown to user or block flow.
Future<void> _sendEmailIfEnabled(String report) async {
  try {
    final enabled = _ref.read(emailReportEnabledProvider);
    if (!enabled) return;

    final email = _ref.read(emailReportAddressProvider);
    if (email.isEmpty) return;

    final vt = await _getVisitTypeApi();
    await _reportService.sendReportEmail(
      report: report,
      email: email,
      visitType: vt,
    );
    WhisperService.debugLog('[SessionNotifier] Report email sent to $email');
  } catch (e) {
    WhisperService.debugLog('[SessionNotifier] Email send failed: $e');
  }
}
```

**Called from two places:**

1. **`_stopRecordingAsync()`** — after successful final report generation (after the line that sets `state = state.copyWith(report: report, visitTypeChanged: false)`):
   ```dart
   if (report != null && report.isNotEmpty) {
     state = state.copyWith(report: report, visitTypeChanged: false);
     WhisperService.debugLog('[SessionNotifier] Report generated OK.');
     // >>> NEW: send email
     _sendEmailIfEnabled(report);
   }
   ```

2. **`regenerateReport()`** — after successful regeneration:
   ```dart
   state = state.copyWith(
     status: RecordingStatus.idle,
     report: report,
   );
   // >>> NEW: send email
   _sendEmailIfEnabled(report);
   return;
   ```

The email call is fire-and-forget (no `await` on the call site, or `await` wrapped in try-catch). Email failure must never block the recording flow or show an error to the user.

### 5.6 Settings Screen UI

New section inserted after the "Typ návštěvy" divider and before "Rozpoznávání řeči":

```
─────────────────────────────────
Automatické odesílání zprávy       ← section title

[toggle switch] Odesílat zprávu e-mailem

(when enabled:)
┌────────────────────────────────┐
│ E-mailová adresa               │
│ doctor@example.com             │
└────────────────────────────────┘

─────────────────────────────────
```

The email text field:
- `keyboardType: TextInputType.emailAddress`
- Basic client-side validation: non-empty + contains `@` and `.`
- Saves on every change (debounced) or on unfocus, same pattern as other settings
- Stored via the `EmailReportAddressNotifier`

---

## 6. File Changes Summary

| File | Change |
|---|---|
| `backend/main.py` | Add `POST /send-report-email` endpoint, SMTP email sending logic, `SendReportEmailRequest` model, visit type labels map |
| `backend/requirements.txt` | No new deps — Python's `smtplib` + `email` are stdlib |
| `mobile/lib/config/constants.dart` | Add `emailReportEnabledPrefKey`, `emailReportAddressPrefKey` |
| `mobile/lib/providers/session_provider.dart` | Add `emailReportEnabledProvider`, `emailReportAddressProvider`, notifier classes, `_sendEmailIfEnabled()` method, calls in `_stopRecordingAsync()` and `regenerateReport()` |
| `mobile/lib/services/report_service.dart` | Add `sendReportEmail()` method |
| `mobile/lib/screens/settings_screen.dart` | Add email toggle switch + email text field section |

No new files needed. No new Flutter packages needed. No new Python packages needed (uses stdlib `smtplib`).

---

## 7. Implementation Plan

### Phase 1: Backend — Email Endpoint

**Step 1.1: Add SMTP email sending to `backend/main.py`**

- Add `SendReportEmailRequest` Pydantic model
- Add `VISIT_TYPE_LABELS` dictionary
- Add helper function `_send_email(to: str, subject: str, body: str)` using Python `smtplib` + `email.mime.text.MIMEText`
- Read SMTP config from environment variables on startup
- Add `POST /send-report-email` endpoint with:
  - Bearer token auth (reuse existing `verify_token`)
  - Validate non-empty report and basic email format
  - Compose subject: `ANOTE – Lékařská zpráva – {today}`
  - Compose body with header, report text, and footer
  - Call `_send_email()`, catch SMTP errors → 502
  - Return `{"status": "sent"}`

**Step 1.2: Test backend endpoint**

- Test with `MOCK_MODE` / without SMTP configured → graceful 502
- Test with valid SMTP config → email delivered
- Test validation: empty report → 400, bad email → 400, no auth → 401

### Phase 2: Mobile — Settings UI

**Step 2.1: Add constants**

- Add `emailReportEnabledPrefKey` and `emailReportAddressPrefKey` to `AppConstants`

**Step 2.2: Add Riverpod providers**

- Create `EmailReportEnabledNotifier` (bool, loads/saves SharedPreferences)
- Create `EmailReportAddressNotifier` (String, loads/saves SharedPreferences)
- Register as `emailReportEnabledProvider` and `emailReportAddressProvider`

**Step 2.3: Add Settings screen section**

- Add "Automatické odesílání zprávy" section with:
  - `SwitchListTile` for enable/disable
  - `TextField` for email address (shown conditionally when enabled)
  - Basic validation feedback

### Phase 3: Mobile — Email Sending Integration

**Step 3.1: Add `sendReportEmail()` to ReportService**

- New method that POSTs to `/send-report-email`
- Same auth pattern as `generateReport()`

**Step 3.2: Add `_sendEmailIfEnabled()` to SessionNotifier**

- Reads email enabled state and address from providers
- Calls `reportService.sendReportEmail()` fire-and-forget
- Logs success/failure, never throws

**Step 3.3: Wire into report completion triggers**

- Call `_sendEmailIfEnabled(report)` in `_stopRecordingAsync()` after final report success
- Call `_sendEmailIfEnabled(report)` in `regenerateReport()` after regeneration success

### Phase 4: Testing & Verification

**Step 4.1: Backend tests**
- Unit test for email composition (subject, body format)
- Endpoint test: valid request → 200
- Endpoint test: empty report → 400
- Endpoint test: missing SMTP config → 502

**Step 4.2: Mobile integration test**
- Verify settings toggle persists across app restart
- Verify email address persists across app restart
- Verify email is sent on stop-recording (with mock backend)
- Verify email is sent on regenerate (with mock backend)
- Verify email is NOT sent during live preview
- Verify email is NOT sent when toggle is off

---

## 8. Environment Setup Required for Deployment

Before the feature works in production, these env vars must be set on the Azure Container Apps backend:

```bash
SMTP_HOST=<smtp-server>
SMTP_PORT=587
SMTP_USER=<smtp-username>
SMTP_PASSWORD=<smtp-password>
SMTP_FROM_EMAIL=noreply@anote.cz
SMTP_USE_TLS=true
```

Options for SMTP provider:
- **Azure Communication Services Email** (native to Azure, pay-per-email)
- **SendGrid** (generous free tier, simple SMTP relay)
- **Gmail SMTP** (for development/testing only)
- **Any standard SMTP relay**

The feature degrades gracefully — if SMTP is not configured, emails silently fail and the app works normally without them.
