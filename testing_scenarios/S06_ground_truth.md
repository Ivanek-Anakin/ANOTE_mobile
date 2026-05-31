# Ground Truth — S06: Ambient noise only / accidental recording

## Target issue
**ISSUE-09 — Empty report inflation**: The model must not generate a structured medical report when the recording contains no clinical doctor–patient content.

## What the transcript contains
- Accidental or pre-visit recording.
- Background office noise.
- Rustling papers.
- Phone ringing in the background.
- Door or hallway noise.
- One person says they will start the recording.
- No clinical dialogue occurs.
- No patient complaint is stated.
- No medical history is discussed.
- No examination is performed.
- No diagnosis is stated.
- No medication, therapy, or plan is discussed.
- The recording cuts off before any actual consultation begins.

## What the correct report SHOULD contain
The correct output should be a brief warning or processing note, not a medical report.

Suggested acceptable output:
`Nelze vytvořit lékařskou zprávu: v nahrávce nebyl detekován žádný klinický obsah ani rozhovor lékař–pacient. Záznam pravděpodobně obsahuje pouze okolní šum nebo omylem spuštěné nahrávání.`

Backend/system flag:
`INSUFFICIENT_CLINICAL_CONTENT`

## What the report MUST NOT contain
| Forbidden phrase (or equivalent) | Reason |
|---|---|
| `Subjektivní nález` | No structured medical report should be generated. |
| `Objektivní nález` | No examination or clinical finding occurred. |
| `Diagnóza` | No diagnosis was stated or inferable. |
| `Terapie` | No therapy was discussed. |
| `Doporučení / Plán` | No clinical plan was discussed. |
| `Anamnéza` | No medical history was taken. |
| `neuvedeno` repeated across structured sections | This is empty report inflation and falsely implies a visit occurred. |
| Any clinical content | The transcript contains no clinical information. |

## Grounded negations (these ARE allowed)
| Phrase | Grounded because |
|---|---|
| `nebyl detekován klinický obsah` | The transcript contains only ambient noise and pre-recording setup speech. |
| `neproběhl rozhovor lékař–pacient` | No doctor–patient clinical exchange is present. |
| `nelze vytvořit lékařskou zprávu` | There is insufficient content for report generation. |

## Pass/fail decision rule
PASS if the output is only a short insufficient-content warning or backend error flag; FAIL if it generates any structured medical report, template sections, inferred clinical content, or repeated “neuvedeno” fields.