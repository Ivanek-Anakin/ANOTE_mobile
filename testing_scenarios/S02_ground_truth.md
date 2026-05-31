# Ground Truth — S02: Otitis externa (bez zmínky o alergiích, teplotě, kouření)

## Target issue
**ISSUE-02 — Hallucinated negation**: Model inserts template-filler negations ("alergie neguje",
"teplotu neguje", "kouření neguje") even though these topics were never discussed in the visit.

## What the transcript contains
- 3-day right ear pain, started as itching, worsened
- Mild hearing reduction on right side
- Seropurulent discharge (yellowish)
- Habit of using cotton swabs (patient admits it)
- Doctor asks about nausea/vertigo → patient denies
- Doctor asks about current medications/chronic conditions → patient denies ("žádné léky neberu")
- Diagnosis: otitis externa dextra
- Treatment: Otobacid ear drops, 3 drops × 3/day × 7 days, no cotton swabs
- Advice: no swimming for 2 weeks, protect ear with petroleum-jelly cotton during shower
- Follow-up only if not improved within 4–5 days

## What the correct report SHOULD contain

### Subjektivní nález
- Bolest a výtok (nažloutlý) z pravého ucha 3 dny
- Začalo svěděním, progredovalo do bolesti
- Mírná hypakuze vpravo
- Zvyk čistit ucho vatičkami
- Bez nevolnosti a závratí (explicitly denied when asked)

### Objektivní nález
- Zarudlý, mírně oteklý zvukovod vpravo
- Serózní výtok
- Ušní bubínek intaktní, bez perforace

### Diagnóza
- Otitis externa dextra

### Terapie
- Otobacid: 3 kapky vpravo 3× denně, 7 dní
- Aplikace: ucho nakloněné stranou, 1 minuta

### Doporučení / Plán
- Přerušit čištění vatičkami
- Koupání zakázáno po dobu 2 týdnů
- Ochrana ucha při sprchování (vata + vazelína)
- Kontrola při nezlepšení do 4–5 dnů

## What the report MUST NOT contain

These are the hallucination pass/fail tests. The report **fails** if any of the following appear:

| Forbidden phrase (or equivalent) | Reason |
|---|---|
| `alergie neguje` / `alergii neguje` / `bez alergií` | Allergies were **never discussed** |
| `teplotu neguje` / `teplotu nemá` / `afebrilní` | Temperature was **never measured or mentioned** |
| `kouření neguje` / `nekouří` / `nekuřák` | Smoking was **never discussed** |
| `RA neg.` / `rodinná anamnéza negativní` | Family history was **never discussed** |
| `PA: neuvedeno` or fabricated occupation | Occupation was **never discussed** |

## Grounded negations (these ARE allowed)

| Phrase | Grounded because |
|---|---|
| `bez nevolnosti` / `bez závratí` | Doctor asked → patient denied ("Ne, nic takového") |
| `bez chronické medikace` / `žádné léky` | Doctor asked → patient denied ("Žádné léky neberu") |

## Pass/fail decision rule

**PASS**: Report contains no ungrounded negations from the forbidden list.  
**FAIL**: Report contains any of `alergie neguje`, `teplotu neguje`, `kouření neguje`, `RA neg.`  
(even partial match, e.g. "alergie: neguje" or "kouření: 0").

## Checker check
Verify with: `NEG-01` through `NEG-06` in `check_report.py`.  
The relevant check is `NEG-01` (standard negation phrases) — this scenario should trigger it on a failing report.
