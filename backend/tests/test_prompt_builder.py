"""Tests for the system prompt builder functions in main.py.

Verifies that visit-type routing, date injection, section structure,
and language rules are correctly assembled.
"""

import os
import re
from datetime import date

# Set env vars before import
os.environ.setdefault("AZURE_OPENAI_KEY", "test-key")
os.environ.setdefault("AZURE_OPENAI_ENDPOINT", "https://test.openai.azure.com")
os.environ.setdefault("APP_API_TOKEN", "test-token")
os.environ.setdefault("MOCK_MODE", "true")

import pytest

from main import (
    _build_base_rules,
    _build_sections_initial,
    _build_sections_followup,
    _build_system_prompt,
)

TODAY = date.today().strftime("%d. %m. %Y")


# ---------------------------------------------------------------------------
# _build_base_rules
# ---------------------------------------------------------------------------

class TestBuildBaseRules:
    """Tests for the shared rules block."""

    def test_returns_nonempty_string(self) -> None:
        rules = _build_base_rules()
        assert isinstance(rules, str)
        assert len(rules) > 100

    def test_contains_zasady_header(self) -> None:
        rules = _build_base_rules()
        assert "ZÁSADY" in rules

    def test_contains_neuvedeno_rule(self) -> None:
        rules = _build_base_rules()
        assert "neuvedeno" in rules

    def test_contains_negation_examples(self) -> None:
        rules = _build_base_rules()
        assert "alergie neguje" in rules
        assert "zvýšenou teplotu neguje" in rules

    def test_contains_asr_noise_rule(self) -> None:
        rules = _build_base_rules()
        assert "automatického rozpoznávání řeči" in rules

    def test_contains_subjective_vs_objective_rule(self) -> None:
        rules = _build_base_rules()
        assert "subjektivní" in rules.lower()
        assert "objektivní" in rules.lower()


# ---------------------------------------------------------------------------
# _build_sections_initial
# ---------------------------------------------------------------------------

class TestBuildSectionsInitial:
    """Tests for the initial (default) visit section template."""

    REQUIRED_SECTIONS = [
        "Identifikace pacienta",
        "NO (Nynější onemocnění)",
        "RA (Rodinná anamnéza)",
        "OA (Osobní anamnéza)",
        "FA (Farmakologická anamnéza",
        "AA (Alergologická anamnéza)",
        "GA (Gynekologická",
        "SA (Sociální anamnéza)",
        "Objektivní nález",
        "Hodnocení",
        "Návrh vyšetření",
        "Návrh terapie",
        "Pokyny a plán kontrol",
    ]

    def test_all_sections_present(self) -> None:
        sections = _build_sections_initial(TODAY)
        for section in self.REQUIRED_SECTIONS:
            assert section in sections, f"Missing section: {section}"

    def test_date_injected(self) -> None:
        sections = _build_sections_initial(TODAY)
        assert TODAY in sections

    def test_adherence_section_present(self) -> None:
        sections = _build_sections_initial(TODAY)
        assert "Adherence" in sections or "spolupráce" in sections.lower()


# ---------------------------------------------------------------------------
# _build_sections_followup
# ---------------------------------------------------------------------------

class TestBuildSectionsFollowup:
    """Tests for the follow-up visit section template."""

    REQUIRED_SECTIONS = [
        "Identifikace pacienta",
        "Subjektivní stav",
        "Průběh od poslední kontroly",
        "Kompenzace",
        "Režim a adherence",
        "Objektivní nález",
        "Hodnocení",
        "Plán",
    ]

    def test_all_sections_present(self) -> None:
        sections = _build_sections_followup(TODAY)
        for section in self.REQUIRED_SECTIONS:
            assert section in sections, f"Missing section: {section}"

    def test_date_injected(self) -> None:
        sections = _build_sections_followup(TODAY)
        assert TODAY in sections

    def test_follow_up_label(self) -> None:
        sections = _build_sections_followup(TODAY)
        assert "Kontrolní" in sections


# ---------------------------------------------------------------------------
# _build_system_prompt — routing
# ---------------------------------------------------------------------------

class TestBuildSystemPrompt:
    """Tests for the top-level prompt builder with visit-type routing."""

    def test_default_includes_auto_detection(self) -> None:
        prompt = _build_system_prompt(TODAY, "default")
        assert "AUTOMATICKÁ DETEKCE" in prompt

    def test_initial_does_not_include_auto_detection(self) -> None:
        prompt = _build_system_prompt(TODAY, "initial")
        assert "AUTOMATICKÁ DETEKCE" not in prompt

    def test_followup_uses_kontrolni(self) -> None:
        prompt = _build_system_prompt(TODAY, "followup")
        assert "Kontrolní" in prompt
        # Follow-up should NOT have the full 13-section initial template
        assert "NO (Nynější onemocnění)" not in prompt

    def test_all_prompts_end_with_language_instruction(self) -> None:
        for vt in ("default", "initial", "followup"):
            prompt = _build_system_prompt(TODAY, vt)
            assert "češtině" in prompt

    def test_unknown_visit_type_falls_back_to_default(self) -> None:
        prompt = _build_system_prompt(TODAY, "bogus_type")
        assert "AUTOMATICKÁ DETEKCE" in prompt

    def test_date_consistent_across_visit_types(self) -> None:
        for vt in ("default", "initial", "followup"):
            prompt = _build_system_prompt(TODAY, vt)
            assert TODAY in prompt
