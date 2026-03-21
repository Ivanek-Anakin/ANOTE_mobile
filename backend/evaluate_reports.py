"""LLM-as-Judge report quality evaluation for ANOTE.

Generates medical reports from transcript files, then evaluates each report
on 6 quality dimensions using a separate LLM judge call.

Usage:
    python evaluate_reports.py --scenarios-dir ../testing_hurvinek/
    python evaluate_reports.py --scenarios-dir ../mobile/assets/demo_scenarios/
    python evaluate_reports.py --scenarios-dir ../testing_hurvinek/ --prompt-variant v1
    python evaluate_reports.py --scenarios-dir ../mobile/assets/demo_scenarios/ --prompt-variant v2

Prompt variants:
    v0  -- baseline (current production prompt)
    v1  -- completeness boost (capture all contextual details)
    v2  -- stricter structure (enforce 13 sections, formatting)
    v3  -- enhanced negation + noise filtering
    v4  -- enhanced production (adherence + negation + SA + roles)
"""

import argparse
import json
import os
import sys
import time
from datetime import date, datetime
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

import httpx
from openai import AzureOpenAI

# ── Azure OpenAI configuration ──────────────────────────────────────────────

ENDPOINT = "https://anote-openai.openai.azure.com/"
API_VERSION = "2025-04-01-preview"
DEFAULT_MODEL = "gpt-4-1-mini"

API_KEY = os.environ.get(
    "AZURE_OPENAI_KEY",
    # Fallback: same key used in test_hurvinek.py (already committed to repo)
    "REDACTED_KEY",
)

# ── System prompt (synced from backend/main.py _build_system_prompt) ──────────


def _build_base_rules() -> str:
    """Return the ZÁSADY (rules) block shared by all visit-type prompts."""
    return (
        "ZÁSADY\n"
        "- Nevymýšlej ani nedoplňuj informace, které v přepisu nejsou.\n"
        '- Pokud informace chybí, napiš přesně: \u201Eneuvedeno\u201C.\n'
        "- Pokud je něco výslovně popřeno (typicky po dotazu lékaře), zaznamenej to "
        "jako NEGACI. Negace má přednost před \u201Eneuvedeno\u201C. Používej formulace jako:\n"
        '  \u2022 \u201Ealergie neguje\u201C\n'
        '  \u2022 \u201Ezvýšenou teplotu neguje\u201C\n'
        '  \u2022 \u201Edušnost neguje\u201C\n'
        '  \u2022 \u201Etěžké hypoglykémie neměl/a\u201C\n'
        '  \u2022 \u201Enoční hypoglykémie neudává\u201C\n'
        '  \u2022 \u201Ebez bolestí\u201C\n'
        '  \u2022 \u201Ejinak se cítí dobře\u201C / \u201Ejiné obtíže neguje\u201C\n'
        '  \u2022 \u201Ekomplikace neguje\u201C\n'
        "- U chronických onemocnění aktivně zaznamenávej negace komplikací "
        "(těžké hypoglykémie, noční hypoglykémie, retinopatie, neuropatie apod.), "
        "pokud byly výslovně popřeny.\n"
        "- Rozlišuj \u201Epacient výslovně popřel\u201C vs \u201Enebylo zmíněno\u201C \u2014 "
        "první je negace, druhé je \u201Eneuvedeno\u201C.\n"
        "- Zachovej přesná čísla, jednotky, dávkování a frekvenci "
        "(mg, ml, 1\u20130\u20131, 2\u00d7 denně, týdny\u2026).\n"
        "- Aktivně zachycuj přibližné údaje a kvantifikace, i pokud jsou nepřesné: "
        "dobu trvání (asi 3 měsíce, pár dní), četnost (2\u00d7 týdně, občas, denně), "
        "hmotnostní změny (přibral/a asi 2 kg), dávkování, naměřené hodnoty "
        "(domácí TK kolem 120/70). Zachovej formulaci s \u201Easi\u201C / \u201Epřibližně\u201C / "
        "\u201Ekolem\u201C \u2014 neupřesňuj ani nezaokrouhluj.\n"
        "- Rozlišuj subjektivní údaje (udává pacient) vs objektivní nález "
        "(naměřeno / zjištěno vyšetřením). Co je jen udávané, nepiš jako objektivní.\n"
        "- Při rozporu v přepisu uveď obě verze a označ \u201Erozpor v přepisu\u201C.\n"
        "- Přepis může obsahovat chyby z automatického rozpoznávání řeči \u2014 "
        "interpretuj smysl, ne doslovný text.\n"
        "- V přepisu se střídají repliky lékaře a pacienta. Otázky, pokyny "
        "a diagnózy přiřaď lékaři. Odpovědi, stížnosti a subjektivní popisy "
        "přiřaď pacientovi. Pokud není jasné, kdo mluví, uveď obsah bez přiřazení.\n"
        "- U změn medikace nebo léčby zaznamenej, kdo změnu doporučil "
        "(jiný lékař, specialista), pokud to v přepisu zazní.\n"
    )


