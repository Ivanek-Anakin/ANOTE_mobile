# ANOTE UI Redesign — Technical Spec & Implementation Plan

## Design: Option C "Full Immersion"

### Visual Reference
See `mockups/option_c.html` for the interactive prototype.

---

## 1. Layout Overview

```
┌─────────────────────────────┐
│ ANOTE                    ⚙️ │  ← Minimal AppBar (no emoji, no theme toggle)
│                             │
│ ┌─────────────────────────┐ │
│ │                         │ │
│ │  Single content card    │ │  ← 1px border, 24px radius, ~85% screen
│ │  (Report OR Transcript) │ │     Editable TextField (report)
│ │                         │ │     or SelectableText (transcript)
│ │                         │ │
│ │                         │ │
│ │                         │ │
│ └─────────────────────────┘ │
│ [Přepis/Odeslat]       📋  │  ← Action row below card
│                             │
│        🔴 Nahrávání...      │  ← Recording label (conditional)
│           ( ● )             │  ← 72px FAB, green→red with pulse
│                             │
└─────────────────────────────┘
```

---

## 2. State Machine — Bottom-Left Button & Content Card

| App State | Card Shows | Left Button | Right Button |
|-----------|-----------|-------------|--------------|
| **Idle, no content** | Report (empty placeholder) | — (hidden) | — (hidden) |
| **Recording** | Transcript (live) | `Přepis` label visible but shows transcript already | 📋 copy transcript |
| **Processing** | Transcript + spinner | — | 📋 |
| **Report generated (not yet edited)** | Report | `Přepis` → toggles to transcript view | 📋 copy |
| **User edits report** | Report (edited) | `Odeslat emailem` (replaces Přepis) | 📋 copy |

### Toggle Logic (Přepis ↔ Lékařská zpráva)

- **Before user edits report**: left button toggles between two views
  - When showing report → button says **"Přepis"** → tap switches card to transcript
  - When showing transcript → button says **"Lékařská zpráva"** → tap switches card back to report
- **After user edits report** (`_hasLocalEdits == true` or report saved after edit):
  - Left button permanently becomes **"✉️ Odeslat emailem"**
  - Card locked to report view (no toggle)
  - Tapping sends report via existing email endpoint

### How to detect "user edited report"
Use the existing `_hasLocalEdits` flag in `_ReportPanelState` — when `_controller.text != _lastSyncedReport` after report was auto-generated, user has made edits. Expose this via a callback or a new provider.

---

## 3. Files to Modify

### 3.1 `lib/screens/home_screen.dart` — Major rewrite

**Remove:**
- Medical icon from AppBar title
- Theme toggle button from AppBar actions
- `_StatusPill` widget (replaced by recording indicator near FAB)
- `_reportExpanded` state and collapsed card logic
- `_buildNarrowLayout` — replace entirely
- `_buildWideLayout` — keep but adapt

**Add:**
- New `_showTranscript` bool state (toggles card content)
- New `_reportWasEdited` bool state (locks to report + email button)
- Green FAB (`Color(0xFF409086)`) at bottom center with pulse animation
- Recording label "Nahrávání..." with blinking dot above FAB
- Action row below card: left button (Přepis/Odeslat) + right copy icon

**New narrow layout structure:**
```dart
Column(
  children: [
    // Error/download banners (keep existing)
    Expanded(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: _ContentCard(),  // Report or Transcript
      ),
    ),
    _ActionRow(),              // Přepis/Odeslat + Copy
    _RecordingIndicator(),     // "Nahrávání..." label
    _RecordFAB(),              // Green/red circle button
    SizedBox(height: 16),
  ],
)
```

### 3.2 `lib/widgets/report_panel.dart` — Simplify

**Remove:**
- Outer `Card` wrapper (home_screen provides the container now)
- Header row with icon, title, close button, fullscreen button
- "Zpráva vygenerována automaticky" hint text
- Visit type regenerate button (move to home_screen if needed)

