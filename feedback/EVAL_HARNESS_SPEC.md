# ANOTE — Evaluation Harness Tech Spec & Implementation Plan

**Status:** Ready to implement  
**Target:** Steps 2 and 3 of the evaluation strategy (see `feedback/README.md`)  
**Prerequisites:** `backend/.env` with `AZURE_OPENAI_KEY`, existing `backend/evaluate_reports.py`

---

## Overview

Two deliverables:

| Deliverable | File | Type | Cost |
|-------------|------|------|------|
| Step 2: Deterministic checker | `backend/check_report.py` | New script | Free (no API) |
| Step 3: Extended LLM judge | `backend/evaluate_reports.py` | Modify existing | API cost per run |

Both must integrate with the existing runner loop in `evaluate_reports.py` and produce output compatible with `summarize_results.py`.

---

## Step 2 — Deterministic Report Checker

### 2.1 Purpose

A standalone Python script that takes a report (and optionally a transcript) and runs a battery of rule-based checks. Zero API cost. Runs in milliseconds. Used as a regression gate — any prompt change that causes a new check to fail is automatically a regression.

### 2.2 File location

```
backend/check_report.py
```

### 2.3 CLI interface

```bash
# Check a single report file (no transcript — structural checks only)
python check_report.py --report path/to/report.txt

# Check report + transcript (full check suite including hallucination probes)
python check_report.py --report path/to/report.txt --transcript path/to/transcript.txt

# Run against all feedback files in a folder (reports only, no transcripts)
python check_report.py --feedback-dir ../feedback/

# Output machine-readable JSON (for integration with evaluate_reports.py)
python check_report.py --report report.txt --transcript transcript.txt --json

# Run against a scenarios dir (uses existing backend transcripts as inputs,
# generates reports via the backend, then checks them)
python check_report.py --scenarios-dir ../testing_hurvinek/ --generate
```

Exit code: `0` if all checks pass, `1` if any check fails.

### 2.4 Output format

**Human-readable (default):**
```
report.txt — 12/14 checks passed
  ✅ STRUCT-01  All required sections present
  ✅ STRUCT-02  Section order correct
  ✅ STRUCT-03  No section appears more than once
  ✅ LEN-01     Word count in range [100, 700]: 342 words
  ✅ NEG-01     No hallucinated temperature negation
  ❌ NEG-02     Hallucinated allergy negation — "alergie neguje" present but topic absent from transcript
  ✅ NEG-03     No combined neuvedeno+negation in same bullet
  ✅ INFER-01   No parenthetical model reasoning detected
  ❌ INFER-02   GA section contains meta-commentary: "(předpoklad muž)"
  ✅ PLACE-01   No plan/action items in Adherence section
  ✅ PLACE-02   No subjective values in Objektivní nález header bullet
  ✅ NOISE-01   No clearly off-topic keywords detected
  ✅ EMPTY-01   Report is not a fully-empty shell
  ✅ DUP-01     No duplicate consecutive bullets
```

**JSON (--json flag):**
```json
{
  "report_file": "report.txt",
  "transcript_file": "transcript.txt",
  "total_checks": 14,
  "passed": 12,
  "failed": 2,
  "checks": [
    {
      "id": "NEG-02",
      "name": "Hallucinated allergy negation",
      "passed": false,
      "severity": "HIGH",
      "detail": "\"alergie neguje\" found in report but allergy topic absent from transcript",
      "evidence": "alergie neguje"
    },
    ...
  ]
}
```

### 2.5 Check definitions

Each check has: id, name, severity (`CRITICAL` / `HIGH` / `MEDIUM` / `LOW`), requires_transcript flag.

#### Structural checks (no transcript required)

**STRUCT-01 — Required sections present**  
Severity: HIGH  
For initial/default visit type: check that all 13 section headers exist.

```python
REQUIRED_SECTIONS_INITIAL = [
    "Identifikace pacienta",
    "NO (Nynější onemocnění)",
    "RA (Rodinná anamnéza)",
    "OA (Osobní anamnéza)",
    "FA (Farmakologická anamnéza",
    "AA (Alergologická anamnéza)",
    "SA (Sociální anamnéza)",
    "Adherence a spolupráce pacienta",
    "Objektivní nález",
    "Hodnocení",
    "Návrh vyšetření",
    "Návrh terapie",
    "Pokyny a plán kontrol",
]
# Check: all strings above appear in report (case-insensitive substring match)
```

