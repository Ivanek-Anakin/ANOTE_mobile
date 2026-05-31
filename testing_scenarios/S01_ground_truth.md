# Ground Truth — S01: Diabetology follow-up with large off-topic noise

## Target issue
**ISSUE-05 — Noise inclusion**: The report must ignore extensive off-topic social conversation and include only clinically relevant diabetes follow-up information.

## What the transcript contains
- The visit begins with a long off-topic conversation about the patient's new car, work conference, AI outage at work, and colleague's investment topic.
- These off-topic topics are not clinically relevant and must not be included in the medical report.
- Patient is a male around 50 years old, office worker.
- Follow-up is for diabetes care.
- Diagnosis implied by the doctor: diabetes mellitus, type 2.
- Last laboratory result: HbA1c 54 mmol/mol.
- Doctor evaluates the result as acceptable but not ideal.
- Grounded denial: doctor asked about hypoglycemic episodes including tremor, sweating, weakness, or values below 4 mmol/l → patient denied hypoglycemia since the last visit.
- Current insulin regimen remains unchanged.
- Basal insulin: Tresiba 20 units in the evening.
- Bolus insulin: according to sliding scale/table before meals.
- Therapy is left unchanged.
- Next laboratory check scheduled in 3 months.
- Planned next labs: HbA1c, lipids, renal function.
- Patient asks whether he may drink wine at a family celebration.
- Doctor permits occasional wine intake: 1–2 glasses, preferably with food, not fasting.
- Doctor advises glucose monitoring after the celebration.
- Doctor advises earlier contact if repeatedly low or high glucose values occur.

## What the correct report SHOULD contain

### Subjektivní nález
Pacient přichází na diabetologickou kontrolu. Od poslední kontroly neudává hypoglykemické epizody, bez třesu, pocení, slabosti či hodnot pod 4 mmol/l. Dotaz na možnost konzumace vína při rodinné oslavě.

### Objektivní nález
Dle poslední laboratoře HbA1c 54 mmol/mol. Hodnota hodnocena jako přijatelná, nikoli ideální.

### Diagnóza
Diabetes mellitus 2. typu.

### Terapie
Terapie ponechána beze změny. Bazální inzulin Tresiba 20 j večer. Bolusový inzulin dle sliding scale / tabulky před jídlem.

### Doporučení / Plán
Kontrolní odběry za 3 měsíce: HbA1c, lipidy, renální funkce. Při rodinné oslavě možná příležitostná konzumace 1–2 skleniček vína, ideálně s jídlem a nikoli nalačno. Doporučena kontrola glykémie po oslavě. Při opakovaně nízkých nebo vysokých hodnotách kontaktovat ambulanci dříve.

## What the report MUST NOT contain
| Forbidden phrase (or equivalent) | Reason |
|---|---|
| `Škoda` | Off-topic social conversation about a car; not clinically relevant. |
| `Octavia` | Off-topic social conversation about a car; not clinically relevant. |
| `Volkswagen` | Off-topic comparison of cars; not clinically relevant. |
| `prezentac` | Off-topic work presentation; not clinically relevant. |
| `konferenc` | Off-topic work conference; not clinically relevant. |
| `GPT` | Off-topic work/AI outage conversation; not clinically relevant. |
| `AI` | Off-topic work/AI outage conversation; not clinically relevant. |
| `výpadek` | Off-topic work/AI outage conversation; not clinically relevant. |
| `fond` | Off-topic investment conversation; not clinically relevant. |
| `Tomáš` | Off-topic colleague/investment conversation; not clinically relevant. |
| `investic` | Off-topic investment conversation; not clinically relevant. |

## Grounded negations (these ARE allowed)
| Phrase | Grounded because |
|---|---|
| `bez hypoglykémií od poslední kontroly` | Doctor explicitly asked about hypoglycemia → patient denied. |
| `bez třesu, pocení a slabosti` | Doctor explicitly asked about these hypoglycemia symptoms → patient denied. |
| `bez hodnot pod 4 mmol/l` | Doctor explicitly asked about glucose values below 4 mmol/l → patient denied. |

## Pass/fail decision rule
PASS if the report summarizes only the diabetes follow-up, HbA1c, insulin regimen, absence of hypoglycemia, next labs, and alcohol advice; FAIL if it includes car, work presentation, conference, GPT/AI outage, fund, colleague, or other off-topic social content.