**Keep:**
- `TextEditingController` with edit tracking
- `_hasLocalEdits` detection
- `_saveChanges` for history entries
- Fullscreen view (accessible from overflow menu or long-press)

**Add:**
- Callback `onEditStateChanged(bool hasEdits)` to notify parent

### 3.3 `lib/widgets/transcript_panel.dart` — Simplify

**Remove:**
- Outer `Card`, header row, expand/collapse logic
- Status badge

**Keep:**
- Transcript text display with scroll
- Fullscreen view

**Result:** Just a scrollable `SelectableText` widget that fills available space.

### 3.4 `lib/widgets/recording_controls.dart` — Delete/Replace

The entire widget is replaced by the FAB in `home_screen.dart`. The FAB handles:
- Tap when idle → `notifier.startRecording()`
- Tap when recording → `notifier.stopRecording()`
- Visual: green `Color(0xFF409086)` when idle, red `Color(0xFFDC2626)` when recording with `AnimationController` pulse

### 3.5 `lib/widgets/recording_history_list.dart` — Move to AppBar

Add a history icon (📋 or `Icons.history`) to the AppBar that opens a `showModalBottomSheet` with the recording history list.

---

## 4. New Widget: `RecordFAB`

```dart
// Stateful widget with SingleTickerProviderStateMixin
// AnimationController for pulse effect (1.5s repeat)
// Size: 72x72, circular
// Colors: idle=Color(0xFF409086), recording=Color(0xFFDC2626)
// Icon: Icons.mic (idle), Icons.stop (recording)
// BoxShadow animates with pulse when recording
```

---

## 5. New Widget: `ActionRow`

```dart
Row(
  mainAxisAlignment: MainAxisAlignment.spaceBetween,
  children: [
    // Left: conditional button
    if (reportWasEdited)
      OutlinedButton.icon(
        icon: Icon(Icons.email_outlined),
        label: Text('Odeslat emailem'),
        style: /* green outline */,
        onPressed: _sendEmail,
      )
    else if (hasContent)
      OutlinedButton(
        label: Text(showingTranscript ? 'Lékařská zpráva' : 'Přepis'),
        onPressed: _toggleView,
      ),
    // Right: copy button
    if (hasContent)
      IconButton(icon: Icon(Icons.copy), onPressed: _copy),
  ],
)
```

---

## 6. Animation Specs

| Animation | Duration | Type |
|-----------|----------|------|
| FAB pulse (recording) | 1.5s | Repeating box-shadow scale |
| Recording dot blink | 1.0s | Opacity 1.0↔0.3 |
| Recording label appear | 300ms | Fade in + slide up |
| Card content switch | 200ms | Cross-fade (`AnimatedSwitcher`) |

---

## 7. Color Constants

```dart
// Add to config/constants.dart or a new theme file
static const Color anoteGreen = Color(0xFF409086);  // rgb(64,144,134)
static const Color recordingRed = Color(0xFFDC2626);
```

---

## 8. Implementation Order

1. **Add color constants** to `config/constants.dart`
2. **Simplify `TranscriptPanel`** — strip to bare scrollable text widget
3. **Simplify `ReportPanel`** — strip chrome, add `onEditStateChanged` callback
4. **Create `RecordFAB` widget** — animated recording button
5. **Create `ActionRow` widget** — Přepis/Odeslat toggle + copy
6. **Rewrite `HomeScreen` layout** — wire everything together
7. **Move recording history** to bottom sheet from AppBar icon
8. **Delete `RecordingControls`** widget (or keep for wide layout)
9. **Test state transitions** — idle → recording → report → edit → email

---

## 9. Edge Cases

- **No transcript yet (first launch):** Card shows report placeholder, no action row buttons
- **Recording with cloud model:** Transcript shows "Nahrávám… Přepis bude k dispozici po zastavení."
- **Report generation fails:** Show error banner (keep existing), card stays on transcript
- **Loading from history:** Show report directly, left button = "Odeslat emailem" (treat as already reviewed)
- **New recording button:** Move to AppBar overflow menu or make FAB long-press trigger `startNewRecording()`
