# Azure OpenAI Model Comparison — gpt-4.1-mini vs gpt-5-mini

**Date:** 1 March 2026  
**Environment:** Azure OpenAI resource `anote-openai`, West Europe, Standard S0  
**API version:** `2025-04-01-preview`  
**Test script:** `backend/test_models.py`

---

## 1. What Was Done

Deployed two models on Azure OpenAI to compare speed, quality, cost, and API compatibility for the ANOTE backend (Czech medical report generation from transcript).

### 1.1 Model Deployment

Both models were deployed via Azure CLI on the `anote-openai` resource (resource group `ANOTE`):

```bash
# gpt-4.1-mini — Standard SKU
az cognitiveservices account deployment create \
  --name anote-openai \
  --resource-group ANOTE \
  --deployment-name gpt-4-1-mini \
  --model-name gpt-4.1-mini \
  --model-version "2025-04-14" \
  --model-format OpenAI \
  --sku-capacity 1 \
  --sku-name Standard

# gpt-5-mini — GlobalStandard SKU (Standard not available for this model)
az cognitiveservices account deployment create \
  --name anote-openai \
  --resource-group ANOTE \
  --deployment-name gpt-5-mini \
  --model-name gpt-5-mini \
  --model-version "2025-08-07" \
  --model-format OpenAI \
  --sku-capacity 1 \
  --sku-name GlobalStandard
```

### 1.2 Retrieving Credentials

```bash
# Endpoint
az cognitiveservices account show \
  --name anote-openai --resource-group ANOTE \
  --query properties.endpoint -o tsv
# → https://anote-openai.openai.azure.com/

# API Key
az cognitiveservices account keys list \
  --name anote-openai --resource-group ANOTE \
  --query key1 -o tsv
```

---

## 2. Test Setup

### 2.1 Input Scenario

Used the Czech cardiac emergency demo scenario (`mobile/assets/demo_scenarios/cz_kardialni_nahoda.txt`) — a realistic doctor-patient dialogue featuring:

- Acute chest pain with radiation to left arm
- Patient age 58, on aspirin 100 mg
- No drug allergies
- Vitals: BP 150/95, HR 98 irregular
- EKG: ST elevation in II, III, aVF
- Diagnosis: Acute inferior MI → urgent catheterisation

### 2.2 System Prompt

The exact production system prompt from `backend/main.py` was used — it instructs the model to generate a structured Czech medical report with 13 sections (Identifikace, NO, NA, RA, OA, FA, AA, GA, SA, Objektivní nález, Hodnocení, Návrh vyšetření, Návrh terapie, Pokyny).

Key rules:
- Never invent missing information → write "neuvedeno"
- Record explicit denials as NEGACI
- Preserve exact numbers and dosages

### 2.3 Test Script

`backend/test_models.py` — Python script using `openai.AzureOpenAI` client. Each model receives the identical system prompt and transcript. The script measures wall-clock time and reports token usage including reasoning tokens.

```bash
cd backend
source ../.venv/bin/activate
python test_models.py
```

---

## 3. API Compatibility Issues Encountered

### 3.1 gpt-5-mini Deployment

| Issue | Error | Solution |
|-------|-------|----------|
| Wrong model version | `2025-06-05` not found | Use `2025-08-07` (found via `az cognitiveservices account list-models`) |
| Wrong SKU | `Standard` not available | Use `GlobalStandard` (data may leave EU region) |

### 3.2 gpt-5-mini API Parameters

| Issue | Error | Solution |
|-------|-------|----------|
| `max_tokens` not supported | `400 — Unsupported parameter` | Use `max_completion_tokens` instead |
| `temperature` not supported | `400 — Only default (1) value is supported` | Remove `temperature` parameter |
| API version too old | Request hangs indefinitely | Use `2025-04-01-preview` (not `2024-10-21`) |

### 3.3 Reasoning Token Budget

gpt-5-mini uses internal reasoning tokens (chain-of-thought) that count against `max_completion_tokens`. With `max_completion_tokens=2000`, the model spent all tokens on reasoning and produced **0 chars** of visible output. Increased to `16000` to allow enough budget for both reasoning and output.

---

## 4. Results

### 4.1 Performance Comparison

| Metric | gpt-4.1-mini | gpt-5-mini |
|--------|-------------|------------|
| **Response time** | **4–6 s** | **15–20 s** |
| **Prompt tokens** | 727 | 726 |
| **Completion tokens** | 443 | 2,077 |
| — Reasoning (hidden) | 0 | 1,536 |
| — Visible output | 443 | 541 |
| **Total tokens billed** | 1,155 | 2,803 |
| **Report length** | ~1,200 chars | ~1,460 chars |
| **Temperature control** | Yes (0.3) | No (fixed at 1) |
| **max_tokens param** | Yes | No (must use `max_completion_tokens`) |

