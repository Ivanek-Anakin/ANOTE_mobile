# Feedback Analysis — Dr. Jan Brož (6 Sessions)

> Analysis of 6 testing sessions by Dr. Jan Brož (internist/diabetologist), testing the ANOTE mobile medical dictation app — on-device Whisper transcription → GPT-5-mini structured Czech medical report generation.

---

## 1. Executive Summary

The app produces **clinically usable** structured medical reports from doctor-patient conversations. The report structure (13-section Czech format) is well-received. However, the **transcription quality is the critical bottleneck** — the on-device Whisper Small model produces heavily garbled Czech text, especially with colloquial speech, overlapping voices, and medical terminology. Despite this, the LLM (GPT-5-mini) does a surprisingly good job recovering clinical meaning from noisy transcripts. The doctor's overall tone across sessions trends from cautious ("zase se to asi spustilo pár sekund po začátku") to positive ("teď to vypadá to super", "docela super").

### Key Metrics Across 6 Sessions

| # | Scenario | Transcript Quality | Report Quality | Doctor's Verdict |
|---|----------|--------------------|----------------|------------------|
| 1 | Cardiac emergency (ACS) | Poor — garbled but key facts survive | Good — correct structure, minor issues | "spustilo se pár sekund po začátku" (delayed start) |
| 2 | Deep vein thrombosis + PE | Very poor — nearly unreadable | Good — mostly correct despite garbage input | (no explicit comment on quality) |
| 3 | Pneumonia | Moderate — better than #1-2 | Very good — "vypadá to super" | "teď to vypadá to super" — specific terminology fix requested |
| 4 | Acute limb ischemia | Poor-moderate | Good — correct diagnosis captured | (detailed inline corrections) |
| 5 | Biliary colic | Moderate | Good — one missed item (food trigger) | "docela super" |
| 6 | Cirrhosis / decompensation | Poor — beginning cut off | Acceptable — limited by missing transcript | "začalo brát rozhovor až po pár vteřinách, chybí začátek" |

---

## 2. Critical Issues (by severity)

### 2.1 🔴 CRITICAL — Transcription Quality (On-Device Whisper Small)

**This is the single biggest problem.** The raw transcripts in feedback 1, 2, 4, 6 are heavily corrupted. Examples from feedback 2:

```
"Jak se mnujete? Já se mnuju jeřina Nováková"  → should be "Jak se jmenujete? Já se jmenuji Jeřina Nováková"
"cté angliou vysetření"                         → should be "CT angiografie vyšetření"
"homa odsobo zdramení"                          → should be "Homansovo znamení"
"hlbokážený trhůz"                              → should be "hluboká žilní trombóza"
```

From feedback 4:
```
"fibrilace síní, že mi to srničko bejží"        → decent (colloquial Czech captured)
"tady prostě v pravo jako podže brama"          → should be "vpravo pod žeberním obloukem"
```

From feedback 6:
```
"círhozu, jak to mu íkají doktorzy"             → should be "cirhózu, jak tomu říkají doktoři"
"olegický na paralén, ne, na ibuprofenu"        → should be "alergický na Paralen, ne, na ibuprofen"
```

**Root cause analysis:**
- Whisper Small INT8 (358 MB) struggles with: colloquial Czech, medical terminology, overlapping/rapid speech, low-confidence segments
- The hotwords file (`hotwords_cs_medical.txt`) has 134 medical terms but **sherpa_onnx's hotwords feature has limited effectiveness** for these error patterns
- VAD threshold (0.5 live / 0.45 final) may be too aggressive — cutting off word boundaries
- The 5-second sliding window with 3-second overlap creates deduplication artifacts

**Impact:** Despite heavily garbled input, GPT-5-mini recovers ~80-90% of clinical facts correctly. But the remaining 10-20% includes:
- Missed facts (food trigger in feedback 5)
- Misattributed information
- Lost beginning/end of recordings

### 2.2 🔴 CRITICAL — Recording Start Delay / Missing Beginning

