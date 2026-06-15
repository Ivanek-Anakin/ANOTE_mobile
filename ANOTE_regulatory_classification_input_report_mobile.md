# ANOTE — Regulatory Classification Input Report

**Prepared by:** Local technical documentation agent (automated codebase inspection)
**Date:** 2026-06-15
**Codebase snapshot:** branch `feature/prompt-improvements`, commit `27bd5c9`
**Purpose:** Input material for EU MDR 2017/745, MDCG medical device software guidance, GDPR, and EU AI Act classification analysis.
**Disclaimer:** This document contains factual observations only. It does not constitute legal advice, a compliance assessment, or a conformity determination. All final regulatory conclusions must be made by qualified legal and regulatory professionals.

---

## 1. Product Overview

### Product Name
ANOTE (ANOTE Mobile, backend service name: "ANOTE Backend")

### Version
- Mobile app: v0.3.0+1 (from `mobile/pubspec.yaml`)
- Backend API: v2.0.0 (from `backend/main.py` FastAPI title)

### Target Users
Czech-speaking physicians and clinicians in private or outpatient clinical practice. No evidence of hospital ward or intensive-care-unit use cases in the codebase. The settings screen uses placeholder email `lekar@nemocnice.cz` ("doctor@hospital.cz").

### Target Customers
Private clinics and individual doctors in Czech Republic. No multi-tenant organisation management, no clinic administrator roles, and no patient portal exists in the current codebase.

### Countries/Markets
Czech Republic (all UI strings are in Czech, transcription language is hardcoded to `cs`, all prompts are in Czech). No localisation for other markets is present.

### Intended Use (as evidenced by the codebase)
ANOTE is a voice-to-medical-report drafting tool. The intended workflow is:

1. Doctor opens the app.
2. Doctor presses record and conducts a patient consultation (or dictates after consultation).
3. The app transcribes the spoken consultation audio to text (on-device or cloud Whisper model).
4. The app sends the transcript to a backend LLM (Azure OpenAI GPT-4.1-mini) with a structured Czech medical report template.
5. A draft structured medical report is returned and displayed to the doctor.
6. The doctor reviews and edits the report in an editable text field.
7. The doctor copies the report to clipboard or sends it by email.
8. The draft is saved locally on the device in JSON format.

### Explicitly Excluded Uses (per context provided by developer, not enforced in code)
- Diagnosis
- Treatment recommendations
- Medication prescribing
- Triage
- Disease prediction
- Replacing clinical judgement

**Important:** These exclusions are stated as developer intent. They are NOT technically enforced by the application code. The LLM is instructed to transcribe/structure what was said, but there are no runtime checks that block the LLM from generating clinical suggestions if the input transcript contains them. See Section 3 for detailed risk analysis of each generated section.

### User Workflow — From App Open to Report Export

1. **App launch** → model download progress shown (if first launch); on-device Whisper model pre-loaded in background.
2. **Settings (optional)** → Doctor configures backend URL, API token, transcription model (Local/Cloud/Hybrid), visit type, email address.
3. **Record** → Doctor taps the circular green FAB. Microphone permission requested. Recording starts (wakelock acquired, foreground service on Android).
4. **Live transcription** → Audio streamed through Silero VAD (silence filter) → Whisper (on-device) or Azure Whisper (cloud). Live transcript appears on screen.
5. **Live report preview** → Every 30 seconds (if transcript ≥ 50 words), the current transcript is sent to `/report` and a draft report appears.
6. **Stop** → Doctor taps the red FAB again. Final transcription pass runs. Final report generated.
7. **Review and edit** → Report displayed in an editable `TextField`. Doctor can type edits directly.
8. **Save/Export** → Doctor can: copy to clipboard ("Zpráva zkopírována"), send by email ("Odeslat emailem"), or the report is auto-saved locally. Auto-send email can be configured to trigger automatically on report completion.
9. **History** → Previous sessions accessible via history panel (transcript + report stored as JSON on device).

### Patient Access to the App
No. Patients do not use the app. The app is used exclusively by the treating physician. No patient-facing interface, patient login, or patient data input screen exists. Audio recordings capture the doctor–patient consultation.

---

## 2. Feature Inventory

