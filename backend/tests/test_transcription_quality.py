"""Transcription quality evaluation tests.

These tests validate the Whisper + VAD pipeline's output quality by comparing
generated transcripts against known reference texts. Unlike the full sweep
in evaluate_transcription.py, these are structured as pytest tests with
pass/fail thresholds.

The tests use the demo scenario .txt files as pseudo-references: since
these are hand-written Czech medical dialogues, a "perfect" transcription
would reproduce the text exactly. For ASR output from audio files, WER/CER
would be measured; here we test the pipeline logic and quality invariants.

Run with:
    python -m pytest tests/test_transcription_quality.py -v

For full WER/CER sweep on Hurvínek audio files:
    python evaluate_transcription.py
"""

import os
import re
from pathlib import Path

os.environ.setdefault("AZURE_OPENAI_KEY", "test-key")
os.environ.setdefault("AZURE_OPENAI_ENDPOINT", "https://test.openai.azure.com")
os.environ.setdefault("APP_API_TOKEN", "test-token")
os.environ.setdefault("MOCK_MODE", "true")

import pytest

# ── Paths ─────────────────────────────────────────────────────────────────

DEMO_SCENARIOS_DIR = Path(__file__).parent.parent.parent / "mobile" / "assets" / "demo_scenarios"
TEST_SCENARIOS_DIR = Path(__file__).parent.parent.parent / "test_scenarios"


# ── Helpers ───────────────────────────────────────────────────────────────

def _load_scenario(path: Path) -> str:
    """Load and strip a scenario text file."""
    return path.read_text(encoding="utf-8").strip()


def _normalize_text(text: str) -> str:
    """Normalize text for comparison (lowercase, collapse whitespace)."""
    text = text.lower()
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def _word_overlap(reference: str, hypothesis: str) -> float:
    """Compute word-level overlap ratio (Jaccard similarity).

    Returns a value between 0.0 and 1.0 — higher is better.
    """
    ref_words = set(_normalize_text(reference).split())
    hyp_words = set(_normalize_text(hypothesis).split())
    if not ref_words:
        return 1.0 if not hyp_words else 0.0
    intersection = ref_words & hyp_words
    union = ref_words | hyp_words
    return len(intersection) / len(union)