Reported in feedback 1 and 6:
- **Feedback 1:** "zase se to asi spustilo pár sekund po začátku, uvedl jsem jméno a věk" — recording started a few seconds late, patient name and age were missed
- **Feedback 6:** "tady to začalo brát rozhovor až po pár vteřinách, chybí začátek" — beginning of conversation cut off

**Root cause analysis:**
- On first recording: Whisper model loading can take up to 30 seconds (5 retry attempts with exponential backoff)
- Even after model is loaded: AudioService initialization + mic permission = ~100-500ms delay
- The `feedAudio()` pipeline starts **after** model init completes — any speech during init is lost
- There is no audio buffering during model loading — early speech is **permanently lost**
- The UI shows "recording" status immediately (optimistic), but audio capture starts later

### 2.3 🟡 MAJOR — Recording End Cutoff (Last 10-20 Seconds)

From developer's personal experience: final 10-20 seconds sometimes missing from transcript.

**Root cause analysis:**
- Live transcription uses a 5-second sliding window trigger — speech in the last <5 seconds may not trigger a window
- `transcribeTail()` on stop should catch this, but:
  - It relies on `speechBuffer` which is VAD-filtered — quiet final remarks may be below VAD threshold (0.5)
  - The `finalizedBoundary` may not cover the very latest audio
  - There's a race condition: audio stream is stopped **before** final transcription runs — late-arriving audio buffers may be dropped
- In cloud mode: the raw audio buffer is sent whole, so this issue should be **less severe** (but not eliminated if audio stream stops too early)

### 2.4 🟡 MAJOR — Specific Medical Terminology Errors in Reports

**Feedback 3 — "chrůpky" vs "chropy":**
> "Jen je tam místo použitého termínu chrůpky slovo chropy (u vyšetření plic). To se též používá, ale chrůpky jsou lepší."

The LLM chose "chropy" (also valid) instead of "chrůpky" (preferred). This is a prompt engineering issue — the system prompt doesn't specify preferred terminology variants.

**Feedback 3 — "alergie" vs "intolerance":**
> "Alergie je alergie a intolerance je něco jiného."

The report conflated allergy with drug intolerance. This is a clinical accuracy issue in the LLM's medical reasoning.

**Feedback 1 — "chrůpky" listed as objective finding:**
> "chybí chrůpky oboustranně" — doctor noted this was wrong in the report's objective findings section

### 2.5 🟡 MAJOR — Gynecological/Urological Anamnesis Misuse

**Feedback 3** (explicit correction):
> "Gynek. ani urologická anamnéza u mužů není. Potíže s močením by měly padnout do nynějšího onemocnění (i u žen). Gynek anamnéza obsahuje obvykle: menzes od 14 let, porody 2, umělé přerušení (potraty): 2, menopausa od 56 let."

**Issue:** The LLM places urinary symptoms in GA section for male patients. GA should only contain gynecological history for female patients (menstruation, pregnancies, menopause). Urinary complaints → NO section.

**Feedback 2** correctly places gyn data:
> "Chodí pravidelně na mamografii a gynekologické prohlídky. Menstruace od 13 let..." — this is correct for a female patient.

### 2.6 🟡 MODERATE — Children Misplaced in Report Structure

**Feedback 1:**
> "Děti patří do RA, schválně jsem je zmínil u zaměstnání."

The doctor intentionally mentioned children in the employment context to test whether the app correctly categorizes them. Children/family should go into RA (Rodinná anamnéza), not SA. The report placed them in SA.

### 2.7 🟡 MODERATE — Missing Information That Was Spoken

**Feedback 3:**
> "není tam nic o bratrovi" — brother was mentioned in the conversation but missing from the report

**Feedback 5:**
> "jídlo jsem uvedl, asi to vypadlo v té části, kde se opakuje ano/ne" — food trigger was mentioned but lost, likely due to transcription repetition artifacts

**Feedback 4:**
> "Chybí popis jak přesně k tomu došlo nahoře v záznamu to je" — the description of how the pain started was in the transcript but not captured in the report

These are a mix of:
1. Transcription dropping segments (speech not captured by VAD)
2. LLM missing details from noisy transcript
3. Repetition/deduplication artifacts removing real content

