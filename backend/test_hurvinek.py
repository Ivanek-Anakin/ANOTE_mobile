"""Test full report generation pipeline with 3 Hurvínek scenarios on Azure OpenAI gpt-4.1-mini."""

import time
import warnings
from pathlib import Path
from datetime import date

warnings.filterwarnings("ignore")
from openai import AzureOpenAI

ENDPOINT = "https://anote-openai.openai.azure.com/"
KEY = "REDACTED_KEY"
API_VERSION = "2025-04-01-preview"
MODEL = "gpt-4-1-mini"

SCENARIOS_DIR = Path(__file__).parent.parent / "testing_hurvinek"

# Use the exact system prompt from backend/main.py
today = date.today().strftime("%d. %m. %Y")

SYSTEM_PROMPT = (
    "Jsi asistent pro tvorbu lékařské dokumentace. Z poskytnutého přepisu "
    "návštěvy vytvoř formální lékařskou zprávu v češtině.\n\n"
    "ZÁSADY\n"
    "- Nevymýšlej ani nedoplňuj informace, které v přepisu nejsou.\n"
    "- Pokud informace chybí, napiš přesně: \u201Eneuvedeno\u201C.\n"
    "- Pokud je něco výslovně popřeno (typicky po dotazu lékaře), zaznamenej to "
    "jako NEGACI (např. \u201Ealergie neguje\u201C, \u201Ezvýšenou teplotu neguje\u201C, \u201Edušnost neguje\u201C). "
    "Negace má přednost před \u201Eneuvedeno\u201C.\n"
    "- Zachovej přesná čísla, jednotky, dávkování a frekvenci (mg, ml, 1\u20130\u20131, 2\u00d7 denně, týdny\u2026).\n"
    "- Rozlišuj subjektivní údaje (udává pacient) vs objektivní nález (naměřeno / zjištěno vyšetřením). "
    "Co je jen udávané, nepiš jako objektivní.\n"
    "- Při rozporu v přepisu uveď obě verze a označ \u201Erozpor v přepisu\u201C.\n"
    "- Přepis může obsahovat chyby z automatického rozpoznávání řeči \u2014 interpretuj smysl, ne doslovný text.\n\n"
    "DATUM NÁVŠTĚVY\n"
    f"- Datum návštěvy vždy: {today}\n\n"
    "VÝSTUP \u2013 dodrž přesně strukturu, názvy a pořadí:\n"
    "Lékařská zpráva\n\n"
    "Identifikace pacienta:\n"
    "- Jméno: (pokud není, \u201Eneuvedeno\u201C)\n"
    "- Věk / r. narození: (neuvedeno)\n"
    f"- Datum návštěvy: {today}\n\n"
    "NO (Hlavní obtíže / důvod návštěvy):\n"
    "- Hlavní problém, proč pacient přichází, časový údaj, spouštěč.\n"
    "- Pokud pacient důvod výslovně neřekl: \u201Eneuvedeno\u201C.\n\n"
    "NA (Anamnéza nynějšího onemocnění):\n"
    "- Průběh aktuálních potíží: začátek, trvání, lokalizace, intenzita, charakter, "
    "provokační/úlevové faktory, doprovodné příznaky.\n"
    "- Zahrň relevantní negativní symptomy, pokud byly výslovně negovány "
    "(např. \u201Ezvýšenou teplotu neguje\u201C).\n\n"
    "RA (Rodinná anamnéza):\n"
    "- Závažná onemocnění v rodině (KV, DM, onko, trombózy, psychiatrie ap.).\n"
    "- Pokud bylo výslovně popřeno: \u201ERA bez pozoruhodností / neg.\u201C.\n"
    "- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n"
    "OA (Osobní anamnéza):\n"
    "- Prodělaná onemocnění, operace, hospitalizace, chronická onemocnění.\n"
    "- Pokud pacient výslovně popře: \u201EOA neg.\u201C / \u201Ebez závažných onemocnění\u201C.\n"
    "- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n"
    "FA (Farmakologická anamnéza / aktuální medikace):\n"
    "- Pravidelně užívané léky (název, dávka, režim), OTC, doplňky.\n"
    "- Pokud výslovně popřeno: \u201Ebez pravidelné medikace\u201C.\n"
    "- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n"
    "AA (Alergologická anamnéza):\n"
    "- Alergie (léky, potraviny, pyl\u2026), reakce.\n"
    "- Pokud výslovně popřeno: \u201Ealergie neguje\u201C.\n"
    "- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n"
    "GA (Gynekologická/urologická anamnéza \u2013 jen pokud relevantní a zmíněno):\n"
    "- Dle přepisu (cyklus, gravidita, antikoncepce / urologické potíže atd.).\n"
    "- Pokud výslovně popřeno: uveď negaci relevantního symptomu.\n"
    "- Jinak \u201Eneuvedeno\u201C.\n\n"
    "SA (Sociální anamnéza):\n"
    "- Kouření, alkohol, drogy, zaměstnání, pohyb, domácí situace \u2013 jen co zazní.\n"
    "- Pokud výslovně popřeno: např. \u201Ekouření neguje\u201C.\n"
    "- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n"
    "Objektivní nález:\n"
    "- Pouze naměřené/zjištěné hodnoty a nálezy (TK, P, SpO2, TT, fyzikální nález).\n"
    "- Pokud není nic objektivně uvedeno: \u201Eneuvedeno\u201C.\n"
    "- Pokud pacient jen udává, že nemá horečku: nepiš jako objektivní TT, "
    "ale dej do NA jako \u201Ezvýšenou teplotu neguje\u201C.\n\n"
    "Hodnocení (pracovní diagnóza / klinický závěr):\n"
    "- Uveď jen to, co zaznělo od lékaře (diagnóza, suspektní stav).\n"
    "- Pokud nezaznělo: \u201Eneuvedeno\u201C.\n\n"
    "Návrh vyšetření:\n"
    "- Doporučená/indikovaná vyšetření, odběry, zobrazování, konzilia \u2013 pouze pokud zaznělo.\n"
    "- Jinak \u201Eneuvedeno\u201C.\n\n"
    "Návrh terapie:\n"
    "- Léčba, medikace, režimová opatření \u2013 pouze pokud zaznělo.\n"
    "- Jinak \u201Eneuvedeno\u201C.\n\n"
    "Pokyny a plán kontrol:\n"
    "- Kontrola, varovné příznaky, návrat při zhoršení \u2013 pouze pokud zaznělo.\n"
    "- Jinak \u201Eneuvedeno\u201C.\n\n"
    "JAZYK\n"
    "- Celý výstup musí být v češtině. Nepřidávej žádné komentáře mimo strukturu."
)