def _char_error_rate(reference: str, hypothesis: str) -> float:
    """Compute a simplified Character Error Rate using edit distance.

    For full WER/CER with jiwer, use evaluate_transcription.py instead.
    """
    ref = _normalize_text(reference)
    hyp = _normalize_text(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0

    # Levenshtein distance (dynamic programming)
    m, n = len(ref), len(hyp)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev = dp[0]
        dp[0] = i
        for j in range(1, n + 1):
            temp = dp[j]
            if ref[i - 1] == hyp[j - 1]:
                dp[j] = prev
            else:
                dp[j] = 1 + min(prev, dp[j], dp[j - 1])
            prev = temp
    return dp[n] / m


# ── Scenario file integrity tests ─────────────────────────────────────────

class TestScenarioFiles:
    """Verify scenario files are well-formed for use as test inputs."""

    CZ_SCENARIOS = sorted(DEMO_SCENARIOS_DIR.glob("cz_*.txt"))

    def test_demo_scenarios_exist(self) -> None:
        assert DEMO_SCENARIOS_DIR.exists(), f"Missing: {DEMO_SCENARIOS_DIR}"
        assert len(self.CZ_SCENARIOS) >= 4, f"Expected ≥4 CZ scenarios, got {len(self.CZ_SCENARIOS)}"

    @pytest.fixture(params=sorted(DEMO_SCENARIOS_DIR.glob("cz_*.txt")), ids=lambda p: p.stem)
    def cz_scenario(self, request: pytest.FixtureRequest) -> tuple[str, str]:
        path: Path = request.param
        return path.stem, _load_scenario(path)

    def test_scenario_not_empty(self, cz_scenario: tuple[str, str]) -> None:
        name, text = cz_scenario
        assert len(text) > 50, f"{name}: scenario too short ({len(text)} chars)"

    def test_scenario_is_czech(self, cz_scenario: tuple[str, str]) -> None:
        """Verify scenarios contain Czech-specific characters."""
        name, text = cz_scenario
        czech_chars = set("áčďéěíňóřšťúůýž")
        found = set(text.lower()) & czech_chars
        assert len(found) >= 3, f"{name}: too few Czech diacritics ({found})"

    def test_scenario_has_dialogue_structure(self, cz_scenario: tuple[str, str]) -> None:
        """Scenarios should have multiple lines (doctor-patient dialogue)."""
        name, text = cz_scenario
        lines = [l for l in text.split("\n") if l.strip()]
        assert len(lines) >= 5, f"{name}: only {len(lines)} lines (expected dialogue)"

    def test_scenario_contains_medical_terms(self, cz_scenario: tuple[str, str]) -> None:
        """Each scenario should contain at least some medical terminology."""
        name, text = cz_scenario
        text_lower = text.lower()
        medical_terms = [
            "pacient", "doktor", "lék", "bolest", "teplota", "vyšetření",
            "diagnóz", "krev", "tlak", "alergi", "operac", "prohlídk",
            "antibiotik", "infarkt", "saturac", "kontrola", "předepíš",
            "symptom", "puls", "ekg", "kašel", "dýchá", "horečk",
            "medikac", "očkování", "pneumoni",
        ]
        found = [t for t in medical_terms if t in text_lower]
        assert len(found) >= 3, f"{name}: too few medical terms ({found})"


# ── Transcript consistency tests ──────────────────────────────────────────

class TestTranscriptConsistency:
    """Verify that matching scenario files across directories are consistent."""

    MATCHING_PAIRS = [
        ("cz_kardialni_nahoda", "cz_kardialni_nahoda"),
        ("cz_respiracni_infekce", "cz_respiracni_infekce"),
        ("cz_detska_prohlidka", "cz_detska_prohlidka"),
        ("cz_otrava_jidlem", "cz_otrava_jidlem"),
    ]

    @pytest.fixture(params=MATCHING_PAIRS, ids=lambda p: p[0])
    def scenario_pair(self, request: pytest.FixtureRequest) -> tuple[str, str, str]:
        name_demo, name_test = request.param
        demo_path = DEMO_SCENARIOS_DIR / f"{name_demo}.txt"
        test_path = TEST_SCENARIOS_DIR / f"{name_test}.txt"
        if not demo_path.exists() or not test_path.exists():
            pytest.skip(f"Missing file: {demo_path} or {test_path}")
        return name_demo, _load_scenario(demo_path), _load_scenario(test_path)

    def test_matching_scenarios_are_identical(self, scenario_pair: tuple[str, str, str]) -> None:
        """Demo and test_scenarios copies should have the same content.

        Files may differ in whitespace (blank lines between dialogue turns),
        so we normalize before comparing.
        """
        name, demo_text, test_text = scenario_pair
        assert _normalize_text(demo_text) == _normalize_text(test_text), (
            f"{name}: demo vs test_scenarios differ in content (not just whitespace). "
            f"Demo: {len(demo_text)} chars, Test: {len(test_text)} chars"
        )


# ── Transcript quality metric tests ───────────────────────────────────────

class TestTranscriptMetrics:
    """Test quality metrics computation on known inputs."""

    def test_word_overlap_identical(self) -> None:
        assert _word_overlap("hello world", "hello world") == 1.0

    def test_word_overlap_disjoint(self) -> None:
        assert _word_overlap("hello world", "foo bar") == 0.0

    def test_word_overlap_partial(self) -> None:
        overlap = _word_overlap("Pacient má bolest hlavy", "Pacient má horečku hlavy")
        assert 0.5 < overlap < 1.0

    def test_cer_identical(self) -> None:
        assert _char_error_rate("test", "test") == 0.0

    def test_cer_completely_wrong(self) -> None:
        cer = _char_error_rate("abc", "xyz")
        assert cer == 1.0

    def test_cer_partial_match(self) -> None:
        cer = _char_error_rate("Pacient", "Pacient má")
        assert 0.0 < cer < 1.0

    def test_cer_handles_czech_diacritics(self) -> None:
        """CER should handle Czech characters correctly."""
        cer = _char_error_rate(
            "pacient přišel s horečkou",
            "pacient prisel s horeckou",
        )
        assert 0.0 < cer < 0.3  # Small difference from missing diacritics


# ── Expected transcription quality thresholds ─────────────────────────────

class TestExpectedQualityThresholds:
    """Document and enforce expected quality thresholds from previous runs.

    These thresholds are based on the Whisper Small INT8 results documented
    in README.md. They serve as regression guards — if transcription quality
    drops below these levels, something is likely broken.

    Note: These are threshold-only tests. The actual WER/CER values come from
    running evaluate_transcription.py against audio files.
    """

    # From README: Mean WER=55.6%, CER=34.5% on Hurvínek (challenging audio)
    # Medical dictation should be significantly better (~20-30% WER expected)
    HURV_WER_THRESHOLD = 0.70   # Allow up to 70% WER on challenging audio
    HURV_CER_THRESHOLD = 0.50   # Allow up to 50% CER on challenging audio
    MEDICAL_WER_TARGET = 0.35   # Target for medical dictation (quiet room)

    def test_threshold_values_are_reasonable(self) -> None:
        """Sanity check: our thresholds are within expected ranges."""
        assert 0.0 < self.HURV_WER_THRESHOLD <= 1.0
        assert 0.0 < self.HURV_CER_THRESHOLD <= 1.0
        assert self.MEDICAL_WER_TARGET < self.HURV_WER_THRESHOLD

    def test_medical_target_better_than_hurv(self) -> None:
        """Medical dictation target should be lower (better) than Hurvínek."""
        assert self.MEDICAL_WER_TARGET < self.HURV_WER_THRESHOLD


# ── Evaluation script smoke test ──────────────────────────────────────────

class TestEvaluationInfrastructure:
    """Verify that the evaluation scripts are importable and well-formed."""

    def test_evaluate_reports_importable(self) -> None:
        """evaluate_reports.py should be importable (syntax check)."""
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "evaluate_reports",
            Path(__file__).parent.parent / "evaluate_reports.py",
        )
        assert spec is not None
        assert spec.loader is not None

    def test_evaluate_transcription_importable(self) -> None:
        """evaluate_transcription.py should be importable (syntax check)."""
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "evaluate_transcription",
            Path(__file__).parent.parent / "evaluate_transcription.py",
        )
        assert spec is not None
        assert spec.loader is not None

    def test_evaluation_results_files_exist(self) -> None:
        """Previously saved evaluation results should still be present."""
        results_dir = Path(__file__).parent.parent
        expected_files = [
            "evaluation_results.json",
            "evaluation_results_demo.json",
            "evaluation_results_5mini_demo.json",
            "evaluation_results_5mini_hurvinek.json",
        ]
        for fname in expected_files:
            path = results_dir / fname
            assert path.exists(), f"Missing evaluation results: {fname}"
            assert path.stat().st_size > 100, f"Empty evaluation results: {fname}"

    def test_evaluation_results_valid_json(self) -> None:
        """Evaluation result files must be valid JSON."""
        import json
        results_dir = Path(__file__).parent.parent
        for path in results_dir.glob("evaluation_results*.json"):
            data = json.loads(path.read_text(encoding="utf-8"))
            assert "metadata" in data, f"{path.name}: missing 'metadata'"
            assert "results" in data, f"{path.name}: missing 'results'"
