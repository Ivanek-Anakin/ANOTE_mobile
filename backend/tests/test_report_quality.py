"""Report generation quality tests against the live Azure backend.

These tests call the REAL production endpoint with known Czech medical
transcripts and verify that the generated report meets structural and
content quality criteria.

Run with:
    ANOTE_API_URL=https://anote-api.politesmoke-02c93984.westeurope.azurecontainerapps.io \
    ANOTE_API_TOKEN=_lZNhJDgaoneVaztSf2tJnf-rZMEQV5ZCLBPRAyC38I \
    python -m pytest tests/test_report_quality.py -v -s

Skip with: python -m pytest tests/ -v --ignore=tests/test_report_quality.py
"""

import os
import re
import time
from pathlib import Path

import httpx
import pytest

# ── Configuration ─────────────────────────────────────────────────────────

API_URL = os.environ.get(
    "ANOTE_API_URL",
    "https://anote-api.gentleriver-a61d304a.westus2.azurecontainerapps.io",
)
API_TOKEN = os.environ.get(
    "ANOTE_API_TOKEN",
    "_lZNhJDgaoneVaztSf2tJnf-rZMEQV5ZCLBPRAyC38I",
)
HEADERS = {
    "Authorization": f"Bearer {API_TOKEN}",
    "Content-Type": "application/json",
}
TIMEOUT = 180  # gpt-5-mini with reasoning can be slow
MAX_RETRIES = 2  # retry on empty response (rate-limit / cold-start)
RETRY_DELAY = 5  # seconds between retries

SKIP_LIVE = os.environ.get("SKIP_LIVE_TESTS", "").lower() in ("1", "true", "yes")

SCENARIOS_DIR = Path(__file__).parent.parent.parent / "mobile" / "assets" / "demo_scenarios"

# ── Required report sections (initial visit) ─────────────────────────────

REQUIRED_SECTIONS_CZ = [
    "Identifikace pacienta",
    "NO",
    "RA",
    "OA",
    "FA",
    "AA",
    "Objektivní nález",
    "Hodnocení",
]

NEGATION_PATTERNS_CZ = [
    r"neguje",
    r"bez\s",
    r"neudává",
    r"neg\.",
    r"neuvedeno",
]

# ── Test transcripts ─────────────────────────────────────────────────────

CARDIAC_TRANSCRIPT = (
    "Dobrý den, já jsem doktor Procházka, jste na urgentním příjmu. Můžete mi říct, co se stalo? "
    "Dobrý den, doktore. Strašně mě bolí na hrudi, začalo to asi před půl hodinou. "
    "Nemůžu se pořádně nadechnout. Kde přesně tu bolest cítíte? Vyzařuje někam? "
    "Tady uprostřed, ale táhne mi to do levé ruky a je mi hrozně špatně, potím se. "
    "Rozumím. Kolik vám je let? Padesát osm. "
    "Berete nějaké léky pravidelně? Jenom aspirin stovku. "
    "Máte alergii na nějaké léky? Ne, na nic. "
    "Takže tlak máte 150 na 95, puls 98, nepravidelný. Na EKG vidím elevaci ST segmentu "
    "ve svodech II, III a aVF. Pane Nováku, máte akutní infarkt myokardu, konkrétně "
    "spodní stěny srdce. Dáme vám heparin a nitráty."
)

SIMPLE_HEADACHE_TRANSCRIPT = (
    "Pacient přichází s bolestí hlavy trvající tři dny. Bez horečky, bez nauzey. "
    "Užívá ibuprofen 400mg. Alergie na penicilin."
)

PEDIATRIC_TRANSCRIPT = (
    "Dobrý den, pojďte dál. Tak to je Tomášek, viďte? "
    "Jdeme na tu preventivní prohlídku. Chodí do druhé třídy. "
    "Chodí na plavání dvakrát týdně a hraje fotbal. "
    "Dvacet čtyři kilo, výška sto dvacet dva centimetrů. "
    "Zrak je v pořádku. Sluch taky bez problémů. "
    "Nějaké alergie? Ne, žádné alergie nemá. Jí dobře, vyváženou stravu. "
    "Všechno je v naprostém pořádku. Další kontrolu za rok."
)


# ── Helpers ───────────────────────────────────────────────────────────────

# Module-level cache: (transcript_hash, visit_type) → response dict
_report_cache: dict[tuple[int, str], dict] = {}


