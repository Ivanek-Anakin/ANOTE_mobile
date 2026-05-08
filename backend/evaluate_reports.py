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

API_KEY = os.environ["AZURE_OPENAI_KEY"]

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
    # ── TASK-0036 v5 candidates (defect-targeted) ────────────────────────
    "v5a_negative": {
        "name": "v5a — negative prohibitions",
        "description": (
            "TASK-0036: 5 defect rules expressed as hard prohibitions "
            "(Do NOT / Never insert)."
        ),
        "suffix": (
            "\n\nTASK-0036 OPRAVY (PRIORITNÍ — PŘEPISUJÍ PŘEDCHOZÍ ZÁSADY)\n"
            "- NIKDY nepiš do žádné sekce neklinický, sociální nebo narativní "
            "obsah (písničky, říkanky, banter, počasí, zmínky o divadle, "
            "vyprávění, obecná konverzace). Vyřaď je úplně.\n"
            "- NIKDY neumísťuj subjektivní výpovědi pacienta (\u201Eudává\u201C, "
            "\u201Ecítí\u201C, \u201Eříká\u201C) do sekce \u201EObjektivní nález\u201C. "
            "NIKDY neumísťuj naměřené hodnoty (TK, P, SpO2, TT, fyzikální nález, "
            "poslechový/palpační nález) do NO ani jiné anamnestické sekce — "
            "vždy je dej výhradně do \u201EObjektivní nález\u201C, i když lékař "
            "měření vyslovil v dialogu uvnitř pacientova vyprávění.\n"
            "- NIKDY neodvozuj klinický obsah z nejednoznačných nebo "
            "podivně znějících tokenů v přepisu (možné chyby ASR, neznámé výrazy, "
            "značkové názvy). NEINTERPRETUJ je jako diagnózy, alergeny ani "
            "prostředí; raději je vynechej nebo cituj doslova s poznámkou "
            "\u201Enejasné, k upřesnění\u201C. NIKDY nedoplňuj alergii, diagnózu "
            "ani kontext, který v přepisu výslovně nezazněl.\n"
            "- NIKDY nevkládej frázi \u201Espolupráce dobrá\u201C, \u201Erežim "
            "dodržuje\u201C, \u201Ebere léky pravidelně\u201C ani jinou boilerplate "
            "o adherenci, pokud o adherenci v přepisu pacient ani lékař "
            "neřekli ani slovo. Pokud se téma neobjevilo, sekce \u201EAdherence "
            "a spolupráce pacienta\u201C MUSÍ obsahovat pouze \u201Eneuvedeno\u201C.\n"
            "- NIKDY neparafrázuj dávkování. Zachovej řetězce dávek doslova "
            "tak, jak zazněly (\u201E1 tbl.\u201C, \u201E2× denně\u201C, \u201E1-0-0\u201C, "
            "\u201E100 mg\u201C, \u201Eráno\u201C, \u201Evečer\u201C). NIKDY je nepřepisuj "
            "na obecnou prózu (\u201Eužívá pravidelně\u201C, \u201Edle doporučení\u201C, "
            "\u201Epředepsanou medikaci\u201C). NIKDY nepřevádějte jednotky."
        ),
    },
    "v5b_positive": {
        "name": "v5b — positive conditional",
        "description": (
            "TASK-0036: 5 defect rules expressed as positive instructions "
            "with explicit conditions."
        ),
        "suffix": (
            "\n\nTASK-0036 ZPŘESNĚNÍ (PRIORITNÍ — PŘEPISUJÍ PŘEDCHOZÍ ZÁSADY)\n"
            "- Do zprávy zařaď pouze klinicky relevantní obsah. Sociální, "
            "narativní a neklinický materiál (písně, říkanky, banter, vyprávění, "
            "konverzaci o počasí či divadle) z přepisu vynech.\n"
            "- Subjektivní výpovědi (co pacient udává, cítí, popisuje) patří "
            "do NO/anamnestických sekcí. Naměřené nebo vyšetřením zjištěné "
            "hodnoty (TK, P, SpO2, TT, fyzikální/poslechový/palpační nález) "
            "patří výhradně do \u201EObjektivní nález\u201C — i když je lékař "
            "vyslovil v dialogu uprostřed pacientova vyprávění; přesuň je "
            "do správné sekce.\n"
            "- Klinický obsah uveď pouze tehdy, když je v přepisu výslovně "
            "podložen. U nejednoznačných tokenů (možné ASR chyby, neznámé výrazy, "
            "značkové názvy) raději obsah vynech nebo přepiš doslova s poznámkou "
            "\u201Enejasné, k upřesnění\u201C. Alergie, diagnózy a kontextové údaje "
            "uváděj jen tehdy, pokud byly v přepisu skutečně řečeny.\n"
            "- Sekci \u201EAdherence a spolupráce pacienta\u201C vyplň pouze tehdy, "
            "pokud v přepisu zaznělo konkrétní téma adherence (užívání léků, "
            "dodržování režimu, kontroly, doporučení). Pokud o adherenci nikdo "
            "nemluvil, napiš výhradně \u201Eneuvedeno\u201C — frázi \u201Espolupráce "
            "dobrá\u201C použij jen tehdy, když pacient výslovně potvrdil, "
            "že režim/léky dodržuje.\n"
            "- Dávkovací řetězce zachovávej v přesné podobě, jak je lékař či "
            "pacient vyslovil (\u201E1 tbl.\u201C, \u201E1-0-0\u201C, \u201E100 mg\u201C, "
            "\u201E2× denně\u201C, \u201Eráno\u201C). Neparafrázuj je do prózy a "
            "neměň jednotky; pokud chybí, napiš \u201Eneuvedeno\u201C."
        ),
    },
    "v5c_fewshot": {
        "name": "v5c — micro-examples",
        "description": (
            "TASK-0036: minimal prose + 1–2 illustrative CZ transcript→report "
            "micro-examples per defect."
        ),
        "suffix": (
            "\n\nTASK-0036 PŘÍKLADY (ILUSTRATIVNÍ — NE REÁLNÝ KLINICKÝ OBSAH)\n"
            "Následující mini-příklady ukazují požadované chování. Aplikuj "
            "stejný princip, ne doslovný text.\n"
            "\n"
            "Příklad A — neklinický obsah a měření v dialogu:\n"
            "Přepis: \u201E…la la la, paní učitelka říkala. TK 145/90, puls 78. "
            "A pak jsme šli do divadla.\u201C\n"
            "Zpráva — NO: (žádná zmínka o písničce, učitelce, divadle.)\n"
            "Zpráva — Objektivní nález: TK 145/90 mmHg, P 78/min.\n"
            "\n"
            "Příklad B — nejednoznačný token v alergii:\n"
            "Přepis: \u201ELékař: A nějaké alergie? Pacient: na jaro mi červenají ruce.\u201C\n"
            "Zpráva — AA: \u201Epacient uvádí ‚na jaro červenají ruce‘ — "
            "nejasné, k upřesnění\u201C. (NIKDY \u201Epylová alergie\u201C ani "
            "\u201Esezónní alergie\u201C bez explicitní zmínky pylu.)\n"
            "\n"
            "Příklad C — adherence nediskutována:\n"
            "Přepis: (žádná zmínka o režimu, lécích nebo kontrolách.)\n"
            "Zpráva — Adherence a spolupráce pacienta: \u201Eneuvedeno\u201C. "
            "(NIKDY \u201Espolupráce dobrá\u201C jako default.)\n"
            "\n"
            "Příklad D — terse dávkování:\n"
            "Přepis: \u201EFurosemid 1 tbl. ráno, Anopyrin 100 mg 1-0-0.\u201C\n"
            "Zpráva — FA: \u201EFurosemid 1 tbl. ráno; Anopyrin 100 mg 1-0-0.\u201C "
            "(NIKDY \u201Eužívá pravidelně předepsanou medikaci\u201C.)\n"
            "\n"
            "Příklad E — subjektivní vs objektivní:\n"
            "Přepis: \u201EPacient: cítím se unavený. Lékař: poslechově dýchání "
            "sklípkové.\u201C\n"
            "Zpráva — NO: \u201Eudává únavu\u201C. Objektivní nález: \u201Edýchání "
            "sklípkové\u201C. (NIKDY naopak.)"
        ),
    },
    # ── v5d: v5c with one example replaced for adherence-absent realism ──
    "v5d_adherence_example": {
        "name": "v5d — v5c + adherence-absent realistic example",
        "description": (
            "TASK-0036: v5c few-shot block, with Example C replaced by a "
            "substantive transcript that contains zero adherence/cooperation "
            "discussion and whose target report writes 'Adherence a spolupráce: "
            "neuvedeno'. Tests whether a richer realistic anti-boilerplate "
            "example fixes the adherence regression."
        ),
        "suffix": (
            "\n\nTASK-0036 PŘÍKLADY (ILUSTRATIVNÍ — NE REÁLNÝ KLINICKÝ OBSAH)\n"
            "Následující mini-příklady ukazují požadované chování. Aplikuj "
            "stejný princip, ne doslovný text.\n"
            "\n"
            "Příklad A — neklinický obsah a měření v dialogu:\n"
            "Přepis: \u201E…la la la, paní učitelka říkala. TK 145/90, puls 78. "
            "A pak jsme šli do divadla.\u201C\n"
            "Zpráva — NO: (žádná zmínka o písničce, učitelce, divadle.)\n"
            "Zpráva — Objektivní nález: TK 145/90 mmHg, P 78/min.\n"
            "\n"
            "Příklad B — nejednoznačný token v alergii:\n"
            "Přepis: \u201ELékař: A nějaké alergie? Pacient: na jaro mi červenají ruce.\u201C\n"
            "Zpráva — AA: \u201Epacient uvádí ‚na jaro červenají ruce‘ — "
            "nejasné, k upřesnění\u201C. (NIKDY \u201Epylová alergie\u201C ani "
            "\u201Esezónní alergie\u201C bez explicitní zmínky pylu.)\n"
            "\n"
            "Příklad C — adherence nediskutována (realistický plný dialog):\n"
            "Přepis: \u201EPacient: bolí mě v krku už čtvrtý den, polykání "
            "nepříjemné, teplotu jsem si neměřil. Lékař: kašel? Pacient: jen "
            "občas, suchý. Lékař: ukažte krk… mandle zarudlé, povlak nevidím. "
            "Lékař: indikuji výtěr a symptomatickou léčbu, kontrola dle "
            "potřeby.\u201C\n"
            "Zpráva — NO: \u201Ebolesti v krku 4 dny, polykání bolestivé, "
            "občasný suchý kašel; teplotu si neměřil\u201C.\n"
            "Zpráva — Objektivní nález: \u201Emandle zarudlé bez povlaku\u201C.\n"
            "Zpráva — Adherence a spolupráce pacienta: \u201Eneuvedeno\u201C. "
            "(Téma adherence, užívání léků ani dodržování režimu v přepisu "
            "vůbec nezaznělo — proto NIKDY \u201Espolupráce dobrá\u201C, "
            "\u201Erežim dodržuje\u201C ani jiná boilerplate. Plný klinický "
            "obsah ve zprávě bude — jen sekce Adherence zůstává \u201Eneuvedeno\u201C.)\n"
            "\n"
            "Příklad D — terse dávkování:\n"
            "Přepis: \u201EFurosemid 1 tbl. ráno, Anopyrin 100 mg 1-0-0.\u201C\n"
            "Zpráva — FA: \u201EFurosemid 1 tbl. ráno; Anopyrin 100 mg 1-0-0.\u201C "
            "(NIKDY \u201Eužívá pravidelně předepsanou medikaci\u201C.)\n"
            "\n"
            "Příklad E — subjektivní vs objektivní:\n"
            "Přepis: \u201EPacient: cítím se unavený. Lékař: poslechově dýchání "
            "sklípkové.\u201C\n"
            "Zpráva — NO: \u201Eudává únavu\u201C. Objektivní nález: \u201Edýchání "
            "sklípkové\u201C. (NIKDY naopak.)"
        ),
    },
    # ── v5e: v5c with one explicit anti-boilerplate adherence rule ──────
    "v5e_explicit_rule": {
        "name": "v5e — v5c + explicit adherence rule",
        "description": (
            "TASK-0036: v5c few-shot block unchanged, plus one additional "
            "explicit rule near the adherence example forbidding the "
            "'spolupráce dobrá' default. Tests whether a single explicit "
            "imperative is sufficient to fix the adherence regression."
        ),
        "suffix": (
            "\n\nTASK-0036 PŘÍKLADY (ILUSTRATIVNÍ — NE REÁLNÝ KLINICKÝ OBSAH)\n"
            "Následující mini-příklady ukazují požadované chování. Aplikuj "
            "stejný princip, ne doslovný text.\n"
            "\n"
            "Příklad A — neklinický obsah a měření v dialogu:\n"
            "Přepis: \u201E…la la la, paní učitelka říkala. TK 145/90, puls 78. "
            "A pak jsme šli do divadla.\u201C\n"
            "Zpráva — NO: (žádná zmínka o písničce, učitelce, divadle.)\n"
            "Zpráva — Objektivní nález: TK 145/90 mmHg, P 78/min.\n"
            "\n"
            "Příklad B — nejednoznačný token v alergii:\n"
            "Přepis: \u201ELékař: A nějaké alergie? Pacient: na jaro mi červenají ruce.\u201C\n"
            "Zpráva — AA: \u201Epacient uvádí ‚na jaro červenají ruce‘ — "
            "nejasné, k upřesnění\u201C. (NIKDY \u201Epylová alergie\u201C ani "
            "\u201Esezónní alergie\u201C bez explicitní zmínky pylu.)\n"
            "\n"
            "Příklad C — adherence nediskutována:\n"
            "Přepis: (žádná zmínka o režimu, lécích nebo kontrolách.)\n"
            "Zpráva — Adherence a spolupráce pacienta: \u201Eneuvedeno\u201C. "
            "(NIKDY \u201Espolupráce dobrá\u201C jako default.)\n"
            "\n"
            "Příklad D — terse dávkování:\n"
            "Přepis: \u201EFurosemid 1 tbl. ráno, Anopyrin 100 mg 1-0-0.\u201C\n"
            "Zpráva — FA: \u201EFurosemid 1 tbl. ráno; Anopyrin 100 mg 1-0-0.\u201C "
            "(NIKDY \u201Eužívá pravidelně předepsanou medikaci\u201C.)\n"
            "\n"
            "Příklad E — subjektivní vs objektivní:\n"
            "Přepis: \u201EPacient: cítím se unavený. Lékař: poslechově dýchání "
            "sklípkové.\u201C\n"
            "Zpráva — NO: \u201Eudává únavu\u201C. Objektivní nález: \u201Edýchání "
            "sklípkové\u201C. (NIKDY naopak.)\n"
            "\n"
            "DODATEČNÉ EXPLICITNÍ PRAVIDLO PRO ADHERENCI (PŘEPISUJE PŘEDCHOZÍ "
            "DOPORUČENÍ V SEKCI ADHERENCE):\n"
            "Pokud přepis NEOBSAHUJE výslovnou diskusi o užívání léků, "
            "dodržování režimu, kontrolách nebo pacientových odmítnutích, "
            "zapiš do sekce \u201EAdherence a spolupráce pacienta\u201C VÝHRADNĚ "
            "\u201Eneuvedeno\u201C. NIKDY se neuchyluj k defaultní frázi "
            "\u201Espolupráce dobrá\u201C, \u201Erežim dodržuje\u201C, "
            "\u201Epacient rozumí doporučením\u201C ani podobné — i když je "
            "klinický obraz jinak v pořádku, nepřítomnost diskuse = "
            "\u201Eneuvedeno\u201C, ne \u201Espolupráce dobrá\u201C."
        ),
    },
    # ── v5g: abstract principles, no concrete clinical values ──────────
    "v5g_principles": {
        "name": "v5g — abstraktní principy bez konkrétních hodnot",
        "description": (
            "TASK-0036: pět zobecněných principů (off-topic, subjektivní vs "
            "objektivní, fabrikace/inference, default-fráze v adherenci, věrnost "
            "krátkých klinických tokenů). Každý princip je doplněn jedním "
            "abstraktním protipříkladem (co NEdělat) bez konkrétních klinických "
            "hodnot, léků, nemocí ani frází, které by zrcadlily evaluační rubriku. "
            "Cílem je naučit chování, ne nakopírovat vzor."
        ),
        "suffix": (
            "\n\nTASK-0036 OBECNÉ PRINCIPY (BEZ KONKRÉTNÍCH KLINICKÝCH HODNOT)\n"
            "Při generování zprávy uplatni následující obecné principy. Příklady "
            "jsou záměrně abstraktní — neopisuj jejich text, pochop princip a "
            "aplikuj jej na vlastní vstup.\n"
            "\n"
            "Princip 1 — Filtrování neklinického obsahu:\n"
            "Do zprávy patří pouze klinicky relevantní informace získané z "
            "rozhovoru. Vše ostatní (sociální vsuvky, vyrušení, obsah cizích "
            "mluvčích v pozadí, opakovaná slova způsobená rozpoznáváním řeči) "
            "ignoruj. Klinickou relevanci posuzuj podle vztahu k symptomům, "
            "vyšetření, diagnóze, léčbě nebo plánu.\n"
            "Protipříklad (NEdělat): zařadit do anamnézy popis činnosti, kterou "
            "pacient zmínil mimoděk a která nemá vztah k jeho potížím, jen "
            "proto, že v přepisu zazněla.\n"
            "\n"
            "Princip 2 — Přiřazení nálezů ke správným sekcím:\n"
            "Co pacient sám vypovídá o svých prožitcích, intenzitě, trvání a "
            "vlastních pozorováních, patří do subjektivní části (anamnéza / "
            "nynější onemocnění). Co lékař objektivně změří, vyšetří nebo "
            "zaznamená přístrojem, patří výhradně do sekce objektivního nálezu. "
            "Tyto kategorie nikdy nemíchej v jedné větě a neumísťuj je do "
            "opačné sekce.\n"
            "Protipříklad (NEdělat): umístit naměřenou hodnotu z fyzikálního "
            "vyšetření do anamnézy proto, že v dialogu zazněla mezi pacientovými "
            "větami.\n"
            "\n"
            "Princip 3 — Žádná inference nad rámec přepisu:\n"
            "Do zprávy zapiš pouze to, co lze přímo doložit z přepisu. "
            "Nedoplňuj diagnózy, etiologie, alergeny, kauzální vysvětlení ani "
            "kategorie, které sám pacient ani lékař neformulovali. Pokud je "
            "vyjádření pacienta nejednoznačné, ponech ho v původní podobě a "
            "označ jako k upřesnění; nepřevádí ho na klinickou kategorii.\n"
            "Protipříklad (NEdělat): převést pacientův popis spouštěče potíží "
            "na konkrétní diagnostickou kategorii, kterou pacient nezmínil, jen "
            "proto, že obecně bývá s podobnými symptomy spojována.\n"
            "\n"
            "Princip 4 — Sekce zaznamenává pouze to, co bylo skutečně probíráno:\n"
            "Každá sekce zprávy reflektuje pouze obsah, který byl v rozhovoru "
            "skutečně diskutován. Pokud určité téma (např. užívání léků, "
            "dodržování režimu, kontroly) v přepisu vůbec nezaznělo, sekce má "
            "obsahovat výslovný marker nepřítomnosti diskuse, nikoli šablonové "
            "pozitivní nebo negativní hodnocení. Negativní explicitní vyjádření "
            "pacienta (něco neguje) zapiš jako negaci; absenci tématu zapiš "
            "jako nepřítomnost informace — tyto dvě situace nikdy nezaměňuj.\n"
            "Protipříklad (NEdělat): vyplnit sekci shrnujícím pozitivním "
            "klišé jen proto, že o daném tématu padla nulová zmínka a sekce by "
            "jinak zůstala prázdná.\n"
            "\n"
            "Princip 5 — Věrnost krátkých klinických tokenů:\n"
            "Přesné zápisy dávkování, frekvence, schémat a dalších kompaktních "
            "klinických údajů přenes ze zdroje doslovně, včetně použité "
            "interpunkce, zkratek a jednotek. Nepřevádí je do prózy, "
            "nepřevádí jednotky, neslučuj více preparátů do souhrnných formulací "
            "a nedoplňuj o údaje, které v přepisu nezazněly.\n"
            "Protipříklad (NEdělat): nahradit přesný originální zápis schématu "
            "obecnou formulací o pravidelném užívání medikace, čímž se ztratí "
            "konkrétní rozpis dávek."
        ),
    },
    # ── v5h: v5g + 3 procedural rules (no concrete tells) ──────────────
    "v5h_procedural": {
        "name": "v5h — v5g + procedurální pravidla",
        "description": (
            "TASK-0036: stejné jako v5g_principles, navíc tři procedurální "
            "pravidla (sociální kontext jako expozice, numerické hodnoty s "
            "jednotkou výhradně do objektivního nálezu, povinné ověření "
            "citace před zápisem do sekce adherence). Cílem je zlepšit "
            "off-topic filtraci, placement numerik a default-fráze v "
            "adherenci bez zrcadlení testů a soudce."
        ),
        "suffix": (
            "\n\nTASK-0036 OBECNÉ PRINCIPY (BEZ KONKRÉTNÍCH KLINICKÝCH HODNOT)\n"
            "Při generování zprávy uplatni následující obecné principy. Příklady "
            "jsou záměrně abstraktní — neopisuj jejich text, pochop princip a "
            "aplikuj jej na vlastní vstup.\n"
            "\n"
            "Princip 1 — Filtrování neklinického obsahu:\n"
            "Do zprávy patří pouze klinicky relevantní informace získané z "
            "rozhovoru. Vše ostatní (sociální vsuvky, vyrušení, obsah cizích "
            "mluvčích v pozadí, opakovaná slova způsobená rozpoznáváním řeči) "
            "ignoruj. Klinickou relevanci posuzuj podle vztahu k symptomům, "
            "vyšetření, diagnóze, léčbě nebo plánu.\n"
            "Protipříklad (NEdělat): zařadit do anamnézy popis činnosti, kterou "
            "pacient zmínil mimoděk a která nemá vztah k jeho potížím, jen "
            "proto, že v přepisu zazněla.\n"
            "\n"
            "Princip 2 — Přiřazení nálezů ke správným sekcím:\n"
            "Co pacient sám vypovídá o svých prožitcích, intenzitě, trvání a "
            "vlastních pozorováních, patří do subjektivní části (anamnéza / "
            "nynější onemocnění). Co lékař objektivně změří, vyšetří nebo "
            "zaznamená přístrojem, patří výhradně do sekce objektivního nálezu. "
            "Tyto kategorie nikdy nemíchej v jedné větě a neumísťuj je do "
            "opačné sekce.\n"
            "Protipříklad (NEdělat): umístit naměřenou hodnotu z fyzikálního "
            "vyšetření do anamnézy proto, že v dialogu zazněla mezi pacientovými "
            "větami.\n"
            "\n"
            "Princip 3 — Žádná inference nad rámec přepisu:\n"
            "Do zprávy zapiš pouze to, co lze přímo doložit z přepisu. "
            "Nedoplňuj diagnózy, etiologie, alergeny, kauzální vysvětlení ani "
            "kategorie, které sám pacient ani lékař neformulovali. Pokud je "
            "vyjádření pacienta nejednoznačné, ponech ho v původní podobě a "
            "označ jako k upřesnění; nepřevádí ho na klinickou kategorii.\n"
            "Protipříklad (NEdělat): převést pacientův popis spouštěče potíží "
            "na konkrétní diagnostickou kategorii, kterou pacient nezmínil, jen "
            "proto, že obecně bývá s podobnými symptomy spojována.\n"
            "\n"
            "Princip 4 — Sekce zaznamenává pouze to, co bylo skutečně probíráno:\n"
            "Každá sekce zprávy reflektuje pouze obsah, který byl v rozhovoru "
            "skutečně diskutován. Pokud určité téma (např. užívání léků, "
            "dodržování režimu, kontroly) v přepisu vůbec nezaznělo, sekce má "
            "obsahovat výslovný marker nepřítomnosti diskuse, nikoli šablonové "
            "pozitivní nebo negativní hodnocení. Negativní explicitní vyjádření "
            "pacienta (něco neguje) zapiš jako negaci; absenci tématu zapiš "
            "jako nepřítomnost informace — tyto dvě situace nikdy nezaměňuj.\n"
            "Protipříklad (NEdělat): vyplnit sekci shrnujícím pozitivním "
            "klišé jen proto, že o daném tématu padla nulová zmínka a sekce by "
            "jinak zůstala prázdná.\n"
            "\n"
            "Princip 5 — Věrnost krátkých klinických tokenů:\n"
            "Přesné zápisy dávkování, frekvence, schémat a dalších kompaktních "
            "klinických údajů přenes ze zdroje doslovně, včetně použité "
            "interpunkce, zkratek a jednotek. Nepřevádí je do prózy, "
            "nepřevádí jednotky, neslučuj více preparátů do souhrnných formulací "
            "a nedoplňuj o údaje, které v přepisu nezazněly.\n"
            "Protipříklad (NEdělat): nahradit přesný originální zápis schématu "
            "obecnou formulací o pravidelném užívání medikace, čímž se ztratí "
            "konkrétní rozpis dávek.\n"
            "\n"
            "PROCEDURÁLNÍ PRAVIDLA (aplikuj při zápisu každé sekce):\n"
            "\n"
            "Pravidlo P1 — Sociální kontext vs. expozice:\n"
            "Místa, volnočasové aktivity ani sociální události do zprávy nepatří, "
            "pokud nejsou přímou expozicí (alergen, trauma, infekce, pracovní "
            "rizikový faktor). Z popisu takové aktivity přenes pouze symptom, "
            "ne situaci.\n"
            "\n"
            "Pravidlo P2 — Numerická hodnota s jednotkou:\n"
            "Každá numerická hodnota s jednotkou patří výhradně do sekce "
            "objektivního nálezu. V subjektivních sekcích takovou hodnotu "
            "neuváděj ani v závorce, ani jako vysvětlivku k negaci; pokud "
            "potřebuješ totéž zmínit v anamnéze, použij kvalitativní formulaci "
            "bez čísla a jednotky. Numerická hodnota se v celé zprávě smí "
            "objevit pouze jednou, a to v sekci objektivního nálezu — v žádné "
            "jiné sekci ji neopakuj, ani jako kontext, ani v závorce.\n"
            "\n"
            "Pravidlo P3 — Ověření citace před zápisem do adherence/spolupráce:\n"
            "Před zápisem do sekce adherence/spolupráce najdi v přepisu "
            "konkrétní výrok, který ji opírá. Pokud takový výrok neexistuje, "
            "hodnota sekce je marker nepřítomnosti tématu — nepřidávej "
            "shrnutí, hodnocení ani předpoklad."
        ),
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

# ── TASK-0036 weighted rubric ────────────────────────────────────────────────

TASK0036_FACTORS = [
    # (key, weight)
    ("clinical_relevance", 3),
    ("section_placement", 2),
    ("no_fabrication", 3),
    ("adherence_appropriateness", 1),
    ("dosage_fidelity", 2),
    ("completeness", 1),
    ("no_critical_omission", 2),
    ("czech_medical_style", 1),
    # Extended orthogonal factors (added 2026-05-03 to reduce overfit signal)
    ("temporal_anchor_fidelity", 1),
    ("negation_explicitness", 1),
    ("speaker_attribution", 1),
]
TASK0036_TOTAL_WEIGHT = sum(w for _, w in TASK0036_FACTORS)  # 18

JUDGE_TASK0036_SYSTEM_PROMPT = """\
You are a strict medical-documentation auditor reviewing a Czech medical report
generated from a Czech doctor-patient transcript. The transcript may contain ASR
errors, irrelevant background content, or non-clinical chatter. Score the report
on the factors listed below. For each factor return an integer score 0-5 and a
short free-text justification. The justification MUST quote the offending Czech
text from the report verbatim in double quotes when a defect is present, or say
"n/a" if the factor does not apply. Judge each factor by the abstract criterion
described, not by surface keyword matching.

Factors and scoring criteria:

1. clinical_relevance — 5 = report contains only clinically relevant content
   derived from the conversation; 0 = report contains material that is not
   clinically relevant (off-topic narrative, social filler, content from
   unrelated voices) presented as if it were part of the medical history.
2. section_placement — 5 = subjective patient-reported information appears
   only in subjective sections, and information obtained by direct measurement
   or examination appears only in the objective-finding section; 0 = systematic
   mixing of these categories.
3. no_fabrication — 5 = every clinical statement in the report has a direct
   basis in the transcript; 0 = report introduces diagnoses, etiologies,
   categories, or causal explanations that the speakers never formulated.
4. adherence_appropriateness — 5 = the adherence/cooperation section reflects
   only what was actually discussed in the transcript; 0 = the section is
   filled with a default summary statement when the topic was never raised.
5. dosage_fidelity — 5 = compact clinical tokens (dosing schemes, frequencies,
   units, abbreviations) are preserved verbatim from the spoken source;
   0 = these tokens are paraphrased into prose, merged, or unit-converted.
6. completeness — 5 = all clinically relevant content from the transcript is
   captured; 0 = major clinically relevant content is missing.
7. no_critical_omission — 5 = no clinically important finding, symptom, or
   medication is dropped; 0 = a safety-relevant element is missing.
8. czech_medical_style — 5 = idiomatic Czech medical documentation register
   and terminology throughout; 0 = informal, non-idiomatic, or inconsistent
   register.
9. temporal_anchor_fidelity — 5 = durations, onsets, frequencies, and
   time-of-day qualifiers from the transcript are preserved with the same
   granularity; 0 = these temporal anchors are dropped, generalized, or altered.
10. negation_explicitness — 5 = the report cleanly distinguishes between
    information explicitly negated by a speaker and information that was never
    raised; both situations are represented appropriately and never conflated;
    0 = explicit negation is treated as absence, or absence is treated as
    explicit negation.
11. speaker_attribution — 5 = subjective utterances are attributed to the
    patient and observations to the clinician without confusion; 0 = the
    report attributes content to the wrong speaker or merges roles.

Respond as STRICT JSON only, with this exact shape:
{
  "factors": {
    "clinical_relevance":        {"score": N, "justification": "..."},
    "section_placement":         {"score": N, "justification": "..."},
    "no_fabrication":            {"score": N, "justification": "..."},
    "adherence_appropriateness": {"score": N, "justification": "..."},
    "dosage_fidelity":           {"score": N, "justification": "..."},
    "completeness":              {"score": N, "justification": "..."},
    "no_critical_omission":      {"score": N, "justification": "..."},
    "czech_medical_style":       {"score": N, "justification": "..."},
    "temporal_anchor_fidelity":  {"score": N, "justification": "..."},
    "negation_explicitness":     {"score": N, "justification": "..."},
    "speaker_attribution":       {"score": N, "justification": "..."}
  }
}
Do not include any text outside the JSON object."""


def evaluate_report_task0036(
    client: AzureOpenAI, model: str, transcript: str, report: str
) -> dict:
    """TASK-0036 weighted rubric judge call. Returns dict with factors + composite."""
    t0 = time.time()
    reasoning = _is_reasoning_model(model)

    def _call():
        kwargs: dict = dict(
            model=model,
            messages=[
                {"role": "system", "content": JUDGE_TASK0036_SYSTEM_PROMPT},
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
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        print(f"  ⚠️  TASK-0036 judge returned invalid JSON. Raw: {raw[:300]}")
        return {
            "factors": {},
            "weighted_composite": None,
            "_error": "invalid_json",
            "_raw": raw,
            "_eval_time_s": round(elapsed, 2),
            "_eval_tokens": {
                "prompt_tokens": response.usage.prompt_tokens,
                "completion_tokens": response.usage.completion_tokens,
            },
        }

    factors_raw = parsed.get("factors", {})
    factors_out: dict = {}
    weighted_sum = 0
    for key, weight in TASK0036_FACTORS:
        entry = factors_raw.get(key, {}) or {}
        score = entry.get("score")
        if not isinstance(score, (int, float)):
            score = 0
        score = max(0, min(5, int(score)))
        factors_out[key] = {
            "score": score,
            "weight": weight,
            "justification": entry.get("justification", ""),
        }
        weighted_sum += score * weight
    composite = round(weighted_sum / TASK0036_TOTAL_WEIGHT, 3)

    return {
        "factors": factors_out,
        "weighted_composite": composite,
        "_eval_time_s": round(elapsed, 2),
        "_eval_tokens": {
            "prompt_tokens": response.usage.prompt_tokens,
            "completion_tokens": response.usage.completion_tokens,
        },
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


def run_evaluation(
    scenarios_dir: str,
    model: str,
    output_path: str,
    prompt_variant: str = "v0",
    task0036_rubric: bool = False,
) -> list[dict]:
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

        scenario_record = {
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
        }

        if task0036_rubric:
            print(f"  → TASK-0036 rubric…", end="", flush=True)
            try:
                t36 = evaluate_report_task0036(client, model, transcript, report)
            except Exception as exc:
                print(f" first attempt failed: {exc}; retrying once…", end="", flush=True)
                try:
                    t36 = evaluate_report_task0036(client, model, transcript, report)
                except Exception as exc2:
                    print(f" failed twice: {exc2}")
                    t36 = {"factors": {}, "weighted_composite": None, "_error": str(exc2)}
            t36_time = t36.get("_eval_time_s", "?")
            comp36 = t36.get("weighted_composite")
            comp36_str = f"{comp36:.2f}" if isinstance(comp36, (int, float)) else "?"
            print(f" done ({t36_time}s, weighted={comp36_str})")
            factor_scores = {
                k: v.get("score") for k, v in t36.get("factors", {}).items()
            }
            print(f"  ⤷ factors: {factor_scores}")
            scenario_record["task0036_rubric"] = {
                "factors": t36.get("factors", {}),
                "weighted_composite": t36.get("weighted_composite"),
            }

        print()
        results.append(scenario_record)

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

    if task0036_rubric:
        t36_composites = [
            r.get("task0036_rubric", {}).get("weighted_composite")
            for r in results
            if isinstance(r.get("task0036_rubric", {}).get("weighted_composite"), (int, float))
        ]
        per_factor_means = {}
        for key, _w in TASK0036_FACTORS:
            vals = [
                r["task0036_rubric"]["factors"].get(key, {}).get("score")
                for r in results
                if r.get("task0036_rubric", {}).get("factors", {}).get(key, {}).get("score") is not None
            ]
            per_factor_means[key] = round(sum(vals) / len(vals), 3) if vals else None
        aggregate["task0036_rubric"] = {
            "mean_weighted_composite": (
                round(sum(t36_composites) / len(t36_composites), 3) if t36_composites else None
            ),
            "per_factor_means": per_factor_means,
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
        choices=list(PROMPT_VARIANTS.keys()),
        help="Prompt variant (v0-v4 + v5a_negative/v5b_positive/v5c_fewshot TASK-0036 candidates).",
    )
    parser.add_argument(
        "--task0036-rubric",
        action="store_true",
        help="Also run the TASK-0036 weighted defect-targeted judge (8 factors).",
    )
    args = parser.parse_args()

    run_evaluation(
        args.scenarios_dir,
        args.model,
        args.output,
        args.prompt_variant,
        task0036_rubric=args.task0036_rubric,
    )

    if args.task0036_rubric:
        try:
            data = json.loads(Path(args.output).read_text(encoding="utf-8"))
            agg = data.get("aggregate", {}).get("task0036_rubric", {})
            print("TASK-0036 weighted rubric — aggregate")
            print(f"  mean_weighted_composite: {agg.get('mean_weighted_composite')}")
            for k, v in (agg.get("per_factor_means") or {}).items():
                print(f"    {k:>26}: {v}")
        except Exception as exc:
            print(f"  (skip TASK-0036 summary: {exc})")
