# ANOTE — Doctor Feedback Analysis

**Corpus:** 18 report samples (feedback_01–18) collected May 2026  
**Doctor:** One testing physician (diabetology / general practice)  
**Format:** Plain-text email reports with inline `<FEEDBACK>…</FEEDBACK>` tags marking issues

---

## File Index

| File | Date | Case / Specialty | Has FEEDBACK tags | Notes |
|------|------|-----------------|-------------------|-------|
| feedback_01.txt | 27.05.2026 | DM1 pump follow-up | ✅ 2 | Verbosity, misattribution |
| feedback_02.txt | 28.05.2026 | GP — suspected pneumonia | ✅ 4 | Critical ASR misinterpretations |
| feedback_03.txt | 21.05.2026 | GP — ear pain (otitis) | ❌ | Missing diastolic TK, ASR error in nález |
| feedback_04.txt | 21.05.2026 | GP — ear pain (duplicate visit) | ❌ | Same case as 03, conflicting pulse value noted |
| feedback_05.txt | 21.05.2026 | DM1 pump + sensor (52y) | ❌ | Irrelevant social detail (Audi) |
| feedback_06.txt | 21.05.2026 | DM1 pump + sensor (duplicate) | ❌ | Same case as 05, slightly cleaner |
| feedback_07.txt | 21.05.2026 | DM1 pump + sensor (3rd gen) | ✅ 3 | Speaker misattribution, hallucinated negation |
| feedback_08.txt | 14.05.2026 | DM2 + urinary symptoms | ✅ 2 | Misunderstood sleep pattern, irrelevant waiting-room complaint |
| feedback_09.txt | 14.05.2026 | DM + 90% off-topic conversation | ✅ 1 (header) | Noise filtering failure |
| feedback_10.txt | 14.05.2026 | DM neuropathy (insulin pump) | ❌ | GA meta-commentary, verbose SA |
| feedback_11.txt | 14.05.2026 | DM neuropathy (email copy) | ❌ | Same case as 10, jehly/cartridge confusion |
| feedback_12.txt | 14.05.2026 | DM2 + urinary (duplicate) | ❌ | Identical to 08 |
| feedback_13.txt | 14.05.2026 | Empty report | ❌ | All sections "neuvedeno" — failed/empty recording |
| feedback_14.txt | 14.05.2026 | Empty report | ❌ | Same — all "neuvedeno" |
| feedback_15.txt | 14.05.2026 | DM neuropathy (3rd variant) | ✅ 2 | Speaker misattribution (doctor's suggestion → patient) |
| feedback_16.txt | 13.05.2026 | Joint pain / knee swelling | ✅ 7 | Most critical: Lyme disease hallucination, multiple filler issues |
| feedback_17.txt | 30.04.2026 | DM pump follow-up + 90% social | ✅ 1 (header) | Noise filtering failure, hallucinated negations |
| feedback_18.tdt | 22.05.2026 | Hepatology — jaundice + alcoholism | ✅ 4 | Irrelevant post-visit event, good structure overall |

**Note on duplicates:** Several visits generated multiple reports (different recordings or regenerations of same transcript):
- feedback_03 ≈ feedback_04 — same ear pain case
- feedback_05 ≈ feedback_06 ≈ feedback_07 — same DM pump session (52yr patient)
- feedback_08 ≈ feedback_12 — identical content
- feedback_10 ≈ feedback_11 ≈ feedback_15 — same neuropathy patient

---

## Issue Catalog

Issues are ranked by severity. Each issue type includes frequency across the 18 files.

---

### ISSUE-01 — Hallucinated Clinical Diagnosis (CRITICAL 🔴)

**Frequency:** 1 confirmed case (feedback_16), pattern risk in others  
**Description:** The model inferred a specific diagnosis ("borelióza" / Lyme disease) from a brief indirect mention of a tick bite and a red spot, without the doctor diagnosing or even suspecting it.

> Doctor's feedback: *"tady jsem jen řekl, že měla klíště a po něm červený flek, aplikace z toho udělala Boreliozu sama — to je velká chyba"*

The report went on to suggest Lyme disease as the differential and ordered borrelia-specific workup. This is a **patient safety issue** — a false diagnosis in a medical record can influence future care.

**Root cause:** TASK0036 Principle 3 ("no inference beyond the transcript") is being violated. The model applied general medical knowledge to fill a causal gap instead of leaving the finding undiagnosed.

---

### ISSUE-02 — Hallucinated Negations (HIGH 🟠)

**Frequency:** 4 files (feedback_07, feedback_16 AA, feedback_17 AA, feedback_01 AA)  
**Description:** The model writes standard negation phrases ("Zvýšenou teplotu neguje", "alergie neguje") in sections where the topic was **never discussed at all**, effectively fabricating a clinical finding.

> Doctor's feedback (feedback_07): *"o teplotě se nemluvilo"*  
> Doctor's feedback (feedback_16 AA): *"Tady jsem nic nezmínil, ani se na to neptal."*

**Root cause:** The prompt instructs the model to "actively record negations" and the base rules list many example negation phrases. The model treats the absence of a topic as an opportunity to insert template negations rather than writing "neuvedeno". Principle 4 in TASK0036 tries to fix this but is not reliably enforced.

---

### ISSUE-03 — ASR Error → Critical Medical Misinterpretation (CRITICAL 🔴)

**Frequency:** 3 files (feedback_02, feedback_03, feedback_18)  
**Description:** ASR transcription errors cause the model to write medically incorrect or inverted information.

Key cases from feedback_02:
- ASR heard **"policie"** (police) → diagnosis **"Polycythemia vera"** — model wrote *"léčen u policie"* (treated at the police). Doctor's real diagnosis was Polycythemia vera.
- ASR transcribed treatment as **"krevní transfuze"** (blood transfusion) → Doctor's feedback: *"provádí se opak — puštění žilou"* (phlebotomy). These are opposite treatments.
- **"alergie na Jar"** (Jar = dish soap brand) → model wrote *"alergie na jarní pyl"* (spring pollen allergy). Completely different.
- feedback_18: "okeny" (window cleaner fluid, consumed as alcohol substitute) → model wrote *"pravděpodobně psychotropní látka"*

**Root cause:** Base rule says "interpretuj smysl, ne doslovný text" (interpret meaning, not literal text). This is correct behavior for minor ASR noise but becomes dangerous when the ASR error produces a plausible but wrong medical word. The model makes the "sensible" interpretation rather than flagging the ambiguity.

---

### ISSUE-04 — Speaker Misattribution (HIGH 🟠)

**Frequency:** 4 files (feedback_07, feedback_08, feedback_15, feedback_16)  
**Description:** The model assigns the doctor's statements, opinions, or suggestions to the patient in the report.

> feedback_07: *"to jsem říkal já"* — doctor's information about a new drug (teplicizumab) put under patient's NO narrative.  
> feedback_15: *"toto vysvětlení jsem navrhoval já"* — doctor's suggestion of dehydration as cause attributed to patient.  
> feedback_15: *"chtěla se zeptat v lékárně"* — doctor's recommendation to ask pharmacist attributed as patient's own initiative.

**Root cause:** The prompt instructs the model to assign roles by cues (questions→doctor, complaints→patient), but in real follow-up conversations the doctor and patient talk naturally without clear syntactic role markers. The model defaults to attributing information to the patient when uncertain.

---

### ISSUE-05 — Noise / Off-Topic Content Included in Report (HIGH 🟠)

**Frequency:** 5 files (feedback_05, feedback_06, feedback_09, feedback_17, feedback_16, feedback_18)  
**Description:** Content with zero clinical relevance leaks into the report. Two files have explicit overall feedback about this being a systemic problem.

Examples:
- Presentation planned for Audi car company → ended up in SA (feedback_05, feedback_06)
- GPT service outages, energy crisis, glass industry, investments, IT problems → in NO and SA (feedback_17)
- Conversation about how history is taught in schools → in SA (feedback_16)
- Patient losing wallet after the visit → "Dodatečná informace" section (feedback_18)
- Waiting-room complaint about another city's clinic → in NO (feedback_08)
- Emotional discussion about a friend's lung transplant and retirement homes → in SA (feedback_09)

Doctor's summary feedback:
> feedback_09: *"tohle je dlouhý rozhovor z 90% o jiných věcech než osobní zdraví. To systém nedokáže rozlišit, je to zmatečné."*  
> feedback_17: *"Systém nepozná, kdo, co v konverzaci řekl. s těmi pacienty, co znáte dlouho, se bavíte o spoustě věcí, které nijak nesouvisí s jejich nemocemi."*

**Root cause:** TASK0036 Principle 1 and Rule P1 try to filter non-clinical content, but the filtering is too conservative. The model still includes content when it's tangentially health-adjacent (stress, lifestyle, social context). Long conversational digressions are the most common real-world scenario for follow-up visits with established patients.

---

### ISSUE-06 — Over-Inferencing / Model Reasoning Visible in Output (MEDIUM 🟡)

**Frequency:** 8 files  
**Description:** The model includes its own reasoning, hedging, or uncertainty into the report text, producing output that reads like analysis rather than documentation.

Examples:
- `"alergie neguje (neuvedeno, ale nezmíněny žádné alergické reakce)"` — combined negation + meta-commentary
- `"neuvedeno (předpoklad muž)"` — in GA section
- `"z kontextu lze předpokládat, že má diabetes"` — inference in OA
- `"pravděpodobně mylný přepis"`, `"patrně poliklinika nebo onemocnění"` — model editing itself inside report
- `"(dýchání 72 za minutu je evidentní chyba"` — model annotating its own uncertainty

**Root cause:** The prompt has many rules that make the model careful about uncertainty (negation vs. "neuvedeno" distinction, etc.), but this carefulness leaks out as visible hedging prose in the output. No instruction explicitly says "do not expose your reasoning in parentheses."

---

### ISSUE-07 — Verbose Reports / Long Compound Sentences (MEDIUM 🟡)

**Frequency:** All reports, explicitly noted in feedback_01, feedback_07  
**Description:** Reports contain over-long bullets, multi-clause sentences, and redundant fillers across sections that add length without clinical value.

> feedback_01: *"Této větě neporozumněl, byla složitá."* — referring to a convoluted sentence about correction boluses and pump regulation that bundled 3 distinct concepts.

Pattern: Sections that have real content expand to 6–10 bullets. Sections with nothing just fill with "Neuvedeno kouření, alkohol ani jiné sociální informace" instead of a clean single-word `neuvedeno`.

**Root cause:**  
- `max_completion_tokens=4096` — no constraint on output length  
- Prompt rule "Raději uveď informaci navíc, než aby chyběla" actively rewards verbosity  
- No instruction specifying a target sentence length or word budget  

---

### ISSUE-08 — Wrong Section Placement (LOW 🟢)

**Frequency:** 3 files (feedback_01, feedback_08, feedback_16)  
**Description:** Clinical items end up in the wrong section.

- Plan/action item (výměna hadiček pumpy) placed in **Adherence** instead of **Návrh terapie** (feedback_01)
- Patient-reported glucose values placed in **Objektivní nález** (feedback_08, feedback_11)
- Medical history inference in **NO** instead of **OA** (feedback_09)

**Root cause:** The model follows section descriptions but sometimes uses neighboring sections when the exact fit is ambiguous. The "Adherence" section instructions say to record what the patient wants/needs, which the model misread as including action items.

---

### ISSUE-09 — Incomplete / Empty Reports (MEDIUM 🟡)

**Frequency:** 2 files (feedback_13, feedback_14)  
**Description:** Two reports are fully empty — all 13 sections contain only "neuvedeno". These appear to be recordings that captured no or insufficient medical speech (too short, background noise only, or accidental trigger).

**Root cause:** The backend accepts any non-empty transcript and generates a report. There is no minimum-content guard at the report generation step. A transcript with only ambient noise or a few words still produces a fully-structured empty report.

---

## Summary Statistics

| Issue | Severity | Files affected | Frequency |
|-------|----------|----------------|-----------|
| ISSUE-01: Hallucinated diagnosis | 🔴 CRITICAL | 1 confirmed | 1/18 |
| ISSUE-03: ASR → medical misinterpretation | 🔴 CRITICAL | 3 | 3/18 |
| ISSUE-02: Hallucinated negations | 🟠 HIGH | 4 | 4/18 |
| ISSUE-04: Speaker misattribution | 🟠 HIGH | 4 | 4/18 |
| ISSUE-05: Noise / off-topic content | 🟠 HIGH | 6 | 6/18 |
| ISSUE-06: Model reasoning in output | 🟡 MEDIUM | 8 | 8/18 |
| ISSUE-07: Verbose / complex sentences | 🟡 MEDIUM | 18 | 18/18 |
| ISSUE-09: Empty reports | 🟡 MEDIUM | 2 | 2/18 |
| ISSUE-08: Wrong section placement | 🟢 LOW | 3 | 3/18 |

---

## Proposed Improvements

### A — Prompt Changes (apply to both live and final generation)

**A1 — Eliminate hallucinated negations** *(fixes ISSUE-02)*  
Replace the current instruction that actively encourages negation recording with a stricter rule:  
> "Piš negaci pouze pokud pacient nebo lékař výslovně negoval danou věc v přepisu. Pokud dané téma v přepisu vůbec nezaznělo, nepiš negaci — piš pouze 'neuvedeno'. Nikdy nepřidávej standardní negace ('alergie neguje', 'teplotu neguje') jako šablonový filler."

**A2 — Suppress model reasoning in output** *(fixes ISSUE-06)*  
Add an explicit rule:  
> "Nikdy nevkládej do zprávy závorky obsahující tvůj vlastní komentář, úvahu o jistotě, nebo popis toho, co jsi usoudil. Report obsahuje pouze klinická fakta. Pokud si nejsi jistý, napiš 'neuvedeno' nebo označ jako 'k upřesnění', nic víc."

**A3 — Hard target length** *(fixes ISSUE-07)*  
Add to the footer of the prompt:  
> "DÉLKA ZPRÁVY: Cílová délka je 200–350 slov pro kontrolní návštěvu a 350–500 slov pro vstupní vyšetření. Piš stručně — každý bullet obsahuje jednu myšlenku v jedné větě. Pokud sekce nemá obsah, piš pouze 'neuvedeno' bez vysvětlení."

**A4 — Noise filtering reinforcement** *(fixes ISSUE-05)*  
Strengthen Principle 1 with a concrete filter rule:  
> "Do zprávy nepatří: rozhovory o počasí, politice, práci (pokud neovlivňuje zdravotní stav), technologiích, financích, jiných lidech kromě pacienta, ani příhody po skončení návštěvy. Pokud 90 % rozhovoru není zdravotní, vytěž pouze klinicky relevantní úseky a ostatní ignoruj."

**A5 — ASR ambiguity flagging** *(partially fixes ISSUE-03)*  
When a word triggers ambiguity (sounds like two very different things):  
> "Pokud slovo v přepisu může být chybně rozpoznáno ASR a má více než jeden smysluplný výklad, zaznamenej ho jako '[slovo — k ověření]'. Neinterpretuj ASR chybu jako klinický pojem, pokud si nejsi jistý."

**A6 — No diagnosis inference** *(fixes ISSUE-01)*  
Reinforce Principle 3 with an explicit clinical example:  
> "Nikdy nestanovi diagnózu na základě implicitních vodítek. Klíště + červený flek ≠ borelióza, pokud lékař boreliózu nezmínil. Zapiš pouze symptom/nález, diagnózu nechej prázdnou nebo neuvedenou."

**A7 — Speaker attribution default** *(fixes ISSUE-04)*  
Clarify the default when speaker is unknown:  
> "Pokud není jasné, kdo informaci vyslovil (lékař nebo pacient), zapiš ji bez přiřazení mluvčího. Nepřiřazuj lékaři formulovaná tvrzení k pacientovi jen proto, že jsou umístěna ve větě blízko jiných pacientových výroků."

---

### B — Dual-Model Architecture (Live Draft + Final Report)

**The proposal:** Use two different models in sequence.

```
Recording in progress
    ↓
Fast model (e.g. gpt-4.1-mini / gpt-5-nano)
→ Live draft shown in app while doctor is still recording
→ Updates every N seconds as transcript grows
→ Purpose: rough orientation, not saved anywhere

Recording stops
    ↓
Better model (e.g. gpt-5 / o3)
→ Final report generated once, sent by email, saved
→ Takes the full final transcript
→ More careful inference, better noise filtering
→ Potentially also does a self-check pass
```

**What this changes in the backend:**

The `/report` endpoint already has `CHAT_MODEL` + `FALLBACK_MODEL`. A new request parameter `final: bool = False` would switch between model tiers:
- `final=False` → `CHAT_MODEL` (fast, cheap, used during recording)
- `final=True` → a new `FINAL_MODEL` env var pointing to the better deployment

The prompt stays **identical** for both — the doctor shouldn't see different structure between the live preview and the final report. Only the model changes.

**What the better model actually improves:**

| Issue | Live model | Final model |
|-------|-----------|-------------|
| Noise filtering (ISSUE-05) | Partial | Better reasoning about clinical relevance |
| Hallucinated diagnosis (ISSUE-01) | Risk | Better instruction following |
| ASR ambiguity (ISSUE-03) | Misinterprets | Better context window for disambiguation |
| Speaker attribution (ISSUE-04) | Struggles | More robust role tracking |
| Sentence brevity (ISSUE-07) | Verbose | Better at following length constraints |

**Important:** Prompt improvements (section A above) apply to **both** models. The better model alone does not fix structural prompt issues — the prompt must also be corrected.

---

### C — Empty Report Guard

For ISSUE-09, add a pre-generation check in the `/report` endpoint:

```python
# Rough heuristic: if transcript has fewer than 50 words or no question marks / medical keywords,
# return a warning instead of generating an empty shell report
if len(transcript.split()) < 50:
    return {"report": None, "warning": "Přepis je příliš krátký pro generování zprávy."}
```

The mobile app should display this gracefully instead of showing an empty 13-section document.

---

## Format Conventions for This Feedback Folder

### File naming
`feedback_NN.txt` — sequential numbering, plain `.txt`.  
(feedback_18 uses `.tdt` — should be renamed to `.txt` for consistency.)

### Recommended header block (not yet used consistently)
```
Visit type: followup|initial|default
Specialty: diabetologie|praktický lékař|gastroenterologie|...
Date: DD.MM.YYYY
Doctor ID: DR-01  (anonymized)
---
[report text with inline <FEEDBACK>…</FEEDBACK> tags]
```

### FEEDBACK tag types
Distinguish feedback categories using the `type` attribute for easier programmatic analysis:

| Type | Meaning |
|------|---------|
| `type="hallucination"` | Model invented something not in the transcript |
| `type="misattribution"` | Doctor's statement attributed to patient or vice versa |
| `type="correction"` | What the patient/doctor actually said vs. what was written |
| `type="noise"` | Irrelevant content that should have been filtered out |
| `type="verbosity"` | Sentence or section is too long / complex |
| `type="structure"` | Item placed in the wrong section |
| `type="missing"` | Something that was said is not in the report |

Example: `<FEEDBACK type="hallucination">Toto jsem neřekl — borelióza nebyla diagnostikována.</FEEDBACK>`

---

## Next Steps

1. **Immediately:** Apply prompt changes A1, A2, A6 — they address the highest-severity issues (hallucinated negations and diagnosis inference) with minimal risk of regression.
2. **Short-term:** Test A3 (length constraint) on 5 real transcripts, compare with current output.
3. **Before model upgrade:** Validate all prompt changes on existing test scenarios in `backend/` eval infrastructure first.
4. **Model upgrade:** Add `FINAL_MODEL` to backend config, add `final` flag to `/report` endpoint, update `ReportService.generateReport()` in Flutter to pass `final: true` on post-recording call.
5. **Ongoing:** Continue collecting feedback files. Aim for 30+ before making major prompt changes, to have enough signal to evaluate regressions.
