#!/usr/bin/env python3
"""Deterministic report checks for ANOTE generated medical reports.

The checker is intentionally stdlib-only so it can run as a cheap regression
gate before any LLM judge calls. It can be used as a CLI script or imported via
``run_all_checks`` from evaluation runners.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


MIN_WORDS = 100
MAX_WORDS = 500           # tightened from 700 — doctor feedback: reports too long
MAX_BULLETS_PER_SECTION = 9   # tightened from 12 — fail at 10+, warn detail at 8+
MAX_NEGATION_PHRASES = 7       # NEG-06: above this without transcript = filler risk

REQUIRED_SECTIONS_INITIAL = [
    "Identifikace pacienta",
    "NO (Nynější onemocnění)",
    "RA (Rodinná anamnéza)",
    "OA (Osobní anamnéza)",
    "FA (Farmakologická anamnéza",
    "AA (Alergologická anamnéza)",
    "SA (Sociální anamnéza)",
    "Adherence a spolupráce pacienta",
    "Objektivní nález",
    "Hodnocení",
    "Návrh vyšetření",
    "Návrh terapie",
    "Pokyny a plán kontrol",
]

SECTION_NAMES = [
    "Identifikace pacienta",
    "NO (Nynější onemocnění)",
    "RA (Rodinná anamnéza)",
    "OA (Osobní anamnéza)",
    "FA (Farmakologická anamnéza / aktuální medikace)",
    "FA (Farmakologická anamnéza",
    "AA (Alergologická anamnéza)",
    "GA (Gynekologická/urologická anamnéza",
    "SA (Sociální anamnéza)",
    "Adherence a spolupráce pacienta",
    "Objektivní nález",
    "Hodnocení",
    "Návrh vyšetření",
    "Návrh terapie",
    "Pokyny a plán kontrol",
]

FEEDBACK_TAG_PATTERN = re.compile(r"<FEEDBACK[^>]*>.*?</FEEDBACK>", re.IGNORECASE | re.DOTALL)
WORD_PATTERN = re.compile(r"\b[\wÁ-Žá-ž]+\b", re.UNICODE)
BULLET_PATTERN = re.compile(r"^\s*[-•*]\s+(.+?)\s*$", re.MULTILINE)

TEMP_NEGATION_PATTERN = re.compile(
    r"(teplotu neguje|zvýšenou teplotu neguje|horečku neguje|teplotu neg\.)",
    re.IGNORECASE,
)
TEMP_IN_TRANSCRIPT_PATTERN = re.compile(
    r"(teplota|horečka|horečku|teplo|subfebr|febrilie|teplý)",
    re.IGNORECASE,
)
ALLERGY_NEGATION_PATTERN = re.compile(
    r"(alergie neguje|alergi[ei] neguje|bez alergi[íe])",
    re.IGNORECASE,
)
ALLERGY_IN_TRANSCRIPT_PATTERN = re.compile(
    r"(alergi[ei]|alergický|alergická|alergen)",
    re.IGNORECASE,
)
CONFLATION_PATTERN = re.compile(
    r"(neguje\s*\(neuvedeno|neuvedeno[^\n•*-]*neguje|neguje[^\n•*-]*neuvedeno)",
    re.IGNORECASE,
)
REASONING_LEAK_PATTERN = re.compile(
    r"\([^)]{5,}\b(pravděpodobně|patrně|lze předpokládat|z kontextu|předpoklad|"
    r"implicitně|evidentn|zřejmě)\b[^)]*\)",
    re.IGNORECASE,
)
GA_META_PATTERN = re.compile(
    r"(\(předpoklad|implicitně|pravděpodobně.*muž|pravděpodobně.*žen)",
    re.IGNORECASE | re.DOTALL,
)
ACTION_IN_ADHERENCE_PATTERN = re.compile(
    r"(zajistit|objednat|domluvit|plánovat|výměna|zavolat|kontaktovat)",
    re.IGNORECASE,
)
SUBJECTIVE_IN_OBJECTIVE_PATTERN = re.compile(
    r"(pacient udává|udávaná hodnota|dle pacienta|pacient popisuje)",
    re.IGNORECASE,
)
NOISE_PATTERNS = [
    re.compile(
        r"(energetická krize|sklářský průmysl|výpadky GPT|výpadky AI|umělá inteligence\s+"
        r"jako nástroj|investic[ei] a rizika|burz[ae]|akciov)",
        re.IGNORECASE,
    ),
    re.compile(r"(válka na Ukra|globální situace|energetická závislost)", re.IGNORECASE),
    re.compile(r"(prezentaci pro Audi|automobilov.*průmysl.*prezentac)", re.IGNORECASE),
    re.compile(r"(borelióz|borelioz|lymsk)", re.IGNORECASE),
]
CASUAL_QUESTION_PATTERN = re.compile(
    r"(jak se vyučuje|co si myslíte o|to jsem se zeptal|jak to vidíte)",
    re.IGNORECASE,
)

# ── Phase 1 V2 patterns ──────────────────────────────────────────────────────

# NEG-06: count bare negation/denial phrases (no transcript context available)
NEGATION_COUNT_PATTERN = re.compile(
    r"\b(neguje|neudává|neuvádí)\b",
    re.IGNORECASE,
)

# INFER-03: reasoning language used inline (outside parentheses)
REASONING_INLINE_PATTERN = re.compile(
    r"\b(z\s+kontextu\s+(lze|vyplývá)|lze\s+předpokládat|implicitně\s+vyplývá)\b",
    re.IGNORECASE,
)

# INFER-04: differential diagnosis language in anamnesis sections (belongs only in Hodnocení)
DIFFERENTIAL_DX_PATTERN = re.compile(
    r"(diferenciální\s+diagnóz[ay]|diferenciálně|možná\s+boreliózní|boreliózní\s+etiologi|"
    r"možná\s+etiologi[ea]|v\s+diferenciální)",
    re.IGNORECASE,
)

# NOISE-03: post-visit events that should not appear in a medical record
POST_VISIT_PATTERN = re.compile(
    r"(po\s+návratu\s+domů|po\s+odchodu\s+z\s+ordinac|po\s+návštěvě\s+ordinac|"
    r"po\s+skončení\s+návštěvy|cestou\s+domů|po\s+proběhlé\s+konzultaci|"
    r"ztrátu\s+peněženky|ztratil\s+peněženku)",
    re.IGNORECASE,
)

# VERBOSE-01: adherence section consisting entirely of template filler phrases
ADHERENCE_FILLER_PATTERN = re.compile(
    r"(spolupráce\s+(je\s+)?(dobrá|dobrý|výborná|výborný|v\s+pořádku)|"
    r"(odmítání|nesouhlas)\s+(léčby\s+)?neuvedeno|"
    r"neuvedeno\s+odmítání|"
    r"bez\s+problémů\s+se\s+spoluprací)",
    re.IGNORECASE,
)

# VERBOSE-02: irrelevant workplace / social content in SA section
SA_IRRELEVANCE_PATTERN = re.compile(
    r"(prezentaci\s+pro\s+\w+|\bAudi\b|\bBMW\b|sklářský\s+průmysl|"
    r"automobilov|výroba\s+skel|IT\s+(problém|výpadek)|výpadek\s+(GPT|AI|systém))",
    re.IGNORECASE,
)


@dataclass
class CheckResult:
    id: str
    name: str
    passed: bool
    severity: str
    detail: str
    evidence: str = ""
    skipped: bool = False


def strip_feedback_tags(text: str) -> str:
    """Remove inline doctor feedback annotations from feedback report files."""
    return FEEDBACK_TAG_PATTERN.sub("", text)


def _normalize(text: str) -> str:
    return text.casefold()


def _word_count(text: str) -> int:
    return len(WORD_PATTERN.findall(text))


def _all_header_positions(report: str) -> list[tuple[str, int, int]]:
    """Return known section headers as (name, start, end) sorted by position."""
    positions: list[tuple[str, int, int]] = []
    for name in SECTION_NAMES:
        pattern = re.compile(rf"(?im)^\s*{re.escape(name)}[^\n:]*:\s*$")
        for match in pattern.finditer(report):
            positions.append((name, match.start(), match.end()))
    positions.sort(key=lambda item: item[1])
    return positions


def extract_section(report: str, section_name: str) -> str:
    """Extract text from a named section until the next known section header."""
    target = section_name.casefold()
    headers = _all_header_positions(report)
    for index, (name, _start, end) in enumerate(headers):
        if target in name.casefold() or name.casefold() in target:
            next_start = headers[index + 1][1] if index + 1 < len(headers) else len(report)
            return report[end:next_start].strip()
    return ""


def _iter_sections(report: str) -> Iterable[tuple[str, str]]:
    headers = _all_header_positions(report)
    for index, (name, _start, end) in enumerate(headers):
        next_start = headers[index + 1][1] if index + 1 < len(headers) else len(report)
        yield name, report[end:next_start].strip()


def _result(
    check_id: str,
    name: str,
    passed: bool,
    severity: str,
    detail: str,
    evidence: str = "",
    skipped: bool = False,
) -> CheckResult:
    return CheckResult(
        id=check_id,
        name=name,
        passed=passed,
        severity=severity,
        detail=detail,
        evidence=evidence,
        skipped=skipped,
    )


def _skip(check_id: str, name: str, severity: str, detail: str) -> CheckResult:
    return _result(check_id, name, True, severity, detail, skipped=True)


def _first_match(pattern: re.Pattern[str], text: str) -> str:
    match = pattern.search(text)
    return match.group(0) if match else ""


def _check_struct_required(report: str) -> CheckResult:
    lowered = _normalize(report)
    missing = [section for section in REQUIRED_SECTIONS_INITIAL if section.casefold() not in lowered]
    if missing:
        return _result(
            "STRUCT-01",
            "All required sections present",
            False,
            "HIGH",
            f"Missing sections: {', '.join(missing)}",
        )
    return _result("STRUCT-01", "All required sections present", True, "HIGH", "All required sections present")


def _check_struct_order(report: str) -> CheckResult:
    lowered = _normalize(report)
    positions = []
    for section in REQUIRED_SECTIONS_INITIAL:
        pos = lowered.find(section.casefold())
        if pos >= 0:
            positions.append((section, pos))
    if len(positions) < 2:
        return _result("STRUCT-02", "Section order correct", False, "MEDIUM", "Not enough sections found to verify order")
    for (previous, previous_pos), (current, current_pos) in zip(positions, positions[1:]):
        if current_pos < previous_pos:
            return _result(
                "STRUCT-02",
                "Section order correct",
                False,
                "MEDIUM",
                f"Section '{current}' appears before '{previous}'",
                evidence=current,
            )
    return _result("STRUCT-02", "Section order correct", True, "MEDIUM", "Section order matches expected template")


def _check_struct_duplicates(report: str) -> CheckResult:
    duplicates = []
    for section in REQUIRED_SECTIONS_INITIAL:
        pattern = re.compile(rf"(?im)^\s*{re.escape(section)}[^\n:]*:\s*$")
        count = len(pattern.findall(report))
        if count > 1:
            duplicates.append(f"{section} ({count}x)")
    if duplicates:
        return _result(
            "STRUCT-03",
            "No duplicate section headers",
            False,
            "MEDIUM",
            f"Duplicate headers: {', '.join(duplicates)}",
        )
    return _result("STRUCT-03", "No duplicate section headers", True, "MEDIUM", "No duplicate section headers found")


def _check_length_words(report: str) -> CheckResult:
    words = _word_count(report)
    passed = MIN_WORDS <= words <= MAX_WORDS
    detail = f"Word count in range [{MIN_WORDS}, {MAX_WORDS}]: {words} words"
    if not passed:
        detail = f"Word count outside range [{MIN_WORDS}, {MAX_WORDS}]: {words} words"
    return _result("LEN-01", "Word count in range", passed, "MEDIUM", detail, str(words))


def _check_bullet_counts(report: str) -> CheckResult:
    offenders = []
    for name, section_text in _iter_sections(report):
        count = len(BULLET_PATTERN.findall(section_text))
        if count > MAX_BULLETS_PER_SECTION:
            offenders.append(f"{name}: {count}")
    if offenders:
        return _result(
            "LEN-02",
            "Bullet count per section",
            False,
            "LOW",
            f"Sections with more than {MAX_BULLETS_PER_SECTION} bullets: {', '.join(offenders)}",
        )
    return _result("LEN-02", "Bullet count per section", True, "LOW", "No section has excessive bullet count")


def _check_temp_negation(report: str, transcript: str | None) -> CheckResult:
    if transcript is None:
        return _skip("NEG-01", "Temperature negation not hallucinated", "HIGH", "Skipped: transcript not supplied")
    evidence = _first_match(TEMP_NEGATION_PATTERN, report)
    if evidence and not TEMP_IN_TRANSCRIPT_PATTERN.search(transcript):
        return _result(
            "NEG-01",
            "Temperature negation not hallucinated",
            False,
            "HIGH",
            f"'{evidence}' found in report but temperature topic absent from transcript",
            evidence,
        )
    return _result("NEG-01", "Temperature negation not hallucinated", True, "HIGH", "No hallucinated temperature negation detected")


def _check_allergy_negation(report: str, transcript: str | None) -> CheckResult:
    if transcript is None:
        return _skip("NEG-02", "Allergy negation not hallucinated", "HIGH", "Skipped: transcript not supplied")
    evidence = _first_match(ALLERGY_NEGATION_PATTERN, report)
    if evidence and not ALLERGY_IN_TRANSCRIPT_PATTERN.search(transcript):
        return _result(
            "NEG-02",
            "Allergy negation not hallucinated",
            False,
            "HIGH",
            f"'{evidence}' found in report but allergy topic absent from transcript",
            evidence,
        )
    return _result("NEG-02", "Allergy negation not hallucinated", True, "HIGH", "No hallucinated allergy negation detected")


def _check_negation_conflation(report: str) -> CheckResult:
    evidence = _first_match(CONFLATION_PATTERN, report)
    if evidence:
        return _result(
            "NEG-03",
            "No neuvedeno+negation conflation",
            False,
            "HIGH",
            "Found negation and neuvedeno conflated in the same local phrase",
            evidence,
        )
    return _result("NEG-03", "No neuvedeno+negation conflation", True, "HIGH", "No neuvedeno+negation conflation detected")


def _check_reasoning_leak(report: str) -> CheckResult:
    matches = [match.group(0) for match in REASONING_LEAK_PATTERN.finditer(report)]
    if matches:
        return _result(
            "INFER-01",
            "No parenthetical inference prose",
            False,
            "MEDIUM",
            f"Found {len(matches)} parenthetical reasoning phrase(s)",
            "; ".join(matches[:3]),
        )
    return _result("INFER-01", "No parenthetical inference prose", True, "MEDIUM", "No parenthetical reasoning detected")


def _check_ga_meta(report: str) -> CheckResult:
    ga_text = extract_section(report, "GA (Gynekologická/urologická anamnéza")
    if not ga_text:
        return _result("INFER-02", "GA section does not contain meta-commentary", True, "LOW", "GA section not found or empty")
    evidence = _first_match(GA_META_PATTERN, ga_text)
    if evidence:
        return _result(
            "INFER-02",
            "GA section does not contain meta-commentary",
            False,
            "LOW",
            "GA section contains model meta-commentary",
            evidence,
        )
    return _result("INFER-02", "GA section does not contain meta-commentary", True, "LOW", "No GA meta-commentary detected")


def _check_adherence_actions(report: str) -> CheckResult:
    section = extract_section(report, "Adherence a spolupráce pacienta")
    evidence = _first_match(ACTION_IN_ADHERENCE_PATTERN, section)
    if evidence:
        return _result(
            "PLACE-01",
            "No action items in Adherence section",
            False,
            "LOW",
            "Adherence section contains action item wording",
            evidence,
        )
    return _result("PLACE-01", "No action items in Adherence section", True, "LOW", "No action items detected in Adherence section")


def _check_subjective_objective(report: str) -> CheckResult:
    section = extract_section(report, "Objektivní nález")
    evidence = _first_match(SUBJECTIVE_IN_OBJECTIVE_PATTERN, section)
    if evidence:
        return _result(
            "PLACE-02",
            "No subjective values in Objektivní nález",
            False,
            "MEDIUM",
            "Objektivní nález contains subjective patient-report wording",
            evidence,
        )
    return _result("PLACE-02", "No subjective values in Objektivní nález", True, "MEDIUM", "No subjective wording detected in Objektivní nález")


def _check_noise_keywords(report: str) -> CheckResult:
    for pattern in NOISE_PATTERNS:
        match = pattern.search(report)
        if match:
            evidence = match.group(0)
            no_text = extract_section(report, "NO (Nynější onemocnění)")
            oa_text = extract_section(report, "OA (Osobní anamnéza)")
            severity = "CRITICAL" if evidence in no_text or evidence in oa_text else "HIGH"
            return _result(
                "NOISE-01",
                "Off-topic keyword detection",
                False,
                severity,
                "Potentially off-topic or known hallucination keyword found in report",
                evidence,
            )
    return _result("NOISE-01", "Off-topic keyword detection", True, "HIGH", "No known off-topic keywords detected")


def _check_casual_questions(report: str) -> CheckResult:
    evidence = _first_match(CASUAL_QUESTION_PATTERN, report)
    if evidence:
        return _result(
            "NOISE-02",
            "Doctor's non-clinical questions not in report",
            False,
            "LOW",
            "Casual non-clinical question text appears in report",
            evidence,
        )
    return _result("NOISE-02", "Doctor's non-clinical questions not in report", True, "LOW", "No casual question text detected")


def _section_has_substantive_content(text: str) -> bool:
    cleaned = re.sub(r"[-•*]", " ", text)
    cleaned = re.sub(r"\bneuvedeno\b", " ", cleaned, flags=re.IGNORECASE)
    return _word_count(cleaned) > 1


def _check_empty_shell(report: str) -> CheckResult:
    substantive = [name for name, text in _iter_sections(report) if _section_has_substantive_content(text)]
    if len(substantive) < 2:
        return _result(
            "EMPTY-01",
            "Report is not a fully-empty shell",
            False,
            "CRITICAL",
            f"Only {len(substantive)} section(s) contain substantive content beyond neuvedeno",
            ", ".join(substantive),
        )
    return _result("EMPTY-01", "Report is not a fully-empty shell", True, "CRITICAL", f"{len(substantive)} sections contain substantive content")


def _check_duplicate_bullets(report: str) -> CheckResult:
    for section_name, section_text in _iter_sections(report):
        bullets = [re.sub(r"\s+", " ", bullet.strip()).casefold() for bullet in BULLET_PATTERN.findall(section_text)]
        for previous, current in zip(bullets, bullets[1:]):
            if previous and previous == current:
                return _result(
                    "DUP-01",
                    "No duplicate consecutive bullets",
                    False,
                    "LOW",
                    f"Duplicate consecutive bullet in section {section_name}",
                    current,
                )
    return _result("DUP-01", "No duplicate consecutive bullets", True, "LOW", "No duplicate consecutive bullets detected")


def _check_negation_density(report: str, transcript: str | None) -> CheckResult:
    """NEG-06: Flag suspiciously high negation phrase count when no transcript is available."""
    if transcript is not None:
        return _skip("NEG-06", "Negation phrase density", "MEDIUM", "Skipped: transcript supplied — use NEG-01/02 instead")
    count = len(NEGATION_COUNT_PATTERN.findall(report))
    if count > MAX_NEGATION_PHRASES:
        return _result(
            "NEG-06",
            "Negation phrase density",
            False,
            "MEDIUM",
            f"Found {count} negation phrases without transcript (threshold: {MAX_NEGATION_PHRASES}); possible template filler",
            str(count),
        )
    return _result("NEG-06", "Negation phrase density", True, "MEDIUM", f"{count} negation phrase(s) — within threshold")


def _check_reasoning_inline(report: str) -> CheckResult:
    """INFER-03: Detect reasoning language used inline in body text (outside parentheses)."""
    matches = [m.group(0).strip() for m in REASONING_INLINE_PATTERN.finditer(report)]
    if matches:
        return _result(
            "INFER-03",
            "No inline reasoning prose outside parentheses",
            False,
            "MEDIUM",
            f"Found {len(matches)} inline reasoning phrase(s) outside parentheses",
            "; ".join(matches[:2]),
        )
    return _result("INFER-03", "No inline reasoning prose outside parentheses", True, "MEDIUM", "No inline reasoning detected outside parentheses")


def _check_differential_dx_placement(report: str) -> CheckResult:
    """INFER-04: Differential diagnosis language must not appear in anamnesis sections."""
    anamnesis_sections = [
        "NO (Nynější onemocnění)",
        "OA (Osobní anamnéza)",
        "FA (Farmakologická anamnéza",
        "AA (Alergologická anamnéza)",
    ]
    for section_name in anamnesis_sections:
        section_text = extract_section(report, section_name)
        if not section_text:
            continue
        evidence = _first_match(DIFFERENTIAL_DX_PATTERN, section_text)
        if evidence:
            return _result(
                "INFER-04",
                "No differential diagnosis inference in anamnesis sections",
                False,
                "HIGH",
                f"Differential diagnosis language found in '{section_name}'",
                evidence,
            )
    return _result("INFER-04", "No differential diagnosis inference in anamnesis sections", True, "HIGH", "No misplaced differential diagnosis language detected")


def _check_post_visit_content(report: str) -> CheckResult:
    """NOISE-03: Post-visit events should not appear in a medical record."""
    evidence = _first_match(POST_VISIT_PATTERN, report)
    if evidence:
        return _result(
            "NOISE-03",
            "No post-visit events in report",
            False,
            "MEDIUM",
            "Report contains post-visit event description",
            evidence,
        )
    return _result("NOISE-03", "No post-visit events in report", True, "MEDIUM", "No post-visit events detected")


def _check_adherence_filler(report: str) -> CheckResult:
    """VERBOSE-01: Adherence section should not consist entirely of template filler."""
    section = extract_section(report, "Adherence a spolupráce pacienta")
    if not section:
        return _skip("VERBOSE-01", "Adherence section not template filler", "MEDIUM", "Adherence section not found")
    filler_match = _first_match(ADHERENCE_FILLER_PATTERN, section)
    if not filler_match:
        return _result("VERBOSE-01", "Adherence section not template filler", True, "MEDIUM", "No filler phrases detected in Adherence section")
    # Only fail if every line is predominantly filler — strip the filler patterns from
    # each line and check if meaningful residual content (≥ 3 words) exists in any line.
    lines = [ln.strip().lstrip("-•*").strip() for ln in section.splitlines() if ln.strip()]
    non_filler = []
    for ln in lines:
        if not ln:
            continue
        ln_stripped = ADHERENCE_FILLER_PATTERN.sub("", ln)
        ln_stripped = re.sub(r"\bneuvedeno\b", "", ln_stripped, flags=re.IGNORECASE)
        if _word_count(ln_stripped) >= 3:
            non_filler.append(ln)
    if non_filler:
        return _result("VERBOSE-01", "Adherence section not template filler", True, "MEDIUM", "Adherence section has substantive content alongside filler phrases")
    return _result(
        "VERBOSE-01",
        "Adherence section not template filler",
        False,
        "MEDIUM",
        "Adherence section appears to consist entirely of template filler",
        filler_match,
    )


def _check_sa_irrelevance(report: str) -> CheckResult:
    """VERBOSE-02: SA section should not contain irrelevant workplace/social details."""
    section = extract_section(report, "SA (Sociální anamnéza)")
    if not section:
        return _skip("VERBOSE-02", "SA section does not contain irrelevant workplace detail", "LOW", "SA section not found")
    evidence = _first_match(SA_IRRELEVANCE_PATTERN, section)
    if evidence:
        return _result(
            "VERBOSE-02",
            "SA section does not contain irrelevant workplace detail",
            False,
            "LOW",
            "SA section contains potentially irrelevant workplace or social detail",
            evidence,
        )
    return _result("VERBOSE-02", "SA section does not contain irrelevant workplace detail", True, "LOW", "No irrelevant workplace detail detected in SA section")


def run_all_checks(report: str, transcript: str | None = None) -> dict:
    """Run all deterministic checks and return a JSON-serializable result."""
    cleaned_report = strip_feedback_tags(report)
    checks = [
        # STRUCT group
        _check_struct_required(cleaned_report),
        _check_struct_order(cleaned_report),
        _check_struct_duplicates(cleaned_report),
        # LEN group
        _check_length_words(cleaned_report),
        _check_bullet_counts(cleaned_report),
        # NEG group
        _check_temp_negation(cleaned_report, transcript),
        _check_allergy_negation(cleaned_report, transcript),
        _check_negation_conflation(cleaned_report),
        _check_negation_density(cleaned_report, transcript),
        # INFER group
        _check_reasoning_leak(cleaned_report),
        _check_ga_meta(cleaned_report),
        _check_reasoning_inline(cleaned_report),
        _check_differential_dx_placement(cleaned_report),
        # PLACE group
        _check_adherence_actions(cleaned_report),
        _check_subjective_objective(cleaned_report),
        # NOISE group
        _check_noise_keywords(cleaned_report),
        _check_casual_questions(cleaned_report),
        _check_post_visit_content(cleaned_report),
        # VERBOSE group
        _check_adherence_filler(cleaned_report),
        _check_sa_irrelevance(cleaned_report),
        # EMPTY + DUP
        _check_empty_shell(cleaned_report),
        _check_duplicate_bullets(cleaned_report),
    ]
    active = [check for check in checks if not check.skipped]
    passed = sum(1 for check in active if check.passed)
    failed = sum(1 for check in active if not check.passed)
    skipped = sum(1 for check in checks if check.skipped)
    total = len(active)
    return {
        "total_checks": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "pass_rate": round(passed / total, 4) if total else None,
        "word_count": _word_count(cleaned_report),
        "checks": [asdict(check) for check in checks],
    }


def _status_icon(check: dict) -> str:
    if check.get("skipped"):
        return "SKIP"
    return "PASS" if check.get("passed") else "FAIL"


def format_result(result: dict, label: str = "report") -> str:
    """Format a single check result for humans."""
    lines = [
        f"{label} - {result['passed']}/{result['total_checks']} checks passed"
        + (f" ({result['skipped']} skipped)" if result.get("skipped") else "")
    ]
    for check in result["checks"]:
        lines.append(f"  {_status_icon(check):4s} {check['id']:9s} {check['detail']}")
        if check.get("evidence"):
            lines.append(f"       evidence: {check['evidence']}")
    return "\n".join(lines)


def _group_pass(checks: list[dict], prefix: str) -> str:
    selected = [check for check in checks if check["id"].startswith(prefix) and not check.get("skipped")]
    if not selected:
        return "SKIP"
    return "PASS" if all(check["passed"] for check in selected) else "FAIL"


def check_feedback_dir(feedback_dir: Path) -> dict:
    files = sorted(
        path for path in feedback_dir.iterdir()
        if path.is_file()
        and path.suffix.lower() in {".txt", ".tdt"}
        and path.name.lower() != "readme.md"
    )
    results = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        result = run_all_checks(report=text)
        result["report_file"] = str(path)
        results.append(result)
    return {"feedback_dir": str(feedback_dir), "results": results}


def format_feedback_summary(dataset_result: dict) -> str:
    lines = [
        f"Feedback checks: {dataset_result['feedback_dir']}",
        "File                 Words  STRUCT  LEN   NEG   INFER  PLACE  NOISE  VERBOSE  EMPTY  DUP   PASS",
    ]
    totals: dict[str, list[bool]] = {key: [] for key in ["STRUCT", "LEN", "NEG", "INFER", "PLACE", "NOISE", "VERBOSE", "EMPTY", "DUP"]}
    for result in dataset_result["results"]:
        checks = result["checks"]
        row = {
            "STRUCT": _group_pass(checks, "STRUCT"),
            "LEN": _group_pass(checks, "LEN"),
            "NEG": _group_pass(checks, "NEG"),
            "INFER": _group_pass(checks, "INFER"),
            "PLACE": _group_pass(checks, "PLACE"),
            "NOISE": _group_pass(checks, "NOISE"),
            "VERBOSE": _group_pass(checks, "VERBOSE"),
            "EMPTY": _group_pass(checks, "EMPTY"),
            "DUP": _group_pass(checks, "DUP"),
        }
        for key, value in row.items():
            if value != "SKIP":
                totals[key].append(value == "PASS")
        filename = Path(result["report_file"]).name
        lines.append(
            f"{filename:<20s} {result['word_count']:>5}  "
            f"{row['STRUCT']:<6s} {row['LEN']:<5s} {row['NEG']:<5s} {row['INFER']:<6s} "
            f"{row['PLACE']:<6s} {row['NOISE']:<6s} {row['VERBOSE']:<7s} {row['EMPTY']:<6s} {row['DUP']:<5s} "
            f"{result['passed']:>2}/{result['total_checks']:<2}"
        )
    total_parts = []
    for key, values in totals.items():
        total_parts.append(f"{key}={sum(values)}/{len(values)}" if values else f"{key}=SKIP")
    lines.append("TOTAL " + "  ".join(total_parts))
    return "\n".join(lines)


def _read_optional_file(path: str | None) -> str | None:
    if not path:
        return None
    return Path(path).read_text(encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="ANOTE deterministic report checker")
    parser.add_argument("--report", help="Path to generated report text file")
    parser.add_argument("--transcript", help="Optional transcript text file")
    parser.add_argument("--feedback-dir", help="Run checks against all feedback *.txt/*.tdt files")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    parser.add_argument("--scenarios-dir", help="Reserved for generated scenario checks")
    parser.add_argument("--generate", action="store_true", help="Reserved for generated scenario checks")
    args = parser.parse_args(argv)

    if args.scenarios_dir or args.generate:
        parser.error("--scenarios-dir/--generate is reserved; use evaluate_reports.py for generate-then-check runs")

    if args.feedback_dir:
        dataset_result = check_feedback_dir(Path(args.feedback_dir))
        if args.json:
            print(json.dumps(dataset_result, ensure_ascii=False, indent=2))
        else:
            print(format_feedback_summary(dataset_result))
        failed = any(result["failed"] for result in dataset_result["results"])
        return 1 if failed else 0

    if not args.report:
        parser.error("Either --report or --feedback-dir is required")

    report_path = Path(args.report)
    report = report_path.read_text(encoding="utf-8")
    transcript = _read_optional_file(args.transcript)
    result = run_all_checks(report=report, transcript=transcript)
    result["report_file"] = str(report_path)
    if args.transcript:
        result["transcript_file"] = args.transcript

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(format_result(result, report_path.name))
    return 1 if result["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())