def _build_system_prompt(today: str) -> str:
    """Build the Czech medical report system prompt with today's date.

    This is the v4 enhanced prompt used in production (default/initial mode).
    """
    intro = (
        "Jsi asistent pro tvorbu lékařské dokumentace. Z poskytnutého přepisu "
        "návštěvy vytvoř formální lékařskou zprávu v češtině.\n\n"
    )
    rules = _build_base_rules()
    sections = (
        f"DATUM NÁVŠTĚVY\n- Datum návštěvy vždy: {today}\n\n"
        "VÝSTUP \u2013 dodrž přesně strukturu, názvy a pořadí:\n"
        "Lékařská zpráva\n\n"
        "Identifikace pacienta:\n"
        '- Jméno: (pokud není, \u201Eneuvedeno\u201C)\n'
        "- Věk / r. narození: (neuvedeno)\n"
        f"- Datum návštěvy: {today}\n\n"
        "NO (Nynější onemocnění):\n"
        "- Hlavní problém, proč pacient přichází, časový údaj, spouštěč.\n"
        '- Pokud pacient důvod výslovně neřekl: \u201Eneuvedeno\u201C.\n'
        "- Průběh aktuálních potíží: začátek, trvání, lokalizace, intenzita, charakter, "
        "provokační/úlevové faktory, doprovodné příznaky.\n"
        "- Zahrň relevantní negativní symptomy, pokud byly výslovně negovány "
        '(např. \u201Ezvýšenou teplotu neguje\u201C).\n\n'
        "RA (Rodinná anamnéza):\n"
        "- Závažná onemocnění v rodině (KV, DM, onko, trombózy, psychiatrie ap.).\n"
        '- Pokud bylo výslovně popřeno: \u201ERA bez pozoruhodností / neg.\u201C.\n'
        '- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n'
        "OA (Osobní anamnéza):\n"
        "- Prodělaná onemocnění, operace, hospitalizace, chronická onemocnění.\n"
        '- Pokud pacient výslovně popře: \u201EOA neg.\u201C / \u201Ebez závažných onemocnění\u201C.\n'
        '- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n'
        "FA (Farmakologická anamnéza / aktuální medikace):\n"
        '- Pravidelně užívané léky (název, dávka, režim), OTC, doplňky.\n'
        '- Pokud výslovně popřeno: \u201Ebez pravidelné medikace\u201C.\n'
        '- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n'
        "AA (Alergologická anamnéza):\n"
        '- Alergie (léky, potraviny, pyl\u2026), reakce.\n'
        '- Pokud výslovně popřeno: \u201Ealergie neguje\u201C.\n'
        '- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n'
        "GA (Gynekologická/urologická anamnéza \u2013 jen pokud relevantní a zmíněno):\n"
        '- Dle přepisu (cyklus, gravidita, antikoncepce / urologické potíže atd.).\n'
        '- Pokud výslovně popřeno: uveď negaci relevantního symptomu.\n'
        '- Jinak \u201Eneuvedeno\u201C.\n\n'
        "SA (Sociální anamnéza):\n"
        "- Kouření, alkohol, drogy \u2013 jen co zazní. Pokud výslovně popřeno: "
        'např. \u201Ekouření neguje\u201C.\n'
        "- Zaměstnání: typ a pracovní zátěž (směnný provoz, fyzická práce, cestování).\n"
        "- Rodinná situace: péče o blízké, psychická a sociální zátěž.\n"
        "- Pohyb a cvičení: typ, frekvence, změna oproti minulosti.\n"
        "- Zaznamenej, jak sociální a pracovní faktory ovlivňují pacientův režim, "
        "kompenzaci onemocnění nebo adherenci (např. nepravidelné stravování kvůli "
        "cestování, nemožnost cvičit kvůli pracovní zátěži).\n"
        '- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n'
        "Adherence a spolupráce pacienta:\n"
        "- Zaznamenej, zda pacient dodržuje doporučený režim, léčbu a kontroly.\n"
        "- Uveď, co pacient odmítá (rehabilitace, technologie, vyšetření) "
        "a důvod odmítnutí, pokud zazněl.\n"
        "- Uveď, co pacient nedodal (záznamy o jídlech, zprávy z vyšetření, výsledky).\n"
        "- Pokud pacient nedodržuje dietu, pohyb nebo medikaci, zaznamenej konkrétně co a proč.\n"
        '- Pokud je spolupráce dobrá: \u201Espolupráce dobrá\u201C / \u201Erežim dodržuje\u201C.\n'
        '- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n'
        "Objektivní nález:\n"
        "- Pouze naměřené/zjištěné hodnoty a nálezy (TK, P, SpO2, TT, fyzikální nález).\n"
        '- Pokud není nic objektivně uvedeno: \u201Eneuvedeno\u201C.\n'
        "- Pokud pacient jen udává, že nemá horečku: nepiš jako objektivní TT, "
        'ale dej do NO jako \u201Ezvýšenou teplotu neguje\u201C.\n\n'
        "Hodnocení (pracovní diagnóza / klinický závěr):\n"
        "- Uveď jen to, co zaznělo od lékaře (diagnóza, suspektní stav).\n"
        '- Pokud nezaznělo: \u201Eneuvedeno\u201C.\n\n'
        "Návrh vyšetření:\n"
        '- Doporučená/indikovaná vyšetření, odběry, zobrazování, konzilia \u2013 pouze pokud zaznělo.\n'
        '- Jinak \u201Eneuvedeno\u201C.\n\n'
        "Návrh terapie:\n"
        '- Léčba, medikace, režimová opatření \u2013 pouze pokud zaznělo.\n'
        '- Jinak \u201Eneuvedeno\u201C.\n\n'
        "Pokyny a plán kontrol:\n"
        '- Kontrola, varovné příznaky, návrat při zhoršení \u2013 pouze pokud zaznělo.\n'
        '- Jinak \u201Eneuvedeno\u201C.\n\n'
    )
    footer = (
        "JAZYK\n"
        "- Celý výstup musí být v češtině. Nepřidávej žádné komentáře mimo strukturu."
    )
    return intro + rules + "\n" + sections + footer