**STRUCT-02 — Section order correct**  
Severity: MEDIUM  
Check that sections appear in the order listed in STRUCT-01 by comparing their first-occurrence character positions.

**STRUCT-03 — No duplicate section headers**  
Severity: MEDIUM  
Each section header should appear at most once. Check by counting regex matches for each header.

---

#### Length checks (no transcript required)

**LEN-01 — Word count in range**  
Severity: MEDIUM  
Count Czech words (split on whitespace, strip punctuation). Flag if `< 100` (likely empty shell) or `> 700` (likely excessively verbose).

```python
MIN_WORDS = 100
MAX_WORDS = 700
word_count = len(report.split())
```

**LEN-02 — Bullet count per section**  
Severity: LOW  
Flag any single section with more than 12 bullet points. More than 12 bullets in one section is almost always verbosity/filler, not clinical content.

---

#### Negation hallucination checks (transcript required)

These are the most important checks based on the feedback corpus. The principle: if a topic was never mentioned in the transcript, the report must not contain a negation of that topic.

**NEG-01 — Temperature negation not hallucinated**  
Severity: HIGH  

```python
TEMP_NEGATION_PATTERN = re.compile(
    r'(teplotu neguje|zvýšenou teplotu neguje|horečku neguje|teplotu neg\.)',
    re.IGNORECASE
)
TEMP_IN_TRANSCRIPT_PATTERN = re.compile(
    r'(teplota|horečka|horečku|teplo|subfebr|febrilie|teplý)',
    re.IGNORECASE
)
# FAIL if: temp_negation in report AND NOT temp_keywords in transcript
```

**NEG-02 — Allergy negation not hallucinated**  
Severity: HIGH  

```python
ALLERGY_NEGATION_PATTERN = re.compile(
    r'(alergie neguje|alergi[ei] neguje|bez alergi[íe])',
    re.IGNORECASE
)
ALLERGY_IN_TRANSCRIPT_PATTERN = re.compile(
    r'(alergi[ei]|alergický|alergická|alergen)',
    re.IGNORECASE
)
# FAIL if: allergy_negation in report AND NOT allergy_keywords in transcript
```

**NEG-03 — No neuvedeno+negation conflation in same bullet**  
Severity: HIGH  
Catch patterns like "alergie neguje (neuvedeno, ale...)" which mix two mutually exclusive categories.

```python
CONFLATION_PATTERN = re.compile(
    r'(neguje\s*\(neuvedeno|neuvedeno.*neguje|neguje.*neuvedeno)',
    re.IGNORECASE | re.DOTALL
)
# FAIL if pattern found anywhere in report
```

---

#### Model reasoning leak checks (no transcript required)

**INFER-01 — No parenthetical inference prose**  
Severity: MEDIUM  
Catch the model inserting its own reasoning in parentheses.

```python
REASONING_LEAK_PATTERN = re.compile(
    r'\([^)]{5,}\b(pravděpodobně|patrně|lze předpokládat|z kontextu|předpoklad|'
    r'implicitně|evidentn|zřejmě|asi|pravdě)\b[^)]*\)',
    re.IGNORECASE
)
# FAIL if any match found (count matches, report each)
```

**INFER-02 — GA section does not contain meta-commentary**  
Severity: LOW  

```python
GA_META_PATTERN = re.compile(
    r'GA.*\(předpoklad|GA.*implicitně|GA.*pravděpodobně.*muž|GA.*pravděpodobně.*žen',
    re.IGNORECASE | re.DOTALL
)
# FAIL if GA section exists and contains meta-reasoning
# Correct outputs: either "neuvedeno" for unknown gender, or actual GA data, or section omitted
```

---

#### Section placement checks (transcript optional, heuristic without)

**PLACE-01 — No action items in Adherence section**  
Severity: LOW  
Action verbs that belong in Návrh terapie/Plán should not appear in the Adherence section.

```python
ACTION_IN_ADHERENCE_PATTERN = re.compile(
    r'(zajistit|objednat|domluvit|plánovat|výměna|objednat|zavolat|kontaktovat)',
    re.IGNORECASE
)
# Extract Adherence section text; FAIL if action_pattern found in that section
```

**PLACE-02 — Subjective patient values not in Objektivní nález**  
Severity: MEDIUM  
The Objektivní nález section should not start bullets with "Pacient udává" / "udávaná hodnota".

