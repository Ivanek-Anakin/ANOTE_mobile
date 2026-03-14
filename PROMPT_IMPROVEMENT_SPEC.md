# ANOTE — Prompt Improvement & Visit Type Selector

**Date:** 2025-03-08
**Status:** Implementation spec

---

## Overview

Three changes to improve report quality based on real hospital diabetological examples:

1. **Visit type mode selector** — settings-page picker (Výchozí / Vstupní / Kontrolní) that switches between prompt variants
2. **System prompt improvements** — adherence, expanded negation, enriched SA, approximate quantities, speaker role detection
3. **Evaluation prompt update** — add new prompt variant `v4` to `evaluate_reports.py` for A/B testing

---

## 1. Visit Type Mode Selector

### 1.1 User Flow

- Doctor opens **Settings** → new section "Typ návštěvy" with `SegmentedButton<VisitType>`
- Three options: **Výchozí** (default, model decides) · **Vstupní** (initial visit) · **Kontrolní** (follow-up)
- Persisted in `SharedPreferences` (key: `visit_type`)
- When visit type changes and a report already exists, a **"Přegenerovat zprávu"** button appears in `ReportPanel`
- Tapping the button regenerates the report using the new visit type

### 1.2 Data Flow

```
Settings → SharedPreferences("visit_type")
                ↓
SessionProvider reads visit type from SharedPreferences
                ↓
ReportService.generateReport(transcript, visitType: "default"|"initial"|"followup")
                ↓
POST /report  { "transcript": "...", "language": "cs", "visit_type": "default" }
                ↓
Backend: _build_system_prompt(today, visit_type) → selects prompt variant
```

### 1.3 Backend Changes

**`ReportRequest` model** — add `visit_type: str = "default"` field (allowed: `"default"`, `"initial"`, `"followup"`)

**`_build_system_prompt(today, visit_type)`** — three prompt strategies:
- **`"default"`** — base prompt + meta-instruction: "Urči z přepisu, zda jde o vstupní vyšetření nebo kontrolní návštěvu, a přizpůsob strukturu."
- **`"initial"`** — full 13-section template (current behavior with all improvements)
- **`"followup"`** — compact follow-up template focused on changes, diabetes management, adherence; omit empty sections

### 1.4 Mobile Changes

| File | Change |
|------|--------|
| `session_state.dart` | Add `visitType` field + `visitTypeChanged` flag |
| `constants.dart` | Add `visitTypePrefKey` |
| `settings_screen.dart` | Add SegmentedButton selector for visit type |
| `report_service.dart` | Accept `visitType` param, send in POST body |
| `session_provider.dart` | Read visit type from prefs, add `regenerateReport()` method |
| `report_panel.dart` | Show "Přegenerovat zprávu" button when `visitTypeChanged` is true |

---

## 2. System Prompt Improvements

All four improvements are applied to the **base prompt** (used by all visit types).

### 2.1 Expanded Negation Handling

Replace the single negation bullet in ZÁSADY with richer instructions covering:
- Standard negations: "alergie neguje", "dušnost neguje"
- Complication negations: "těžké hypoglykémie neměl/a", "noční hypoglykémie neudává"
- Blanket negatives: "bez bolestí", "jinak se cítí dobře"
- Distinction: "pacient výslovně popřel" ≠ "nebylo zmíněno"

### 2.2 Approximate Quantities

New ZÁSADY bullet to actively capture approximate durations, frequencies, weight changes, and measured values with their hedging language preserved ("asi", "přibližně", "kolem").

### 2.3 Enriched SA

Replace the SA section with expanded instructions covering:
- Work type and load (shift work, travel, physical labor)
- Family caregiving and psychosocial stress
- Exercise (type, frequency, change over time)
- **How social factors influence disease management**

### 2.4 Adherence Section

New section after SA:
- Compliance with treatment, diet, appointments
- What patient refuses and why
- Missing documents/records
- Positive adherence ("režim dodržuje")

### 2.5 Speaker Role Detection (LLM-based, Option B)

New ZÁSADY bullet instructing the model to infer who is speaking:
- Questions/instructions/diagnoses → doctor
- Answers/complaints/subjective reports → patient
- When unclear → report content without attribution

---

## 3. Evaluation Updates

### 3.1 New Prompt Variant

Add `v4` to `PROMPT_VARIANTS` in `evaluate_reports.py`:
- Name: "Enhanced v4 (adherence + negation + SA + roles)"
- Description: Uses the new production prompt (all improvements baked in)
- The `_build_system_prompt()` in evaluate_reports.py is updated to match the new production prompt

### 3.2 Judge Prompt Updates

Add evaluation dimensions awareness for:
- Adherence section (judge should check if patient refusals/missing docs are captured)
- Speaker role detection quality
- Approximate quantity preservation

---

## 4. Implementation Order

1. Backend: Update `_build_system_prompt()` with all prompt improvements
2. Backend: Add `visit_type` to `ReportRequest`, wire into prompt selection
3. Backend: Update `evaluate_reports.py` with new prompt variant
4. Mobile: Add `VisitType` enum and persist in SharedPreferences
5. Mobile: Update Settings UI with selector
6. Mobile: Wire `visit_type` through ReportService → backend
7. Mobile: Add regenerate button to ReportPanel
8. Run backend tests to verify no regressions

---

## 5. Files Changed

### Backend
- `backend/main.py` — prompt rewrite, visit_type support
- `backend/evaluate_reports.py` — new v4 variant, updated base prompt
- `backend/tests/test_report_endpoint.py` — test visit_type parameter

### Mobile
- `mobile/lib/models/session_state.dart` — visitType, visitTypeChanged
- `mobile/lib/config/constants.dart` — pref key
- `mobile/lib/services/report_service.dart` — visitType param
- `mobile/lib/providers/session_provider.dart` — read/track visit type
- `mobile/lib/screens/settings_screen.dart` — selector UI
- `mobile/lib/widgets/report_panel.dart` — regenerate button
