"""ANOTE Backend — FastAPI proxy for structured Czech medical report generation."""

import logging
import os
import re
import smtplib
from datetime import date
from email.mime.text import MIMEText
from pathlib import Path

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from openai import AzureOpenAI, OpenAI
import httpx
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
    # Azure OpenAI (production) — preferred when AZURE_OPENAI_KEY is set
    if os.environ.get("AZURE_OPENAI_KEY"):
        client = AzureOpenAI(
            api_key=os.environ["AZURE_OPENAI_KEY"],
            api_version="2025-04-01-preview",
            azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
            timeout=httpx.Timeout(60.0, connect=10.0),
        )
        logger.info("Using Azure OpenAI at %s", os.environ["AZURE_OPENAI_ENDPOINT"])
    else:
        # Dev fallback — plain OpenAI
        client = OpenAI(
            api_key=os.environ["OPENAI_API_KEY"],
            timeout=httpx.Timeout(60.0, connect=10.0),
        )
        logger.info("Using plain OpenAI (dev fallback)")
else:
    client = None  # type: ignore[assignment]
    logger.warning("MOCK_MODE is ON — OpenAI will not be called")

CHAT_MODEL: str = os.environ.get("AZURE_OPENAI_DEPLOYMENT",
                                  os.environ.get("OPENAI_CHAT_MODEL", "gpt-5-chat"))
FALLBACK_MODEL: str = os.environ.get("AZURE_OPENAI_FALLBACK_DEPLOYMENT", "gpt-4-1-mini")
API_TOKEN: str = os.environ.get("APP_API_TOKEN", "dev-token")

# Path to demo scenario .txt files (relative to this file's location)
SCENARIOS_DIR: Path = (
    Path(__file__).parent.parent / "mobile" / "assets" / "demo_scenarios"
)


VALID_VISIT_TYPES = {"default", "initial", "followup", "gastroscopy", "colonoscopy", "ultrasound"}

VISIT_TYPE_LABELS: dict[str, str] = {
    "default": "Automatická detekce",
    "initial": "Vstupní vyšetření",
    "followup": "Kontrolní návštěva",
    "gastroscopy": "Gastroskopie",
    "colonoscopy": "Koloskopie",
    "ultrasound": "Ultrazvuk",
}

# SMTP configuration (all optional — feature disabled if SMTP_HOST is unset)
SMTP_HOST: str | None = os.environ.get("SMTP_HOST")
SMTP_PORT: int = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER: str = os.environ.get("SMTP_USER", "")
SMTP_PASSWORD: str = os.environ.get("SMTP_PASSWORD", "")
SMTP_FROM_EMAIL: str = os.environ.get("SMTP_FROM_EMAIL", "noreply@anote.cz")
SMTP_USE_TLS: bool = os.environ.get("SMTP_USE_TLS", "true").lower() == "true"

if SMTP_HOST:
    logger.info("SMTP configured: host=%s port=%d from=%s", SMTP_HOST, SMTP_PORT, SMTP_FROM_EMAIL)
else:
    logger.info("SMTP not configured — email sending disabled")


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