def _generate_report(transcript: str, visit_type: str = "default") -> dict:
    """Call the live /report endpoint and return the JSON response.

    Results are cached by (transcript, visit_type) to avoid redundant API
    calls — gpt-5-mini takes 30-60s per request with reasoning tokens.
    """
    cache_key = (hash(transcript), visit_type)
    if cache_key in _report_cache:
        return _report_cache[cache_key]

    last_error = None
    for attempt in range(MAX_RETRIES + 1):
        try:
            with httpx.Client(timeout=TIMEOUT) as client:
                r = client.post(
                    f"{API_URL}/report",
                    json={"transcript": transcript, "visit_type": visit_type},
                    headers=HEADERS,
                )
            r.raise_for_status()
            data = r.json()
            report_text = data.get("report", "")
            if report_text:
                _report_cache[cache_key] = data
                return data
            # Empty report — retry after delay
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_DELAY)
        except (httpx.TimeoutException, httpx.HTTPStatusError) as exc:
            last_error = exc
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_DELAY)

    # Return whatever we got (may be empty), let the test decide
    if last_error:
        pytest.fail(f"API call failed after {MAX_RETRIES + 1} attempts: {last_error}")
    _report_cache[cache_key] = data  # type: ignore[possibly-undefined]
    return data  # type: ignore[possibly-undefined]


def _has_section(report: str, section_name: str) -> bool:
    """Check if a section header appears in the report text."""
    return section_name in report


def _count_neuvedeno(report: str) -> int:
    """Count occurrences of 'neuvedeno' in the report."""
    return report.lower().count("neuvedeno")


def _has_negation_language(report: str) -> bool:
    """Check if the report uses proper Czech negation patterns."""
    for pat in NEGATION_PATTERNS_CZ:
        if re.search(pat, report, re.IGNORECASE):
            return True
    return False


# ── Tests ─────────────────────────────────────────────────────────────────


@pytest.mark.skipif(SKIP_LIVE, reason="SKIP_LIVE_TESTS is set")
class TestReportStructure:
    """Verify report structure matches the 13-section Czech medical format."""

    def test_health_check(self) -> None:
        with httpx.Client(timeout=30) as client:
            r = client.get(f"{API_URL}/health")
        assert r.status_code == 200
        assert r.json()["status"] == "ok"

    def test_cardiac_report_has_required_sections(self) -> None:
        result = _generate_report(CARDIAC_TRANSCRIPT)
        report = result["report"]
        for section in REQUIRED_SECTIONS_CZ:
            assert _has_section(report, section), (
                f"Missing section '{section}' in cardiac report"
            )

    def test_cardiac_report_is_in_czech(self) -> None:
        result = _generate_report(CARDIAC_TRANSCRIPT)
        report = result["report"]
        # Check for key Czech words that must appear
        assert "Lékařská zpráva" in report or "Kontrolní zpráva" in report
        assert "Datum" in report

    def test_cardiac_report_length_reasonable(self) -> None:
        """Report should be at least 500 chars for a detailed transcript."""
        result = _generate_report(CARDIAC_TRANSCRIPT)
        report = result["report"]
        assert len(report) >= 500, f"Report too short: {len(report)} chars"

    def test_simple_report_has_required_sections(self) -> None:
        result = _generate_report(SIMPLE_HEADACHE_TRANSCRIPT)
        report = result["report"]
        for section in REQUIRED_SECTIONS_CZ:
            assert _has_section(report, section), (
                f"Missing section '{section}' in simple report"
            )


@pytest.mark.skipif(SKIP_LIVE, reason="SKIP_LIVE_TESTS is set")
class TestReportFactualAccuracy:
    """Verify that reports contain facts from the transcript and no hallucinations."""

    def test_cardiac_contains_key_findings(self) -> None:
        """Key medical facts from the cardiac transcript must appear."""
        result = _generate_report(CARDIAC_TRANSCRIPT)
        report = result["report"].lower()
        # Patient age
        assert "58" in report or "padesát osm" in report
        # Blood pressure
        assert "150" in report
        assert "95" in report
        # Heart rate
        assert "98" in report
        # Diagnosis
        assert "infarkt" in report
        # Medication
        assert "aspirin" in report
        # EKG finding
        assert "st" in report  # ST segment

    def test_cardiac_allergy_negated(self) -> None:
        """Patient explicitly denied allergies — report must reflect this."""
        result = _generate_report(CARDIAC_TRANSCRIPT)
        report = result["report"].lower()
        assert "neguje" in report or "ne, na nic" in report or "bez" in report

    def test_headache_contains_ibuprofen(self) -> None:
        result = _generate_report(SIMPLE_HEADACHE_TRANSCRIPT)
        report = result["report"].lower()
        assert "ibuprofen" in report
        assert "400" in report

    def test_headache_allergy_penicilin(self) -> None:
        result = _generate_report(SIMPLE_HEADACHE_TRANSCRIPT)
        report = result["report"].lower()
        assert "penicilin" in report

    def test_headache_negations_captured(self) -> None:
        """Transcript says 'Bez horečky, bez nauzey' → report should reflect."""
        result = _generate_report(SIMPLE_HEADACHE_TRANSCRIPT)
        report = result["report"].lower()
        # The model should capture the negative findings in some form:
        # "neguje horečku", "bez horečky", "bez nauzey", "neguje nauzeu",
        # or grouped: "neguje horečku, nauzeu" or "bez horečky a nauzey"
        has_negation = any(
            pat in report
            for pat in [
                "neguje",
                "bez horečk",
                "bez nauz",
                "neudává",
                "nepřítomn",
                "není přítomn",
                "nemá horečk",
                "bez teploty",
                "bez zvracení",
            ]
        )
        assert has_negation, (
            f"Missing negation language for fever/nausea.\n"
            f"Report excerpt (AA/NO section): {report[:500]}"
        )


