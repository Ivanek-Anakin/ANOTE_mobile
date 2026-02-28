"""ANOTE Backend — FastAPI proxy for structured Czech medical report generation."""

import logging
import os
from datetime import date
from pathlib import Path

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from openai import OpenAI
from pydantic import BaseModel

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

MOCK_MODE: bool = os.environ.get("MOCK_MODE", "false").lower() == "true"

app = FastAPI(title="ANOTE Backend", version="2.0.0")

# Allow all origins in development; tighten in production
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

if not MOCK_MODE:
    client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
else:
    client = None  # type: ignore[assignment]
    logger.warning("MOCK_MODE is ON — OpenAI will not be called")

CHAT_MODEL: str = os.environ.get("OPENAI_CHAT_MODEL", "gpt-4o-mini")
API_TOKEN: str = os.environ.get("APP_API_TOKEN", "dev-token")

# Path to demo scenario .txt files (relative to this file's location)
SCENARIOS_DIR: Path = (
    Path(__file__).parent.parent / "mobile" / "assets" / "demo_scenarios"
)


def _build_system_prompt(today: str) -> str:
    """Build the Czech medical report system prompt with today's date."""
    return (
        "Jsi asistent pro tvorbu lékařské dokumentace. Z poskytnutého přepisu "
        "návštěvy vytvoř formální lékařskou zprávu v češtině.\n\n"
        "ZÁSADY\n"
        '- Nevymýšlej ani nedoplňuj informace, které v přepisu nejsou.\n'
        '- Pokud informace chybí, napiš přesně: \u201Eneuvedeno\u201C.\n'
        '- Pokud je něco výslovně popřeno (typicky po dotazu lékaře), zaznamenej to '
        'jako NEGACI (např. \u201Ealergie neguje\u201C, \u201Ezvýšenou teplotu neguje\u201C, \u201Edušnost neguje\u201C). '
        'Negace má přednost před \u201Eneuvedeno\u201C.\n'
        '- Zachovej přesná čísla, jednotky, dávkování a frekvenci (mg, ml, 1\u20130\u20131, 2\u00d7 denně, týdny\u2026).\n'
        '- Rozlišuj subjektivní údaje (udává pacient) vs objektivní nález (naměřeno / zjištěno vyšetřením). '
        'Co je jen udávané, nepiš jako objektivní.\n'
        '- Při rozporu v přepisu uveď obě verze a označ \u201Erozpor v přepisu\u201C.\n'
        '- Přepis může obsahovat chyby z automatického rozpoznávání řeči \u2014 interpretuj smysl, ne doslovný text.\n\n'
        "DATUM NÁVŠTĚVY\n"
        f"- Datum návštěvy vždy: {today}\n\n"
        "VÝSTUP \u2013 dodrž přesně strukturu, názvy a pořadí:\n"
        "Lékařská zpráva\n\n"
        "Identifikace pacienta:\n"
        '- Jméno: (pokud není, \u201Eneuvedeno\u201C)\n'
        "- Věk / r. narození: (neuvedeno)\n"
        f"- Datum návštěvy: {today}\n\n"
        "NO (Hlavní obtíže / důvod návštěvy):\n"
        "- Hlavní problém, proč pacient přichází, časový údaj, spouštěč.\n"
        '- Pokud pacient důvod výslovně neřekl: \u201Eneuvedeno\u201C.\n\n'
        "NA (Anamnéza nynějšího onemocnění):\n"
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
        '- Kouření, alkohol, drogy, zaměstnání, pohyb, domácí situace \u2013 jen co zazní.\n'
        '- Pokud výslovně popřeno: např. \u201Ekouření neguje\u201C.\n'
        '- Pokud se neřešilo: \u201Eneuvedeno\u201C.\n\n'
        "Objektivní nález:\n"
        "- Pouze naměřené/zjištěné hodnoty a nálezy (TK, P, SpO2, TT, fyzikální nález).\n"
        '- Pokud není nic objektivně uvedeno: \u201Eneuvedeno\u201C.\n'
        "- Pokud pacient jen udává, že nemá horečku: nepiš jako objektivní TT, "
        'ale dej do NA jako \u201Ezvýšenou teplotu neguje\u201C.\n\n'
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
        "JAZYK\n"
        "- Celý výstup musí být v češtině. Nepřidávej žádné komentáře mimo strukturu."
    )


def verify_token(authorization: str = Header(...)) -> None:
    """Verify the Bearer token in the Authorization header."""
    if authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid token")


class ReportRequest(BaseModel):
    """Request body for the /report endpoint."""

    transcript: str
    language: str = "cs"


@app.get("/health")
async def health() -> dict:
    """Health check endpoint — no authentication required."""
    return {"status": "ok"}


