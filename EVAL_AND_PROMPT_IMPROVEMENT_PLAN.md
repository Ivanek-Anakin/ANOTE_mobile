# Evaluation & Prompt Improvement Plan

**Branch:** `feature/prompt-improvements`  
**Updated:** 01. 06. 2026  
**Scope:** ANOTE report generation quality, evaluator reliability, prompt variants, model upgrade path

---

## Executive Summary

Yes — the first real prompt improvement worked.

The strongest failure mode in the Phase 3 synthetic set was template negation, especially `alergie neguje` appearing when allergies were never discussed. We ported the best tested variant, `v6b_negation_strict`, into the real backend base prompt and mirrored it in the evaluator prompt copy.

The result is a clear improvement on both targeted synthetic scenarios and the Hurvínek regression set.

| Dataset | Before | After v6b Base-Port |
|---|---:|---:|
| Synthetic scenarios mean | 3.30 | **3.94** |
| Synthetic deterministic pass | 91.8% | **98.6%** |
| Hurvínek mean | 3.36 | **3.94** |
| Hurvínek deterministic pass | 92.1% | **100.0%** |

Primary verification: final reports contain **zero** `alergie neguje` filler across both datasets.

The correct next move is not a model switch yet. The next phase should tighten the remaining prompt and evaluator gaps while keeping the current model, then benchmark a stronger model using the same evaluation harness. Architecture changes should come after we know whether a single-call better model or cleaner prompt is enough.

Recommended order:

1. **Lock in v6b base-port** as the current candidate.
2. **Tighten remaining prompt issues**: noise filtering, `neuvedeno` phrasing, adherence boilerplate, brevity.
3. **Run wider regression** on feedback corpus, not only synthetic + Hurvínek.
4. **Evaluate model upgrade** with the same prompt and judge.
5. **Only then consider multi-stage architecture** if single-call quality is still insufficient.

---

## Completed Work

### Phase 1 — Deterministic Checker V2

**Status:** Completed in previous session.  
**Commit:** `d9e6925`

Purpose: make deterministic checks reflect real doctor feedback rather than only format compliance.

Outcome:

- Added stricter checks for unsupported negations, inference, noise, and verbosity.
- Established that the old evaluator was too optimistic.

### Phase 2 — LLM Judge V2/V3

**Status:** Completed and iterated.  
**Phase 2 commit:** `a3892d1`  
**Phase 3 judge commit:** `c1fdbb9`

Key improvements:

- Judge became adversarial and transcript-grounded.
- Added negation and hallucination inventories.
- Added Python-side hard caps.
- Raised `noise_resilience` weight from 1 to 2.
- Added empty-input cap: transcript `<100` words and report `>60` words -> composite `<=1.5`.
- Added `noise_inventory` concept and Python-side noise cap.
- Added judge clarification: `neuvedeno` placeholders are not negations and must not inflate ungrounded-negation count.

Important lesson: the judge must not treat `neuvedeno`, `neuvedena`, or `neuvedeny` as patient denials. They mean the topic was not discussed.

### Phase 3 — Targeted Synthetic Scenarios

**Status:** Completed.  
**Directory:** `testing_scenarios/`

Created 7 Czech synthetic transcripts with ground truths:

| Scenario | Target |
|---|---|
| `S01_noise_followup` | social/off-topic noise |
| `S02_no_allergy_visit` | hallucinated allergy/temp/smoking negations |
| `S03_tick_no_diagnosis` | diagnosis inference from tick bite |
| `S04_speaker_attribution` | doctor/patient attribution |
| `S05_asr_ambiguity` | ASR ambiguity and unsafe interpretation |
| `S06_ambient_noise` | empty/accidental recording |
| `S07_long_social_diabeto` | long social diabetology follow-up |

Official Phase 3b baseline with Judge V3:

| Dataset | Prompt | Mean | DET |
|---|---|---:|---:|
| Synthetic scenarios | `v5h_procedural` | 3.30 | 91.8% |

### Phase 4a — Prompt Variant Exploration

**Status:** Completed for first variant family.