| # | Feature | Implemented In | User-Facing Description | Input | Output | Output Type | Could Influence Clinical Decision? | Doctor Review Required? | Warnings/Disclaimers in UI |
|---|---------|----------------|------------------------|-------|--------|-------------|-------------------------------------|------------------------|---------------------------|
| 1 | **Audio recording** | Mobile: `audio_service.dart`, `session_provider.dart` | Record consultation via microphone | Microphone PCM 16 kHz mono | Raw PCM Float32 samples (in-memory) | None — raw data | No | N/A | None |
| 2 | **On-device transcription (Small)** | Mobile: `whisper_service.dart`, `whisper_isolate_worker.dart` | Offline Whisper Small INT8 model transcription (~358 MB) | PCM audio samples → Silero VAD → Whisper Small | Czech text transcript | Transcription only | No — converts speech to text | N/A | Warning if model download fails; "Local na tomto zařízení nebylo ověřeno" for Turbo on untested iOS |
| 3 | **On-device transcription (Turbo)** | Mobile: `whisper_service.dart` | Offline Whisper Large-v3-Turbo INT8 (~1 GB) | PCM audio → Silero VAD → Whisper Turbo | Czech text transcript | Transcription only | No | N/A | "experimentální" warning on untested devices; auto-disabled after crash |
| 4 | **Cloud transcription** | Mobile: `cloud_transcription_service.dart` | Azure OpenAI Whisper API (gpt-4o-mini-transcribe, Sweden Central) | PCM → WAV → Azure API | Czech text transcript | Transcription only | No | N/A | "Vyžaduje internet" label in settings |
| 5 | **Hybrid mode** | Mobile: `session_provider.dart` + cloud service | On-device live preview + cloud final transcript | PCM audio | Czech text transcript | Transcription only | No | N/A | Description: "On-device živý náhled + Cloud finální přepis" |
| 6 | **Voice Activity Detection (VAD)** | Mobile: `vad_service.dart`, `whisper_isolate_worker.dart` | Silero VAD — filters silence to reduce hallucinations | PCM audio samples | Filtered PCM speech segments | Internal signal processing | No | N/A | None |
| 7 | **Live transcript preview** | Mobile: `transcript_panel.dart`, `session_provider.dart` | Real-time text display during recording | Live transcription stream | Scrollable text display | Transcription display | No | N/A | None |
| 8 | **Final transcript** | Mobile: `whisper_service.dart` → `session_provider.dart` | Final high-quality transcript after stop | Full recorded audio | Complete Czech text transcript | Transcription only | No | N/A | None |
| 9 | **Live report preview** | Mobile: `session_provider.dart` → backend `/report`; every 30s if ≥50 words | Draft report generated during recording | Partial live transcript | Partial structured medical report | LLM-generated structure | Potentially — see Section 3 | Yes — editable TextField | "Generuji lékařskou zprávu…" spinner |
| 10 | **Final report generation** | Backend: `main.py` `/report` endpoint → Azure OpenAI GPT-4.1-mini | Structured Czech medical report from transcript | Full transcript + visit_type | Structured medical report (13 sections) | LLM-generated structure | Potentially — see Section 3 | Yes — editable TextField; regenerate button | "Generování zprávy selhalo" on error |
| 11 | **Automatic visit-type detection** | Backend: `_build_system_prompt()` (`visit_type = "default"`) | LLM auto-detects whether visit is initial or follow-up | Transcript content | Visit type selection (initial/followup) + corresponding report structure | LLM classification | No (affects formatting only, not clinical content) | Yes (doctor chooses visit type before or after) | None |
| 12 | **Visit type selection** | Mobile settings: `settings_screen.dart`; Backend `visit_type` parameter | Doctor selects report structure: Default/Vstupní/Kontrolní/Gastroskopie/Koloskopie/Ultrazvuk | Doctor selection | Selected report template used | Settings/configuration | No | N/A — doctor's explicit choice | "Ovlivňuje strukturu generované zprávy" |
| 13 | **Report section: Identifikace pacienta** | Backend: `_build_sections_initial()` | Patient name, age, date of visit | Transcript | Patient name, age from speech | Structured transcription | No | Yes | None |
| 14 | **Report section: NO (Nynější onemocnění)** | Backend: `_build_sections_initial()` | Chief complaint, duration, character | Transcript | Structured summary of current illness | Structured transcription | Potentially (see Section 3) | Yes | None |
| 15 | **Report section: RA (Rodinná anamnéza)** | Backend: `_build_sections_initial()` | Family history | Transcript | Structured family history | Structured transcription | Low | Yes | None |
| 16 | **Report section: OA (Osobní anamnéza)** | Backend: `_build_sections_initial()` | Personal medical history | Transcript | Structured personal history | Structured transcription | Low | Yes | None |
| 17 | **Report section: FA (Farmakologická anamnéza)** | Backend: `_build_sections_initial()` | Current medications | Transcript | Medication list with doses | Structured transcription | Potentially — medication accuracy critical | Yes | None |
| 18 | **Report section: AA (Alergologická anamnéza)** | Backend: `_build_sections_initial()` | Allergy history | Transcript | Allergy list | Structured transcription | Potentially — safety critical | Yes | None |
| 19 | **Report section: GA (Gynekologická anamnéza)** | Backend: `_build_sections_initial()` | Gynaecological history (women only) | Transcript | Gynaecological history | Structured transcription | Low | Yes | None |
| 20 | **Report section: SA (Sociální anamnéza)** | Backend: `_build_sections_initial()` | Social history: smoking, alcohol, employment | Transcript | Social history | Structured transcription | Low | Yes | None |
| 21 | **Report section: Adherence a spolupráce** | Backend: `_build_sections_initial()` | Patient adherence to treatment | Transcript | Adherence assessment | Structured transcription | Low | Yes | None |
| 22 | **Report section: Objektivní nález** | Backend: `_build_sections_initial()` | Objective clinical findings, measurements | Transcript | Measured values from examination | Structured transcription | Potentially (accuracy of values critical) | Yes | None |
| 23 | **Report section: Hodnocení** | Backend: `_build_sections_initial()` | Working diagnosis / clinical assessment | Transcript (what doctor said) | Working diagnosis or "neuvedeno" | Structured transcription of doctor's statement | **Yes — contains diagnostic language** (see Section 3) | Yes | None |
| 24 | **Report section: Návrh vyšetření** | Backend: `_build_sections_initial()` | Proposed investigations | Transcript (what doctor said) | Recommended tests or "neuvedeno" | Structured transcription of doctor's statement | **Yes — contains investigation recommendations** (see Section 3) | Yes | None |
| 25 | **Report section: Návrh terapie** | Backend: `_build_sections_initial()` | Proposed therapy | Transcript (what doctor said) | Recommended treatment or "neuvedeno" | Structured transcription of doctor's statement | **Yes — contains treatment language** (see Section 3) | Yes | None |
| 26 | **Report section: Pokyny a plán kontrol** | Backend: `_build_sections_initial()` | Instructions and follow-up plan | Transcript (what doctor said) | Follow-up schedule or "neuvedeno" | Structured transcription of doctor's statement | Moderate | Yes | None |
| 27 | **Gastroscopy report** | Backend: `_build_sections_gastroscopy()` | Full endoscopy procedure report | Transcript of procedure dictation | Structured gastroscopy report (indication, premedication, equipment, findings, conclusion, recommendations) | Structured transcription | Potentially (medication recommendations in output) | Yes | None |
| 28 | **Colonoscopy report** | Backend: `_build_sections_colonoscopy()` | Full colonoscopy procedure report | Transcript of procedure dictation | Structured colonoscopy report | Structured transcription | Potentially | Yes | None |
| 29 | **Ultrasound report** | Backend: `_build_sections_ultrasound()` | Abdominal ultrasound report | Transcript of procedure dictation | Structured ultrasound report with organ findings and fibrosis staging | Structured transcription | **Potentially — includes clinical interpretation (fibrosis grade, steatosis grade)** | Yes | None |
| 30 | **Copy to clipboard** | Mobile: `home_screen.dart` `_copyVisibleContent()` | Copy report or transcript to clipboard | Current report or transcript text | Clipboard | Export | No | Implicit (content already reviewed) | None |
| 31 | **Email send (manual)** | Mobile: `home_screen.dart` `_sendEmail()` → backend `/send-report-email` | Send report to configured email address | Report text + optional transcript | Email with report as plain text body | Export | No | Implicit (content already displayed) | None |
| 32 | **Email send (automatic)** | Mobile: `session_provider.dart` `_sendEmailIfEnabled()` | Auto-send report on completion if enabled in settings | Generated report | Email to configured address | Auto-export | **Potential concern — no explicit review confirmation step before auto-send** | **No forced review** — auto-sends if enabled | Settings label: "Po dokončení zprávy ji automaticky odešle e-mailem" |
| 33 | **Recording history** | Mobile: `recording_storage_service.dart`, `recording_history_provider.dart` | View, load, and delete past recordings | On-device JSON files | List of past transcripts and reports | History management | No | N/A | None |
| 34 | **Account / login** | None | No user account or login | N/A | N/A | N/A | N/A | N/A | N/A |
| 35 | **Subscription / trial** | None | No subscription or payment implemented | N/A | N/A | N/A | N/A | N/A | N/A |
| 36 | **Backend API auth** | Backend: `verify_token()` in `main.py` | Bearer token validation on all POST endpoints | HTTP Authorization header | 401 rejection or pass-through | Authentication | No | N/A | N/A |
| 37 | **Admin/monitoring** | None in codebase | No admin UI, no monitoring dashboard | N/A | N/A | N/A | N/A | N/A | N/A |
| 38 | **Error handling** | Mobile + backend | Error banners, retry buttons, fallback models | Error conditions | User-visible error messages | UI feedback | No | N/A | Error messages in Czech |
| 39 | **Logs** | Backend: `logging.basicConfig(level=logging.INFO)` | Server-side logs to stdout | HTTP request metadata | Log lines (deliberately excluding transcript/report content) | Server operations | No | N/A | None |
| 40 | **Demo scenarios** | Backend: `/scenarios`, `/test-report/{scenario_name}`; Mobile: `assets/demo_scenarios/` | Pre-loaded fictional patient transcripts for testing | Pre-written scenario text files | Generated medical report for demo | Testing/demo | No | Yes | None |
| 41 | **Hallucination filter** | Mobile: `whisper_service.dart` `removeHallucinations()` | Strips known Whisper artifacts (Czech YouTube subtitles, URLs, emoji) from transcription output | Raw Whisper text | Cleaned transcript | Post-processing | No | N/A | None |

---

## 3. Medical-Device Risk Trigger Review

### 3.1 Methodology

Each section of the generated report was examined against the prompt template in `backend/main.py` to determine whether the LLM is instructed to synthesise clinical content vs. transcribe what the doctor already said. The core prompt rule is:

> "Nevymýšlej ani nedoplňuj informace, které v přepisu nejsou." (`backend/main.py` line 185)
> *("Do not invent or add information not in the transcript.")*

> "Uveď jen to, co zaznělo od lékaře (diagnóza, suspektní stav). Pokud nezaznělo: 'neuvedeno'." (line 298–299)
> *("State only what was said by the doctor. If nothing was said: 'not stated'.")*

This means the intended behaviour is that the LLM reformats and structures what the doctor actually said, rather than generating independent clinical decisions. However, this is a prompt-level instruction to a generative model, not a technical hard constraint.

### 3.2 Feature-by-Feature Risk Trigger Table