### 4.2 Estimated Cost per Report

Pricing based on Azure OpenAI pay-as-you-go (Standard/GlobalStandard):

| | gpt-4.1-mini | gpt-5-mini |
|---|---|---|
| Input | 727 × $0.40/1M = $0.0003 | 726 × $0.40/1M = $0.0003 |
| Output | 443 × $1.60/1M = $0.0007 | 541 × $1.60/1M = $0.0009 |
| Reasoning | — | 1,536 × $1.60/1M = $0.0025 |
| **Total** | **~$0.001** | **~$0.004** |

gpt-5-mini is approximately **4× more expensive** per report.

### 4.3 Quality Comparison

#### gpt-4.1-mini Output (representative run)

```
Lékařská zpráva

Identifikace pacienta:
muž, 58 let

NO (Hlavní obtíže / důvod návštěvy):
bolest na hrudi uprostřed, vyzařující do levé ruky, dušnost, pocení

NA (Anamnéza nynějšího onemocnění):
Bolest na hrudi začala před cca 30 minutami, lokalizovaná uprostřed hrudníku,
vyzařující do levé ruky, doprovázena dušností a pocením. Pacient se cítí velmi špatně.

RA (Rodinná anamnéza): neuvedeno
OA (Osobní anamnéza): neuvedeno
FA (Farmakologická anamnéza): pravidelně užívá aspirin 100 mg jako prevenci,
  předepsaný praktickým lékařem
AA (Alergologická anamnéza): bez známých alergií na léky
GA (Gynekologická/urologická anamnéza): neuvedeno
SA (Sociální anamnéza): neuvedeno

Objektivní nález:
TK 150/95 mmHg, puls 98/min, nepravidelný; EKG: elevace ST segmentu ve svodech II, III a aVF

Hodnocení: Akutní infarkt myokardu spodní stěny
Návrh vyšetření: koronární angiografie na katetrizačním sále
Návrh terapie: podání heparinu a nitroglycerinu, urgentní katetrizační vyšetření
Pokyny a plán kontrol: okamžitý transport na katetrizační sál, aktivace katetrizačního týmu
```

#### gpt-5-mini Output (representative run)

```
Lékařská zpráva

Identifikace pacienta:
Příjmení: Novák; Křestní jméno: neuvedeno; Věk: 58 let; Pohlaví: muž;
Datum návštěvy: 01. 03. 2026

NO (Hlavní obtíže / důvod návštěvy):
Bolest na hrudi, dušnost, začalo před cca 30 minutami, potí se.

NA (Anamnéza nynějšího onemocnění):
Bolest uprostřed hrudníku zahájená před asi 30 minutami, vyzařuje do levé ruky,
obtížné nadechnutí, pocení, pacient uvádí sníženou schopnost soustředění.

RA (Rodinná anamnéza): neuvedeno
OA (Osobní anamnéza): neuvedeno
FA (Farmakologická anamnéza): Aspirin 100 mg, předepsán praktickým lékařem jako prevence.
AA (Alergologická anamnéza): NEGACI: žádné alergie hlášeny (na nic).
GA (Gynekologická/urologická anamnéza): neuvedeno
SA (Sociální anamnéza): neuvedeno

Objektivní nález:
Krevní tlak 150/95 mmHg, pulz 98/min, nepravidelný. EKG: elevace ST segmentu
ve svodech II, III a aVF. Pacient diaphoretický, dušný.

Hodnocení:
Akutní infarkt myokardu – spodní (inferiorní) stěna (ST elevace ve svodech II, III, aVF).

Návrh vyšetření:
Koronární angiografie (převod na katetrizační sál).
(Jiné specifické laboratorní nebo zobrazovací vyšetření neuvedeno.)

Návrh terapie:
Podání heparinu (dávka neuvedena) a nitráty (dávka/formulace neuvedena).
Okamžitý transport na katetrizační sál.

Pokyny a plán kontrol:
Kontaktovat katetrizační tým a připravit pacienta na překlad na katetrizační sál.
Další kontrola a sledování podle stavu během přípravy na převod.
```

### 4.4 Quality Observations