Tested evaluator-only variants:

| Variant | Result |
|---|---|
| `v6a_no_inference` | Useful but not best overall |
| `v6b_negation_strict` | **Best overall** |
| `v6c_noise_strict` | Useful targeted noise improvement, but weaker on Hurvínek |
| `v6d_brevity` | Too much collateral factual loss |
| `v6e_asr_safety` | Mild improvement only |
| `v6f_combined` | Too many interactions; not recommended |

Initial variant results on synthetic scenarios:

| Variant | Mean | DET | Decision |
|---|---:|---:|---|
| `v6b_negation_strict` | **3.72** | **97.3%** | Advance |
| `v6c_noise_strict` | 3.47 | 93.9% | Keep as idea, do not port yet |
| `v6a_no_inference` | 3.43 | 90% | Revisit later if diagnosis inference remains |
| `v6f_combined` | 3.43 | 90% | Reject for now |
| `v6e_asr_safety` | 3.40 | 90% | Revisit later |
| `v6d_brevity` | 3.34 | 90% | Reject for now |

### Phase 4b — v6b Base-Port

**Status:** Completed, not yet committed.

Changed files:

- `backend/main.py`
- `backend/evaluate_reports.py`

Core prompt change:

- Removed `alergie neguje` from generic negation examples.
- Replaced proactive/template negation guidance with grounded-only rule:
  - negation requires explicit doctor question plus explicit patient denial.
  - if the topic was not discussed, write `neuvedeno`, not a negation.
- Updated AA section:
  - `alergie neguje` only if allergies were explicitly asked and denied.
  - if allergies never appear in transcript, write `neuvedeno`.

Final v6b base-port evaluation:

| Dataset | Old Baseline | v6b Base-Port | Delta |
|---|---:|---:|---:|
| Synthetic mean | 3.30 | **3.94** | +0.64 |
| Synthetic DET | 91.8% | **98.6%** | +6.8 pp |
| Hurvínek mean | 3.36 | **3.94** | +0.58 |
| Hurvínek DET | 92.1% | **100.0%** | +7.9 pp |

Final result files:

- `backend/evaluation_results_v6b_ported_base_scenarios_judge_v3b.json`
- `backend/evaluation_results_v6b_ported_base_hurvinek_judge_v3b.json`

Conclusion: **v6b base-port is successful and should be committed after review.**

---

## Remaining Known Problems

The v6b base-port fixed the main negation failure, but several quality issues remain.

### 1. Noise and social content still leak in hard cases

Synthetic S01 and S07 still receive low/moderate noise scores. The prompt is better, but it still sometimes includes social context or background story when it should compress to clinical facts only.

Candidate next prompt work: a refined `v6g_noise_and_concision`, based on the useful parts of `v6c`, but without over-tightening the whole prompt.

### 2. `neuvedeno` wording can be awkward

The model sometimes writes phrases like:

- `Neuvedeno zvýšenou teplotu...`
- `Neuvedeno, zda jsou přítomny...`
- `Neuvedeno explicitní popření...`

These are not negations anymore, but they are stylistically poor and can confuse the judge. The output should prefer either:

- a section-level `neuvedeno`, or
- omission of irrelevant unasked negatives in follow-up/control reports.

Candidate prompt work: add a section-empty rule:

> If a topic was not discussed, write only `neuvedeno` for the whole section. Do not create sentences listing which subtopics were not discussed.

### 3. Adherence boilerplate remains

The prompt still sometimes writes `spolupráce dobrá` or patient-compliance summaries when the transcript only contains a treatment instruction, not actual adherence behavior.

Candidate prompt work: port a narrow adherence rule from the old v5h/v5e experiments:

> Adherence describes observed or discussed patient behavior. A doctor instruction is treatment/patient education, not adherence.

### 4. Empty/ambient recording behavior is still handled mostly by judge cap

S06 correctly scores `1.5`, but the generator still produces a report-shaped artifact for near-empty input. That is more a product/backend behavior issue than a prompt issue.

Candidate architecture work:

- Add pre-generation transcript quality gate.
- If transcript is too short or lacks medical dialogue, return a user-facing warning instead of generating a full report.

### 5. ASR ambiguity is not fully solved

S05 improved strongly in the final v6b run, but the broader ASR problem needs more real examples. We should not overfit to one `policie` scenario.

Candidate work:

- Add 3–5 additional ASR ambiguity scenarios.
- Only then revisit `v6e_asr_safety`.

---

## Recommended Next Phase

### Phase 4c — Tighten Prompt Without Changing Model

Do this before switching models.

Reason: the v6b base-port produced a large gain with a small prompt change. We still have obvious prompt-level issues, so a model switch now would mix variables and make it harder to learn what actually helped.

Proposed next variants:

| Variant | Target | What to change | Acceptance criterion |
|---|---|---|---|
| `v6g_noise_concision` | S01/S07, verbosity | Add narrow blocklist for non-clinical story content; compress social context to clinical consequence only | Synthetic mean >= 3.94 and Hurvínek mean >= 3.94 |
| `v6h_neuvedeno_style` | awkward placeholders | If topic absent, write section-level `neuvedeno`; do not list absent subtopics | No `Neuvedeno zvýšenou...` style phrases in Hurvínek |
| `v6i_adherence_grounding` | adherence boilerplate | Adherence only for actual patient behavior; treatment instruction belongs in therapy/plan | No unsupported `spolupráce dobrá` in Hurvínek |
| `v6j_combined_minimal` | candidate final prompt | Combine v6b + accepted parts of v6g/v6h/v6i | Beats current v6b base-port on both datasets |

Recommended sequence:

1. Implement `v6h_neuvedeno_style` first. It is low risk and directly reduces judge confusion and awkward text.
2. Implement `v6i_adherence_grounding` second.
3. Implement a conservative `v6g_noise_concision` third.
4. Only combine accepted changes.

Do not revive `v6d_brevity` as originally written. It was too blunt.

---

## Model Upgrade Plan

### Should we switch to GPT-5 now?

Not yet as the default production model.

We should evaluate it next, but not switch until we have side-by-side results with the current best prompt.

Recommended model-eval matrix:

| Model | Prompt | Datasets | Decision question |
|---|---|---|---|
| `gpt-4-1-mini` | v6b base-port | synthetic + Hurvínek + feedback corpus | Current reference |
| stronger GPT-4.1 class model | v6b base-port | same | Does quality improve enough for cost/latency? |
| GPT-5-class model if available | v6b base-port | same | Does it solve noise, ASR, and inference without architecture changes? |
| GPT-5-class model | v6j final prompt | same | Final model candidate |

Acceptance criteria for a model switch:

- Beats `gpt-4-1-mini` on both synthetic and Hurvínek means.
- Does not regress deterministic pass rate below 95%.
- Improves at least two of: noise, ASR ambiguity, inference, adherence grounding.
- Latency/cost acceptable for final report generation.

Recommended product architecture if upgrading model:

- Keep `gpt-4-1-mini` for fast draft/live UX.
- Use stronger model only for final report generation.
- Add `FINAL_MODEL` backend env var.
- Add `final: bool = False` request flag.
- `final=False` -> fast model.
- `final=True` -> stronger model.

This gives quality where it matters without making live UX slow or expensive.

---

## Architecture Improvement Options

Multi-call generation is promising, but it should be tested after prompt and model baselines are stable.

### Option A — Single-call generation with stronger prompt

Current approach. Lowest latency and simplest to operate.

Status: improved substantially with v6b base-port.

Best for: current near-term production.

### Option B — Two-stage clean + generate

Pipeline:

1. Clean transcript:
   - remove non-medical banter,
   - mark ASR uncertainty,
   - detect speaker roles,
   - detect whether visit is real/empty.
2. Generate report from cleaned clinical transcript.

Pros:

- Better noise control.
- Better ASR handling.
- Easier debugging because intermediate clinical facts are visible.

Cons:

- Higher latency/cost.
- Risk of losing clinical detail during cleaning.
- Requires evaluation of both stages.