def _build_sections_initial(today: str) -> str:
    """Return full 13-section structure for initial / default visits."""
    return (
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


def _build_sections_followup(today: str) -> str:
    """Return a compact follow-up visit structure."""
    return (
        f"DATUM NÁVŠTĚVY\n- Datum návštěvy vždy: {today}\n\n"
        "TYP NÁVŠTĚVY: Kontrolní návštěva\n"
        "- Toto je kontrolní návštěva chronického pacienta.\n"
        "- Zaměř se na změny od poslední kontroly, aktuální kompenzaci "
        "a případné nové obtíže.\n"
        "- Vynechej sekce, které nejsou relevantní (netiskni opakovaně "
        '\u201Eneuvedeno\u201C u irelevantních sekcí).\n'
        "- Pokud jde o nekomplikovanou kontrolu bez nálezů, vytvoř stručnou zprávu.\n\n"
        "VÝSTUP \u2013 použij následující strukturu, vynechej prázdné sekce:\n"
        "Kontrolní zpráva\n\n"
        "Identifikace pacienta:\n"
        '- Jméno: (pokud není, \u201Eneuvedeno\u201C)\n'
        "- Věk / r. narození: (neuvedeno)\n"
        f"- Datum kontroly: {today}\n\n"
        "Subjektivní stav pacienta:\n"
        "- Jak se pacient cítí, co udává, jaké má obtíže.\n"
        "- Výslovně popřené obtíže zaznamenej jako negaci.\n\n"
        "Průběh od poslední kontroly:\n"
        "- Vývoj obtíží, změny stavu, nové příznaky.\n"
        "- Změny medikace a důvod (včetně toho, kdo změnu doporučil).\n"
        "- Hmotnostní změny.\n\n"
        "Kompenzace onemocnění:\n"
        "- Stabilita hladin (glykémie, TK, apod.).\n"
        "- Hypoglykémie: četnost, závažnost, denní doba, zda je pacient pozná a zaléčí, "
        "těžké hypoglykémie ano/ne.\n"
        "- Používání technologií (pumpa, senzor, uzavřený okruh) a spokojenost.\n"
        "- Preference pacienta ohledně technologií.\n\n"
        "Režim a adherence:\n"
        "- Dieta, pravidelnost stravy, odhad sacharidů.\n"
        "- Pohyb a cvičení.\n"
        "- Co pacient dodržuje, co odmítá, co nedodal.\n"
        "- Sociální a pracovní zátěž ovlivňující kompenzaci.\n\n"
        "Přidružené obtíže:\n"
        "- Bolesti, neuropatie, závratě, jiné komorbidity.\n"
        "- Probíhající odborná vyšetření.\n"
        '- Pokud žádné: \u201Ebez dalších obtíží\u201C.\n\n'
        "Objektivní nález:\n"
        "- Naměřené hodnoty (TK, P, TT, SpO2, váha, laboratorní výsledky).\n"
        '- Pokud není nic uvedeno: \u201Eneuvedeno\u201C.\n\n'
        "Hodnocení:\n"
        "- Závěr lékaře, pracovní diagnóza.\n"
        '- Pokud nezaznělo: \u201Eneuvedeno\u201C.\n\n'
        "Plán:\n"
        "- Změny léčby, doporučená vyšetření, plán kontrol.\n"
        "- Co pacient zatím nechce.\n"
        "- Co je třeba doložit při další kontrole.\n"
        '- Pokud nezaznělo: \u201Eneuvedeno\u201C.\n\n'
    )


def _build_sections_gastroscopy(today: str) -> str:
    """Return structure for a gastroscopy (gastroskopie) report."""
    return (
        f"DATUM VYŠETŘENÍ\n- Datum vyšetření vždy: {today}\n\n"
        "TYP VYŠETŘENÍ: Gastroskopie (ezofagogastroduodenoskopie)\n\n"
        "VÝSTUP – dodrž přesně strukturu, názvy a pořadí:\n"
        "Gastroskopie\n\n"
        "Indikace:\n"
        "- Důvod vyšetření (anémie, dyspepsie, reflux, screening apod.).\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Odesílající lékař:\n"
        '- Jméno odesílajícího lékaře. Pokud nezaznělo: „neuvedeno".\n\n'
        "Premedikace:\n"
        "- Typ premedikace (např. Lidocain spray 10% lokálně, sedace apod.).\n"
        "- Kdo aplikoval.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Přístroj:\n"
        "- Název a sériové číslo gastroskopického přístroje.\n"
        "- Zdroj (procesor, světelný zdroj), oplachová pumpa, odsávačka, monitor – "
        "včetně výrobních čísel, pokud zazněla.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Asistence:\n"
        '- Jména sester / asistujícího personálu. Pokud nezaznělo: „neuvedeno".\n\n'
        "Čas:\n"
        '- Čas začátku a konce výkonu. Pokud nezaznělo: „neuvedeno".\n\n'
        "Informovaný souhlas:\n"
        "- Zaznamenej, zda pacient/pacientka podepsal/a informovaný souhlas.\n"
        "- Použij správný rod (pacient podepsal / pacientka podepsala).\n"
        "- U hospitalizovaných: kopie ponechána v dokumentaci lůžkového oddělení.\n"
        "- Pacient/ka poučen/a o svých právech, měl/a možnost klást doplňující otázky.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Popis výkonu:\n"
        "- Podrobný popis celého průběhu gastroskopie:\n"
        "  • Poloha pacienta (na levém boku).\n"
        "  • Jícen: stav sliznice, kardie (vzdálenost v cm), těsnost.\n"
        "  • Žaludek: sliznice, řasy, jezírko (čiré/kalné/s obsahem).\n"
        "  • Inverze: kardie a fundus.\n"
        "  • Angulární řasa, antrum.\n"
        "  • Pylorus: průchodnost.\n"
        "  • Bulbus duodena a D2.\n"
        "  • Případné patologie: eroze, vředy, polypy, varixe, Barrett, hiátová hernie.\n"
        "  • Provedené intervence: biopsie (odkud, počet vzorků), polypektomie, "
        "hemostáza, dilatace.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Závěr:\n"
        "- Stručný klinický závěr z gastroskopie.\n"
        "- Diagnóza / makroskopický nález.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Doporučení:\n"
        "- Medikace (inhibitor protonové pumpy – název, dávka, délka podávání).\n"
        "- Informace o histologii (za kolik dní, kam bude odeslána, kontaktní telefon).\n"
        "- Dietní a režimová opatření (nejíst a nepít 1 hodinu od výkonu apod.).\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Stav po výkonu:\n"
        "- Výkon bez komplikací / s komplikacemi (popsat).\n"
        "- Stav pacienta po výkonu (stabilizovaný, KP kompenzovaný).\n"
        "- Kam pacient odchází / je předán.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
    )


def _build_sections_colonoscopy(today: str) -> str:
    """Return structure for a colonoscopy (koloskopie) report."""
    return (
        f"DATUM VYŠETŘENÍ\n- Datum vyšetření vždy: {today}\n\n"
        "TYP VYŠETŘENÍ: Koloskopie\n\n"
        "VÝSTUP – dodrž přesně strukturu, názvy a pořadí:\n"
        "Koloskopie\n\n"
        "Indikace:\n"
        "- Důvod vyšetření (screening, FOBT+, krvácení, sledování polypů, IBD apod.).\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Odesílající lékař:\n"
        '- Jméno odesílajícího lékaře. Pokud nezaznělo: „neuvedeno".\n\n'
        "Premedikace:\n"
        "- Typ premedikace (viz záznam KAR / Propofol / bez sedace apod.).\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Přístroj:\n"
        "- Název a sériové číslo koloskopického přístroje.\n"
        "- Zdroj, odsávačka, oplachová pumpa, monitor – včetně výrobních čísel.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Asistence:\n"
        '- Jména sester / asistujícího personálu. Pokud nezaznělo: „neuvedeno".\n\n'
        "Čas:\n"
        '- Čas začátku a konce výkonu. Pokud nezaznělo: „neuvedeno".\n\n'
        "Informovaný souhlas:\n"
        "- Zaznamenej, zda pacient/pacientka podepsal/a informovaný souhlas.\n"
        "- Použij správný rod (pacient podepsal / pacientka podepsala).\n"
        "- U hospitalizovaných: kopie ponechána v dokumentaci lůžkového oddělení.\n"
        "- Pacient/ka poučen/a o svých právech, měl/a možnost klást doplňující otázky.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Popis výkonu:\n"
        "- Podrobný popis celého průběhu koloskopie:\n"
        "  • Poloha pacienta (na levém boku).\n"
        "  • Zevní nález a per rectum.\n"
        "  • Dosažený rozsah (dno céka, terminální ileum – ano/ne).\n"
        "  • Bauhinská chlopeň – vzhled.\n"
        "  • Terminální ileum – intaktní / patologie.\n"
        "  • Sliznice tlustého střeva v celém rozsahu – vzhled, cévní kresba.\n"
        "  • Patologie: polypy (lokalizace, velikost, počet, morfologie), divertikly, "
        "zánětlivé změny, stenózy, tumory.\n"
        "  • Provedené intervence: biopsie (odkud, počet), polypektomie (metoda, "
        "lokalizace), hemostáza.\n"
        "  • Nález při vysouvání přístroje.\n"
        "  • Hemoroidy (stupeň).\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Závěr:\n"
        "- Stručný klinický závěr z koloskopie.\n"
        "- Totální / parciální koloskopie.\n"
        "- Hlavní diagnózy a nálezy.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Stav po výkonu:\n"
        "- Pacient/ka ve stabilizovaném stavu, předán/a na dospávací pokoj.\n"
        "- Po odeznění premedikace dále dle KAR.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Doporučení:\n"
        "- Režim po výkonu (klid na lůžku, tekutiny, dietní opatření, vláknina).\n"
        "- Kontrola s výsledkem u odesílajícího lékaře.\n"
        "- Histologie – za kolik dní bude hotová, kam bude odeslána, kontaktní telefon.\n"
        "- Kontrolní koloskopie – za kolik let, event. dříve dle histologie.\n"
        "- Případná polypektomie: termín hospitalizace, příprava střeva, "
        "vysazení antikoagulancií / LMWH, kontrolní odběry.\n"
        "- Varovné příznaky: bolesti břicha, zvracení, krvácení z konečníku, "
        "teplota, zimnice → vyhledat lékařskou péči / linka 155.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
    )


def _build_sections_ultrasound(today: str) -> str:
    """Return structure for an abdominal ultrasound (ultrazvuk břicha) report."""
    return (
        f"DATUM VYŠETŘENÍ\n- Datum vyšetření vždy: {today}\n\n"
        "TYP VYŠETŘENÍ: Ultrazvuk břicha\n\n"
        "VÝSTUP – dodrž přesně strukturu, názvy a pořadí:\n"
        "Ultrazvuk břicha\n\n"
        "Indikace:\n"
        "- Důvod vyšetření.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Odesílající lékař:\n"
        '- Jméno odesílajícího lékaře. Pokud nezaznělo: „neuvedeno".\n\n'
        "Přístroj:\n"
        "- Název a sériové číslo UZ přístroje a použitých sond.\n"
        "- FibroScan (pokud byl proveden) – typ a sériové číslo.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
        "Popis nálezu:\n"
        "- Podrobný popis jednotlivých orgánů:\n\n"
        "  Játra:\n"
        "  - Velikost (zvětšena / nezvětšena).\n"
        "  - Parenchym (homogenní / nehomogenní, echogenita).\n"
        "  - Cévy (pravidelné / nepravidelné).\n"
        "  - Povrch (hladký / nerovný).\n"
        "  - Ložiskové změny (popis / nejsou patrné).\n"
        "  - V. portae: dilatace, směr toku, rychlost (cm/s).\n\n"
        "  Žlučník:\n"
        "  - Stěna (zesílená / normální).\n"
        "  - Obsah (anechogenní / konkrementy / sludge).\n\n"
        "  Žlučové cesty:\n"
        "  - Hepatocholedochus (šíře v mm, dilatace ano/ne).\n"
        "  - Intrahepatální žlučovody (dilatace ano/ne).\n\n"
        "  Slinivka:\n"
        "  - Velikost, homogenita, ohraničení.\n\n"
        "  Ledviny:\n"
        "  - Velikost, funkční parenchym, echogenita.\n"
        "  - Dutý systém (městnání ano/ne).\n"
        "  - Případné konkrementy, cysty.\n\n"
        "  Slezina:\n"
        "  - Velikost, homogenita.\n\n"
        "  Volná tekutina:\n"
        "  - Přítomnost volné tekutiny v dutině břišní.\n\n"
        "  Malá pánev:\n"
        "  - Orientační nález.\n\n"
        "  Močový měchýř:\n"
        "  - Naplnění, stěna.\n\n"
        "- U každého orgánu zaznamenej přesně, co zaznělo v přepisu.\n"
        '- Pokud orgán nebyl zmíněn: „nevyšetřeno" nebo vynechej.\n\n'
        "Elastografie / FibroScan (pokud provedeno):\n"
        "- ARFI jater: medián z měření (m/s).\n"
        "- FibroScan: medián (kPa), IQR/med (%), stupeň fibrózy (F0–F4).\n"
        "- CAP: hodnota (dB/m), SD, stupeň steatózy (S0–S3).\n"
        '- Pokud neprovedeno: vynechej celou sekci.\n\n'
        "Závěr:\n"
        "- Stručný klinický závěr z UZ vyšetření.\n"
        "- Hlavní diagnózy (steatóza, steatofibróza, normální nález apod.).\n"
        "- Stupeň fibrózy a steatózy dle elastografie (pokud provedena).\n"
        "- Případné omezení vyšetřitelnosti.\n"
        '- Pokud nezaznělo: „neuvedeno".\n\n'
    )


def _build_system_prompt(today: str, visit_type: str = "default") -> str:
    """Build the Czech medical report system prompt.

    Args:
        today: Formatted date string for the report.
        visit_type: One of "default", "initial", "followup",
                    "gastroscopy", "colonoscopy", "ultrasound".
    """
    if visit_type in ("gastroscopy", "colonoscopy", "ultrasound"):
        intro = (
            "Jsi asistent pro tvorbu lékařské dokumentace. Z poskytnutého přepisu "
            "vyšetření vytvoř formální zprávu z vyšetření v češtině.\n\n"
        )
    else:
        intro = (
            "Jsi asistent pro tvorbu lékařské dokumentace. Z poskytnutého přepisu "
            "návštěvy vytvoř formální lékařskou zprávu v češtině.\n\n"
        )
    rules = _build_base_rules()

    if visit_type == "followup":
        sections = _build_sections_followup(today)
    elif visit_type == "initial":
        sections = _build_sections_initial(today)
    elif visit_type == "gastroscopy":
        sections = _build_sections_gastroscopy(today)
    elif visit_type == "colonoscopy":
        sections = _build_sections_colonoscopy(today)
    elif visit_type == "ultrasound":
        sections = _build_sections_ultrasound(today)
    else:
        # "default" — model decides; include both templates as guidance
        sections = (
            "AUTOMATICKÁ DETEKCE TYPU NÁVŠTĚVY\n"
            "- Urči z přepisu, zda jde o vstupní vyšetření nebo kontrolní návštěvu "
            "chronického pacienta.\n"
            "- Vstupní vyšetření: obsáhlý odběr anamnézy, první kontakt.\n"
            "- Kontrolní návštěva: pacient přichází opakovaně, řeší se kompenzace, "
            "změny léčby, průběh od minula.\n"
            "- Pokud nelze určit, použij strukturu vstupního vyšetření.\n\n"
            + _build_sections_initial(today)
        )

    footer = (
        "JAZYK\n"
        "- Celý výstup musí být v češtině. Nepřidávej žádné komentáře mimo strukturu."
    )

    return intro + rules + "\n" + sections + footer


def verify_token(authorization: str = Header(...)) -> None:
    """Verify the Bearer token in the Authorization header."""
    if authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid token")


class ReportRequest(BaseModel):
    """Request body for the /report endpoint."""

    transcript: str
    language: str = "cs"
    visit_type: str = "default"


class SendReportEmailRequest(BaseModel):
    """Request body for the /send-report-email endpoint."""

    report: str
    email: str
    visit_type: str = "default"


def _send_email(to: str, subject: str, body: str) -> None:
    """Send a plain-text email via SMTP."""
    if not SMTP_HOST:
        raise RuntimeError("Email not configured on server")

    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM_EMAIL
    msg["To"] = to

    if SMTP_USE_TLS:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as server:
            server.starttls()
            if SMTP_USER:
                server.login(SMTP_USER, SMTP_PASSWORD)
            server.send_message(msg)
    else:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as server:
            if SMTP_USER:
                server.login(SMTP_USER, SMTP_PASSWORD)
            server.send_message(msg)


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
    system_prompt = _build_system_prompt(today, "default")

    if MOCK_MODE:
        report = f"[MOCK — scenario: {scenario_name}]\n\n{transcript[:200]}..."
        return {"scenario": scenario_name, "transcript": transcript, "report": report}

    messages = [
        {"role": "system", "content": system_prompt},
        {
            "role": "user",
            "content": (
                "Převeď tento přepis do strukturované lékařské zprávy"
                f" v češtině:\n\n{transcript}"
            ),
        },
    ]

    for model in (CHAT_MODEL, FALLBACK_MODEL):
        try:
            response = client.chat.completions.create(
                model=model,
                messages=messages,
                max_completion_tokens=4096,
                timeout=60.0,
            )
            report = response.choices[0].message.content or ""
            logger.info("Test-report completed for scenario: %s (model=%s)", scenario_name, model)
            return {"scenario": scenario_name, "transcript": transcript, "report": report}
        except Exception as e:
            logger.warning("Model %s failed for test-report: %s", model, e)
            if model == FALLBACK_MODEL:
                raise HTTPException(
                    status_code=502, detail=f"OpenAI error: {str(e)}"
                ) from e



@app.post("/send-report-email")
async def send_report_email(
    data: SendReportEmailRequest, _: None = Depends(verify_token)
) -> dict:
    """Send a generated medical report to the specified email address."""
    report = data.report.strip()
    if not report:
        raise HTTPException(status_code=400, detail="Empty report")

    email = data.email.strip()
    if not email or not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email):
        raise HTTPException(status_code=400, detail="Invalid email address")

    today: str = date.today().strftime("%d. %m. %Y")
    visit_type = data.visit_type if data.visit_type in VALID_VISIT_TYPES else "default"
    vt_label = VISIT_TYPE_LABELS.get(visit_type, visit_type)

    subject = f"ANOTE \u2013 L\u00e9ka\u0159sk\u00e1 zpr\u00e1va \u2013 {today}"
    body = (
        "L\u00e9ka\u0159sk\u00e1 zpr\u00e1va vygenerovan\u00e1 aplikac\u00ed ANOTE\n"
        f"Datum: {today}\n"
        f"Typ n\u00e1v\u0161t\u011bvy: {vt_label}\n"
        "\n---\n\n"
        f"{report}\n"
        "\n---\n"
        "Tato zpr\u00e1va byla automaticky odesl\u00e1na aplikac\u00ed ANOTE.\n"
    )

    try:
        _send_email(email, subject, body)
        logger.info("Report email sent to %s (visit_type=%s)", email, visit_type)
        return {"status": "sent"}
    except Exception as e:
        logger.error("Email delivery failed: %s", e)
        raise HTTPException(
            status_code=502, detail=f"Email delivery failed: {str(e)}"
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
    visit_type = data.visit_type if data.visit_type in VALID_VISIT_TYPES else "default"

    # NOTE: transcript and report content are deliberately NOT logged (GDPR).
    logger.info("Report generation request received (visit_type=%s)", visit_type)

    system_prompt = _build_system_prompt(today, visit_type)

    if MOCK_MODE:
        logger.info("Returning mock report (MOCK_MODE=true)")
        mock_report = (
            "Lékařská zpráva\n\n"
            f"Identifikace pacienta:\n- Jméno: Testovací Pacient\n- Věk / r. narození: 45 let\n"
            f"- Datum návštěvy: {today}\n\n"
            "NO (Nynější onemocnění):\n[MOCK] Bolest hlavy trvající 3 dny. "
            "Pulzující bolest, VAS 6/10. "
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

    messages = [
        {"role": "system", "content": system_prompt},
        {
            "role": "user",
            "content": (
                "Převeď tento přepis do strukturované lékařské zprávy"
                f" v češtině:\n\n{transcript}"
            ),
        },
    ]

    for model in (CHAT_MODEL, FALLBACK_MODEL):
        try:
            response = client.chat.completions.create(
                model=model,
                messages=messages,
                max_completion_tokens=4096,
                timeout=60.0,
            )
            report = response.choices[0].message.content or ""
            logger.info("Report generation completed successfully (model=%s)", model)
            return {"report": report}
        except Exception as e:
            logger.warning("Model %s failed for report: %s", model, e)
            if model == FALLBACK_MODEL:
                raise HTTPException(
                    status_code=502, detail=f"OpenAI error: {str(e)}"
                ) from e
