"""ANOTE Backend — FastAPI proxy for structured Czech medical report generation."""

import logging
import os
from datetime import date

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from openai import AzureOpenAI
from pydantic import BaseModel

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="ANOTE Backend", version="2.0.0")

client = AzureOpenAI(
    api_key=os.environ["AZURE_OPENAI_KEY"],
    api_version="2024-10-21",
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
)

CHAT_MODEL: str = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4o-mini")
API_TOKEN: str = os.environ["APP_API_TOKEN"]


def verify_token(authorization: str = Header(...)) -> None:
    """Verify the Bearer token provided in the Authorization header.

    Args:
        authorization: Value of the Authorization header.

    Raises:
        HTTPException: 401 if the token is missing or does not match.
    """
    if authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid token")


class ReportRequest(BaseModel):
    """Request body for the /report endpoint."""

    transcript: str
    language: str = "cs"


@app.get("/health")
async def health() -> dict:
    """Health check endpoint — no authentication required.

    Returns:
        dict: ``{"status": "ok"}``
    """
    return {"status": "ok"}


@app.post("/report")
async def generate_report(
    data: ReportRequest, _: None = Depends(verify_token)
) -> dict:
    """Generate a structured Czech medical report from a spoken transcript.

    Accepts a plain-text transcript, builds a Czech-language system prompt
    with today's date, and calls Azure OpenAI to produce a structured report.

    Args:
        data: Request body containing ``transcript`` and optional ``language``.
        _: Token verification dependency (result unused).

    Returns:
        dict: ``{"report": "<structured Czech medical report>"}``

    Raises:
        HTTPException: 400 if the transcript is empty or whitespace-only.
        HTTPException: 502 if Azure OpenAI returns an error.
    """
    transcript = data.transcript.strip()
    if not transcript:
        raise HTTPException(status_code=400, detail="Empty transcript")

    today: str = date.today().strftime("%d. %m. %Y")

    # NOTE: transcript and report content are deliberately NOT logged (GDPR).
    logger.info("Report generation request received")

    system_prompt = f"""Jsi specialista na lékařskou dokumentaci. Tvým úkolem je převést přepis návštěvy pacienta do strukturované lékařské zprávy v ČESKÉM jazyce s následujícími sekcemi:

1. **Identifikace pacienta** – Jméno, věk, datum návštěvy (dnešní datum je {today})
2. **Hlavní obtíže / Důvod návštěvy** – Proč pacient přišel
3. **Anamnéza nynějšího onemocnění** – Podrobnosti o aktuálních příznacích
4. **Osobní anamnéza / Alergie / Léky** – Relevantní historie a současná medikace
5. **Objektivní nález** – Vitální funkce, vyšetřovací nálezy
6. **Hodnocení** – Klinický dojem a diagnóza
7. **Plán** – Léčebný plán a kontroly

Pravidla:
- NEVYMÝŠLEJ informace, které nejsou v přepisu
- Datum návštěvy VŽDY vyplň jako {today}
- Pokud informace pro danou sekci chybí, napiš: "Nezmíněno v přepisu"
- Používej stručný, klinický jazyk v češtině
- Formátuj přehledně s nadpisy sekcí
- Celá zpráva MUSÍ být v češtině, i když je přepis v angličtině

Vrať pouze strukturovanou zprávu, žádný další komentář."""

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
        logger.error("Azure OpenAI error occurred (details omitted for GDPR)")
        raise HTTPException(
            status_code=502, detail=f"Azure OpenAI error: {str(e)}"
        ) from e