| Trigger | Feature(s) Affected | Yes / No / Unclear | Evidence | File / Line | Suggested Mitigation |
|---------|--------------------|--------------------|----------|-------------|----------------------|
| **Diagnoses or suggests a diagnosis** | Hodnocení section | **Unclear** | Prompt: "Uveď jen to, co zaznělo od lékaře (diagnóza, suspektní stav)." The LLM is instructed to record the doctor's stated diagnosis. However, the LLM may reformulate or infer a diagnostic label from contextual information. | `backend/main.py` lines 297–299 | Add explicit disclaimer in Hodnocení output ("přepis výroku lékaře"). Add UI disclaimer "Toto je přepis — zkontrolujte obsah." |
| **Predicts disease or health deterioration** | None identified | **No** | No prompt instruction for prognostic content. | — | — |
| **Recommends treatment** | Návrh terapie, Gastroscopy Doporučení, Colonoscopy Doporučení, Ultrasound (no explicit therapy section) | **Unclear** | Prompt: "Léčba, medikace, režimová opatření — pouze pokud zaznělo." Intended to transcribe what doctor said. LLM could elaborate. | `backend/main.py` lines 302–305; `_build_sections_gastroscopy()` lines 413–418 | Ensure output labels each recommendation as "dle lékaře" or similar attribution. |
| **Recommends medication** | FA section (current meds), Návrh terapie, Gastroscopy Doporučení | **Unclear** | Prompt instructs to preserve exact medication names, doses, frequencies from transcript. Risk: LLM could normalise or add standard dosing not stated by doctor. | `backend/main.py` lines 204–205 (preserve numbers/units); TASK-0036 Principle 5 | Add validation that medication names appear verbatim in transcript before inclusion in output. |
| **Recommends dosage** | FA, Návrh terapie | **Unclear** | Prompt: "Zachovej přesná čísla, jednotky, dávkování a frekvenci." — correct intent but LLM can still alter or invent if transcript is ambiguous. | `backend/main.py` lines 204–210 | Flag any dose not found verbatim in transcript (post-processing check). |
| **Prioritises urgency** | None identified | **No** | No urgency or triage scoring in prompts. | — | — |
| **Performs triage** | None identified | **No** | No triage instruction or output field. | — | — |
| **Scores clinical risk** | None identified | **No** | No scoring rubric in prompts. | — | — |
| **Interprets medical findings beyond rewriting** | Ultrasound: Závěr, fibrosis/steatosis grading; Gastroscopy/Colonoscopy: Závěr | **Unclear** | Prompt for ultrasound includes: "Stupeň fibrózy a steatózy dle elastografie (pokud provedena)." The LLM is asked to include fibrosis/steatosis staging — these are clinical interpretations. If the doctor stated them, it is transcription; if the LLM infers them from numeric values alone, it is interpretation. | `backend/main.py` lines 542–548 | Restrict ultrasound fibrosis/steatosis staging to only explicit doctor statements; do not allow LLM to compute staging from numbers. |
| **Detects abnormalities** | Objektivní nález, Závěr (procedure reports) | **Unclear** | The LLM is instructed to record objective findings from the transcript. If the doctor stated them, it is transcription. The risk is that the LLM could characterise unlabelled values (e.g. "TK 180/110") as abnormal without the doctor having said so. | `backend/main.py` lines 293–296 | Instruct model not to add qualitative interpretive labels to measurements not characterised by the doctor. |
| **Recommends referral to specialist** | Návrh vyšetření, Plán (followup) | **Unclear** | Prompt: "Doporučená/indikovaná vyšetření, odběry, zobrazování, konzilia — pouze pokud zaznělo." Intended as transcription of doctor's statement. Could be interpreted as recommendation if phrased generically. | `backend/main.py` lines 301–302 | Label section content as "dle lékaře". |
| **Makes patient-specific clinical recommendations** | Hodnocení, Návrh terapie, Návrh vyšetření, Procedure Doporučení sections | **Unclear** | These sections contain patient-specific content structured by the LLM. All are intended to reflect doctor speech, but the LLM's rephrasing could alter clinical meaning. | `backend/main.py` lines 297–308 | Require explicit human review before any export. Do not auto-send if those sections are non-empty. |
| **Generates content mistakable as final medical advice** | All report sections, especially Hodnocení, Návrh terapie, Doporučení | **Yes** | The output is a structured document with official Czech medical report section headers (NO, OA, FA, etc.) that resembles a standard clinical record. A reader who receives it by email without the "draft" context could mistake it for final clinical documentation. | Email body format in `backend/main.py` lines 640–657 | Add header: "NÁVRH ZPRÁVY — NUTNO ZKONTROLOVAT LÉKAŘEM" to all exported documents. |

### 3.3 Summary Assessment

The application is designed to perform **structured transcription and reformatting** of a doctor–patient consultation. The prompts contain explicit anti-hallucination rules. However:

- The output includes sections (Hodnocení, Návrh terapie, Návrh vyšetření) that use clinical language identical to that of a real medical record.
- The LLM is a generative model; prompt-level constraints are not technically guaranteed.
- The auto-email feature can send the report without an explicit human review gate.
- Exported emails are not watermarked as drafts.
- Procedure reports (gastroscopy, colonoscopy, ultrasound) include clinically interpretive sections (Závěr, fibrosis staging).

---

## 4. AI and LLM Behaviour

### 4.1 AI Models Used

| Role | Model | Provider | Location | Notes |
|------|-------|----------|----------|-------|
| Report generation (primary) | GPT-4.1-mini (`gpt-4-1-mini`) | Azure OpenAI | West Europe | Configured via `AZURE_OPENAI_DEPLOYMENT` env var. Default fallback to `gpt-4-1-mini` |
| Report generation (fallback) | GPT-5-nano (`gpt-5-nano`) | Azure OpenAI | West Europe | `FALLBACK_MODEL` in `main.py` line 59 |
| Cloud transcription | gpt-4o-mini-transcribe | Azure OpenAI | Sweden Central | `constants.dart` line 31 |
| On-device transcription (default) | Whisper Small INT8 | On-device (sherpa-onnx) | On-device | Downloaded from HuggingFace; 358 MB |
| On-device transcription (Turbo) | Whisper Large-v3-Turbo INT8 | On-device (sherpa-onnx) | On-device | Optional; ~1 GB; may be unavailable on low-memory devices |
| Voice Activity Detection | Silero VAD (ONNX) | On-device (sherpa-onnx) | On-device | Downloaded from GitHub; ~300 KB |

### 4.2 Local vs Cloud Processing

| Step | Processing Location | Data Leaves Device? |
|------|--------------------|--------------------|
| Audio capture | Device (microphone) | No |
| VAD filtering | Device (on-device mode / hybrid preview) | No |
| Transcription (Local/Turbo mode) | On-device (background isolate) | No |
| Transcription (Cloud/Hybrid final) | Azure OpenAI, Sweden Central | **Yes — audio WAV file sent to Azure** |
| Report generation | Azure OpenAI, West Europe (via backend) | **Yes — transcript text sent to Azure** |
| Recording storage | Device filesystem (JSON) | No |
| Email export | Backend SMTP relay → recipient email server | **Yes — report text sent** |

### 4.3 Transcription Models

- **Whisper Small INT8**: sherpa-onnx port; encoder + decoder + tokens downloaded from HuggingFace (`csukuangfj/sherpa-onnx-whisper-small`); runs in a persistent background isolate on device; uses 16 kHz mono PCM; language hardcoded to `cs`.
- **Whisper Large-v3-Turbo INT8**: sherpa-onnx port; ~1 GB; same pipeline; blocked on devices that have previously crashed.
- **Azure OpenAI gpt-4o-mini-transcribe**: WAV file uploaded via multipart HTTP to Azure Sweden Central; language parameter `cs`; downsampled 16 kHz → 8 kHz before upload (halves upload size); no transcription prompt injected (deliberately omitted to prevent Whisper regurgitation, per comment in `cloud_transcription_service.dart` line 129).

### 4.4 Report Generation Model

- Model: Azure OpenAI deployment, primary `gpt-4-1-mini`, fallback `gpt-5-nano`.
- Temperature: not set (uses model default; no `temperature` parameter in API call, `backend/main.py` lines 733–741).
- max_completion_tokens: 4096.
- Outputs are **variable** (non-deterministic); no fixed seed or temperature=0.

### 4.5 Prompt Templates — Complete Text

#### 4.5.1 System Prompt Construction

The system prompt is assembled in `_build_system_prompt()` (`backend/main.py` lines 553–601). It is constructed from:

1. **Intro paragraph** — identifies the AI as a medical documentation assistant.
2. **ZÁSADY (Rules block)** — core anti-hallucination rules (see below).
3. **Sections block** — per visit-type template.
4. **Footer** — language instruction.
5. **TASK-0036 suffix** — five abstract principles and three procedural rules.

#### 4.5.2 Intro (all visit types except procedure reports)
```
Jsi asistent pro tvorbu lékařské dokumentace. Z poskytnutého přepisu 
návštěvy vytvoř formální lékařskou zprávu v češtině.
```
*(Translation: "You are a medical documentation assistant. From the provided visit transcript, create a formal medical report in Czech.")*

#### 4.5.3 ZÁSADY (Rules block) — Full Text (`_build_base_rules()`, lines 181–231)

```
ZÁSADY
- Nevymýšlej ani nedoplňuj informace, které v přepisu nejsou.
- Pokud informace chybí, napiš přesně: „neuvedeno".
- Negaci zapiš POUZE tehdy, pokud v přepisu existuje obojí: explicitní dotaz 
  lékaře na dané téma a explicitní popření pacientem. Negace má přednost před 
  „neuvedeno" jen při takto doloženém Q&A.
- U chronických onemocnění nezapisuj negace komplikací preventivně ani 
  šablonově.
- Rozlišuj „pacient výslovně popřel" vs „nebylo zmíněno".
- Zachovej přesná čísla, jednotky, dávkování a frekvenci.
- Aktivně zachycuj přibližné údaje (asi 3 měsíce, pár dní, 2× týdně…). 
  Zachovej formulaci s „asi" / „přibližně" / „kolem".
- Rozlišuj subjektivní údaje (udává pacient) vs objektivní nález 
  (naměřeno / zjištěno vyšetřením).
- Při rozporu v přepisu uveď obě verze a označ „rozpor v přepisu".
- Přepis může obsahovat chyby z automatického rozpoznávání řeči — 
  interpretuj smysl, ne doslovný text.
- V přepisu se střídají repliky lékaře a pacienta. Otázky, pokyny a diagnózy 
  přiřaď lékaři. Odpovědi, stížnosti a subjektivní popisy přiřaď pacientovi.
- U změn medikace zaznamenej, kdo změnu doporučil.
- Rozlišuj ALERGII (imunitní reakce) a INTOLERANCI / nesnášenlivost.
- Preferovaná terminologie u poslechového nálezu plic: „chrůpky".
- Děti pacienta patří do RA, NE do SA.
- Potíže s močením patří do NO, NE do GA.
- DŮKLADNĚ projdi celý přepis. Raději uveď informaci navíc, než aby chyběla.
```