# ── Prompt variants ──────────────────────────────────────────────────────────

PROMPT_VARIANTS = {
    "v0": {
        "name": "Baseline",
        "description": "Current production prompt (no modifications)",
        "suffix": "",
    },
    "v1": {
        "name": "Completeness boost",
        "description": "Extra instructions to capture all contextual details",
        "suffix": (
            "\n\nDOPLŇUJÍCÍ POKYNY PRO ÚPLNOST\n"
            "- Zahrň VŠECHNY lékařsky relevantní informace z přepisu, včetně "
            "kontextuálních údajů (přítomnost doprovodu, délka obtíží, okolnosti vzniku, "
            "údaje o životním stylu zmíněné mimochodem).\n"
            "- Raději zapiš více informací než méně — vynechání relevantního údaje "
            "je horší než jeho zapsání.\n"
            "- Pokud pacient zmíní sociální kontext (bydlení, práce, sport, strava), "
            "zapiš ho do SA.\n"
            "- Pokud lékař zmíní předpokládanou délku onemocnění nebo prognózu, "
            "zapiš to do Pokynů a plánu kontrol."
        ),
    },
    "v2": {
        "name": "Strict structure",
        "description": "Enforce 13-section format, no merging/skipping",
        "suffix": (
            "\n\nDOPLŇUJÍCÍ POKYNY PRO STRUKTURU\n"
            "- Výstup MUSÍ obsahovat VŠECH 13 sekcí v přesně uvedeném pořadí.\n"
            "- Každá sekce začíná na novém řádku svým PŘESNÝM názvem, jak je uveden výše.\n"
            "- NIKDY neslučuj dvě sekce do jedné (např. OA a FA musí být oddělené).\n"
            "- NIKDY nepřeskakuj sekci — pokud nemáš data, napiš \u201Eneuvedeno\u201C.\n"
            "- Za názvem každé sekce VŽDY následuje obsah na dalším řádku "
            "(ne na stejném řádku jako název).\n"
            "- Nepoužívej odrážky uvnitř sekcí, pokud to není nutné pro přehlednost."
        ),
    },
    "v3": {
        "name": "Negation + noise",
        "description": "Enhanced negation handling and noise filtering",
        "suffix": (
            "\n\nDOPLŇUJÍCÍ POKYNY PRO NEGACE\n"
            "- Pro KAŽDOU anamnestickou sekci (RA, OA, FA, AA, GA, SA): "
            "pokud téma bylo prokazatelně diskutováno a pacient popřel, "
            "VŽDY zapiš explicitní negaci (např. \u201Ealergie neguje\u201C, "
            "\u201ERA bez pozoruhodností\u201C).\n"
            "- Pokud téma nebylo diskutováno vůbec, napiš \u201Eneuvedeno\u201C.\n"
            "- NIKDY nesměšuj tyto dva stavy — \u201Eneguje\u201C \u2260 \u201Eneuvedeno\u201C.\n"
            "- Pokud pacient řekne \u201Ene\u201C nebo \u201Enemám\u201C na přímý dotaz lékaře, "
            "je to vždy NEGACE, nikoli \u201Eneuvedeno\u201C.\n"
            "\nDOPLŇUJÍCÍ POKYNY PRO FILTROVÁNÍ ŠUMU\n"
            "- Přepis může obsahovat: zpěv, říkanky, písničky, nesouvislé hlasy, "
            "šum pozadí, vtipkování, komentáře třetích osob.\n"
            "- Tyto části ZCELA IGNORUJ. Extrahuj POUZE lékařsky relevantní dialog "
            "mezi lékařem a pacientem.\n"
            "- Pokud si nejsi jistý, zda jde o lékařský údaj nebo šum z přepisu, "
            "NEZAPISUJ ho do zprávy."
        ),
    },
    "v4": {
        "name": "Enhanced v4 (adherence + negation + SA + roles)",
        "description": (
            "Production prompt with expanded negation handling, approximate quantities, "
            "enriched SA, adherence section, and LLM-based speaker role detection"
        ),
        "suffix": "",  # v4 is the new base prompt — no suffix needed
    },
}


