# Ground Truth — S04: Speaker attribution in headache visit

## Target issue
**ISSUE-04 — Speaker misattribution**: The report must correctly attribute the dehydration/sleep hypothesis to the doctor and metoprolol prescribing to the cardiologist.

## What the transcript contains
- Female patient, approximately 32 years old, attends GP visit for recurrent headaches.
- Headaches have been present for approximately 1 month.
- Frequency: 2–3 times per week.
- Duration: approximately 3–4 hours.
- Character: bilateral, pressing/squeezing quality around temples/forehead.
- Pain is not unilateral and not pulsating.
- Patient reports association with prolonged computer work.
- Grounded denial: doctor asked about aura/visual symptoms → patient denied.
- Grounded denial: doctor asked about nausea → patient denied nausea.
- Grounded denial: doctor asked about photophobia → patient denied significant light sensitivity.
- Grounded denial: doctor asked whether pain wakes her from sleep → patient denied nocturnal awakening.
- Grounded denial: doctor asked about worsening with exertion → patient denied clear exertional worsening.
- Patient drinks little during the day: two coffees and perhaps one glass of water, then more in the evening.
- Patient sleeps insufficiently: goes to bed around midnight, wakes at 6 a.m.
- Current medication: metoprolol 25 mg in the morning.
- Metoprolol was prescribed/added by a cardiologist approximately 8 months ago for palpitations.
- Patient occasionally takes ibuprofen 400 mg for headaches with effect.
- Objective finding: orientational neurological examination without focal deficit.
- Blood pressure: 118/76 mmHg.
- Pulse: regular.
- Doctor states as their own assessment that the headaches may be due to tension and probably dehydration and lack of sleep.
- Doctor assesses the condition as functional and without warning signs in the current examination.
- Doctor does not prescribe new regular medication.
- Doctor recommends fluids at least 2 litres/day.
- Doctor recommends going to bed one hour earlier.
- Doctor recommends breaks from computer work.
- Doctor allows ibuprofen PRN, not daily.
- Doctor advises urgent review if sudden worsening, visual disturbance, limb weakness, vomiting, or fever develops.
- Doctor advises follow-up if no improvement within one month or headache frequency increases.

## What the correct report SHOULD contain

### Subjektivní nález
Pacientka udává 1 měsíc trvající bolesti hlavy 2–3× týdně, trvající cca 3–4 hodiny. Bolest je oboustranná, tlaková/svíravá, v oblasti spánků a čela, spíše při delším sezení u počítače. Bez aury, bez nevolnosti, bez výrazné fotofobie, nebudí ji ze spánku, bez jasného zhoršení při námaze. Udává nízký příjem tekutin a nedostatek spánku. Občas užívá ibuprofen 400 mg s efektem.

### Objektivní nález
Orientační neurologické vyšetření bez ložiskového nálezu. TK 118/76 mmHg, puls pravidelný.

### Diagnóza
Tenzní bolesti hlavy / funkční bolesti hlavy bez aktuálních varovných příznaků.

### Terapie
Nová pravidelná farmakoterapie nenasazena. Ibuprofen dle potřeby, ne denně. Chronická medikace: metoprolol 25 mg ráno, nasazen kardiologem před cca 8 měsíci pro palpitace.

### Doporučení / Plán
Dle hodnocení lékaře mohou obtíže souviset s napětím, dehydratací a nedostatkem spánku. Doporučeno pít alespoň 2 litry tekutin denně, chodit spát přibližně o hodinu dříve a dělat přestávky od počítače. Kontrola při nezlepšení do 1 měsíce nebo při zvyšování frekvence bolestí. Ihned vyhledat lékaře při náhlém výrazném zhoršení, poruchách vidění, slabosti končetiny, zvracení nebo horečce.

## What the report MUST NOT contain
| Forbidden phrase (or equivalent) | Reason |
|---|---|
| `pacientka si myslí, že bolesti jsou z dehydratace` | Dehydration was the doctor's assessment, not the patient's belief. |
| `pacientka se domnívá, že bolesti jsou z nedostatku spánku` | Sleep deficit as cause was the doctor's assessment, not the patient's self-diagnosis. |
| `pacient se domnívá, že dehydratace` | Wrong speaker attribution; this is the doctor's hypothesis. |
| `metoprolol 25 mg` without `kardiolog`, `dle kardiologa`, or equivalent attribution | Metoprolol was prescribed by a cardiologist 8 months ago, not by the current GP. |
| `nasazen metoprolol` without cardiologist attribution | Would imply the current doctor prescribed it. |
| New regular headache medication | The doctor did not prescribe any new regular medication. |

## Grounded negations (these ARE allowed)
| Phrase | Grounded because |
|---|---|
| `bez aury` | Doctor asked about aura/visual symptoms → patient denied. |
| `bez nevolnosti` | Doctor asked about nausea → patient denied. |
| `bez výrazné fotofobie` | Doctor asked about light sensitivity → patient denied significant symptoms. |
| `nebudí ze spánku` | Doctor asked whether pain wakes her at night → patient denied. |
| `bez jasného zhoršení při námaze` | Doctor asked about exertional worsening → patient denied. |
| `bez ložiskového neurologického nálezu` | Doctor performed orientational neurological exam and stated no focal finding. |

## Pass/fail decision rule
PASS if the report attributes the dehydration/sleep explanation to the doctor's assessment and states metoprolol 25 mg was prescribed by a cardiologist; FAIL if it attributes the doctor's explanation to the patient or lists metoprolol as if newly prescribed by the GP.