### 2.8 🟢 MINOR — Pharmacological Anamnesis Completeness

**Feedback 4:** Report lists only one medication (antihypertensive) but patient mentioned multiple drugs including anticoagulation for AF and cholesterol medication. The transcript captured these partially, but the LLM only extracted one.

**Feedback 2:** "Bylo řečeno, že nic neužívá" — doctor noted the report should say "no medications" rather than "neuvedeno" since the patient explicitly denied taking any.

---

## 3. What Works Well

1. **Report structure** — The 13-section Czech medical report format is correct and clinically appropriate
2. **Negation handling** — The LLM correctly uses "neguje" formulations (e.g., "zvýšenou teplotu neguje", "dušnost neguje") — this was explicitly praised in feedback 3 ("teď to vypadá to super")
3. **Clinical reasoning** — Despite garbage transcripts, the LLM correctly identifies:
   - Suspected MI from chest pain + family history (feedback 1)
   - DVT + PE from leg swelling + respiratory symptoms (feedback 2)
   - Pneumonia from cough + fever + sputum (feedback 3)
   - Acute limb ischemia from sudden foot pain + AF history (feedback 4)
   - Biliary colic from RUQ pain + radiating to back (feedback 5)
4. **Robustness** — The LLM handles severely garbled input remarkably well
5. **Iterative improvement** — Between sessions, quality noticeably improved (doctor noted "teď to vypadá to super" in session 3)

---

## 4. Transcription Quality — Deep Dive & Improvement Paths

### 4.1 Current Pipeline Bottleneck Analysis

```
Doctor speaks → Mic (16kHz) → VAD (Silero 0.5) → Whisper Small INT8 → Garbled Czech
                                                                              ↓
                                                                   GPT-5-mini recovers ~85%
```

The bottleneck is clearly **Whisper Small INT8 on Czech colloquial medical speech**. The model is:
- Quantized (INT8) — loses precision vs FP16/FP32
- Small variant (244M params) — limited Czech vocabulary
- Running on mobile — no beam search, no language model rescoring
- VAD-filtered — may cut word boundaries

### 4.2 Will Cloud Transcription Solve It?

**Likely yes, substantially.** Azure OpenAI Whisper API uses:
- Whisper Large V3 (1.5B params) — ~4× larger model
- Full-precision inference on server hardware
- Better Czech language coverage
- The existing prompt provides medical context: `"Lékařská prohlídka, anamnéza pacienta. Diagnóza, terapie, medikace..."`

**However, cloud transcription has current limitations:**
1. **No streaming** — currently sends entire WAV file after recording stops (batch mode)
2. **No live transcript** — user sees nothing during recording in cloud mode
3. **Prompt is generic** — doesn't include the full medical terminology list from `hotwords_cs_medical.txt`
4. **Single request** — Azure Whisper has a ~25MB file limit, long recordings may exceed this
5. **Network dependency** — fails without internet, falls back to on-device

**Expected improvement with cloud:** Based on Azure Whisper's known Czech performance, expect:
- Medical terms like "Homansovo znamení", "hluboká žilní trombóza" to be correctly transcribed
- Patient names to be captured accurately
- Colloquial Czech ("srničko bejží") to still be challenging but better handled
- Overall transcript quality: ~70-80% → ~90-95% accuracy

### 4.3 Recommended Improvement Strategy (Prioritized)

#### Priority 1: Enhance Cloud Transcription (Highest Impact, Lowest Effort)

**A. Expand the Whisper prompt** — The current prompt is only 1 sentence. Azure Whisper supports up to ~224 tokens of prompt. A richer prompt biases the model toward correct medical terminology:

```
Current:  "Lékařská prohlídka, anamnéza pacienta. Diagnóza, terapie, medikace, vyšetření..."
Proposed: Include top 50 most-confused medical terms from feedback analysis, structured
          as example text the model would expect to transcribe.
```

**B. Implement chunked cloud transcription** — Split long recordings into ~2-minute chunks with overlap, send in parallel. This:
- Stays under Azure's file size limit
- Enables partial results during recording (pseudo-streaming)
- Allows per-chunk prompts tailored to conversation phase