| Aspect | gpt-4.1-mini | gpt-5-mini |
|--------|-------------|------------|
| Patient identification | "muž, 58 let" | "Novák; Věk: 58 let; muž" — extracts surname from dialogue |
| Medical terminology depth | Standard Czech | Adds synonyms — "inferiorní" for "spodní" |
| Missing data handling | "neuvedeno" | "neuvedeno" + explicit notes like "(dávka neuvedena)" |
| Allergy negation | "bez známých alergií" | "NEGACI: žádné alergie hlášeny" |
| Overall completeness | Very good | Slightly more thorough |
| Factual accuracy | Excellent | Excellent |

Both models produce clinically accurate reports with no hallucinations.

---

## 5. Evaluation & Recommendation

### gpt-4.1-mini — Recommended for Production

**Pros:**
- **4–6s latency** fits the 15-second report update cycle with room to spare
- **~$0.001/report** — cost-efficient even at scale
- Supports `temperature=0.3` for deterministic, consistent output
- Standard SKU — **data stays in West Europe** (GDPR compliant)
- Simpler API — standard `max_tokens` parameter supported
- Output quality is already excellent for the medical documentation use case

**Cons:**
- Slightly less detailed than gpt-5-mini (misses patient surname on some runs)

### gpt-5-mini — Not Recommended for Current Use Case

**Pros:**
- Marginally higher output quality (extracts more details, adds medical synonyms)
- Internal reasoning produces more carefully structured reports

**Cons:**
- **15–20s latency** — exceeds the 15-second report generation interval, would cause queued/stale updates
- **4× more expensive** ($0.004 vs $0.001 per report)
- GlobalStandard SKU — **data may leave EU** (GDPR concern for medical data)
- No `temperature` control — output variability cannot be reduced
- Requires higher token budget due to hidden reasoning tokens
- Newer API version required (`2025-04-01-preview`)

### Decision

**Use gpt-4.1-mini** as the production model. The 4× speed advantage and GDPR-compliant data residency outweigh the marginal quality improvement of gpt-5-mini. The gpt-5-mini deployment can be deleted to avoid confusion.

---

## 6. Next Steps

1. Delete `gpt-5-mini` deployment (unless needed for future testing)
2. Switch `backend/main.py` from `OpenAI` to `AzureOpenAI` with `gpt-4-1-mini` deployment
3. Deploy backend to Azure Container Apps
4. Update `mobile/lib/config/constants.dart` with production backend URL

---

## 7. LLM-as-Judge Evaluation Results

Automated quality evaluation was run using `backend/evaluate_reports.py` (see `LLM_JUDGE_SPEC.md` for full methodology). The judge scores each report on 6 dimensions (0–5 scale).

### 7.1 Model Comparison (v0 baseline prompt)

| Model | Scenario Set | Fact | Comp | Strc | Neg | Lang | Noise | **AVG** |
|-------|-------------|------|------|------|-----|------|-------|---------|
| gpt-4.1-mini | Demo (8) | 5.00 | 4.62 | 4.88 | 4.88 | 5.00 | 5.00 | **4.90** |
| gpt-4.1-mini | Hurvínek (3) | 5.00 | 4.00 | 4.00 | 5.00 | 5.00 | 5.00 | **4.67** |
| gpt-5-mini | Demo (8) | 4.00 | 4.75 | 5.00 | 4.88 | 4.75 | 4.62 | **4.67** |
| gpt-5-mini | Hurvínek (3) | 4.00 | 4.00 | 5.00 | 4.33 | 4.67 | 4.67 | **4.44** |

**gpt-4.1-mini outperforms gpt-5-mini** in overall score (4.90 vs 4.67 on demo, 4.67 vs 4.44 on Hurvínek). The gpt-5-mini model scores lower on Factual Accuracy because the judge (also gpt-5-mini's reasoning capability) flags the system-prompt-injected visit date as a hallucination.

### 7.2 Prompt Variant A/B Test (gpt-4.1-mini)

| Variant | Demo AVG | Hurvínek AVG | Delta vs v0 (Demo) | Delta vs v0 (Hurv) |
|---------|----------|-------------|--------------------|--------------------|
| **v0** (baseline) | 4.90 | 4.67 | — | — |
| **v1** (completeness boost) | **4.98** | **4.78** | **+0.08** | **+0.11** |
| **v2** (strict structure) | 4.90 | 4.72 | +0.00 | +0.05 |
| **v3** (negation+noise) | 4.92 | 4.72 | +0.02 | +0.05 |

**v1 recommended** — adds a single sentence emphasizing completeness; yields the best scores on both scenario sets with no regressions. See `LLM_JUDGE_SPEC.md` §11 for full per-dimension breakdown.