#### 4.5.4 TASK-0036 Prompt Suffix — Full Text (`TASK0036_PROMPT_SUFFIX`, lines 97–178)

This suffix is appended to every system prompt. It contains five principles and three procedural rules designed to prevent hallucination, content mixing, and inference beyond the transcript:

```
TASK-0036 OBECNÉ PRINCIPY (BEZ KONKRÉTNÍCH KLINICKÝCH HODNOT)
...
Princip 1 — Filtrování neklinického obsahu: Do zprávy patří pouze klinicky 
relevantní informace. Vše ostatní ignoruj.
Princip 2 — Přiřazení nálezů ke správným sekcím: Co pacient vypovídá → 
subjektivní sekce. Co lékař naměří → objektivní sekce. Nikdy nemíchej.
Princip 3 — Žádná inference nad rámec přepisu: Do zprávy zapiš pouze to, co 
lze přímo doložit z přepisu. Nedoplňuj diagnózy, etiologie, alergeny…
Princip 4 — Sekce zaznamenává pouze to, co bylo skutečně probíráno.
Princip 5 — Věrnost krátkých klinických tokenů: Přesné zápisy dávkování, 
frekvence, schémat přenes doslovně.
Pravidlo P1 — Sociální kontext vs. expozice.
Pravidlo P2 — Numerická hodnota s jednotkou patří výhradně do objektivního 
nálezu.
Pravidlo P3 — Ověření citace před zápisem do adherence/spolupráce.
```

#### 4.5.5 User Prompt (fixed, all calls)
```
Převeď tento přepis do strukturované lékařské zprávy v češtině:

{transcript}
```

#### 4.5.6 Section Structures

**Initial visit (13 sections):** Identifikace pacienta, NO, RA, OA, FA, AA, GA, SA, Adherence, Objektivní nález, Hodnocení, Návrh vyšetření, Návrh terapie, Pokyny a plán kontrol.

**Follow-up visit (compact):** Identifikace pacienta, Subjektivní stav, Průběh od poslední kontroly, Kompenzace onemocnění, Režim a adherence, Přidružené obtíže, Objektivní nález, Hodnocení, Plán.

**Procedure reports (gastroscopy/colonoscopy):** Indikace, Odesílající lékař, Premedikace, Přístroj, Asistence, Čas, Informovaný souhlas, Popis výkonu, Závěr, Doporučení, Stav po výkonu.

**Ultrasound:** Indikace, Odesílající lékař, Přístroj, Popis nálezu (per organ), Elastografie/FibroScan, Závěr.

### 4.6 Hidden Instructions

None identified. All system prompt content is constructed from named Python functions and the `TASK0036_PROMPT_SUFFIX` constant — all visible in `backend/main.py`. There are no hidden instructions injected from external configuration or environment variables.

### 4.7 Fine-Tuning or RAG

None. The model is called directly via Azure OpenAI API with no retrieval-augmented generation, no vector store, and no fine-tuning.

### 4.8 Patient Data Sent to Third-Party APIs

| Data | Sent to | Conditions |
|------|---------|------------|
| Audio WAV file (encoded consultation recording) | Azure OpenAI Whisper API (Sweden Central) | Cloud or Hybrid mode only; not in Local/Small/Turbo mode |
| Czech text transcript of consultation | Azure OpenAI LLM API via ANOTE backend (West Europe) | All report generation calls |
| Report text | Backend SMTP server → recipient email | Only when email feature enabled/used |

The transcript may contain patient health information (symptoms, diagnoses mentioned by doctor, medications, personal history) and potentially identifying information (patient name, age if spoken).

### 4.9 Data Used for Training

**Unclear.** The code does not contain any explicit configuration to opt out of Azure OpenAI model training. Azure's default data processing terms vary by service tier. No zero-data-retention or no-training flag is set in API calls.

**Risk:** Azure OpenAI Standard SKU (used for GPT-4.1-mini, per README decision note) may be subject to Azure OpenAI's standard terms including potential use for model improvement unless a Data Privacy Addendum / Zero Data Retention agreement is in place. The developer selected Standard SKU specifically for GDPR compliance.

### 4.10 Zero-Retention Settings

**Not configured in code.** No `zero_retention` or equivalent parameter is passed to Azure OpenAI API calls. The README states the GDPR compliance rationale as "Azure OpenAI in West Europe" (data residency), not zero-retention.

### 4.11 Determinism

- Report generation: **Non-deterministic** — no `temperature=0` or `seed` parameter is set; Azure OpenAI uses its default temperature.
- Transcription: **Effectively deterministic for the same audio input** (Whisper models are deterministic given the same beam search settings and audio).

### 4.12 Hallucination Controls

Present:

1. **Prompt-level rules** — explicit instruction "Nevymýšlej ani nedoplňuj" and "neuvedeno" fallback.
2. **TASK-0036 suffix** — five principles against inference and a "no Q&A negation unless explicitly spoken" rule.
3. **Whisper hallucination filter** (`removeHallucinations()` in `whisper_service.dart`) — strips known Czech YouTube subtitle artifacts from transcription output.
4. **"neuvedeno" pattern** — all sections default to "neuvedeno" if not discussed; LLM instructed to use this value.

Limitations:

- Hallucination controls are prompt-level only, not post-processing or validation.
- No automated check that output content appears in the input transcript.
- Non-zero temperature makes output variable.

### 4.13 Source-Grounded Output

The prompt explicitly instructs the model to only produce content grounded in the transcript. Principle 3 of TASK-0036: "Do zprávy zapiš pouze to, co lze přímo doložit z přepisu." However, this is enforced only by the LLM's compliance with the instruction, not by a technical retrieval or grounding mechanism.

---

## 5. Data Flow and GDPR Map

### 5.1 Data Flow Diagram (text form)

```
Doctor's voice (microphone)
    │
    ▼
AudioService (16 kHz PCM, in-memory)
    │
    ├──[Local/Turbo mode]──► WhisperService (on-device isolate)
    │                              │ Silero VAD (silence filter)
    │                              │ Whisper Small/Turbo (STT)
    │                              ▼
    │                         Czech text transcript (in-memory)
    │
    └──[Cloud/Hybrid mode]──► WAV encoding (in-memory)
                                   │
                                   ▼
                              Azure OpenAI Whisper API (Sweden Central)
                                   │
                                   ▼
                         Czech text transcript (returned to device)
    │
    ▼
Czech text transcript (in-memory SessionState)
    │
    ├──► Auto-save every 10s ──► recordings/{uuid}.json (on-device filesystem)
    │
    └──► ReportService ──► HTTP POST /report ──► ANOTE Backend (Azure Container Apps, West Europe)
                                                      │
                                                      ▼
                                             Azure OpenAI GPT-4.1-mini (West Europe)
                                                      │
                                                      ▼
                                         Structured Czech medical report (text)
                                                      │
                                                      ▼
                                         Returned to device (HTTP response)
                                                      │
    ▼                                                 │
Structured report (in-memory SessionState) ◄──────────┘
    │
    ├──► Displayed to doctor in editable TextField
    ├──► Auto-save ──► recordings/{uuid}.json (on-device filesystem)
    └──► Email export ──► ANOTE Backend /send-report-email ──► SMTP relay ──► Doctor's email
```

### 5.2 Data Inventory Table