def _get_system_prompt(today: str, variant: str = "v0") -> str:
    """Build system prompt with optional variant suffix appended."""
    base = _build_system_prompt(today)
    suffix = PROMPT_VARIANTS.get(variant, PROMPT_VARIANTS["v0"])["suffix"]
    return base + suffix


# ── Judge prompt (from LLM_JUDGE_SPEC.md §4) ────────────────────────────────

JUDGE_SYSTEM_PROMPT = """\
You are a medical documentation quality auditor. You will receive:
1. A transcript of a doctor-patient conversation (may contain ASR errors, background noise, irrelevant content)
2. A structured medical report generated from that transcript

Evaluate the report on these 6 dimensions (score 0-5 each):

1. FACTUAL_ACCURACY: Are all facts in the report traceable to the transcript? Any hallucinated information?
2. COMPLETENESS: Does the report capture all medically relevant information from the transcript? This includes:
   - approximate quantities (durations, frequencies, weight changes)
   - patient adherence (what patient refuses, didn't bring, doesn't follow)
   - social/occupational factors affecting disease management
   - who recommended medication changes (other specialists)
3. STRUCTURE: Are all required sections present? Is information placed in the correct section? Is there an Adherence section if relevant?
4. NEGATION_HANDLING: Does the report correctly distinguish "neuvedeno" (not discussed) from explicit negations? Are complication negations captured (e.g., "těžké hypoglykémie neměl", "noční hypoglykémie neudává")?
5. CLINICAL_LANGUAGE: Is the Czech medical terminology appropriate and professional?
6. NOISE_RESILIENCE: Does the report correctly filter ASR errors, songs, banter, and irrelevant content? Does it correctly attribute statements to doctor vs patient?

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
}"""