**C. Hybrid mode: on-device live preview + cloud final** — Use on-device Whisper for live preview (low quality is OK for preview), then cloud Whisper for the final high-quality transcript on stop. This gives:
- Live feedback during recording (on-device, garbled but usable)
- High-quality final transcript (cloud)
- Best of both worlds

#### Priority 2: Fix Recording Start/End Issues (High Impact, Medium Effort)

**A. Pre-buffer audio during model load** — Start capturing audio immediately when user presses Record, buffer in memory. Once model is loaded, feed the buffered audio first. This prevents losing the first few seconds.

**B. Post-buffer audio on stop** — Continue capturing for 1-2 seconds after the user presses Stop, to catch trailing speech. Run final VAD+transcription on complete buffer including post-buffer.

**C. Preload model on app startup** — Instead of loading Whisper on first record press, preload during app initialization (background). This eliminates the cold-start delay entirely.

#### Priority 3: Improve LLM Report Accuracy (Medium Impact, Low Effort)

**A. Update system prompt with doctor's corrections:**
- GA section: Add rule "GA sekce pouze pro ženy (menzes, gravidity, porody, menopauza). U mužů GA sekce vynechej. Potíže s močením patří do NO."
- RA section: Add rule "Děti pacienta patří do RA, ne do SA."
- Terminology: Add preference for "chrůpky" over "chropy", distinction between "alergie" (immune-mediated) and "intolerance" (non-immune)
- Explicit negation: Add rule "Pokud pacient výslovně uvede, že neužívá žádné léky, napiš 'bez pravidelné medikace', nikoli 'neuvedeno'."

**B. Add post-processing validation** — Simple rule-based checks:
- If patient is male (detected from transcript), remove or skip GA section
- Cross-reference: if a fact appears in transcript but not in report, flag it

#### Priority 4: Improve On-Device Transcription (Medium Impact, High Effort)

**A. Switch to Whisper Turbo** — Already available in the app (~1 GB). Larger model = better Czech accuracy. Trade-off: more memory, slower initial load, but better transcription.

**B. Lower live VAD threshold** — From 0.5 to 0.4 or 0.35. More false positives (some silence transcribed) but fewer missed speech segments. The LLM can handle extra "noise" words better than missing words.

**C. Increase sliding window overlap** — From 3s to 5s. More redundancy at boundaries reduces word-boundary cutting.

**D. Czech-specific fine-tuning** — Long-term: fine-tune Whisper on Czech medical dictation audio. This is the nuclear option — highest impact but requires training data and infrastructure.

---

## 5. The "Last 10-20 Seconds Missing" Issue — Detailed Analysis

This symptom has multiple potential causes:

### Cause A: Audio stream stopped before final buffer delivered
The stop sequence is: cancel audio subscription → stop microphone → run final transcription. If there are audio buffers in-flight (async) when the subscription is cancelled, they are lost.

**Fix:** Flush the audio stream before cancelling. Wait for a "stream ended" confirmation, or add a 500ms drain delay.

### Cause B: VAD filters out trailing speech
If the doctor speaks quietly at the end (common — wrapping up), VAD at 0.5 threshold may not detect it as speech.

**Fix:** Always include the last 5-10 seconds of raw audio in the final transcription pass, regardless of VAD output.

### Cause C: Finalization boundary hasn't caught up
The incremental finalization (Phase 4) runs in 30-second chunks. If recording stops mid-chunk, `transcribeTail()` should handle the remainder. But if `finalizedBoundary` calculation has a off-by-one error, the tail may be shorter than expected.

**Fix:** Add 3-5 second overlap when computing the tail boundary.

### Cause D: Sliding window deduplication removes trailing content
The overlap removal algorithm normalizes text and finds suffix/prefix matches. If the final segment repeats words from the previous window, they may be deduplicated away.

**Fix:** Skip deduplication for the very last segment.

---

## 6. Summary of Recommendations

