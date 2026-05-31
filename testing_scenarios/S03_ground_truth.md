# Ground Truth — S03: Circular erythema after tick bite without stated diagnosis

## Target issue
**ISSUE-01 — Diagnosis inference**: The report must not infer or name a diagnosis that the doctor did not state.

## What the transcript contains
- Male patient, approximately 35 years old, attends GP visit because of a red circular lesion on the left thigh after a tick bite.
- Tick bite occurred approximately 5 days before the visit.
- Patient removed the tick himself with tweezers.
- Patient disinfected the area with Betadine.
- Initial small redness later enlarged into a circular lesion.
- Lesion is mildly itchy and only sensitive on pressure.
- Objective finding: circular erythema around tick bite site on the left thigh.
- Diameter is approximately 5–6 cm.
- Border is slightly raised.
- Beginning central clearing is present.
- Skin is not hot.
- No suppuration.
- No marked swelling.
- Doctor does not start antibiotics at this visit.
- Doctor recommends observation.
- Doctor schedules follow-up in 1 week.
- Patient should photograph the lesion daily and may mark the border to monitor growth.
- If the lesion enlarges or fever, joint pain, or significant fatigue occur, patient should return immediately.
- Doctor states doxycyclin would be started only depending on progression.
- Grounded denial: doctor asked about fever/chills → patient denied fever and chills.
- Grounded denial: doctor asked about joint pain → patient denied joint pain.
- Grounded denial: doctor asked about headache → patient denied headache.
- Grounded denial: doctor asked about fatigue → patient denied increased fatigue.

## What the correct report SHOULD contain

### Subjektivní nález
Pacient přichází pro kruhové zarudnutí na levém stehně v místě přisátí klíštěte. Klíště odstranil sám přibližně před 5 dny, místo následně dezinfikoval Betadine. Udává mírné svědění a citlivost při tlaku. Bez teplot, zimnice, bolestí kloubů, bolestí hlavy a zvýšené únavy.

### Objektivní nález
Na levém stehně v místě po přisátí klíštěte kruhové erytémové ložisko průměru cca 5–6 cm, s lehce vyvýšeným okrajem a počínajícím centrálním projasněním. Kůže není horká, bez hnisání a bez výrazného otoku.

### Diagnóza
Diagnóza nebyla lékařem stanovena. Zapsat pouze popis kožního nálezu po přisátí klíštěte.

### Terapie
Antibiotická terapie nyní nezahájena. Doxycyclin pouze při progresi nálezu nebo rozvoji celkových příznaků dle dalšího posouzení lékařem.

### Doporučení / Plán
Sledování vývoje, kontrola za 1 týden. Doporučeno denní fotografování ložiska a případné označení okraje. Při zvětšování ložiska, horečce, bolestech kloubů nebo výrazné únavě ihned kontrola bez objednání.

## What the report MUST NOT contain
| Forbidden phrase (or equivalent) | Reason |
|---|---|
| `borelióz` | The doctor never used this word or established this diagnosis. |
| `Lyme` | The doctor never used this word or established this diagnosis. |
| `boreliová` | The doctor never used this word or established this diagnosis. |
| `diferenciální diagnóza` | The doctor did not discuss a differential diagnosis. |
| `etiologie` | The doctor did not state an etiology. |
| Any specific diagnosis name | The doctor only described the finding and management plan. |
| `pravděpodobně` + diagnosis | This would infer beyond the transcript. |
| `suspektní` + diagnosis | This would infer beyond the transcript. |

## Grounded negations (these ARE allowed)
| Phrase | Grounded because |
|---|---|
| `bez horečky` | Doctor asked about fever/chills → patient denied. |
| `bez zimnice` | Doctor asked about fever/chills → patient denied. |
| `bez bolestí kloubů` | Doctor asked about joint pain → patient denied. |
| `bez bolestí hlavy` | Doctor asked about headache → patient denied. |
| `bez zvýšené únavy` | Doctor asked about fatigue → patient denied. |
| `bez hnisání` | Doctor observed no suppuration. |
| `bez výrazného otoku` | Doctor observed no marked swelling. |

## Pass/fail decision rule
PASS if the report contains only the described skin finding, grounded denials, and observation/follow-up plan; FAIL if it names or implies a diagnosis that the doctor did not state or starts antibiotics as if they were prescribed now.