| Data Category | Example | Source | Destination | Storage Location | Retention | Encryption in Transit | Encryption at Rest | Access | Deletion | Personal Data? | Health Data? | Leaves Device? | Leaves EU/EEA? |
|---------------|---------|--------|-------------|-----------------|-----------|----------------------|-------------------|--------|----------|---------------|-------------|----------------|----------------|
| Audio recording (in-memory) | 16 kHz PCM samples of consultation | Microphone | WhisperService / CloudTranscriptionService | RAM only — never written to disk | Session duration (cleared on reset/stop) | N/A (in-memory) | N/A (in-memory) | App process only | Auto-cleared on session end | Yes | Yes | Yes (Cloud/Hybrid: sent as WAV to Azure) | No — Azure Sweden Central is EU |
| Live transcript (in-memory) | "Pacient udává bolest hlavy…" | WhisperService / Azure Whisper | SessionProvider (Riverpod state) | RAM | Session duration | N/A | N/A | App process only | Auto-cleared on session end or new recording | Yes | Yes | Yes — transcript sent to backend | No — backend in West Europe |
| Final transcript (on-device) | Full consultation text | SessionProvider | RecordingStorageService | `{appDocDir}/recordings/{uuid}.json` | Until doctor deletes entry | N/A (local file) | OS-level file encryption (iOS Secure Enclave, Android encryption) | App process only; no cloud backup configured | Delete via history UI | Yes | Yes | Yes — sent to backend for report generation | No |
| Generated medical report (on-device) | 13-section structured report | Backend API | SessionProvider / RecordingStorageService | `{appDocDir}/recordings/{uuid}.json` | Until doctor deletes entry | N/A (local file) | OS-level | App process only | Delete via history UI | Yes | Yes | Yes — sent as email via backend | No |
| User email address | `lekar@nemocnice.cz` | Settings screen (doctor input) | SharedPreferences | `SharedPreferences` (on device) | Until changed | N/A | Android: unencrypted; iOS: not in secure storage | App process only | Clear settings | Yes (doctor's email) | No | Yes — sent to backend for email sending | No |
| API Bearer Token | Hex string | Settings screen / `secrets.dart` | `flutter_secure_storage` | OS secure keystore | Until changed | HTTPS | OS secure keychain/keystore | App only | Clear secure storage | No (technical credential) | No | No | No |
| Backend URL | `https://anote-api…azurecontainerapps.io` | `secrets.dart` / settings | `flutter_secure_storage` | OS secure keystore | Until changed | N/A | OS secure | App only | Clear | No | No | No | No |
| Azure Whisper API Key | API key string | `secrets.dart` / settings | `flutter_secure_storage` | OS secure keystore | Until changed | HTTPS | OS secure | App only | Clear | No | No | No | No |
| Visit type preference | "followup" | Settings screen | `SharedPreferences` | Unencrypted shared prefs | Until changed | N/A | No | App only | Clear prefs | No | No | No | No |
| Transcription model preference | "cloud" | Settings screen | `SharedPreferences` | Unencrypted shared prefs | Until changed | N/A | No | App only | Clear prefs | No | No | No | No |
| Theme preference | "dark" | Settings screen | `SharedPreferences` | Unencrypted shared prefs | Until changed | N/A | No | App only | Clear prefs | No | No | No | No |
| Recording metadata | uuid, timestamp, wordCount, visitType, preview | App session | `recordings/_index.json` | On-device JSON | Until deleted | N/A | OS-level | App only | Delete entry | Indirectly (timing of visits) | Indirectly | No | No |
| Backend server logs | `Report generation request received (visit_type=followup)` | Backend | Azure Container Apps stdout | Azure log service | Azure default (typically 30 days) | N/A | Azure managed | Azure admin | Azure log expiry | No (transcript/report deliberately NOT logged — see `main.py` line 795) | No | N/A — generated server-side | No — West Europe |
| Email body (report) | Full structured medical report in plain text | Backend `_build_email_body()` | SMTP relay → recipient email server | Email server of recipient | Email server retention | STARTTLS (optional SMTP TLS) | Email server dependent | Doctor and email server admins | Manual email deletion | Yes | Yes | Yes | **Unclear** — depends on email server configuration |
| Patient identifiers | Patient name, age (if spoken in consultation) | Doctor's speech → transcript | On-device JSON, backend LLM, email | On-device + Azure OpenAI processing + email | Local: until deleted; Azure: per Azure terms | HTTPS (transit) | OS-level (local) | App + Azure | Local: delete entry; Azure: per Azure terms | Yes | Yes | Yes | No (Azure EU regions) |
| Crash/error logs | Stack traces, error messages | Flutter `FlutterError.onError`, `runZonedGuarded` | stdout (print statements) | None — no crash reporting service integrated | Session only | N/A | N/A | Console only | N/A | No | No | No | No |
| Analytics | None | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | No | No |
| Payment/subscription | None — not implemented | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | No | No |
| Audio backups | None — audio is never stored | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |

### 5.3 GDPR-Relevant Notes

- The backend deliberately excludes transcript and report content from logs: `# NOTE: transcript and report content are deliberately NOT logged (GDPR)` (`main.py` line 795–796).
- Azure OpenAI is in West Europe (report generation) and Sweden Central (transcription) — both EU/EEA.
- No data is sent outside the EU/EEA in normal operation.
- No data retention policy is implemented or documented within the codebase.
- No consent management or data subject rights mechanism (access, erasure, portability) is implemented.
- No privacy policy or terms of service are linked from within the app.
- Local recordings include health data (transcript + report) and are stored unencrypted in the app documents directory (protected only by OS-level file encryption — iOS Data Protection API, Android Full Disk Encryption).
- Email export sends the report and optional transcript in plain text via SMTP. TLS is configurable (`SMTP_USE_TLS`). The encryption of the email after the initial TLS connection depends on intermediate email servers.

---

## 6. Architecture

### 6.1 Mobile App Architecture

**Framework:** Flutter (Dart), Material 3 design system, Riverpod for state management.

**State management:** `sessionProvider` (StateNotifier) orchestrates the entire recording → transcription → report pipeline. Child providers: `transcriptionModelProvider`, `visitTypeProvider`, `emailReportEnabledProvider`, `emailReportAddressProvider`, `deviceCapabilityProvider`, `recordingIndexProvider`.

**Key layers:**

```
UI Layer (screens/widgets)
    ├── HomeScreen — main interface
    └── SettingsScreen — backend URL, token, model, email, visit type

Provider Layer (Riverpod)
    └── SessionNotifier — state machine (idle → recording → processing → idle)

Service Layer
    ├── AudioService — microphone capture (audio_streamer plugin, 16 kHz PCM)
    ├── WhisperService — on-device STT (sherpa-onnx, background isolate)
    │   └── WhisperIsolateWorker — persistent isolate with VAD + Whisper
    ├── VadService — standalone VAD for cloud path
    ├── CloudTranscriptionService — Azure Whisper HTTP client
    ├── ReportService — HTTP client for backend /report
    └── RecordingStorageService — JSON file persistence

Utilities
    ├── WavEncoder — PCM → WAV encoding with 2x downsampling
    └── TurboCapabilityResolver — iOS Turbo crash detection

Persistent storage
    ├── flutter_secure_storage — API token, backend URL, Whisper API key
    ├── SharedPreferences — model preference, visit type, theme, email settings
    └── {appDocDir}/recordings/*.json — transcripts and reports
```

**Background operation:** Uses `flutter_foreground_task` (Android foreground service notification) and `wakelock_plus` (screen-on lock) to maintain recording while screen is off.

### 6.2 Backend Architecture

**Framework:** Python 3.12 + FastAPI 0.115.0 + Uvicorn.

**Deployment:** Azure Container Apps (Consumption tier), West Europe region. Resource group: `ANOTE` / `anote-rg`. Container registry: `cae82690c7c7acr.azurecr.io` (West Europe). Container: 0.5 CPU / 1 GB RAM.

**Endpoints:**

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | None | Health check |
| GET | `/scenarios` | None | List demo scenario names |
| POST | `/report` | Bearer token | Generate Czech medical report from transcript |
| POST | `/send-report-email` | Bearer token | Send report via SMTP to email address |
| POST | `/test-report/{scenario_name}` | Bearer token | Generate report from bundled demo scenario |

**LLM pipeline:**
```
POST /report
    │
    ├── Validate Bearer token (verify_token dependency)
    ├── Validate transcript (non-empty)
    ├── Determine visit_type
    ├── Build system prompt (_build_system_prompt)
    ├── Call Azure OpenAI GPT-4.1-mini (primary)
    │   └── On failure → retry with GPT-5-nano (fallback)
    └── Return {"report": "<text>"}
```

**Email pipeline:**
```
POST /send-report-email
    │
    ├── Validate Bearer token
    ├── Validate report (non-empty) and email (regex)
    ├── Build email body (_build_email_body)
    └── SMTP send via smtplib (STARTTLS)
```

### 6.3 Authentication

- **Mobile → Backend:** Bearer token in `Authorization` header. Token stored in `flutter_secure_storage`. Default token embedded in `mobile/lib/config/secrets.dart` (not in version control — `.gitignore` assumed; file present locally).
- **Backend → Azure OpenAI:** `AZURE_OPENAI_KEY` environment variable (stored as Azure Container Apps secret `azure-openai-key`).
- **Mobile → Azure Whisper:** `Azure-Whisper-Key` in `api-key` HTTP header. Key stored in `flutter_secure_storage`.

### 6.4 Authorization

- Single-role application: all authenticated requests have equal access.
- No user roles, no per-doctor access control, no clinic hierarchy.
- No audit log of which doctor made which request.

### 6.5 Storage

| Layer | Storage Type | Data |
|-------|-------------|------|
| Device | App Documents directory (filesystem) | Recording JSON files (transcript + report) |
| Device | flutter_secure_storage (OS keychain/keystore) | API token, backend URL, Azure Whisper key |
| Device | SharedPreferences | App settings (model, visit type, theme) |
| Device | RAM | Audio PCM, live transcript, live report |
| Backend | None | Stateless — no database, no persistent storage |
| Cloud | Azure Container Apps secrets | Azure OpenAI key, app API token |
| Cloud | Azure Container Apps logs | HTTP request logs (no content) |

### 6.6 Cloud Providers and Regions

| Service | Provider | Region | Purpose |
|---------|----------|--------|---------|
| Backend hosting | Azure Container Apps | West Europe | FastAPI server |
| LLM (report generation) | Azure OpenAI | West Europe | GPT-4.1-mini |
| LLM (transcription) | Azure OpenAI | Sweden Central | gpt-4o-mini-transcribe |
| Container registry | Azure Container Registry | West Europe | Docker images |
| On-device models | HuggingFace (`csukuangfj/`) + GitHub (`k2-fsa/sherpa-onnx`) | CDN (no specific region) | One-time download |

### 6.7 Third-Party Services

| Service | Purpose | Data Shared | Notes |
|---------|---------|------------|-------|
| Azure OpenAI (West Europe) | Report generation | Czech transcript text | Standard SKU selected for GDPR compliance per README |
| Azure OpenAI (Sweden Central) | Cloud speech-to-text | WAV audio file | gpt-4o-mini-transcribe deployment |
| HuggingFace | One-time model download | None (download only) | Whisper Small/Turbo ONNX files |
| GitHub releases (k2-fsa/sherpa-onnx) | One-time model download | None | Silero VAD ONNX model |
| SMTP provider | Email delivery | Report text + optional transcript | Configured via environment variables; not a named fixed provider |

### 6.8 CI/CD

No CI/CD pipeline configuration files found in the repository. Deployment is performed manually via Azure CLI commands documented in `README.md`.

### 6.9 Monitoring

No application performance monitoring (APM), no error tracking service (e.g. Sentry), no uptime monitoring integrated. Backend logging is via Python `logging` to stdout, captured by Azure Container Apps log service.

### 6.10 Error Reporting

- Mobile: `FlutterError.onError` + `runZonedGuarded` print to console only. No remote error reporting service.
- Backend: Python logging to stdout.

### 6.11 Secrets Management

- Backend: Azure Container Apps secrets (`azure-openai-key`, `app-api-token`). Referenced via `secretref:` in environment variable configuration.
- Mobile: `flutter_secure_storage` (iOS Keychain, Android Keystore). Default secrets embedded in `mobile/lib/config/secrets.dart` (this file is not visible in the repository listing, suggesting it may be git-ignored or not tracked — this needs verification).

---

## 7. Security Controls

### 7.1 Existing Controls

| Control | Implementation | Status |
|---------|---------------|--------|
| HTTPS/TLS | All backend API calls use HTTPS (Azure Container Apps provides TLS termination). Azure OpenAI calls over HTTPS. | ✅ Present |
| Token authentication | Bearer token validated on all POST endpoints via `verify_token()` dependency | ✅ Present |
| User roles | None — single-tier access | ❌ Absent |
| Password/authentication | Bearer token only; no username/password | Partial |
| Encryption in transit | HTTPS for backend, Azure Whisper API. SMTP uses STARTTLS (optional, configured by `SMTP_USE_TLS`). | ✅ Present (SMTP conditional) |
| Secure device storage | `flutter_secure_storage` for API keys/tokens (iOS Keychain, Android Keystore) | ✅ Present for secrets |
| At-rest encryption for recordings | Relies on OS-level file encryption (iOS Data Protection, Android FDE) — not app-enforced encryption | Partial |
| Backend access control | Single bearer token; no per-user tokens | Partial |
| Admin access | None implemented | ❌ Absent |
| Logging | Backend logs HTTP metadata (not content) via Python logging | Partial |
| Audit trails | No audit trail of who accessed what or when | ❌ Absent |
| Backups | None implemented; Azure Container Apps does not provide automatic backup of stateless containers | ❌ Absent |
| Incident response | Not documented | ❌ Absent |
| Data deletion | Users can delete individual recording entries via history UI. No bulk deletion. No server-side deletion | Partial |
| Rate limiting | **Not implemented** | ❌ Absent |
| Abuse protection | Bearer token is the only control. CORS set to `allow_origins=["*"]` in backend (`main.py` line 29) — **all origins allowed** | ❌ Weak |
| Dependency scanning | Not implemented; no `requirements.txt` lockfile with hash verification | ❌ Absent |
| Vulnerability management | Not documented | ❌ Absent |
| Input validation | Backend validates: non-empty transcript, valid email format (regex), valid visit type (whitelist). | ✅ Present (basic) |
| SQL injection | No SQL database used — not applicable | N/A |
| XSS | Backend returns JSON; no HTML rendering. Not applicable for API. | N/A |

### 7.2 Missing or Weak Controls

| Gap | Risk | Recommendation |
|-----|------|----------------|
| CORS `allow_origins=["*"]` | Any web origin can call the API with a known token | Restrict to known mobile app origins or implement token binding |
| No rate limiting | API can be abused to run unlimited LLM calls | Add per-token rate limiting (e.g. 100 requests/hour) |
| Single shared bearer token | All users share one token; compromise affects all; no per-user audit | Implement per-device or per-doctor tokens |
| No audit log | Cannot detect unauthorised access or data breach | Add audit log: timestamp, token hash, endpoint, response code |
| Default secrets in `secrets.dart` | If the file is not git-ignored, secrets are in version control | Verify file is git-ignored; rotate any accidentally exposed secrets |
| SMTP TLS optional | If `SMTP_USE_TLS=false`, emails sent unencrypted | Enforce TLS; document security requirement |
| No patient data minimisation | Patient name and age captured from transcript; no field to exclude them | Provide option to exclude or redact patient identifiers |
| No data retention policy in code | Recordings accumulate indefinitely on device | Implement configurable retention window or deletion reminder |
| No consent mechanism | No mechanism to record patient consent for AI processing | Consider consent logging or opt-out mechanism |
| No backup of local recordings | If phone is lost/destroyed, recordings are permanently lost | Consider optional encrypted cloud backup with user consent |
| Recording in RAM during session | If app crashes during recording, in-progress transcript may be lost | Auto-save partial transcript more frequently (currently 10s) |

---

## 8. Human Oversight and Clinical Responsibility

### 8.1 Where the App Communicates That Outputs Are Drafts

| Location | Text | Context |
|----------|------|---------|
| Report panel loading indicator | "Generuji lékařskou zprávu…" | Spinner shown while report is being generated |
| Report panel hint text | "Začněte nahrávat pro automatické generování lékařské zprávy..." | Shown when report field is empty |
| About section (settings) | "Generování lékařských zpráv z hlasu." | Product description in settings |
| Email body header | "Lékařská zpráva vygenerovaná aplikací ANOTE" | Present in all emailed reports — indicates AI origin |
| Email body footer | "Tato zpráva byla automaticky odeslána aplikací ANOTE." | Present in all emailed reports |

**Not present anywhere:**
- Explicit "DRAFT — DO NOT USE CLINICALLY WITHOUT REVIEW" watermark on the report.
- Disclaimer that the report was AI-generated and may contain errors.
- Instruction to review before filing in patient record.

### 8.2 Where the App Requires Review Before Use

The app does **not** technically require or enforce review. The report is displayed in an editable `TextField` (ReportPanel widget), which the doctor can read and modify. There is no mandatory "I have reviewed this" confirmation step before copying or sending the report.

The auto-email feature (`_sendEmailIfEnabled()` in `session_provider.dart`) sends the report immediately after generation without any confirmation prompt.

### 8.3 Whether the Doctor Can Edit All Generated Text

**Yes.** The entire report is displayed in a single `TextField` with `maxLines: null` (unlimited scrolling text field, `report_panel.dart` line 133). The doctor can edit any character of the output. There is a "Uložit změny" (Save Changes) button when editing a loaded historical recording.

### 8.4 Automatic Sending to Patients or EHR

**No automatic EHR integration exists.** Reports are not automatically filed in any patient record system.

**Auto-email:** The report can be automatically emailed to a configured email address when the `Odesílat zprávu e-mailem` toggle is enabled in settings. This sends the full report (and optionally transcript) immediately after generation, without an explicit review step. The email address is configured by the doctor (not the patient). There is no forced delay or review gate before auto-send.

### 8.5 Final Confirmation Step

**No final confirmation step exists for any export operation:**
- Copy to clipboard: immediate, no confirmation.
- Manual email send: immediate after tapping "Odeslat emailem", no confirmation dialog.
- Auto-email: immediate on report generation completion, no confirmation.

### 8.6 Disclaimers in App, Website, Onboarding, Terms, Exported Report

| Location | Disclaimer Present? | Content |
|----------|--------------------|---------| 
| Mobile app UI (any screen) | **No explicit AI/draft disclaimer** | None found |
| In-app onboarding | **Not implemented** | No onboarding flow |
| Settings "About" section | Partial | "ANOTE Mobile v1.0.0 — Generování lékařských zpráv z hlasu." |
| Website/landing page | **Not found in codebase** | Not applicable to this analysis |
| Exported report (email) | Partial | "Lékařská zpráva vygenerovaná aplikací ANOTE / Tato zpráva byla automaticky odeslána aplikací ANOTE" |
| Terms of service | **Not implemented** | No terms or privacy policy in app |
| Privacy policy | **Not implemented** | No privacy policy in app |

---

## 9. Marketing and Website Claims

### 9.1 Claims Found in the Codebase (README.md, APP_ARCHITECTURE.md, settings screen)

| Claim | Location | File | Risk Level | Regulatory Impact | Safer Alternative |
|-------|----------|------|------------|-------------------|------------------|
| "Medical report generation from voice" | App description in pubspec.yaml, README title | `mobile/pubspec.yaml` line 3; `README.md` line 1 | **Medium** | "Medical report" implies clinical output; if interpreted as final documentation, may imply medical device use | "Medical documentation draft generation from voice" |
| "Structured Czech medical reports" | README Features section | `README.md` line 42 | **Medium** | "Medical reports" could imply clinical-grade finalised documentation | "Structured Czech medical report drafts" |
| "GDPR-compliant — Azure OpenAI in West Europe, no patient data leaves the EU" | README Features | `README.md` line 44 | **High** | Claims GDPR compliance without documented DPA, retention policy, or consent mechanism; data residency ≠ full GDPR compliance | "Azure OpenAI in West Europe (EU data residency). GDPR compliance requires additional organisational measures." |
| "On-device transcription — Whisper Small (INT8) via sherpa_onnx, no audio leaves the device" | README Features | `README.md` line 40 | **Medium** | True for Local/Turbo mode, but false for Cloud/Hybrid mode. Could mislead about data processing | "On-device transcription available (Local mode); cloud transcription option also available" |
| "Medical dictation app for Czech doctors" | Architecture overview | `APP_ARCHITECTURE.md` line 3 | **Low** | Factually accurate | No change needed |
| "Generování lékařských zpráv z hlasu." (Medical report generation from voice) | Settings screen About section | `settings_screen.dart` line 403 | **Medium** | Same as above | "Generování návrhů lékařských zpráv z hlasu." (draft) |
| "gpt-4.1-mini selected for production — fast enough for 15s update cycle, GDPR-compliant" | README model comparison table | `README.md` line 424 | **Medium** | "GDPR-compliant" applied to a model without documented zero-retention or DPA | Remove the claim or qualify: "EU data residency (Standard SKU)" |
| "13-section structured Czech medical report" | README | `README.md` line 42 | **Low** | Accurate description | No change needed |
| "Azure deployment — GDPR: Standard SKU ✅ / GlobalStandard ❌" | README model comparison | `README.md` line 418 | **Medium** | Implies Standard SKU is fully GDPR-compliant; this is incomplete | Clarify that Standard SKU provides EU data residency; full GDPR compliance requires DPA and organisational measures |

### 9.2 Claims Not Found

No claims of "medical-grade", "certified", "diagnosis", "doctor approved", "accuracy", "safety", "AI Act compliant" were found in the reviewed files.

### 9.3 Marketing Materials Not Reviewed

The following were not found in the codebase and could not be reviewed: website, App Store/Google Play listings, social media, advertisements. These must be reviewed separately.

---

## 10. EU AI Act Classification Support (Factual Input Only)

*No legal conclusions are drawn. Facts only.*

| Question | Answer | Evidence |
|----------|--------|----------|
| Is the app used in healthcare? | **Yes** | Target users are Czech doctors; output is structured medical documentation; audio content is doctor–patient consultations. |
| Is it used by professionals only? | **Yes** — in the current implementation | No patient interface. Patients do not use the app. |
| Does it make or assist decisions about patients? | **Unclear** | The app structures what the doctor said into a report. The doctor decides. However, the reformatting and structuring by the LLM could influence how information is presented, which could affect downstream clinical decisions. |
| Does it influence access to healthcare? | **No** — directly | The app does not gate or restrict access to care. It produces documentation that may be used in clinical decision-making, but does not make triage or access decisions. |
| Does it perform diagnosis? | **Intended: No. Actual: Unclear** | The Hodnocení section may contain diagnostic language transcribed from the doctor's speech. The LLM may reformat or infer diagnostic labels. |
| Does it perform prognosis? | **No** | No prognostic section or instruction in prompts. |
| Does it perform triage? | **No** | No triage function or output. |
| Does it perform risk assessment? | **No** | No risk scoring. |
| Does it perform treatment recommendation? | **Intended: No. Actual: Unclear** | Návrh terapie section may contain treatment recommendations structured from the doctor's speech. |
| Is it only a productivity/documentation assistant? | **Intended: Yes** | Developer intent is documentation assistance. But the output resembles a final clinical record. |
| Is there human review? | **Yes — technically possible, not enforced** | Report displayed in editable text field. Doctor can review and edit. Auto-email can bypass manual review. |
| Are users informed that AI generated the draft? | **Partially** | Email footer says "vygenerovaná aplikací ANOTE". No explicit "AI-generated draft" label in the app UI or on the report itself. |
| Are patients informed when AI is used? | **No** | No patient notification mechanism. Patients are not users of the app. No mechanism for the app to generate patient-facing consent or notification. |
| Are logs kept? | **Partially** | Backend logs HTTP metadata (not content). No audit log of AI outputs, no log of who accessed what. |
| Are instructions for use (IFU) available? | **No** | No IFU documented in the codebase. README is a developer guide, not a clinical IFU. |
| Are accuracy/limitations documented? | **Partial** | README documents WER/CER benchmarks for transcription. No documentation of LLM report accuracy, failure modes, or limitations for clinical use. |
| Is the AI system purpose-built for the healthcare domain? | **Yes** | Czech medical report generation, Czech clinical terminology, medical section headers, healthcare-specific prompts. |
| Is there a technical measures list (transparency/oversight)? | **No** | No technical measures documentation for AI Act compliance purposes. |

---

## 11. MDR Classification Support (Factual Input Only)

*No legal conclusions are drawn. Facts only.*

| Question | Answer | Evidence |
|----------|--------|----------|
| Is there an intended medical purpose? | **Unclear** | Developer states: documentation/transcription tool, not diagnosis. The output is used to create medical records. Whether creating medical records constitutes a "medical purpose" under MDR Rule 2(1) is a legal question. |
| Does the software provide information used for diagnosis? | **Unclear** | Hodnocení section contains working diagnosis from the doctor's own words, reformatted by LLM. If the LLM's reformatting changes or selects the diagnostic framing, this could be information used in a diagnostic context. |
| Does the software provide information used for therapeutic decisions? | **Unclear** | Návrh terapie and Návrh vyšetření sections contain treatment/investigation proposals. These originate from the doctor's speech, but are reformatted by the LLM. |
| Does it monitor physiological processes? | **No** | No sensor integration, no continuous monitoring. Audio is of speech only. |
| Are outputs used directly for patient management? | **Unclear** | The structured report is the output; the doctor uses it for clinical documentation. If the report is directly filed as the clinical record without further editing, the LLM output becomes the patient management document. |
| Are outputs only administrative/documentation drafts? | **Intended: Yes. Actual: Unclear** | Intended as drafts. No technical mechanism prevents unedited filing. No watermark/draft label on output. |
| Does all output require physician review? | **Technically possible, not technically enforced** | Editable text field is present. Auto-email bypasses explicit review. |
| Does the software perform calculations or transformations with clinical significance? | **Unclear** | No arithmetic calculations. The LLM performs natural language transformation that may alter clinical meaning (e.g. normalising medication names, inferring negations). Procedure reports include fibrosis/steatosis staging which, if inferred from numeric values by the LLM without explicit doctor statement, would constitute clinically significant interpretation. |
| Does the software control or influence a medical device? | **No** | No hardware interface; no medical device control. |
| Could any feature fall under Rule 11 for medical device software? | **Unclear — requires legal assessment** | Rule 11 applies to software that provides information used to make decisions with diagnostic or therapeutic purposes. The Hodnocení, Návrh terapie, Návrh vyšetření, and procedure Závěr sections produce text that doctors may use as part of diagnostic/therapeutic documentation. Whether this constitutes "information used to make decisions" within Rule 11 is a legal question for regulatory counsel. |
| Is the software intended to replace clinical judgement? | **Intended: No** | Developer explicitly states it is not. Prompts instruct the LLM to transcribe what the doctor said, not to add clinical judgement. |
| Does the software output a finished document or a draft? | **Both** — depending on what the doctor does with it | Technically it is a draft. Functionally, a doctor could file it unchanged as the clinical record. |

---

## 12. Evidence Appendix

### 12.1 Files Reviewed

| File | Description |
|------|-------------|
| `backend/main.py` | Backend API, all endpoints, all prompts, all system prompt construction functions |
| `backend/requirements.txt` | Backend Python dependencies |
| `backend/Dockerfile` | Container build specification |
| `backend/.env.example` | Environment variable template |
| `backend/.azure/config` | Azure CLI defaults |
| `mobile/pubspec.yaml` | Flutter app metadata and dependencies |
| `mobile/lib/main.dart` | App entry point, theme setup |
| `mobile/lib/config/constants.dart` | App constants, URLs, storage keys |
| `mobile/lib/models/session_state.dart` | Session state model, enum definitions |
| `mobile/lib/models/recording_entry.dart` | Recording persistence model |
| `mobile/lib/providers/session_provider.dart` | Core state machine, recording pipeline |
| `mobile/lib/screens/home_screen.dart` | Main UI |
| `mobile/lib/screens/settings_screen.dart` | Settings UI |
| `mobile/lib/services/audio_service.dart` | (referenced; content not read directly but inferred from usage) |
| `mobile/lib/services/whisper_service.dart` | On-device STT, hallucination filter, model download |
| `mobile/lib/services/cloud_transcription_service.dart` | Azure Whisper API client, VAD integration |
| `mobile/lib/services/vad_service.dart` | Standalone VAD for cloud path |
| `mobile/lib/services/report_service.dart` | HTTP client for backend |
| `mobile/lib/services/recording_storage_service.dart` | JSON file persistence |
| `mobile/lib/widgets/record_fab.dart` | Recording button widget |
| `mobile/lib/widgets/report_panel.dart` | Report display and editing widget |
| `README.md` | Project documentation, deployment instructions, marketing claims |
| `APP_ARCHITECTURE.md` | Architecture diagrams and descriptions |
| `mobile/assets/hotwords_cs_medical.txt` | Czech medical hotwords for Whisper (existence confirmed; content not read) |
| `mobile/assets/demo_scenarios/*.txt` | Demo patient scenario transcripts |

### 12.2 API Endpoints Reviewed

| Endpoint | Method | Auth | Reviewed |
|----------|--------|------|---------|
| `/health` | GET | None | ✅ |
| `/scenarios` | GET | None | ✅ |
| `/report` | POST | Bearer | ✅ |
| `/send-report-email` | POST | Bearer | ✅ |
| `/test-report/{scenario_name}` | POST | Bearer | ✅ |

### 12.3 Prompt Files Reviewed

All prompts are embedded in `backend/main.py`. No external prompt files exist. Reviewed:

- `_build_base_rules()` — ZÁSADY block
- `_build_sections_initial()` — 13-section initial visit template
- `_build_sections_followup()` — follow-up visit template
- `_build_sections_gastroscopy()` — gastroscopy template
- `_build_sections_colonoscopy()` — colonoscopy template
- `_build_sections_ultrasound()` — ultrasound template
- `TASK0036_PROMPT_SUFFIX` — principles and procedural rules
- `_build_system_prompt()` — assembly function

### 12.4 UI Screens Reviewed (via source code)

- HomeScreen (`home_screen.dart`) — recording, transcript, report panels, action row
- SettingsScreen (`settings_screen.dart`) — backend config, model selection, email, visit type, theme
- ReportPanel (`report_panel.dart`) — editable report display
- RecordFAB (`record_fab.dart`) — recording control button

### 12.5 Configuration Files Reviewed

| File | Content |
|------|---------|
| `backend/.env.example` | Azure OpenAI key, endpoint, deployment, API token template |
| `backend/requirements.txt` | Python dependencies |
| `backend/Dockerfile` | Python 3.12-slim, uvicorn startup |
| `mobile/pubspec.yaml` | Flutter dependencies: riverpod, sherpa_onnx, flutter_secure_storage, dio, audio_streamer, flutter_foreground_task |

### 12.6 Third-Party Services Identified

| Service | Purpose | Data Shared | EU Region? |
|---------|---------|------------|-----------|
| Azure OpenAI (West Europe) | LLM report generation | Czech transcript | ✅ Yes |
| Azure OpenAI (Sweden Central) | Cloud STT | Audio WAV | ✅ Yes |
| Azure Container Apps (West Europe) | Backend hosting | HTTP traffic | ✅ Yes |
| Azure Container Registry (West Europe) | Docker images | No runtime data | ✅ Yes |
| HuggingFace (CDN) | Model download | No personal data | ❓ Unknown CDN region |
| GitHub releases (CDN) | VAD model download | No personal data | ❓ Unknown CDN region |
| SMTP provider (configurable) | Email delivery | Report + transcript text | ❓ Unknown |

### 12.7 Unknowns and Missing Information

| Item | Status | Notes |
|------|--------|-------|
| `mobile/lib/config/secrets.dart` | File exists locally but not inspected in full | Contains `Secrets.backendApiToken` and `Secrets.azureWhisperKey` — likely git-ignored. Confirm whether git-ignored or exposed in version history. |
| Azure Data Processing Agreement (DPA) | Unknown | Determines whether Azure OpenAI processing of health data is lawful under GDPR. |
| Azure OpenAI zero-retention configuration | Not in code | Needs confirmation at Azure account/subscription level. |
| SMTP provider identity | Not specified | `SMTP_HOST`, `SMTP_USER` are environment variables — provider unknown. Data residency of email unknown. |
| Privacy policy | Not in codebase | Must be documented externally. |
| Terms of service | Not in codebase | Must be documented externally. |
| Patient consent mechanism | Not in codebase | No mechanism exists. |
| Azure log retention period | Not specified | Azure Container Apps default log retention applies (typically 30 days). |
| Git history of `secrets.dart` | Not reviewed | Should be checked to confirm no credentials were committed. |
| Website/landing page content | Not in codebase | Separate review needed. |
| App Store listing copy | Not in codebase | Separate review needed. |
| Audio service implementation | `audio_service.dart` referenced but not read | Content not reviewed; assumed to be standard microphone capture. |
| Whisper isolate worker | `whisper_isolate_worker.dart` referenced but not read | Assumed to implement the on-device transcription pipeline per `whisper_service.dart` usage. |

### 12.8 Questions for the Founder/Developer

1. **Training data opt-out:** Have you signed an Azure OpenAI Data Processing Agreement and confirmed that Standard SKU does not use your data for model training? If not, what data protection measures are in place?
2. **Zero-retention:** Is zero-data-retention configured for the Azure OpenAI resource, or is this on the roadmap?
3. **SMTP provider:** Which SMTP provider is used in production? Is it EU-based? Is TLS enforced?
4. **Secrets file:** Is `mobile/lib/config/secrets.dart` excluded from version control? Has the git history been checked for accidental secret commits?
5. **Patient consent:** Is the tool used during live doctor–patient consultations (audio of patient captured), or only for doctor dictation after the patient has left? If patient audio is captured, what is the consent mechanism?
6. **Data retention:** What is the intended data retention period for on-device recordings? For Azure OpenAI processing logs?
7. **Clinical context:** Will the LLM-generated report be directly filed in the patient record, or will it only be used as a working draft that the doctor then transcribes into their EHR?
8. **IFU/documentation:** Is there any instruction for use document, user manual, or training material for doctors?
9. **Email recipient:** Is the configured email always the doctor's own address, or can it be a clinic shared address, a secretary, or a patient?
10. **Auto-email and review:** Is the auto-email feature intended to be used before the doctor has reviewed the report, or is the expectation that the doctor reviews first and then manually triggers the email?
11. **MDR classification intent:** Has the developer obtained any regulatory opinion on whether the tool falls inside or outside MDR scope?
12. **Speciality scope:** Which specialities are currently using or intended to use ANOTE? The follow-up visit template appears tailored for diabetology/endocrinology (mentions hypoglycaemia, pump, sensor, closed loop).
13. **HuggingFace download:** The Whisper models are downloaded from HuggingFace on first launch. Is there any integrity/checksum verification? (Note: size checks exist, but no hash verification.)
14. **CORS policy:** The backend currently allows all origins (`allow_origins=["*"]`). Is this intentional for production, or was this set for development?

---

*End of report.*
