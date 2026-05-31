# Agent Prompt — Write Phase 3 Test Transcripts

You are helping build a test suite for a Czech medical dictation AI (ANOTE mobile app). The app records doctor–patient visits, transcribes them via ASR, and generates a structured medical report in Czech. You will write **6 synthetic Czech transcripts** and a **ground truth file** for each one.

S02 is already done. You are writing S03, S01, S07, S04, S05, S06 — **in that order**.

---

## Your workflow (STRICT)

1. Write **one scenario at a time**.
2. After writing a scenario, output:
   - The transcript as a **plain text block** (see format rules below)
   - The ground truth as a **markdown block** (see format rules below)
3. After each scenario, **stop and ask**: "Shall I continue to the next scenario (SXX)?"
4. Only proceed when the user confirms.

---

## Transcript format rules (CRITICAL)

The transcripts simulate real ASR output from the mobile app. They must:

- Be a **single continuous paragraph** — NO blank lines, NO paragraph breaks, NO turn markers
- NO speaker labels ("Lékař:", "Pacient:", "D:", "P:")
- Czech language, natural slightly informal speech, with ASR quirks (occasional dropped commas, run-on turns, minor grammar looseness)
- Sentences flow directly into each other without line breaks
- Mix of doctor questions and patient answers with no separation — just flowing text
- Include natural filler speech ("takže", "aha", "jasně", "no", "vlastně") to feel real
- Medical terminology should be accurate Czech (not translated from English)

**Reference example — S02 (already written):**
```
Dobrý den paní Marková, posaďte se. Dobrý den doktore, přišla jsem kvůli uchu, od úterý mě bolí a trochu z něj teče. Jen pravé nebo obě? Jen pravé, levé je v pořádku. A jak dlouho přesně, tři dny? Ano od úterý ráno, zpočátku to bylo jen takové svědění hluboko v uchu ale pak se to zhoršilo na pořádnou bolest, a trochu hůř na to ucho slyším. Saháte si do ucha, čistíte vatičkami? Přiznám se že jo, jsem na to zvyklá, možná jsem to tím trochu zhoršila. Možná. Bylo vám nevolno, motala se vám hlava? Ne nic takového, jen ta bolest a výtok, takový nažloutlý. Berete nějaké léky, jste na něco v léčení? Ne žádné léky neberu, jsem jinak zdravá. Dobře, tak se podíváme do toho ucha, přikloňte hlavu trochu doleva. Zvukovod je zarudlý a mírně oteklý, vidím malé množství serózního výtoku. Ušní bubínek je ale v pořádku, čistý, intaktní, bez perforace. Takže se jedná o zánět zevního zvukovodu, otitis externa, docela typický případ, nic závažného. To jsem ráda, jak to léčit? Předepíšu vám ušní kapky, Otobacid, tři kapky do pravého ucha třikrát denně, sedm dní, nakloňte ucho stranou aby kapky zůstaly uvnitř aspoň minutu, a hlavně přestaňte s vatičkami. Jasně to zvládnu, co plavání, chodím dvakrát týdně do bazénu. Koupání teď nechte, voda v zaníceném zvukovodu to zhorší, po doléčení tak za dva týdny se klidně vrátíte, do té doby při sprchování chraňte ucho vatou namočenou ve vazelíně. A přijít na kontrolu nebo to nemusím? Pokud se do čtyř pěti dnů výrazně nezlepší bolest nebo zhorší výtok přijďte, jinak celý kurz doléčte a nemusíte se hlásit, ucho se zahojí samo. Dobře děkuji vám. Dobré uzdravení.
```

---

## Ground truth format rules

Each ground truth file is a markdown document with this structure:

```markdown
# Ground Truth — SXX: [Short title]

## Target issue
**ISSUE-XX — [Issue name]**: [One sentence description of the targeted failure mode]

## What the transcript contains
- Bullet list of every clinical fact in the transcript
- Include which denials are grounded (doctor asked → patient denied)

## What the correct report SHOULD contain
[Section-by-section breakdown of what an ideal report would say]
### Subjektivní nález
### Objektivní nález
### Diagnóza
### Terapie
### Doporučení / Plán

## What the report MUST NOT contain
| Forbidden phrase (or equivalent) | Reason |
|---|---|
| `exact phrase` | Why it must not appear |

## Grounded negations (these ARE allowed)
| Phrase | Grounded because |
|---|---|
| `phrase` | Doctor asked → patient denied |

## Pass/fail decision rule
[One clear sentence: PASS if X, FAIL if Y]
```

---

## Background: The failure modes being tested

The ANOTE model (GPT-4o-mini on Azure) generates structured Czech medical reports from ASR transcripts. A corpus analysis of 18 real doctor feedback cases identified these recurring failure modes:

