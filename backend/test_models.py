"""Quick comparison test: gpt-4.1-mini vs gpt-5-mini on Azure OpenAI."""

import os
import time
from openai import AzureOpenAI

ENDPOINT = "https://anote-openai.openai.azure.com/"
KEY = os.environ["AZURE_OPENAI_KEY"]
API_VERSION = "2025-04-01-preview"

TRANSCRIPT = """Dobrý den, já jsem doktor Procházka, jste na urgentním příjmu. Můžete mi říct, co se stalo?
Dobrý den, doktore. Strašně mě bolí na hrudi, začalo to asi před půl hodinou. Nemůžu se pořádně nadechnout.
Kde přesně tu bolest cítíte? Vyzařuje někam?
Tady uprostřed, ale táhne mi to do levé ruky a je mi hrozně špatně, potím se.
Rozumím. Kolik vám je let?
Osmdesát... ne, padesát osm. Promiňte, nemůžu se soustředit.
To je v pořádku. Berete nějaké léky pravidelně?
Jenom aspirin stovku, předepsal mi ho obvoďák jako prevenci.
Máte alergii na nějaké léky?
Ne, na nic.
Tak teď vás vyšetřím. Sestřičko, změřte prosím tlak a natočte EKG. Takže tlak máte 150 na 95, puls 98, nepravidelný. Na EKG vidím elevaci ST segmentu ve svodech II, III a aVF.
Co to znamená, doktore? Je to vážné?
Pane Nováku, máte akutní infarkt myokardu, konkrétně spodní stěny srdce. Musíme jednat rychle. Dáme vám heparin a nitráty a okamžitě vás převezeme na katetrizační sál, kde provedeme koronární angiografii. Sestřičko, volejte katetrizační tým a připravte pacienta na překlad."""

SYSTEM_PROMPT = """Jsi asistent pro tvorbu lékařské dokumentace. Z poskytnutého přepisu návštěvy vytvoř formální lékařskou zprávu v češtině.

ZÁSADY
- Nevymýšlej ani nedoplňuj informace, které v přepisu nejsou.
- Pokud informace chybí, napiš přesně: „neuvedeno".
- Pokud je něco výslovně popřeno, zaznamenej to jako NEGACI.
- Zachovej přesná čísla, jednotky, dávkování a frekvenci.

DATUM NÁVŠTĚVY: 01. 03. 2026

VÝSTUP – dodrž přesně strukturu:
Lékařská zpráva

Identifikace pacienta:
NO (Nynější onemocnění):
RA (Rodinná anamnéza):
OA (Osobní anamnéza):
FA (Farmakologická anamnéza):
AA (Alergologická anamnéza):
GA (Gynekologická/urologická anamnéza):
SA (Sociální anamnéza):
Objektivní nález:
Hodnocení:
Návrh vyšetření:
Návrh terapie:
Pokyny a plán kontrol:

JAZYK: Celý výstup musí být v češtině."""

MODELS = ["gpt-4-1-mini", "gpt-5-mini"]

client = AzureOpenAI(
    api_key=KEY,
    api_version=API_VERSION,
    azure_endpoint=ENDPOINT,
)

for model in MODELS:
    print(f"\n{'='*70}")
    print(f"MODEL: {model}")
    print(f"{'='*70}")

    start = time.time()
    kwargs = dict(
        model=model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Převeď tento přepis do strukturované lékařské zprávy v češtině:\n\n{TRANSCRIPT}"},
        ],
    )
    # gpt-5-mini requires max_completion_tokens and doesn't support custom temperature
    # It also uses reasoning tokens internally, so needs a higher budget
    if "5-mini" in model:
        kwargs["max_completion_tokens"] = 16000
    else:
        kwargs["temperature"] = 0.3
        kwargs["max_tokens"] = 2000
    response = client.chat.completions.create(**kwargs)
    elapsed = time.time() - start

    report = response.choices[0].message.content
    usage = response.usage
    reasoning_tokens = 0
    if hasattr(usage, 'completion_tokens_details') and usage.completion_tokens_details:
        reasoning_tokens = usage.completion_tokens_details.reasoning_tokens or 0

    print(f"TIME: {elapsed:.2f}s")
    print(f"TOKENS: {usage.prompt_tokens} in / {usage.completion_tokens} out (reasoning: {reasoning_tokens}, visible: {usage.completion_tokens - reasoning_tokens})")
    print(f"REPORT LENGTH: {len(report or '')} chars")
    print(f"\n{report}")
    print()
