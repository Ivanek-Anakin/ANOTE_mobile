#!/usr/bin/env python3
"""Direct Azure OpenAI comparison: gpt-4-1-mini vs gpt-5-mini (both West Europe)

Outputs full results to compare_eu_models_results.txt for easy review.
"""
import os
import time, textwrap, sys
from datetime import date
from pathlib import Path
from openai import AzureOpenAI
import httpx

ENDPOINT = "https://anote-openai.openai.azure.com/"
API_KEY = os.environ["AZURE_OPENAI_KEY"]
API_VERSION = "2025-04-01-preview"

MODELS = ["gpt-4-1-mini", "gpt-5-nano"]

client = AzureOpenAI(
    api_key=API_KEY,
    api_version=API_VERSION,
    azure_endpoint=ENDPOINT,
    timeout=httpx.Timeout(300.0, connect=10.0),
)

TODAY = date.today().strftime("%d. %m. %Y")

SYSTEM_PROMPT = f"""Jsi lékařský asistent. Převeď přepis rozhovoru lékaře a pacienta do strukturované lékařské zprávy v češtině.

ZÁSADY
- Nevymýšlej ani nedoplňuj informace, které v přepisu nejsou.
- Pokud informace chybí, napiš přesně: „neuvedeno".
- Zachovej přesná čísla, jednotky, dávkování a frekvenci.
- Rozlišuj subjektivní údaje vs objektivní nález.

DATUM NÁVŠTĚVY: {TODAY}

VÝSTUP – dodrž přesně strukturu:
Lékařská zpráva

Identifikace pacienta:
- Jméno / Věk / Datum návštěvy

NO (Nynější onemocnění)
RA (Rodinná anamnéza)
OA (Osobní anamnéza)
FA (Farmakologická anamnéza)
AA (Alergologická anamnéza)
SA (Sociální anamnéza)
Objektivní nález
Hodnocení
Návrh vyšetření
Návrh terapie
Pokyny a plán kontrol
"""


SCRIPT_DIR = Path(__file__).resolve().parent

def _load(path: str) -> str:
    """Load transcript from file, strip UniScribe headers."""
    txt = (SCRIPT_DIR / path).read_text(encoding="utf-8")
    lines = [l for l in txt.splitlines()
             if "UniScribe" not in l and "Upgrade to remove" not in l]
    return "\n".join(lines).strip()