@app.get("/scenarios")
async def list_scenarios() -> dict:
    """List all available demo scenario names (without .txt extension)."""
    if not SCENARIOS_DIR.exists():
        return {"scenarios": []}
    names = sorted(p.stem for p in SCENARIOS_DIR.glob("*.txt"))
    return {"scenarios": names}


@app.post("/test-report/{scenario_name}")
async def test_report_from_scenario(
    scenario_name: str, _: None = Depends(verify_token)
) -> dict:
    """Load a demo scenario .txt file and generate a full Czech medical report."""
    scenario_file = SCENARIOS_DIR / f"{scenario_name}.txt"
    if not scenario_file.exists():
        available = sorted(p.stem for p in SCENARIOS_DIR.glob("*.txt"))
        raise HTTPException(
            status_code=404,
            detail=f"Scenario '{scenario_name}' not found. Available: {available}",
        )

    transcript = scenario_file.read_text(encoding="utf-8").strip()
    logger.info("Test-report for scenario: %s", scenario_name)

    today: str = date.today().strftime("%d. %m. %Y")
    system_prompt = _build_system_prompt(today)

    if MOCK_MODE:
        report = f"[MOCK — scenario: {scenario_name}]\n\n{transcript[:200]}..."
        return {"scenario": scenario_name, "transcript": transcript, "report": report}

    try:
        response = client.chat.completions.create(
            model=CHAT_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {
                    "role": "user",
                    "content": (
                        "Převeď tento přepis do strukturované lékařské zprávy"
                        f" v češtině:\n\n{transcript}"
                    ),
                },
            ],
            temperature=0.3,
            max_tokens=2000,
        )
        report = response.choices[0].message.content
        logger.info("Test-report completed for scenario: %s", scenario_name)
        return {"scenario": scenario_name, "transcript": transcript, "report": report}
    except Exception as e:
        logger.error("OpenAI error on test-report (details omitted for GDPR)")
        raise HTTPException(
            status_code=502, detail=f"OpenAI error: {str(e)}"
        ) from e


@app.post("/report")
async def generate_report(
    data: ReportRequest, _: None = Depends(verify_token)
) -> dict:
    """Generate a structured Czech medical report from a spoken transcript."""
    transcript = data.transcript.strip()
    if not transcript:
        raise HTTPException(status_code=400, detail="Empty transcript")

    today: str = date.today().strftime("%d. %m. %Y")

    # NOTE: transcript and report content are deliberately NOT logged (GDPR).
    logger.info("Report generation request received")

    system_prompt = _build_system_prompt(today)

    if MOCK_MODE:
        logger.info("Returning mock report (MOCK_MODE=true)")
        mock_report = (
            "Lékařská zpráva\n\n"
            f"Identifikace pacienta:\n- Jméno: Testovací Pacient\n- Věk / r. narození: 45 let\n"
            f"- Datum návštěvy: {today}\n\n"
            "NO (Hlavní obtíže / důvod návštěvy):\n[MOCK] Bolest hlavy trvající 3 dny.\n\n"
            "NA (Anamnéza nynějšího onemocnění):\n[MOCK] Pulzující bolest, VAS 6/10. "
            "Zvýšenou teplotu neguje.\n\n"
            "RA (Rodinná anamnéza):\nneuvedeno\n\n"
            "OA (Osobní anamnéza):\n[MOCK] Hypertenze.\n\n"
            "FA (Farmakologická anamnéza):\n[MOCK] Amlodipin 5 mg 1–0–0.\n\n"
            "AA (Alergologická anamnéza):\n[MOCK] Alergie neguje.\n\n"
            "GA (Gynekologická/urologická anamnéza):\nneuvedeno\n\n"
            "SA (Sociální anamnéza):\nneuvedeno\n\n"
            "Objektivní nález:\n[MOCK] TK 138/88 mmHg, TF 76/min.\n\n"
            "Hodnocení:\n[MOCK] Tenzní bolest hlavy.\n\n"
            "Návrh vyšetření:\nneuvedeno\n\n"
            "Návrh terapie:\n[MOCK] Ibuprofen 400 mg dle potřeby.\n\n"
            "Pokyny a plán kontrol:\n[MOCK] Kontrola za 14 dní."
        )
        return {"report": mock_report}

    try:
        response = client.chat.completions.create(
            model=CHAT_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {
                    "role": "user",
                    "content": (
                        "Převeď tento přepis do strukturované lékařské zprávy"
                        f" v češtině:\n\n{transcript}"
                    ),
                },
            ],
            temperature=0.3,
            max_tokens=2000,
        )
        logger.info("Report generation completed successfully")
        return {"report": response.choices[0].message.content}
    except Exception as e:
        logger.error("OpenAI error occurred (details omitted for GDPR)")
        raise HTTPException(
            status_code=502, detail=f"OpenAI error: {str(e)}"
        ) from e