# ── Dimensions (for iteration and display) ───────────────────────────────────

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

# ── Helpers ──────────────────────────────────────────────────────────────────


def _is_reasoning_model(model: str) -> bool:
    """Return True for models that use internal reasoning tokens (gpt-5-mini etc.)."""
    return "5-mini" in model or "o1" in model or "o3" in model or "o4" in model


def _make_client(model: str) -> AzureOpenAI:
    """Create an AzureOpenAI client with a generous HTTP timeout."""
    return AzureOpenAI(
        api_key=API_KEY,
        api_version=API_VERSION,
        azure_endpoint=ENDPOINT,
        http_client=httpx.Client(timeout=httpx.Timeout(300.0)),
    )


def _strip_watermark(text: str) -> str:
    """Remove UniScribe watermark lines from a transcript."""
    lines = text.strip().splitlines()
    cleaned = [l for l in lines if "UniScribe" not in l and "uniscribe" not in l]
    return "\n".join(cleaned).strip()


def _call_with_retry(fn, *, max_retries: int = 5):
    """Call *fn* with exponential backoff on HTTP 429 rate-limit errors."""
    for attempt in range(max_retries + 1):
        try:
            return fn()
        except Exception as exc:
            # Check for rate-limit (429) in various openai exception shapes
            is_rate_limit = False
            if hasattr(exc, "status_code") and exc.status_code == 429:
                is_rate_limit = True
            elif "429" in str(exc):
                is_rate_limit = True

            if is_rate_limit and attempt < max_retries:
                wait = 2 ** attempt * 5  # 5, 10, 20, 40, 80 seconds
                print(f"  ⏳ Rate-limited (429). Waiting {wait}s before retry {attempt + 1}/{max_retries}…")
                time.sleep(wait)
                continue
            raise


# ── Core functions ───────────────────────────────────────────────────────────


def generate_report(client: AzureOpenAI, model: str, transcript: str, system_prompt: str) -> tuple[str, dict]:
    """Generate a medical report from a transcript. Returns (report_text, usage_info)."""
    t0 = time.time()
    reasoning = _is_reasoning_model(model)

    def _call():
        kwargs: dict = dict(
            model=model,
            messages=[
                {"role": "system", "content": system_prompt},
                {
                    "role": "user",
                    "content": f"Převeď tento přepis do strukturované lékařské zprávy v češtině:\n\n{transcript}",
                },
            ],
        )
        if reasoning:
            # gpt-5-mini: no temperature, uses max_completion_tokens, needs high budget for reasoning
            kwargs["max_completion_tokens"] = 16000
        else:
            kwargs["temperature"] = 0.3
            kwargs["max_tokens"] = 2000
        return client.chat.completions.create(**kwargs)

    response = _call_with_retry(_call)
    elapsed = time.time() - t0
    report = response.choices[0].message.content
    reasoning_tokens = 0
    if hasattr(response.usage, 'completion_tokens_details') and response.usage.completion_tokens_details:
        reasoning_tokens = getattr(response.usage.completion_tokens_details, 'reasoning_tokens', 0) or 0
    usage = {
        "time_s": round(elapsed, 2),
        "prompt_tokens": response.usage.prompt_tokens,
        "completion_tokens": response.usage.completion_tokens,
        "reasoning_tokens": reasoning_tokens,
    }
    return report, usage


def evaluate_report(client: AzureOpenAI, model: str, transcript: str, report: str) -> dict:
    """Evaluate a report with the LLM judge. Returns parsed JSON evaluation."""
    t0 = time.time()
    reasoning = _is_reasoning_model(model)

    def _call():
        kwargs: dict = dict(
            model=model,
            messages=[
                {"role": "system", "content": JUDGE_SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": (
                        f"=== TRANSCRIPT ===\n{transcript}\n\n"
                        f"=== GENERATED REPORT ===\n{report}"
                    ),
                },
            ],
            response_format={"type": "json_object"},
        )
        if reasoning:
            kwargs["max_completion_tokens"] = 16000
        else:
            kwargs["temperature"] = 0.0
            kwargs["max_tokens"] = 2000
        return client.chat.completions.create(**kwargs)

    response = _call_with_retry(_call)
    elapsed = time.time() - t0

    raw = response.choices[0].message.content
    try:
        evaluation = json.loads(raw)
    except json.JSONDecodeError:
        print(f"  ⚠️  Judge returned invalid JSON. Raw response:\n{raw[:500]}")
        evaluation = {"error": "invalid_json", "raw": raw}

    evaluation["_eval_time_s"] = round(elapsed, 2)
    evaluation["_eval_tokens"] = {
        "prompt_tokens": response.usage.prompt_tokens,
        "completion_tokens": response.usage.completion_tokens,
    }
    return evaluation