# ---------- test scenarios ----------
TESTS = [
    # --- SHORT (inline) ---
    {
        "name": "1. Short / simple (cold, headache)",
        "transcript": "Pacient přišel s bolestí hlavy a teplotou 38.5. Kašel a rýma trvají 3 dny. Doporučuji Paralen 500mg.",
    },
    {
        "name": "2. Follow-up (post pneumonia)",
        "transcript": "Dobrý den paní doktorko, přicházím na kontrolu. Minulý týden jsem měl zápal plic, byl jsem tady a dostal jsem antibiotika Augmentin. Bral jsem je pravidelně, horečka ustoupila asi po třech dnech. Teď už se cítím mnohem líp, ale pořád trochu kašlu, hlavně ráno. Dýchání je lepší, žádná bolest na hrudi. Spím lépe, jím normálně. Alergie na penicilin nemám, jiné léky neberu žádné. V rodině nikdo nemá plicní problémy. Nekouřím, alkohol příležitostně. Pracuji jako učitel na základní škole.",
    },
    {
        "name": "3. Complex (angina + otitis, vitals, meds, allergy)",
        "transcript": "Tak pojďte dál, posaďte se. Co vás trápí? Hele doktore, já mám takový problém, bolí mě strašně v krku, nemůžu polykat, a mám horečku asi 39. To trvá od včerejška. A taky mě bolí uši, hlavně to pravé. Rozumím. A berete nějaké léky pravidelně? No, beru Enalapril na tlak, 10 miligramů, a pak Metformin na cukrovku, 500 dvakrát denně. A jste na něco alergický? Jo, na Biseptol, z toho dostanu vyrážku. Dobře. Tak se podíváme. Otevřete pusu... Tak tady vidím zarudlé mandle s bílými čepy. Uši - pravé ucho je zarudlé, bubínek zánětlivé změny. Teplota 39.1. Tlak 145 na 85. Tep 88. Váha 92 kilo. Výška 178. Tak to vypadá na angínu a ještě ten zánět středního ucha. Předepíšu vám antibiotika, Klarithromycin 500 dvakrát denně na 7 dní, a Ibuprofen 400 na bolest a horečku. Kontrola za týden.",
    },
    {
        "name": "4. Pediatric (bronchitis, 4yr girl)",
        "transcript": "Tak maminka přivedla holčičku, je jí 4 roky, má rýmu a kašel asi 5 dní. Horečka do 38 stupňů. Antibiotika zatím nedostávala. Alergie žádné. Poslechově pískoty oboustranně. Nález: oboustranná bronchitida. Předepisuji Mucosolvan sirup třikrát denně a inhalace Ventolinu. Kontrola za 3 dny, pokud se zhorší, přijít dříve.",
    },
    {
        "name": "5. Minimal (stomach pain only)",
        "transcript": "Bolí mě břicho, hlavně nahoře uprostřed, po jídle se to zhoršuje. Trvá to asi týden.",
    },
    {
        "name": "6. Cardiology emergency (chest pain, ECG)",
        "transcript": "Pacient muž 62 let přivezen záchrankou s bolestí na hrudi, trvá asi 2 hodiny, svíravá bolest za hrudní kostí s propagací do levé ruky. Pocení, nauzea. Anamnéza: hypertenze, hyperlipidémie, kouří 20 cigaret denně 30 let. Léky: Prestarium 5mg, Atorvastatin 20mg, Anopyrin 100mg. EKG: elevace ST ve svodech II, III, aVF. Troponin pozitivní. Diagnóza: akutní infarkt myokardu spodní stěny. Zahájena duální antiagregace, heparin, překlad na katetrizační sál k urgentní PCI.",
    },
    # --- MEDIUM (from test_scenarios, ~1.3KB each) ---
    {
        "name": "7. Pediatric checkup (Tomášek, preventivní)",
        "transcript": _load("../test_scenarios/cz_detska_prohlidka.txt"),
    },
    {
        "name": "8. Food poisoning (mořské plody)",
        "transcript": _load("../test_scenarios/cz_otrava_jidlem.txt"),
    },
    {
        "name": "9. Respiratory infection (pneumonie)",
        "transcript": _load("../test_scenarios/cz_respiracni_infekce.txt"),
    },
    {
        "name": "10. Cardiac ER (infarkt, urgentní)",
        "transcript": _load("../test_scenarios/cz_kardialni_nahoda.txt"),
    },
    # --- LONG (Hurvínek transcripts, ~6-7KB each) ---
    {
        "name": "11. LONG: Hurvínek – Nachlazení (6.6KB)",
        "transcript": _load("../testing_hurvinek/S Hurvínkem za lékařem   1  Díl   Nachlazení.txt"),
    },
    {
        "name": "12. LONG: Hurvínek – Zlomenina (6.0KB)",
        "transcript": _load("../testing_hurvinek/S Hurvínkem za lékařem   2  Díl   Zlomenina.txt"),
    },
    {
        "name": "13. LONG: Hurvínek – Angína (6.9KB)",
        "transcript": _load("../testing_hurvinek/S Hurvínkem za lékařem 08 Angína.txt"),
    },
]

SEP = "=" * 80
OUT_FILE = Path(__file__).parent / "compare_4mini_5nano_results.txt"
results = []

# Tee output to both stdout and file
class Tee:
    def __init__(self, *streams):
        self.streams = streams
    def write(self, data):
        for s in self.streams:
            s.write(data)
            s.flush()
    def flush(self):
        for s in self.streams:
            s.flush()