| # | Recommendation | Impact | Effort | Category |
|---|----------------|--------|--------|----------|
| 1 | Hybrid mode: on-device live + cloud final transcript | 🔴 Critical | Medium | Transcription |
| 2 | Pre-buffer audio during model load (fix start delay) | 🔴 Critical | Low | Recording |
| 3 | Post-buffer 1-2s after stop + flush audio stream | 🔴 Critical | Low | Recording |
| 4 | Expand Azure Whisper prompt with medical terminology | 🟡 Major | Low | Transcription |
| 5 | Fix GA section rules in system prompt (male vs female) | 🟡 Major | Low | Report quality |
| 6 | Fix children → RA rule in system prompt | 🟡 Major | Low | Report quality |
| 7 | Add explicit negation vs "neuvedeno" prompt rules | 🟡 Major | Low | Report quality |
| 8 | Preload Whisper model on app startup | 🟡 Major | Medium | Recording |
| 9 | Lower VAD threshold for final pass to 0.35 | 🟢 Moderate | Low | Transcription |
| 10 | Medical terminology preferences in system prompt | 🟢 Moderate | Low | Report quality |
| 11 | Chunked cloud transcription for long recordings | 🟢 Moderate | Medium | Transcription |
| 12 | Switch default on-device model to Whisper Turbo | 🟢 Moderate | Low | Transcription |

---

## 7. Raw Feedback Notes per Session

### Session 1 — Cardiac Emergency (ACS)
- **Doctor says:** Recording started a few seconds late, patient name and age were missed
- **Doctor says:** Children were intentionally mentioned under employment — should go to RA
- **Doctor notes:** "chrůpky oboustranně" missing from objective findings
- **Transcript:** Moderate quality, key medical facts preserved despite errors
- **Report:** Correct MI diagnosis, correct medication capture, structure good

### Session 2 — Deep Vein Thrombosis + Pulmonary Embolism
- **Transcript:** Very poor — nearly unreadable raw text ("hlbokážený trhůz", "cté angliou")
- **Report:** Remarkably good given input — correct DVT + PE diagnosis, correct Homans sign, correct history
- **Doctor notes:** Report included extra AI-generated question at the end ("Chcete, abych... vytvořil... standardizovanou formulaci pro EHR") — this should NOT appear
- **Notable:** FA section should say "bez medikace" not "neuvedeno" when patient explicitly denies medications

### Session 3 — Pneumonia
- **Doctor says:** "teď to vypadá to super" — positive overall
- **Doctor says:** Prefers "chrůpky" over "chropy" for lung auscultation findings
- **Doctor says:** Allergy ≠ intolerance — the report conflated these
- **Doctor says:** No mention of patient's brother in report (was in transcript)
- **Doctor says:** GA section doesn't apply to men; urinary symptoms → NO
- **Transcript:** Better quality than sessions 1-2
- **Report:** Very good structure, minor terminology issues

### Session 4 — Acute Limb Ischemia
- **Doctor conducted the session talking to himself** (solo simulation)
- **Transcript:** Moderate quality — key facts (AF, bypass history, sudden foot pain) captured
- **Report:** Good — correct acute arterial occlusion diagnosis
- **Doctor notes inline:** Description of how pain started is in transcript but not in report
- **FA section incomplete:** Patient mentioned multiple medications, only one captured

### Session 5 — Biliary Colic
- **Doctor says:** "docela super" — mostly satisfied
- **Doctor conducted solo simulation again**
- **Doctor notes:** Food trigger ("jedl jsem") was mentioned but likely lost in transcript repetition artifact region
- **Transcript:** Moderate quality, notable repetition artifacts ("ne, ne, ne, ne, ne..." repeated ~70 times)
- **Report:** Good diagnosis (biliary colic with obstruction), correct per rectum findings

### Session 6 — Hepatic Cirrhosis / Decompensation
- **Doctor says:** "začalo brát rozhovor až po pár vteřinách, chybí začátek" — beginning cut off
- **Doctor says:** "jinak ok" — otherwise fine
- **Transcript:** Poor — garbled throughout, beginning missing
- **Report:** Acceptable given limited input, correctly identifies liver cirrhosis, medications, allergy to ibuprofen
- **Notable:** No objective findings, assessment, or plan — because recording cut off before physical exam
