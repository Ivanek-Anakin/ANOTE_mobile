# TASK-0036 v4 Baseline Results

## Execution status

- Date: 2026-05-02
- Prompt variant: v4
- Runner mode: `backend/evaluate_reports.py` in-process generation + in-process LLM judge
- Credentials source used at runtime: Azure Container App secret `azure-openai-key` (exported only in active shell)
- Scenarios: 11
- Output JSON: `backend/evaluation_results_v4_baseline_TASK0036.json`

## Judge rubric scores by scenario

| Scenario | factual_accuracy | completeness | structure | negation_handling | clinical_language | noise_resilience | composite |
|---|---:|---:|---:|---:|---:|---:|---:|
| S Hurvínkem za lékařem   1  Díl   Nachlazení | 5 | 4 | 5 | 5 | 5 | 5 | 4.8 |
| S Hurvínkem za lékařem   2  Díl   Zlomenina | 5 | 4 | 5 | 5 | 5 | 5 | 4.8 |
| S Hurvínkem za lékařem 08 Angína | 5 | 4 | 5 | 5 | 5 | 5 | 4.8 |
| cz_detska_prohlidka | 5 | 5 | 5 | 5 | 5 | 5 | 5.0 |
| cz_jar_allergy | 5 | 5 | 5 | 5 | 5 | 5 | 5.0 |
| cz_kardialni_nahoda | 5 | 4 | 5 | 5 | 5 | 5 | 4.8 |
| cz_objective_in_dialogue | 5 | 5 | 5 | 5 | 5 | 5 | 5.0 |
| cz_otrava_jidlem | 5 | 5 | 5 | 5 | 5 | 5 | 5.0 |
| cz_quiet_compliant | 5 | 5 | 5 | 5 | 5 | 5 | 5.0 |
| cz_respiracni_infekce | 5 | 5 | 5 | 5 | 5 | 5 | 5.0 |
| cz_terse_dosing | 5 | 5 | 5 | 5 | 5 | 5 | 5.0 |

## Aggregate baseline

- Mean composite: 4.93
- Min composite: 4.8
- Max composite: 5.0
- Mean by dimension:
  - factual_accuracy: 5.00
  - completeness: 4.64
  - structure: 5.00
  - negation_handling: 5.00
  - clinical_language: 5.00
  - noise_resilience: 5.00

## Hallucinations and omissions captured by judge

| Scenario | Hallucinations | Omissions |
|---|---|---|
| S Hurvínkem za lékařem   1  Díl   Nachlazení | none | not measuring temperature before visit; social factor of going to theater while ill |
| S Hurvínkem za lékařem   2  Díl   Zlomenina | none | injury timing emphasis; emotional state emphasis |
| S Hurvínkem za lékařem 08 Angína | none | symptom duration wording; cold-exposure context |
| cz_detska_prohlidka | none | none |
| cz_jar_allergy | none | none |
| cz_kardialni_nahoda | none | age confusion detail; concentration issue |
| cz_objective_in_dialogue | none | none |
| cz_otrava_jidlem | none | none |
| cz_quiet_compliant | none | none |
| cz_respiracni_infekce | none | none |
| cz_terse_dosing | none | none |

## Manual defect evaluation per generated report

Pass/fail legend:
- Defect 1: off-topic content leakage
- Defect 2: objective findings misplaced to NO
- Defect 3: JAR allergy handling without pollen inference
- Defect 4: cooperation boilerplate when adherence not discussed
- Defect 5: terse dosage token preservation

| Scenario | D1 | D2 | D3 | D4 | D5 | Evidence for fail (if any) |
|---|---|---|---|---|---|---|
| S Hurvínkem za lékařem   1  Díl   Nachlazení | pass | pass | pass | pass | pass | - |
| S Hurvínkem za lékařem   2  Díl   Zlomenina | pass | pass | pass | pass | pass | - |
| S Hurvínkem za lékařem 08 Angína | pass | pass | pass | pass | pass | - |
| cz_detska_prohlidka | pass | pass | pass | **fail** | pass | `Adherence a spolupráce pacienta: Spolupráce dobrá, režim dodržuje.` despite no direct adherence dialogue |
| cz_jar_allergy | pass | pass | **fail** | pass | pass | `AA: Alergie na léky neguje; Alergie na potraviny neguje.` while allergy trigger JAR appears only in NO |
| cz_kardialni_nahoda | pass | pass | pass | **fail** | pass | `Adherence a spolupráce pacienta: Spolupráce dobrá...` without explicit adherence discussion |
| cz_objective_in_dialogue | pass | **fail** | pass | **fail** | pass | NO includes objective values (`Objektivně: tlak 145/90...`); also `Spolupráce dobrá...` with no adherence dialogue |
| cz_otrava_jidlem | pass | pass | pass | **fail** | pass | `Adherence a spolupráce pacienta: spolupráce dobrá...` without explicit adherence dialogue |
| cz_quiet_compliant | pass | pass | pass | **fail** | pass | `Adherence a spolupráce pacienta: Spolupráce dobrá...` despite fixture intentionally omitting adherence topic |
| cz_respiracni_infekce | pass | pass | pass | **fail** | pass | `Adherence a spolupráce pacienta: spolupráce dobrá...` without explicit adherence dialogue |
| cz_terse_dosing | pass | pass | pass | pass | pass | - |

Manual pass counts (11 scenarios):
- Defect 1: 11/11 pass
- Defect 2: 10/11 pass
- Defect 3: 10/11 pass
- Defect 4: 5/11 pass
- Defect 5: 11/11 pass

## Pytest baseline evidence

Command:

`/Users/ivananikin/Documents/Ivanek-Anakin/ANOTE_mobile/.venv/bin/python -m pytest backend/tests/test_prompt_fixes.py -v -m feedback_fixes`

Captured output:

`backend/tests/baseline_v4_pytest.txt`

Result:
- 10 collected
- 7 passed
- 3 failed

Failing tests against v4:
- `test_objective_findings_in_correct_section[cz_objective_in_dialogue]`
- `test_jar_allergy_no_pollen_inference`
- `test_no_cooperation_boilerplate_when_absent`

Passing tests against v4:
- `test_no_song_or_offtopic_in_report` (all 3 Hurvínek files)
- `test_objective_findings_in_correct_section` (all 3 Hurvínek files)
- `test_dosage_preserved_verbatim`