outf = open(OUT_FILE, "w", encoding="utf-8")
tee = Tee(sys.stdout, outf)

def p(msg=""):
    tee.write(msg + "\n")


for i, test in enumerate(TESTS):
    transcript = test["transcript"]
    p(f"\n{SEP}")
    p(f"  TEST {i+1}/{len(TESTS)}: {test['name']}")
    p(f"  Transcript length: {len(transcript)} chars")
    p(f"  Transcript (full):")
    p(textwrap.indent(transcript, "    "))
    p(SEP)

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"Převeď tento přepis do strukturované lékařské zprávy v češtině:\n\n{transcript}"},
    ]

    row = {"name": test["name"], "input_len": len(transcript)}

    for model in MODELS:
        p(f"\n  >>> {model} ...")
        t0 = time.time()
        try:
            response = client.chat.completions.create(
                model=model,
                messages=messages,
                max_completion_tokens=4096,
                timeout=300.0,
            )
            elapsed = time.time() - t0
            report = response.choices[0].message.content or ""
            usage = response.usage
            p(f"      {elapsed:.1f}s | {len(report)} chars | tokens: prompt={usage.prompt_tokens}, completion={usage.completion_tokens}")
            row[model] = {"time": elapsed, "chars": len(report), "report": report,
                          "prompt_tokens": usage.prompt_tokens, "completion_tokens": usage.completion_tokens}
        except Exception as e:
            elapsed = time.time() - t0
            p(f"      ERROR after {elapsed:.1f}s: {e}")
            row[model] = {"time": elapsed, "chars": 0, "report": f"ERROR: {e}",
                          "prompt_tokens": 0, "completion_tokens": 0}

    # Print full reports
    for model in MODELS:
        p(f"\n  --- {model} report (FULL) ---")
        p(textwrap.indent(row[model]["report"], "  "))

    results.append(row)

# Summary table
p(f"\n\n{'=' * 100}")
p("  SUMMARY — EU West Europe: gpt-4-1-mini vs gpt-5-nano")
p(f"{'=' * 100}")
p(f"  {'Test':<55} {'Input':>7} {'gpt-4-1-mini':>14} {'gpt-5-nano':>14} {'Ratio':>8}")
p(f"  {'-'*55} {'-'*7} {'-'*14} {'-'*14} {'-'*8}")

for r in results:
    t41 = r.get("gpt-4-1-mini", {}).get("time", 0)
    t5m = r.get("gpt-5-nano", {}).get("time", 0)
    ratio = t5m / t41 if t41 > 0 else 0
    p(f"  {r['name']:<55} {r['input_len']:>5}ch {t41:>11.1f}s {t5m:>11.1f}s {ratio:>7.1f}x")

# Averages
avg_41 = sum(r.get("gpt-4-1-mini", {}).get("time", 0) for r in results) / len(results)
avg_5m = sum(r.get("gpt-5-nano", {}).get("time", 0) for r in results) / len(results)
avg_ratio = avg_5m / avg_41 if avg_41 > 0 else 0
p(f"  {'-'*55} {'-'*7} {'-'*14} {'-'*14} {'-'*8}")
p(f"  {'AVERAGE':<55} {'':>7} {avg_41:>11.1f}s {avg_5m:>11.1f}s {avg_ratio:>7.1f}x")

# Token averages
avg_comp_41 = sum(r.get("gpt-4-1-mini", {}).get("completion_tokens", 0) for r in results) / len(results)
avg_comp_5m = sum(r.get("gpt-5-nano", {}).get("completion_tokens", 0) for r in results) / len(results)
p(f"\n  Avg completion tokens: gpt-4-1-mini={avg_comp_41:.0f} | gpt-5-nano={avg_comp_5m:.0f}")

p(f"\n{'=' * 100}")
p("  DONE")
p(f"{'=' * 100}")
p(f"\n  Full results saved to: {OUT_FILE}")
outf.close()