# ── Main pipeline ────────────────────────────────────────────────────────────


def run_evaluation(scenarios_dir: str, model: str, output_path: str, prompt_variant: str = "v0") -> list[dict]:
    """Run the full generate-then-evaluate pipeline on all .txt files in a directory."""
    scenarios_path = Path(scenarios_dir)
    if not scenarios_path.exists():
        print(f"Error: scenarios directory '{scenarios_dir}' does not exist.")
        sys.exit(1)

    txt_files = sorted(scenarios_path.glob("*.txt"))
    if not txt_files:
        print(f"Error: no .txt files found in '{scenarios_dir}'.")
        sys.exit(1)

    variant_info = PROMPT_VARIANTS.get(prompt_variant, PROMPT_VARIANTS["v0"])
    today = date.today().strftime("%d. %m. %Y")
    system_prompt = _get_system_prompt(today, prompt_variant)
    client = _make_client(model)

    print(f"\n{'═' * 80}")
    print(f"  ANOTE LLM-as-Judge Evaluation")
    print(f"  Model: {model}  |  Date: {today}  |  Scenarios: {len(txt_files)}")
    print(f"  Prompt: {prompt_variant} ({variant_info['name']})")
    print(f"  Directory: {scenarios_path.resolve()}")
    print(f"{'═' * 80}\n")

    results = []

    for i, txt_file in enumerate(txt_files, 1):
        name = txt_file.stem
        transcript_raw = txt_file.read_text(encoding="utf-8")
        transcript = _strip_watermark(transcript_raw)
        word_count = len(transcript.split())

        print(f"[{i}/{len(txt_files)}] {name}  ({word_count} words)")

        # Step 1: Generate report
        print(f"  → Generating report…", end="", flush=True)
        report, gen_usage = generate_report(client, model, transcript, system_prompt)
        reasoning_info = f", reasoning={gen_usage['reasoning_tokens']}" if gen_usage.get('reasoning_tokens') else ""
        print(f" done ({gen_usage['time_s']}s, {gen_usage['prompt_tokens']}+{gen_usage['completion_tokens']} tok{reasoning_info})")

        # Step 2: Evaluate report
        print(f"  → Evaluating report…", end="", flush=True)
        evaluation = evaluate_report(client, model, transcript, report)
        eval_time = evaluation.get("_eval_time_s", "?")
        print(f" done ({eval_time}s)")

        # Extract scores for quick display
        scores = evaluation.get("scores", {})
        score_vals = []
        for dim in DIMENSIONS:
            s = scores.get(dim, {}).get("score", "?")
            score_vals.append(s)
        composite = evaluation.get("composite_score", "?")
        score_str = "  ".join(f"{DIM_SHORT[d]}={v}" for d, v in zip(DIMENSIONS, score_vals))
        print(f"  ✓ Scores: {score_str}  |  AVG={composite}")

        if evaluation.get("hallucinations"):
            print(f"  ⚠ Hallucinations: {evaluation['hallucinations']}")
        if evaluation.get("omissions"):
            print(f"  ⚠ Omissions: {evaluation['omissions']}")
        print()

        results.append({
            "scenario": name,
            "transcript_words": word_count,
            "report_generation": gen_usage,
            "report": report,
            "evaluation": {
                "scores": scores,
                "composite_score": composite,
                "hallucinations": evaluation.get("hallucinations", []),
                "omissions": evaluation.get("omissions", []),
                "summary": evaluation.get("summary", ""),
            },
        })

    # ── Aggregate statistics ─────────────────────────────────────────────────
    composites = [
        r["evaluation"]["composite_score"]
        for r in results
        if isinstance(r["evaluation"]["composite_score"], (int, float))
    ]
    per_dim_means = {}
    for dim in DIMENSIONS:
        vals = [
            r["evaluation"]["scores"].get(dim, {}).get("score")
            for r in results
            if isinstance(r["evaluation"]["scores"].get(dim, {}).get("score"), (int, float))
        ]
        per_dim_means[dim] = round(sum(vals) / len(vals), 2) if vals else None

    aggregate = {
        "mean_composite": round(sum(composites) / len(composites), 2) if composites else None,
        "min_composite": min(composites) if composites else None,
        "max_composite": max(composites) if composites else None,
        "per_dimension_means": per_dim_means,
    }

    # ── Write JSON output ────────────────────────────────────────────────────
    output = {
        "metadata": {
            "date": datetime.now().isoformat(),
            "model": model,
            "api_version": API_VERSION,
            "prompt_variant": prompt_variant,
            "prompt_variant_name": variant_info["name"],
            "prompt_variant_description": variant_info["description"],
            "num_scenarios": len(results),
            "scenarios_dir": str(scenarios_path.resolve()),
        },
        "results": results,
        "aggregate": aggregate,
    }

    output_file = Path(output_path)
    output_file.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Results saved to: {output_file.resolve()}\n")

    # ── Console summary table ────────────────────────────────────────────────
    _print_summary_table(results, aggregate, model, today, prompt_variant)

    return results