```python
SUBJECTIVE_IN_OBJNÁLEZU_PATTERN = re.compile(
    r'(pacient udává|udávaná hodnota|dle pacienta|pacient popisuje)',
    re.IGNORECASE
)
# Extract Objektivní nález section text; FAIL if pattern found there
```

---

#### Noise / off-topic detection (transcript optional, best with transcript)

**NOISE-01 — Off-topic keyword detection**  
Severity: HIGH  
Catch the most common off-topic topics that leaked into reports in the feedback corpus.

```python
NOISE_KEYWORDS = [
    # IT / technology off-topic
    r'(energetická krize|sklářský průmysl|výpadky GPT|výpadky AI|umělá inteligence '
    r'jako nástroj|investic[ei] a rizika|burz[ae]|akciov)',
    # Social/political
    r'(válka na Ukra|globální situace|energetická závislost)',
    # Post-visit events
    r'(ztrátu peněženky|ztratil peněženku|po návratu domů)',
    # Irrelevant occupational details
    r'(prezentaci pro Audi|automobilov.*průmysl.*prezentac)',
]
# FAIL if any noise keyword found in report
# Severity escalates to CRITICAL if found in NO or OA sections
```

**NOISE-02 — Doctor's non-clinical questions not in report**  
Severity: LOW  
Heuristic: if a section contains a casual question verbatim ("jak se vyučuje soudobá historie", "co si myslíte o"), flag it.

```python
CASUAL_QUESTION_PATTERN = re.compile(
    r'(jak se vyučuje|co si myslíte o|to jsem se zeptal|jak to vidíte)',
    re.IGNORECASE
)
```

---

#### Empty report check (no transcript required)

**EMPTY-01 — Not a fully empty shell**  
Severity: CRITICAL  
If every section contains only "neuvedeno", the report is useless.

```python
# Count how many sections have content beyond just "neuvedeno"
# FAIL (CRITICAL) if < 2 sections have substantive content (word count > 1 beyond neuvedeno)
```

---

#### Duplicate content check (no transcript required)

**DUP-01 — No duplicate consecutive bullets**  
Severity: LOW  
Identical or near-identical bullet text appearing twice in the same section.

```python
# Extract all bullets (lines starting with "- ")
# For each consecutive pair: if Levenshtein distance < 10% of length, flag
# Simple version: check for exact duplicate lines first
```

---

### 2.6 Helper: section extractor

All section-level checks require extracting the text of a named section. Implement a reusable helper:

```python
def extract_section(report: str, section_name: str) -> str:
    """
    Extract text from a named section until the next section header.
    Section headers are lines matching: /^[A-ZÁ-Ž][\w\s()\/]+:$/
    Returns empty string if section not found.
    """
```

### 2.7 Running against feedback folder

When `--feedback-dir` is specified, the script:
1. Reads all `*.txt` and `*.tdt` files in the folder
2. Strips `<FEEDBACK>...</FEEDBACK>` tags from report text before checking (these are doctor annotations, not part of the report)
3. Runs structural + non-transcript checks on each
4. Prints a summary table:

```
File                 Words  STRUCT  LEN  NEG  INFER  PLACE  NOISE  EMPTY  PASS
feedback_01.txt        342   ✅      ✅   ❌    ❌     ✅     ✅     ✅    10/12
feedback_16.txt        398   ✅      ✅   ❌    ✅     ❌     ✅     ✅     9/12
...
TOTAL                         18/18   16/18  12/18  ...
```

### 2.8 Integration into evaluate_reports.py

After the LLM judge call in `evaluate_reports.py`, call the deterministic checker and merge results:

```python
from check_report import run_all_checks

det_result = run_all_checks(report=report_text, transcript=transcript_text)
# Store in evaluation result dict under "deterministic_checks" key
result["deterministic_checks"] = det_result
result["deterministic_pass_rate"] = det_result["passed"] / det_result["total_checks"]
```

---

## Step 3 — Extended LLM Judge

### 3.1 What changes in evaluate_reports.py

Two additions:
1. Two new scoring dimensions added to `JUDGE_SYSTEM_PROMPT` and `DIMENSIONS` / `DIM_SHORT`
2. The judge is called with a **different model** than the generator when a judge-model override is configured

### 3.2 New dimensions

#### BREVITY (new dimension 7)

**Rationale:** All 18 feedback files show verbose output. The existing `NOISE_RESILIENCE` dimension does not penalize sentence complexity or word count — it only checks for ASR noise and off-topic content. A separate `BREVITY` dimension captures the length/complexity issue.