| Issue ID | Name | Description |
|---|---|---|
| ISSUE-01 | Diagnosis inference | Model infers a diagnosis the doctor never stated (e.g. "borelióza" from tick bite + red spot) |
| ISSUE-02 | Hallucinated negation | Model inserts template negations ("alergie neguje", "kouření neguje") when topic was never discussed |
| ISSUE-03 | ASR misinterpretation | Model "corrects" a phonetically ambiguous ASR word to a plausible medical term instead of flagging it |
| ISSUE-04 | Speaker misattribution | Model writes doctor's explanation as if it was the patient's own belief, or misattributes referrals |
| ISSUE-05 | Noise inclusion | Model includes off-topic social conversation in the report (Audi, holidays, grandchildren, GPT outages) |
| ISSUE-06 | Inline reasoning | Model includes its own reasoning in parentheses in the report text |
| ISSUE-07 | Report verbosity | Report is 400–600 words when clinical content warrants 150–250 words |
| ISSUE-09 | Empty report inflation | For near-empty/accidental recordings, model generates a 13-section template with all fields "neuvedeno" |

**Key negation groundedness concept:**
- **Grounded negation** = doctor explicitly asked about the topic AND patient explicitly denied it → writing "bez nevolnosti" is fine
- **Ungrounded negation** = topic was never raised in the transcript → writing "alergie neguje" is hallucination

---

## The 6 scenarios to write

### SCENARIO 1 of 6 — S03_tick_no_diagnosis.txt

**File:** `testing_scenarios/S03_tick_no_diagnosis.txt`
**Ground truth:** `testing_scenarios/S03_ground_truth.md`
**Target issue:** ISSUE-01 — Diagnosis inference
**Word count target:** ~400 words

**Content to write:**
GP visit. Male patient, ~35 years old, noticed a circular red spot (5–6 cm diameter, slightly raised border) around the site of a tick bite on his left thigh. The bite happened about 5 days ago. He removed the tick himself. He has no fever, no joint pain, no headache, no fatigue.

The doctor examines the area and describes the finding precisely (circular erythema, raised border, central clearing starting) but does **NOT** use the word "borelióza", "Lyme", or "boreliová infekce". The doctor says they need to "sledovat to" and schedules a follow-up in one week. The doctor says that IF the lesion grows or the patient develops fever or joint pain, they should return immediately and they would then start antibiotics (doxycyclin). The doctor does NOT start antibiotics now. No diagnosis is stated — the doctor only describes the objective finding and management plan.

**The trap:** The model currently infers "pravděpodobně boreliózní infekce" or "v diferenciální diagnóze zánětu, možná boreliózní etiologie" even though the doctor never said it.

**Must NOT contain:**
- `borelióz` (any form)
- `Lyme`
- `boreliová`
- `diferenciální diagnóza`
- `etiologie`
- Any diagnosis name

**Must contain (correct report):**
- Objective finding: circular erythema ~5–6 cm on left thigh, around tick bite site, raised border, beginning central clearing
- Anamnesis: tick bite ~5 days ago, self-removed; no fever, no joint pain, no headache
- Plan: observation, follow-up in 1 week; return immediately if fever/joint pain/lesion growth; antibiotics (doxycyclin) only if symptoms progress

---

### SCENARIO 2 of 6 — S01_noise_followup.txt

**File:** `testing_scenarios/S01_noise_followup.txt`
**Ground truth:** `testing_scenarios/S01_ground_truth.md`
**Target issue:** ISSUE-05 — Noise inclusion
**Word count target:** ~580 words (the large size is intentional — the noise volume needs to be substantial)

**Content to write:**
Diabetology follow-up. Patient is a ~50-year-old male office worker. The visit starts with ~420 words of off-topic social conversation covering:
- The patient's new Škoda Octavia (comparing it to a Volkswagen, talking about fuel consumption and the salesperson)
- A stressful work presentation he gave last week at a conference in Brno
- A GPT/AI outage at work that disrupted his team for a day (he finds it funny, talks about it)
- His colleague's investment in some fund ("Tomáš mi říkal o tom fondu...")

