# LLM-as-Judge — Report Quality Evaluation

## Tech Spec & Implementation Plan

**Date:** 1 March 2026
**Status:** Implemented & Tested

---

## 1. Problem

ANOTE generates medical reports from noisy ASR transcripts. We have no automated way to measure report quality. Manual review by a doctor doesn't scale and introduces subjectivity. We need a repeatable, automated evaluation pipeline that scores each report on multiple dimensions.

## 2. Approach: LLM-as-Judge

Use the same Azure OpenAI gpt-4.1-mini model to evaluate its own output. The judge receives the original transcript and the generated report, then scores the report on a structured rubric. This is a well-established technique (see: [Judging LLM-as-a-Judge, NeurIPS 2023](https://arxiv.org/abs/2306.05685)).

**Why self-evaluation works here:**
- The task is extraction (not creative generation) — the model can verify facts against the source transcript
- We're checking for hallucinations, omissions, and structure — not subjective quality
- Cost is minimal (~$0.002 per evaluation, same as generating the report itself)

**Known limitation:** Self-evaluation has a positive bias. The model is unlikely to catch its own systematic blind spots. A doctor review of a sample (e.g., 10 reports) remains essential for calibration.

## 3. Evaluation Rubric

Each report is scored on **6 dimensions**, each 0–5:

| Dimension | What it measures | 0 (worst) | 5 (best) |
|-----------|-----------------|-----------|----------|
| **Factual Accuracy** | No hallucinated facts; all stated facts traceable to transcript | Multiple fabricated facts | Every fact verifiable in transcript |
| **Completeness** | All medically relevant info from transcript captured | Major findings missing | All relevant info included |
| **Structure** | Correct 13-section format, proper section assignment | Missing sections / wrong placement | All 13 sections present and correctly populated |
| **Negation Handling** | Properly distinguishes "neuvedeno" (not discussed) vs negation (explicitly denied) | Confuses or ignores negations | All negations correctly identified and marked |
| **Clinical Language** | Appropriate Czech medical terminology, professional tone | Layperson language or errors | Proper medical Czech throughout |
| **Noise Resilience** | Correctly interprets ASR errors, filters irrelevant content (songs, banter) | ASR artifacts leak into report | All noise filtered, meaning correctly inferred |

**Composite score:** Weighted average (all equal weight = simple mean, 0–5 scale).

**Thresholds:**
- ≥ 4.0 — Production quality
- 3.0–3.9 — Acceptable with caveats
- < 3.0 — Needs investigation

## 4. Judge Prompt Design

```
You are a medical documentation quality auditor. You will receive:
1. A transcript of a doctor-patient conversation (may contain ASR errors, background noise, irrelevant content)
2. A structured medical report generated from that transcript

Evaluate the report on these 6 dimensions (score 0-5 each):

1. FACTUAL_ACCURACY: Are all facts in the report traceable to the transcript? Any hallucinated information?
2. COMPLETENESS: Does the report capture all medically relevant information from the transcript?
3. STRUCTURE: Are all 13 required sections present? Is information placed in the correct section?
4. NEGATION_HANDLING: Does the report correctly distinguish "neuvedeno" (not discussed) from explicit negations?
5. CLINICAL_LANGUAGE: Is the Czech medical terminology appropriate and professional?
6. NOISE_RESILIENCE: Does the report correctly filter ASR errors, songs, banter, and irrelevant content?

For each dimension, provide:
- score (integer 0-5)
- reasoning (1-2 sentences explaining the score)

Also list:
- hallucinations: any facts in the report NOT in the transcript
- omissions: any medically relevant facts in the transcript NOT in the report

Respond in this exact JSON format:
{
  "scores": {
    "factual_accuracy": {"score": N, "reasoning": "..."},
    "completeness": {"score": N, "reasoning": "..."},
    "structure": {"score": N, "reasoning": "..."},
    "negation_handling": {"score": N, "reasoning": "..."},
    "clinical_language": {"score": N, "reasoning": "..."},
    "noise_resilience": {"score": N, "reasoning": "..."}
  },
  "composite_score": N.N,
  "hallucinations": ["...", "..."],
  "omissions": ["...", "..."],
  "summary": "1-2 sentence overall assessment"
}
```

## 5. Architecture

```
┌─────────────────────────────────────────────────────┐
│  evaluate_reports.py                                │
│                                                     │
│  For each scenario:                                 │
│    1. Load transcript (.txt)                        │
│    2. Generate report (gpt-4.1-mini, production     │
│       system prompt, temperature=0.3)               │
│    3. Evaluate report (gpt-4.1-mini, judge prompt,  │
│       temperature=0.0, JSON mode)                   │
│    4. Parse JSON scores                             │
│    5. Append to results                             │
│                                                     │
│  Output:                                            │
│    - Console: summary table                         │
│    - File: evaluation_results.json (full details)   │
│    - File: evaluation_summary.md (human-readable)   │
└─────────────────────────────────────────────────────┘
```

### Data flow per scenario:

```
transcript.txt
    │
    ├──► gpt-4.1-mini (system_prompt, temp=0.3) ──► report
    │                                                  │
    └──► gpt-4.1-mini (judge_prompt, temp=0.0) ◄──────┘
                │
                ▼
         JSON evaluation
         {scores, hallucinations, omissions, summary}
```

## 6. Implementation Plan

### 6.1 File: `backend/evaluate_reports.py`

Single self-contained script (~200 lines). No new dependencies needed — uses the same `openai` SDK already installed.

**Inputs:**
- `--scenarios-dir` — path to folder with `.txt` transcripts (default: `testing_hurvinek/`)
- `--output` — path for JSON results (default: `evaluation_results.json`)
- `--model` — deployment name (default: `gpt-4-1-mini`)

**Key functions:**
```python
def generate_report(client, model, transcript, system_prompt) -> str
def evaluate_report(client, model, transcript, report) -> dict
def run_evaluation(scenarios_dir, model, output_path) -> list[dict]
```

### 6.2 Evaluation call specifics

- **Temperature: 0.0** for judge (maximize consistency between runs)
- **response_format: {"type": "json_object"}** to enforce valid JSON
- **Separate API call** from report generation (not the same conversation)
- **Retry logic** for rate limits (exponential backoff, max 3 retries)

### 6.3 Output: `evaluation_results.json`

```json
{
  "metadata": {
    "date": "2026-03-01",
    "model": "gpt-4-1-mini",
    "api_version": "2025-04-01-preview",
    "num_scenarios": 3
  },
  "results": [
    {
      "scenario": "S Hurvínkem za lékařem 1 Nachlazení",
      "transcript_words": 1081,
      "report_generation": {
        "time_s": 10.8,
        "prompt_tokens": 3480,
        "completion_tokens": 905
      },
      "evaluation": {
        "scores": { ... },
        "composite_score": 4.2,
        "hallucinations": [],
        "omissions": ["..."],
        "summary": "..."
      }
    }
  ],
  "aggregate": {
    "mean_composite": 4.1,
    "min_composite": 3.8,
    "max_composite": 4.5,
    "per_dimension_means": {
      "factual_accuracy": 4.3,
      "completeness": 4.0,
      ...
    }
  }
}
```

### 6.4 Output: Console summary

```
EVALUATION RESULTS — gpt-4-1-mini — 2026-03-01
═══════════════════════════════════════════════════
Scenario                        Fact Comp Strc Neg  Lang Noise  AVG
───────────────────────────────────────────────────
Nachlazení                       4    4    5    4    5    4     4.3
Zlomenina                        5    4    5    3    5    4     4.3
Angína                           4    5    5    4    5    5     4.7
───────────────────────────────────────────────────
MEAN                             4.3  4.3  5.0  3.7  5.0  4.3   4.4
```

## 7. Test Scenarios

### Current (3 Hurvínek episodes):
- Good stress test — noisy transcripts with songs, multiple characters, ASR errors
- Not realistic medical consultations — children's puppet show

### Recommended additions:
- Use existing `mobile/assets/demo_scenarios/` (8 scenarios) — cleaner, more realistic
- Record 2-3 real consultations (with consent) for ground truth
- Generate synthetic scenarios with GPT to test edge cases (rare conditions, drug interactions, contradictory statements)

## 8. Future Extensions

| Extension | Effort | Value |
|-----------|--------|-------|
| **Run on CI** — evaluate on every system prompt change | 1 day | High — catches regressions |
| **A/B test prompts** — compare two system prompts on same scenarios | 2 hours | High — data-driven prompt tuning |
| **Doctor calibration** — have a doctor score 10 reports, compare to LLM scores | 4 hours | Critical — validates the judge |
| **Stronger judge** — use gpt-4.1 (not mini) as judge for less bias | Trivial | Medium — more expensive |
| **Multi-run stability** — generate 3 reports per scenario, measure variance | 1 hour | Medium — tests consistency |
| **Transcript quality (WER)** — add Whisper vs human transcript comparison | 2 days | High — requires manual transcription |

## 9. Cost Estimate

| Operation | Tokens | Cost |
|-----------|--------|------|
| Report generation (per scenario) | ~3,500 in + ~800 out | ~$0.003 |
| Evaluation (per scenario) | ~4,500 in + ~400 out | ~$0.002 |
| **Total per scenario** | | **~$0.005** |
| **Full run (3 Hurvínek + 8 demo)** | | **~$0.055** |

## 10. Timeline

| Step | Time |
|------|------|
| Implement `evaluate_reports.py` | 30 min |
| Run on 3 Hurvínek scenarios | 5 min |
| Run on 8 demo scenarios | 5 min |
| Analyze results, tune judge prompt if needed | 15 min |
| **Total** | **~1 hour** |

---

## 11. Evaluation Results

All runs use the LLM-as-Judge pipeline implemented in `backend/evaluate_reports.py`. Judge model: gpt-4.1-mini, temperature=0.0, JSON mode. Each dimension scored 0–5.

### 11.1 Baseline Results (v0 — Production Prompt)

#### gpt-4.1-mini (recommended model)

| Scenario Set | Fact | Comp | Strc | Neg | Lang | Noise | **AVG** |
|-------------|------|------|------|-----|------|-------|---------|
| Demo (8 scenarios) | 5.00 | 4.62 | 4.88 | 4.88 | 5.00 | 5.00 | **4.90** |
| Hurvínek (3 scenarios) | 5.00 | 4.00 | 4.00 | 5.00 | 5.00 | 5.00 | **4.67** |

#### gpt-5-mini (comparison)

| Scenario Set | Fact | Comp | Strc | Neg | Lang | Noise | **AVG** |
|-------------|------|------|------|-----|------|-------|---------|
| Demo (8 scenarios) | 4.00 | 4.75 | 5.00 | 4.88 | 4.75 | 4.62 | **4.67** |
| Hurvínek (3 scenarios) | 4.00 | 4.00 | 5.00 | 4.33 | 4.67 | 4.67 | **4.44** |

**Key finding:** gpt-5-mini scores lower on Factual Accuracy (4.0 vs 5.0) — the stricter reasoning model flags the system-prompt-injected visit date as a "hallucination" since it does not appear in the transcript. This is a known self-evaluation artifact, not an actual quality issue.

### 11.2 Prompt Variant A/B Test

Four system prompt variants were tested on both scenario sets using gpt-4.1-mini:

| Variant | Description | Suffix added to base prompt |
|---------|-------------|----------------------------|
| **v0** | Baseline | *(none — production prompt as-is)* |
| **v1** | Completeness boost | "IMPORTANT: Capture every medically relevant detail from the transcript, including all symptoms, their onset, duration, severity, and any contextual factors." |
| **v2** | Strict structure | "IMPORTANT: Follow the 13-section structure exactly. Every section must be present. Place information in the correct section — do not merge or skip sections." |
| **v3** | Negation + noise | "IMPORTANT: Pay special attention to distinguishing explicit denials from simply unmentioned topics. Filter out all non-medical content such as small talk, background noise markers, or conversational filler." |

#### Demo Scenarios (8 scenarios, gpt-4.1-mini)

| Variant | Fact | Comp | Strc | Neg | Lang | Noise | **AVG** |
|---------|------|------|------|-----|------|-------|---------|
| **v0** (baseline) | 5.00 | 4.62 | 4.88 | 4.88 | 5.00 | 5.00 | **4.90** |
| **v1** (completeness) | 5.00 | 4.88 | 5.00 | 5.00 | 5.00 | 5.00 | **4.98** |
| **v2** (strict structure) | 5.00 | 4.62 | 4.75 | 5.00 | 5.00 | 5.00 | **4.90** |
| **v3** (negation+noise) | 5.00 | 4.88 | 4.62 | 5.00 | 5.00 | 5.00 | **4.92** |

#### Hurvínek Scenarios (3 noisy scenarios, gpt-4.1-mini)

| Variant | Fact | Comp | Strc | Neg | Lang | Noise | **AVG** |
|---------|------|------|------|-----|------|-------|---------|
| **v0** (baseline) | 5.00 | 4.00 | 4.00 | 5.00 | 5.00 | 5.00 | **4.67** |
| **v1** (completeness) | 5.00 | 4.33 | 4.33 | 5.00 | 5.00 | 5.00 | **4.78** |
| **v2** (strict structure) | 5.00 | 4.00 | 4.33 | 5.00 | 5.00 | 5.00 | **4.72** |
| **v3** (negation+noise) | 5.00 | 4.00 | 4.33 | 5.00 | 5.00 | 5.00 | **4.72** |

### 11.3 Analysis

1. **v1 (Completeness boost) is the best variant** — achieves the highest mean score on both scenario sets (+0.08 on demo, +0.11 on Hurvínek vs baseline).

2. **Completeness is the weakest dimension** across all variants (4.00–4.88). The Hurvínek scenarios are particularly challenging because they contain conversational/educational content that the judge considers "medically relevant" (e.g., patient reluctance to take medication, social context).

3. **Factual Accuracy, Clinical Language, and Noise Resilience are consistently perfect** (5.0) across all gpt-4.1-mini variants — the model does not hallucinate and produces excellent Czech medical terminology.

4. **Structure improves with v1** (4.88→5.00 on demo) — the completeness emphasis indirectly helps fill all 13 sections.

5. **v2 and v3 do not improve** over baseline — the production prompt already handles structure and negation well; adding explicit emphasis provides no lift.

6. **All variants exceed the 4.0 production quality threshold** on both scenario sets.

### 11.4 Recommendation

**Adopt v1 (Completeness boost) as the production system prompt.** The single-sentence addition provides a measurable improvement (+0.08–0.11 mean score) with no regressions on any dimension. The change is minimal and low-risk.

### 11.5 Result Files

All raw evaluation data is stored in `backend/`:

| File | Config |
|------|--------|
| `evaluation_results.json` | v0, gpt-4.1-mini, Hurvínek |
| `evaluation_results_demo.json` | v0, gpt-4.1-mini, Demo |
| `evaluation_results_5mini_hurvinek.json` | v0, gpt-5-mini, Hurvínek |
| `evaluation_results_5mini_demo.json` | v0, gpt-5-mini, Demo |
| `eval_v1_demo.json` | v1, gpt-4.1-mini, Demo |
| `eval_v1_hurvinek.json` | v1, gpt-4.1-mini, Hurvínek |
| `eval_v2_demo.json` | v2, gpt-4.1-mini, Demo |
| `eval_v2_hurvinek.json` | v2, gpt-4.1-mini, Hurvínek |
| `eval_v3_demo.json` | v3, gpt-4.1-mini, Demo |
| `eval_v3_hurvinek.json` | v3, gpt-4.1-mini, Hurvínek |