**Definition to add to `JUDGE_SYSTEM_PROMPT`:**

```
7. BREVITY: Is the report appropriately concise?
   Score 5: Every bullet is a single short clinical fact. No parenthetical hedging or meta-commentary.
            Total report is roughly 200–500 words. No section padded with multi-clause run-on bullets.
   Score 3: Some verbose bullets or parenthetical reasoning visible, but report is usable.
   Score 1: Report contains extensive multi-clause sentences, reasoning exposed in text,
            or sections padded with meta-commentary instead of clinical content.
   Score 0: Report is so verbose that the clinical signal is obscured.
```

#### HALLUCINATED_NEGATION (new dimension 8)

**Rationale:** The most frequent and dangerous hallucination in the corpus is fabricated negations ("alergie neguje", "teplotu neguje") inserted as template fillers when the topic was never discussed. This is distinct from `FACTUAL_ACCURACY` (which catches hallucinated positive facts) and `NEGATION_HANDLING` (which checks correct use of negation format when negation IS present). This dimension specifically catches negations invented from nothing.

**Definition to add to `JUDGE_SYSTEM_PROMPT`:**

```
8. HALLUCINATED_NEGATION: Are negation phrases grounded in the transcript?
   Score 5: Every negation phrase ("neguje", "neudává", "bez ...") in the report corresponds
            to an explicit denial in the transcript. No negation is written as a template filler.
   Score 3: 1 negation present in report for a topic that wasn't discussed, but it is minor
            (e.g. a low-risk section like AA).
   Score 1: Multiple negations present for topics never raised.
   Score 0: Section AA, temperature, or a diagnosis is negated in the report with no basis
            in the transcript at all. Doctor never asked, patient never denied.
```

### 3.3 Changes to JUDGE_SYSTEM_PROMPT string

In `evaluate_reports.py`, locate `JUDGE_SYSTEM_PROMPT`. Change:

**Old header line:**
```
Evaluate the report on these 6 dimensions (score 0-5 each):
```

**New header line:**
```
Evaluate the report on these 8 dimensions (score 0-5 each):
```

**Append after dimension 6 (NOISE_RESILIENCE):**
```
7. BREVITY: Is the report appropriately concise? Are bullets single-fact? Is the word count
   in the 200–500 range? Is there no parenthetical model reasoning exposed in the text?
   5 = concise, single-fact bullets, no hedging prose; 0 = verbose, multi-clause, bloated.
8. HALLUCINATED_NEGATION: Are all negation phrases ("neguje", "neudává", "bez...") grounded
   in an explicit denial in the transcript? 5 = every negation traceable to transcript denial;
   0 = negations added as template fillers for topics never discussed.
```

**Add to JSON schema in the prompt:**
```json
    "brevity": {"score": N, "reasoning": "..."},
    "hallucinated_negation": {"score": N, "reasoning": "..."}
```

**Update composite_score calculation instruction:**
```
"composite_score": weighted average of all 8 scores where hallucinated_negation and
factual_accuracy have weight 2, all others weight 1. Formula: 
(factual_accuracy*2 + completeness + structure + negation_handling + clinical_language + 
noise_resilience + brevity + hallucinated_negation*2) / 10
```

### 3.4 Changes to DIMENSIONS and DIM_SHORT

```python
# Old
DIMENSIONS = [
    "factual_accuracy",
    "completeness",
    "structure",
    "negation_handling",
    "clinical_language",
    "noise_resilience",
]

DIM_SHORT = {
    "factual_accuracy": "Fact",
    "completeness": "Comp",
    "structure": "Strc",
    "negation_handling": "Neg",
    "clinical_language": "Lang",
    "noise_resilience": "Noise",
}

# New — append two entries
DIMENSIONS = [
    "factual_accuracy",
    "completeness",
    "structure",
    "negation_handling",
    "clinical_language",
    "noise_resilience",
    "brevity",                  # NEW
    "hallucinated_negation",    # NEW
]

DIM_SHORT = {
    "factual_accuracy": "Fact",
    "completeness": "Comp",
    "structure": "Strc",
    "negation_handling": "Neg",
    "clinical_language": "Lang",
    "noise_resilience": "Noise",
    "brevity": "Brev",          # NEW
    "hallucinated_negation": "HalNeg",  # NEW
}
```

### 3.5 Judge model override

Currently the judge uses the same `DEFAULT_MODEL` as the generator. Add a new constant and CLI arg:

```python
# New constant (after DEFAULT_MODEL line)
DEFAULT_JUDGE_MODEL = os.environ.get("AZURE_OPENAI_JUDGE_DEPLOYMENT", DEFAULT_MODEL)
```

Add `--judge-model` arg to argparse:
```python
parser.add_argument("--judge-model", default=DEFAULT_JUDGE_MODEL,
                    help="Model to use for LLM judge (defaults to AZURE_OPENAI_JUDGE_DEPLOYMENT env var)")
```

Pass it through to the judge call function so that when gpt-5 or o3 is available, the judge can be a different (stronger) model than the generator.

### 3.6 Update summarize_results.py

The current `summarize_results.py` hardcodes 6 dimension names. Update to handle variable dimensions and also display the new `deterministic_pass_rate` field.

```python
# Replace hardcoded dims list with dynamic discovery:
dims = set()
for s in results:
    ev = s.get('evaluation', {})
    sc = ev.get('scores', {})
    dims.update(sc.keys())
dims = sorted(dims)  # or use a preferred order

# Add deterministic pass rate to the summary line if present:
det_rates = [
    s.get('deterministic_pass_rate')
    for s in results
    if s.get('deterministic_pass_rate') is not None
]
if det_rates:
    avg_det = sum(det_rates) / len(det_rates)
    print(f'{label:12s}  ...  DET={avg_det:.0%}')
```

---

## Step 3b — Feedback Folder as an Evaluation Dataset

The 18 feedback files in `feedback/` are reports without transcripts. They are valuable as regression inputs for the deterministic checker even without transcripts (structural checks, inference leak checks, empty report checks).

Create a thin adapter script:

### File: `backend/run_feedback_checks.py`

```
Usage:
    python run_feedback_checks.py

Reads all *.txt / *.tdt files from ../feedback/ (skipping README.md),
strips <FEEDBACK>...</FEEDBACK> tags, runs deterministic checks on each,
and prints a summary table + saves results to feedback_check_results.json.
```

This script:
1. Strips all `<FEEDBACK[^>]*>.*?</FEEDBACK>` tags from each file before checking
2. Skips `README.md`
3. Runs `check_report.run_all_checks(report=cleaned_text)` (no transcript)
4. Saves to `feedback/feedback_check_results.json`

---

## File Summary

| File | Action | Description |
|------|--------|-------------|
| `backend/check_report.py` | **Create new** | Deterministic checker, 14 checks, CLI + library |
| `backend/run_feedback_checks.py` | **Create new** | Thin runner for feedback/ folder |
| `backend/evaluate_reports.py` | **Modify** | Add 2 dimensions, judge model param, call det checker |
| `backend/summarize_results.py` | **Modify** | Dynamic dimension discovery, show det pass rate |

---

## Implementation Order

Implement in this exact order to avoid dependency issues:

1. `check_report.py` — fully self-contained, no imports from other project files
2. `run_feedback_checks.py` — depends on `check_report.py`
3. Run `python run_feedback_checks.py` to get baseline — this gives the current state before any prompt changes
4. `evaluate_reports.py` — add 2 dimensions + judge model param + call check_report
5. `summarize_results.py` — update display

---

## Acceptance Criteria

After implementation:

```bash
# Should print table with 18 rows and pass/fail per check
cd backend && python run_feedback_checks.py

# Should run checks on a single report file
python check_report.py --report ../feedback/feedback_16.txt

# Should detect the Lyme disease hallucination in feedback_16 via INFER-01 / NOISE checks
# (note: NEG-02 won't fire without transcript, but NOISE-01 may catch "borelióza" if in keywords)

# Extended judge: should show 8 dimensions in output
python evaluate_reports.py --scenarios-dir ../testing_hurvinek/ --prompt-variant v4 | head -5

# Summarize should show Brev and HalNeg columns
python summarize_results.py
```

---

## Notes on Test Data

For runs that require a transcript+report pair:
- Use existing scenarios in `../testing_hurvinek/` and `../mobile/assets/demo_scenarios/` as transcript inputs
- The generate-then-check flow (`evaluate_reports.py` with `--generate` flag) already handles this
- The feedback files (feedback_01–18) have no paired transcripts yet — transcript-dependent checks will be skipped with a note in output

When the golden set (transcript + annotations) is built later (Step 1 from the strategy), the deterministic checker's `--transcript` mode will unlock the transcript-dependent checks (NEG-01, NEG-02, NEG-03) on those cases.