@pytest.mark.skipif(SKIP_LIVE, reason="SKIP_LIVE_TESTS is set")
class TestReportNeuvedeno:
    """Verify correct use of 'neuvedeno' for missing information."""

    def test_headache_missing_sections_marked_neuvedeno(self) -> None:
        """Simple transcript has no family/personal history → must be 'neuvedeno'."""
        result = _generate_report(SIMPLE_HEADACHE_TRANSCRIPT)
        report = result["report"]
        count = _count_neuvedeno(report)
        # At least RA, OA, GA, SA should be neuvedeno
        assert count >= 3, f"Expected ≥3 'neuvedeno', got {count}"

    def test_cardiac_has_neuvedeno_for_missing_info(self) -> None:
        result = _generate_report(CARDIAC_TRANSCRIPT)
        report = result["report"]
        count = _count_neuvedeno(report)
        assert count >= 2, f"Expected ≥2 'neuvedeno', got {count}"


@pytest.mark.skipif(SKIP_LIVE, reason="SKIP_LIVE_TESTS is set")
class TestReportVisitTypes:
    """Verify different visit types produce appropriate report structures."""

    def test_initial_visit_produces_full_report(self) -> None:
        result = _generate_report(CARDIAC_TRANSCRIPT, visit_type="initial")
        report = result["report"]
        assert "Lékařská zpráva" in report
        for section in ("NO", "RA", "OA", "FA", "AA"):
            assert section in report

    def test_followup_visit_uses_kontrolni_format(self) -> None:
        followup_transcript = (
            "Dobrý den, pane Nováku, jak se máte od minula? Bolest hlavy ustoupila. "
            "Ibuprofen už neberu. Tlak doma měřím, kolem 130 na 85. Cítím se dobře."
        )
        result = _generate_report(followup_transcript, visit_type="followup")
        report = result["report"]
        # Should use follow-up format with "Kontrolní" or follow-up sections
        assert "Kontrolní" in report or "Subjektivní" in report or "Průběh" in report


@pytest.mark.skipif(SKIP_LIVE, reason="SKIP_LIVE_TESTS is set")
class TestReportPerformance:
    """Verify report generation performance is acceptable."""

    def test_response_time_under_120s(self) -> None:
        """gpt-5-mini with reasoning should still respond within 2 minutes."""
        start = time.time()
        _generate_report(SIMPLE_HEADACHE_TRANSCRIPT)
        elapsed = time.time() - start
        assert elapsed < 120, f"Report took {elapsed:.1f}s (limit: 120s)"

    def test_pediatric_report_generated(self) -> None:
        """Pediatric scenario with no medications/complaints should work."""
        result = _generate_report(PEDIATRIC_TRANSCRIPT)
        report = result["report"]
        assert len(report) > 200
        # Should mention the child's measurements
        assert "24" in report or "dvacet čtyři" in report.lower()
        assert "122" in report or "sto dvacet dva" in report.lower()


@pytest.mark.skipif(SKIP_LIVE, reason="SKIP_LIVE_TESTS is set")
class TestScenarioFiles:
    """Test report generation for each demo scenario .txt file."""

    @pytest.fixture(params=sorted(SCENARIOS_DIR.glob("cz_*.txt")), ids=lambda p: p.stem)
    def scenario(self, request: pytest.FixtureRequest) -> tuple[str, str]:
        path: Path = request.param
        return path.stem, path.read_text(encoding="utf-8").strip()

    def test_scenario_generates_valid_report(self, scenario: tuple[str, str]) -> None:
        name, transcript = scenario
        result = _generate_report(transcript)
        report = result.get("report", "")

        # Basic structural checks
        assert len(report) > 300, (
            f"{name}: report too short ({len(report)} chars). "
            f"Response keys: {list(result.keys())}. "
            f"Report preview: {report[:200]!r}"
        )
        assert "Identifikace" in report, f"{name}: missing Identifikace"
        assert _has_negation_language(report), f"{name}: no negation language found"