Recommended only if v6g/v6h/v6i plus model upgrade still leave unacceptable noise/ASR failures.

### Option C — Extract structured facts, then render report

Pipeline:

1. Extract JSON facts:
   - symptoms,
   - negations with transcript evidence,
   - meds,
   - objective findings,
   - diagnoses explicitly stated,
   - plan,
   - uncertain ASR tokens.
2. Validate facts deterministically.
3. Render report from JSON.

Pros:

- Best auditability.
- Strongest defense against hallucinated negation.
- Enables deterministic checks before final text.

Cons:

- More engineering work.
- More schema design.
- Risk of brittle extraction if transcripts vary widely.

Recommended as the long-term architecture if ANOTE needs clinical-grade reliability and explainability.

### Option D — Generate + critique + revise

Pipeline:

1. Generate report.
2. Judge/critic reviews report against transcript.
3. Model revises report using critic findings.

Pros:

- Can reuse current judge work.
- Usually improves output without full schema design.

Cons:

- Can overfit to judge wording.
- More expensive.
- Needs guardrails so the revision does not introduce new facts.

Recommended as an experiment after v6g/v6h/v6i, especially for final reports only.

---

## Proposed Work Order From Here

### Immediate

1. Review and commit v6b base-port and final eval artifacts.
2. Add a short changelog entry or release note for prompt behavior.
3. Run wider feedback corpus regression if tooling supports it.

### Next prompt iteration

1. Implement `v6h_neuvedeno_style`.
2. Evaluate on `testing_scenarios/` and `testing_hurvinek/`.
3. Implement `v6i_adherence_grounding`.
4. Evaluate again.
5. Implement conservative `v6g_noise_concision`.
6. Evaluate again.

### Model evaluation

1. Run current best prompt on stronger available model(s).
2. Compare quality, latency, and cost.
3. Decide whether to introduce `FINAL_MODEL` final-report path.

### Architecture exploration

Only start if model+prompt still leaves unacceptable quality gaps:

1. Prototype two-stage `clean transcript -> generate report` on the 10-scenario suite.
2. Compare against single-call final model.
3. If promising, move to structured extraction JSON.

---

## Current Decision Log

| Date | Decision | Reason |
|---|---|---|
| 31. 05. 2026 | Improve evaluator before prompt | Old judge was falsely optimistic |
| 31. 05. 2026 | Add 7 targeted synthetic scenarios | Hurvínek alone was too clean/playful |
| 31. 05. 2026 | Advance `v6b_negation_strict` | Best initial variant on synthetic and acceptable on Hurvínek |
| 01. 06. 2026 | Port v6b into base prompt | Suffix-only fix helped, but base prompt contained the bad `alergie neguje` example |
| 01. 06. 2026 | Do not stack v6b suffix after base-port | Redundant suffix did not improve results |
| 01. 06. 2026 | Do not switch model yet | Prompt-level fix still yields large gains; model switch should be benchmarked cleanly next |
| 01. 06. 2026 | Consider multi-call architecture later | Useful, but should come after prompt/model baselines are stable |

---

## Current Reference Results

Use these as the reference until the next accepted prompt/model change.

| Result File | Dataset | Prompt | Mean | DET |
|---|---|---|---:|---:|
| `backend/evaluation_results_v6b_ported_base_scenarios_judge_v3b.json` | synthetic scenarios | v6b base-port via `v5h_procedural` | 3.94 | 98.6% |
| `backend/evaluation_results_v6b_ported_base_hurvinek_judge_v3b.json` | Hurvínek | v6b base-port via `v5h_procedural` | 3.94 | 100.0% |

Important: these use `gpt-4-1-mini` as both generator and judge.

---

## Open Questions

1. Should final reports optimize for very short GP-style summaries or fuller specialist documentation? This affects brevity thresholds.
2. How much latency is acceptable for final report generation if using a stronger model?
3. Do we want the UI/API to show warnings for empty/low-quality transcripts instead of always returning a report?
4. Should the report endpoint expose a structured intermediate representation for audit/debugging?
5. Which real feedback files should become permanent regression tests?