import httpx
client = AzureOpenAI(
    api_key=KEY,
    api_version=API_VERSION,
    azure_endpoint=ENDPOINT,
    http_client=httpx.Client(timeout=httpx.Timeout(300.0)),
)

# Find all .txt files
txt_files = sorted(SCENARIOS_DIR.glob("*.txt"))
print(f"Found {len(txt_files)} scenarios in {SCENARIOS_DIR}\n")

results = []

for txt_file in txt_files:
    name = txt_file.stem
    transcript = txt_file.read_text(encoding="utf-8")
    # Strip UniScribe watermark lines
    lines = [l for l in transcript.strip().splitlines()
             if "UniScribe" not in l and "uniscribe" not in l]
    transcript_clean = "\n".join(lines).strip()

    print(f"{'='*80}")
    print(f"SCENARIO: {name}")
    print(f"TRANSCRIPT LENGTH: {len(transcript_clean)} chars ({len(transcript_clean.split())} words)")
    print(f"{'='*80}")

    start = time.time()
    response = client.chat.completions.create(
        model=MODEL,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Převeď tento přepis do strukturované lékařské zprávy v češtině:\n\n{transcript_clean}"},
        ],
        temperature=0.3,
        max_tokens=2000,
    )
    elapsed = time.time() - start

    report = response.choices[0].message.content
    usage = response.usage

    print(f"\nTIME: {elapsed:.2f}s")
    print(f"TOKENS: {usage.prompt_tokens} in / {usage.completion_tokens} out / {usage.total_tokens} total")
    print(f"COST: ~${usage.prompt_tokens * 0.4 / 1e6 + usage.completion_tokens * 1.6 / 1e6:.4f}")
    print(f"\n{report}")
    print()

    results.append({
        "name": name,
        "transcript_words": len(transcript_clean.split()),
        "time": elapsed,
        "prompt_tokens": usage.prompt_tokens,
        "completion_tokens": usage.completion_tokens,
        "report": report,
    })

# Summary
print(f"\n{'='*80}")
print("SUMMARY")
print(f"{'='*80}")
print(f"{'Scenario':<45} {'Words':>6} {'Time':>6} {'In':>6} {'Out':>5}")
print(f"{'-'*45} {'-'*6} {'-'*6} {'-'*6} {'-'*5}")
for r in results:
    print(f"{r['name']:<45} {r['transcript_words']:>6} {r['time']:>5.1f}s {r['prompt_tokens']:>6} {r['completion_tokens']:>5}")
total_time = sum(r["time"] for r in results)
total_cost = sum(r["prompt_tokens"] * 0.4 / 1e6 + r["completion_tokens"] * 1.6 / 1e6 for r in results)
print(f"\nTotal time: {total_time:.1f}s | Total cost: ~${total_cost:.4f}")
