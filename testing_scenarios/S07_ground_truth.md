# Ground Truth — S07: Long diabetology follow-up with social noise and required concise report

## Target issue
**ISSUE-05 + ISSUE-07 — Noise inclusion + Report verbosity**: The report must ignore extensive social conversation and produce a concise clinically focused summary, not a long narrative report.

## What the transcript contains
- Female patient, approximately 68 years old, attends a diabetology follow-up.
- The visit begins with extensive off-topic social conversation about holiday travel, family, neighbours, car issues, fuel prices, and news.
- The social conversation is not clinically relevant and must not appear in the report.
- Patient reports home fasting glucose values roughly 5–8 mmol/l.
- Patient checks glucose at home.
- Patient had 2 nocturnal hypoglycemic episodes in the last month.
- Both nocturnal episodes occurred around 2 a.m.
- During episodes she woke up sweaty and shaky.
- Measured glucose was approximately 3.2 mmol/l, once possibly 3.1 mmol/l.
- Episodes resolved after drinking juice.
- Current basal insulin before the visit: Tresiba 18 units in the evening.
- Doctor reduces basal insulin Tresiba from 18 to 16 units in the evening because of nocturnal hypoglycemia.
- Bolus regimen remains according to previous/current regime.
- Patient admits she is not keeping the food diary.
- Doctor recommends at least simplified food diary entries.
- Doctor schedules HbA1c check in 6 weeks.
- Doctor advises glucose measurement before bedtime.
- If bedtime glucose is below 6 mmol/l, patient should eat a small snack.
- Doctor advises earlier contact if nocturnal hypoglycemia recurs after dose reduction.
- Grounded symptoms during hypoglycemia: sweating and shakiness were reported by the patient during nocturnal episodes.

## What the correct report SHOULD contain

### Subjektivní nález
Pacientka na diabetologické kontrole. Udává 2 noční hypoglykémie za poslední měsíc kolem 2:00, s pocením a třesem, glykémie cca 3,2 mmol/l, upraveno džusem. Domácí ranní glykémie nalačno přibližně 5–8 mmol/l. Zápisník stravy nedodržuje, zapomíná zapisovat.

### Objektivní nález
Bez nového objektivního vyšetření uvedeného v záznamu. K dispozici domácí selfmonitoring glykémie dle pacientky.

### Diagnóza
Diabetes mellitus léčený inzulinem, s nočními hypoglykémiemi při stávající dávce bazálního inzulinu.

### Terapie
Tresiba snížena z 18 j na 16 j večer. Bolusový režim ponechán dle dosavadního nastavení.

### Doporučení / Plán
HbA1c za 6 týdnů. Měřit glykémii před spaním. Při hodnotě <6 mmol/l malá svačina. Pokusit se vést alespoň zjednodušený zápisník stravy. Při opakování nočních hypoglykémií kontaktovat ambulanci dříve.

## What the report MUST NOT contain
| Forbidden phrase (or equivalent) | Reason |
|---|---|
| `Chorvatsko` | Off-topic holiday conversation; not clinically relevant. |
| `Brač` | Off-topic holiday conversation; not clinically relevant. |
| `Croatia` | Off-topic holiday conversation; not clinically relevant. |
| `vnoučata` | Off-topic family/social conversation; not clinically relevant. |
| `vnučka` | Off-topic family/social conversation; not clinically relevant. |
| `vnuk` | Off-topic family/social conversation; not clinically relevant. |
| `Novotná` | Off-topic neighbour conversation; not clinically relevant. |
| `sousedka` | Off-topic neighbour conversation; not clinically relevant. |
| `kyčel` | Off-topic neighbour's surgery; not clinically relevant to this patient. |
| `Fabia` | Off-topic car conversation; not clinically relevant. |
| `Škoda` | Off-topic car conversation; not clinically relevant. |
| `servis` | Off-topic car repair conversation; not clinically relevant. |
| `benzín` | Off-topic fuel price conversation; not clinically relevant. |
| `Amerika` | Off-topic news conversation; not clinically relevant. |
| `zprávy` | Off-topic news conversation; not clinically relevant. |
| A report longer than 200 words | Clinical content is limited and should be summarized concisely. |

## Grounded negations (these ARE allowed)
| Phrase | Grounded because |
|---|---|
| `bez dalšího objektivního nálezu v záznamu` | No objective examination was described in the clinical portion. |
| `bez uvedené změny bolusového režimu` | Doctor explicitly left bolus regimen according to the previous/current regime. |

## Pass/fail decision rule
PASS if the report is clinically focused, omits all social noise, includes the nocturnal hypoglycemia details and insulin adjustment, and stays under 200 words; FAIL if it includes holiday/family/neighbour/car/news content or produces a verbose narrative report over 200 words.