def _print_summary_table(results: list[dict], aggregate: dict, model: str, today: str, prompt_variant: str = "v0") -> None:
    """Print a formatted console summary table."""
    col_w = 6  # width per score column
    name_w = 40
    header_dims = " ".join(f"{DIM_SHORT[d]:>{col_w}}" for d in DIMENSIONS)
    variant_info = PROMPT_VARIANTS.get(prompt_variant, PROMPT_VARIANTS["v0"])

    print(f"EVALUATION RESULTS \u2014 {model} \u2014 {prompt_variant} ({variant_info['name']}) \u2014 {today}")
    print("═" * (name_w + 1 + len(DIMENSIONS) * (col_w + 1) + col_w + 2))
    print(f"{'Scenario':<{name_w}} {header_dims} {'AVG':>{col_w}}")
    print("─" * (name_w + 1 + len(DIMENSIONS) * (col_w + 1) + col_w + 2))

    for r in results:
        name = r["scenario"][:name_w]
        scores_str = ""
        for dim in DIMENSIONS:
            val = r["evaluation"]["scores"].get(dim, {}).get("score", "?")
            scores_str += f" {val:>{col_w}}"
        comp = r["evaluation"]["composite_score"]
        comp_str = f"{comp:.1f}" if isinstance(comp, (int, float)) else str(comp)
        print(f"{name:<{name_w}}{scores_str} {comp_str:>{col_w}}")

    print("─" * (name_w + 1 + len(DIMENSIONS) * (col_w + 1) + col_w + 2))

    # Mean row
    means_str = ""
    per_dim = aggregate.get("per_dimension_means", {})
    for dim in DIMENSIONS:
        val = per_dim.get(dim)
        means_str += f" {val:>{col_w}}" if val is not None else f" {'?':>{col_w}}"
    mean_comp = aggregate.get("mean_composite")
    mean_comp_str = f"{mean_comp:.1f}" if mean_comp is not None else "?"
    print(f"{'MEAN':<{name_w}}{means_str} {mean_comp_str:>{col_w}}")
    print()


# ── CLI ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="ANOTE LLM-as-Judge — evaluate report quality on transcript scenarios"
    )
    parser.add_argument(
        "--scenarios-dir",
        default="../testing_hurvinek/",
        help="Directory containing .txt transcript files (default: ../testing_hurvinek/)",
    )
    parser.add_argument(
        "--output",
        default="evaluation_results.json",
        help="Output JSON file path (default: evaluation_results.json)",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Azure OpenAI deployment name (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--prompt-variant",
        default="v0",
        choices=["v0", "v1", "v2", "v3", "v4"],
        help="Prompt variant: v0=baseline, v1=completeness, v2=structure, v3=negation+noise, v4=enhanced-production (default: v0)",
    )
    args = parser.parse_args()

    run_evaluation(args.scenarios_dir, args.model, args.output, args.prompt_variant)
