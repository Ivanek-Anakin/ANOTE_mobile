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
        "Jsi specialista na lékařskou dokumentaci. Tvým úkolem je převést přepis "
        "návštěvy pacienta do strukturované lékařské zprávy v ČESKÉM jazyce "
        "s následujícími sekcemi:\n\n"
        f"1. **Identifikace pacienta** – Jméno, věk, datum návštěvy (dnešní datum je {today})\n"
        "2. **Hlavní obtíže / Důvod návštěvy** – Proč pacient přišel\n"
        "3. **Anamnéza nynějšího onemocnění** – Podrobnosti o aktuálních příznacích\n"
        "4. **Osobní anamnéza / Alergie / Léky** – Relevantní historie a současná medikace\n"
        "5. **Objektivní nález** – Vitální funkce, vyšetřovací nálezy\n"
        "6. **Hodnocení** – Klinický dojem a diagnóza\n"
        "7. **Plán** – Léčebný plán a kontroly\n\n"
        "Pravidla:\n"
        "- NEVYMÝŠLEJ informace, které nejsou v přepisu\n"
        f"- Datum návštěvy VŽDY vyplň jako {today}\n"
        '- Pokud informace pro danou sekci chybí, napiš: "Nezmíněno v přepisu"\n'
        "- Používej stručný, klinický jazyk v češtině\n"
        "- Formátuj přehledně s nadpisy sekcí\n"
        "- Celá zpráva MUSÍ být v češtině, i když je přepis v angličtině\n\n"
        "Vrať pouze strukturovanou zprávu, žádný další komentář."
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
            f"**1. Identifikace pacienta**\nJméno: Testovací Pacient\nVěk: 45 let\n"
            f"Datum návštěvy: {today}\n\n"
            "**2. Hlavní obtíže / Důvod návštěvy**\n[MOCK] Bolest hlavy trvající 3 dny.\n\n"
            "**3. Anamnéza nynějšího onemocnění**\n[MOCK] Pulzující bolest, VAS 6/10.\n\n"
            "**4. Osobní anamnéza / Alergie / Léky**\n[MOCK] Hypertenze – amlodipin 5 mg. Alergie: neguje.\n\n"
            "**5. Objektivní nález**\n[MOCK] TK 138/88 mmHg, TF 76/min.\n\n"
            "**6. Hodnocení**\n[MOCK] Tenzní bolest hlavy.\n\n"
            "**7. Plán**\n[MOCK] Ibuprofen 400 mg dle potřeby. Kontrola za 14 dní."
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