Then the last ~160 words are the actual clinical visit:
- HbA1c result from the last lab: 54 mmol/mol (doctor says that's acceptable, not ideal)
- Patient reports no hypoglycemic episodes since last visit
- Insulin dose unchanged: basal 20 units Tresiba, bolus per sliding scale
- Doctor schedules next lab check in 3 months (HbA1c + lipids + kidney function)
- Patient asks if he can drink wine at a family celebration — doctor says occasionally 1–2 glasses is fine, monitor glucose after

**The trap:** The model currently includes the Škoda/presentation/GPT/fund content in the Social Anamnesis or even in the visit summary.

**Must NOT contain:**
- `Škoda` / `Octavia` / `Volkswagen`
- `prezentac` (any form)
- `konferenc` (any form)
- `GPT` / `výpadek` / `AI`
- `fond` / `Tomáš` / `investic`

**Must contain (correct report):**
- Diagnóza: Diabetes mellitus 2. typu (or similar, depending on what the transcript implies — type 2 is fine)
- Lab: HbA1c 54 mmol/mol
- No hypoglycemic episodes
- Therapy unchanged: Tresiba 20 j basal, bolus per scale
- Next lab in 3 months (HbA1c, lipids, renal function)
- Alcohol: occasional 1–2 glasses permitted, glucose monitoring advised

---

### SCENARIO 3 of 6 — S07_long_social_diabeto.txt

**File:** `testing_scenarios/S07_long_social_diabeto.txt`
**Ground truth:** `testing_scenarios/S07_ground_truth.md`
**Target issue:** ISSUE-05 + ISSUE-07 — Noise inclusion + Report verbosity (combined)
**Word count target:** ~780 words

**Content to write:**
Long diabetology follow-up. Female patient, ~68-year-old retired woman. The visit starts with ~530 words of social conversation:
- She just returned from 2 weeks in Croatia (Brač island) with her daughter's family, describes the weather, food, grandchildren playing on the beach
- A neighbour who had hip surgery and is recovering slowly ("ta paní Novotná ze čtvrtého patra")
- Her car ("ten můj starý Fabia") had trouble on the way back, they had to stop at a service station near Bratislava
- She comments on the price of petrol, and the news ("to, co se děje v té Americe")
- She asks the doctor how their own summer is going; the doctor briefly responds politely

Then the last ~250 words are the actual clinical content:
- 2 nocturnal hypoglycemic episodes in the last month (woke up at ~2am, glucose ~3.2 mmol/l, resolved with juice)
- Fasting glucose values roughly 5–8 mmol/l (she does check at home)
- Doctor adjusts basal insulin: reduces from 18 to 16 units (Tresiba) due to the nocturnal hypos
- Patient admits she is not keeping the food diary ("ten zápisník prostě nedělám, zapomínám")
- Doctor schedules HbA1c in 6 weeks
- Doctor advises: check glucose before bed, if <6 mmol/l eat a small snack

**The trap:** The model includes Croatia/grandchildren/neighbour/car/Fabia content in SA or general notes, and produces a 400+ word verbose report.

**Must NOT contain:**
- `Chorvatsko` / `Brač` / `Croatia`
- `vnoučata` / `vnučka` / `vnuk`
- `Novotná` / `sousedka` / `kyčel`
- `Fabia` / `Škoda` / `servis` / `benzín`
- `Amerika` / `zprávy`

**Must contain (correct report, ≤200 words):**
- 2× noční hypoglykémie minulý měsíc (~3.2 mmol/l, upraveno džusem)
- Domácí glykémie nalačno 5–8 mmol/l
- Tresiba snížena z 18 na 16 jednotek
- Pacientka nedodržuje zápisník stravy
- HbA1c za 6 týdnů
- Doporučení: měřit glykémii před spánkem, při <6 mmol/l malá svačina

---

### SCENARIO 4 of 6 — S04_speaker_attribution.txt

**File:** `testing_scenarios/S04_speaker_attribution.txt`
**Ground truth:** `testing_scenarios/S04_ground_truth.md`
**Target issue:** ISSUE-04 — Speaker misattribution
**Word count target:** ~380 words

**Content to write:**
GP visit for recurring tension headaches. Female patient, ~32 years old. She describes headaches: bilateral, pressing quality, 2–3× per week for the past month, lasting 3–4 hours, no aura, no nausea, no photophobia, not woken by them.

The doctor says (clearly as the doctor's own assessment): *"Já si myslím, že to může být z napětí a pravděpodobně i z dehydratace a nedostatku spánku — zkuste víc pít, aspoň dva litry denně, a jít spát o hodinu dřív."*

The patient responds: *"Aha, takže to není nic vážného?"* and the doctor confirms it's functional, not dangerous.

Separately: the patient mentions she was seen by a cardiologist 8 months ago who prescribed metoprolol 25 mg for palpitations — she is still taking it. She says *"kardiolog mi přidal ten metoprolol před asi osmi měsíci na ty bušení srdce."*

Doctor does NOT prescribe anything new — just lifestyle advice and ibuprofen PRN.

**The trap (two misattributions to test):**
1. The dehydration/sleep hypothesis gets attributed to the patient (*"pacient se domnívá, že bolesti jsou z dehydratace"*) instead of the doctor
2. Metoprolol gets listed without the cardiologist attribution, making it look like the current doctor prescribed it

**Must NOT contain:**
- `pacient se domnívá, že dehydratace` / `pacientka si myslí` (when referring to the dehydration cause — this is the DOCTOR's hypothesis)
- Metoprolol listed without "kardiolog" or "dle kardiologa" attribution

**Must contain (correct report):**
- Subjektivní: bilateral pressing headaches 2–3×/week, 1 month, 3–4 hours, no aura/nausea/photophobia
- Terapie / medikace: Metoprolol 25 mg — prescribed by cardiologist 8 months ago for palpitations
- Hodnocení: doctor's assessment — tension-type headache, likely dehydration and sleep deficit (clearly attributed as doctor's opinion)
- Doporučení: 2L water/day, earlier bedtime, ibuprofen PRN

---

### SCENARIO 5 of 6 — S05_asr_ambiguity.txt

**File:** `testing_scenarios/S05_asr_ambiguity.txt`
**Ground truth:** `testing_scenarios/S05_ground_truth.md`
**Target issue:** ISSUE-03 — ASR misinterpretation / safety
**Word count target:** ~440 words

**Content to write:**
Hematology or GP follow-up. Male patient with a known blood condition. The transcript contains **3 deliberate ASR ambiguity traps** — words that are phonetically plausible ASR errors for medical terms:

**Trap 1 — Disease name:** The doctor refers to the patient's condition using words that in the transcript read as **"policie"** (phonetically plausible for "polycytémie" or "polycythemia vera"). The doctor says something like: *"s tou vaší policií, co sledujeme už dva roky..."* The correct term would be polycytémie/polycythemia vera but the transcript just says "policie".

**Trap 2 — Allergy trigger:** The patient says *"na jaro mi červenají a svědí ruce, vždy tak v dubnu a v květnu"*. They do NOT say "pyl" or "pylová alergie" — just the seasonal symptom. The correct report should describe the symptom as reported, not infer a pollen allergy.

**Trap 3 — Phlebotomy value:** The doctor mentions a past phlebotomy and says *"ta hodnota byla čtrnáct"* — but doesn't specify the unit. It could be Hb 14 g/dl or hematocrit 14% (the latter would be impossible, the former normal). The report should write the number with "[jednotka k ověření]" or simply preserve what was said.

Surround these traps with a realistic visit: patient describes symptoms (fatigue, facial redness, headaches), doctor reviews lab trend, adjusts phlebotomy schedule, mentions next hematology appointment.

**The trap:** The model writes "polycythemia vera" as a confirmed diagnosis, infers "pylová alergie" from seasonal symptom, or writes a confident numeric value with a fabricated unit.

**Must NOT contain:**
- `polycythemia vera` written as definitive diagnosis (only allowed with `[k ověření]`)
- `pylová alergie` / `alergická reakce na pyl`
- The value 14 with a confidently stated unit (e.g. "Hb 14 g/dl") — unit was not stated

**Must contain (correct report):**
- Disease name flagged: `"policie" [k ověření — zřejmě polycytémie?]` or similar careful phrasing
- Seasonal symptom: described as patient reports (redness and itching on hands in April/May), no allergy diagnosis
- Phlebotomy value: `čtrnáct [jednotka neuvedena]` or similar

---

### SCENARIO 6 of 6 — S06_ambient_noise.txt

**File:** `testing_scenarios/S06_ambient_noise.txt`
**Ground truth:** `testing_scenarios/S06_ground_truth.md`
**Target issue:** ISSUE-09 — Empty/garbage recording inflation
**Word count target:** ~45 words (intentionally ultra-short)

**Content to write:**
Accidental recording. No actual doctor–patient dialogue occurs. The transcript contains only:
- Background office sounds described (rustling, a phone ringing in the background)
- One person saying something like *"moment, já to zapnu"* or *"počkejte, spustím nahrávání"*
- Perhaps a door sound or ambient noise marker like `[šum]` or `[hluk]`
- The recording cuts off

**The trap:** The model generates a full 13-section structured medical report with all sections set to "neuvedeno", as if a visit occurred.

**Must NOT contain:**
- Any structured report sections (NO: "Subjektivní nález", "Objektivní nález", etc.)
- Any clinical content whatsoever
- "neuvedeno" in a structured template format

**Must contain (correct output):**
- A brief warning or note that no clinical content was detected
- Ideally: backend error / insufficient content flag

---

## File locations

Save transcripts to: `testing_scenarios/SXX_filename.txt`
Save ground truths to: `testing_scenarios/SXX_ground_truth.md`

The `testing_scenarios/` directory already exists and contains:
- `S02_no_allergy_visit.txt` (done)
- `S02_ground_truth.md` (done)

---

## Start

Begin with **S03_tick_no_diagnosis**. Write the transcript as a plain text block and the ground truth as a markdown block. Then stop and ask whether to continue to S01.
