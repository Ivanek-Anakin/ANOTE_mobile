"""Comprehensive tests for ANOTE backend endpoints.

Extends the existing test_report_endpoint.py with additional edge cases:
- Visit-type routing
- Scenario listing and test-report
- Long transcript handling
- Content-type validation
- GDPR: no transcript in error messages
"""

import os
from typing import Any
from unittest.mock import MagicMock, patch

os.environ.setdefault("AZURE_OPENAI_KEY", "test-key")
os.environ.setdefault("AZURE_OPENAI_ENDPOINT", "https://test.openai.azure.com")
os.environ.setdefault("AZURE_OPENAI_DEPLOYMENT", "gpt-5-mini")
os.environ.setdefault("APP_API_TOKEN", "test-token")

import pytest
from fastapi.testclient import TestClient

from main import app

VALID_TOKEN = "test-token"
AUTH = {"Authorization": f"Bearer {VALID_TOKEN}"}


def _mock_completion(content: str) -> Any:
    mock = MagicMock()
    mock.choices[0].message.content = content
    return mock


@pytest.fixture()
def client() -> TestClient:
    return TestClient(app)


# ── Visit-type routing ────────────────────────────────────────────────────

class TestVisitTypeRouting:
    """POST /report respects the visit_type field."""

    def test_default_visit_type(self, client: TestClient) -> None:
        with patch("main.client.chat.completions.create", return_value=_mock_completion("report")):
            r = client.post("/report", json={"transcript": "test", "visit_type": "default"}, headers=AUTH)
        assert r.status_code == 200

    def test_initial_visit_type(self, client: TestClient) -> None:
        with patch("main.client.chat.completions.create", return_value=_mock_completion("report")):
            r = client.post("/report", json={"transcript": "test", "visit_type": "initial"}, headers=AUTH)
        assert r.status_code == 200

    def test_followup_visit_type(self, client: TestClient) -> None:
        with patch("main.client.chat.completions.create", return_value=_mock_completion("report")):
            r = client.post("/report", json={"transcript": "test", "visit_type": "followup"}, headers=AUTH)
        assert r.status_code == 200

    def test_invalid_visit_type_falls_back(self, client: TestClient) -> None:
        """Unknown visit_type should not error — falls back to default."""
        with patch("main.client.chat.completions.create", return_value=_mock_completion("report")):
            r = client.post("/report", json={"transcript": "test", "visit_type": "unknown"}, headers=AUTH)
        assert r.status_code == 200

    def test_missing_visit_type_uses_default(self, client: TestClient) -> None:
        """Omitting visit_type should work (defaults to 'default')."""
        with patch("main.client.chat.completions.create", return_value=_mock_completion("report")):
            r = client.post("/report", json={"transcript": "test"}, headers=AUTH)
        assert r.status_code == 200


# ── Scenario endpoints ────────────────────────────────────────────────────

class TestScenarioEndpoints:
    """GET /scenarios and POST /test-report/{name}."""

    def test_list_scenarios_returns_list(self, client: TestClient) -> None:
        r = client.get("/scenarios")
        assert r.status_code == 200
        data = r.json()
        assert "scenarios" in data
        assert isinstance(data["scenarios"], list)

    def test_list_scenarios_contains_known_files(self, client: TestClient) -> None:
        r = client.get("/scenarios")
        names = r.json()["scenarios"]
        for expected in ("cz_kardialni_nahoda", "cz_respiracni_infekce"):
            assert expected in names, f"Missing scenario: {expected}"

    def test_test_report_nonexistent_scenario(self, client: TestClient) -> None:
        r = client.post("/test-report/nonexistent_xyz", headers=AUTH)
        assert r.status_code == 404
        assert "nonexistent_xyz" in r.json()["detail"]

    def test_test_report_requires_auth(self, client: TestClient) -> None:
        r = client.post("/test-report/cz_kardialni_nahoda")
        assert r.status_code in (401, 422)

    def test_test_report_success_mock(self, client: TestClient) -> None:
        """In MOCK_MODE, test-report returns a mock but valid response."""
        with patch("main.MOCK_MODE", True):
            r = client.post("/test-report/cz_kardialni_nahoda", headers=AUTH)
        assert r.status_code == 200
        body = r.json()
        assert "scenario" in body
        assert "transcript" in body
        assert "report" in body
        assert body["scenario"] == "cz_kardialni_nahoda"


# ── Edge cases ────────────────────────────────────────────────────────────

class TestEdgeCases:
    """Boundary and edge-case tests."""

    def test_very_long_transcript(self, client: TestClient) -> None:
        """Backend should handle a very long transcript without crashing."""
        long_text = "Pacient udává bolest. " * 500  # ~10k chars
        with patch("main.client.chat.completions.create", return_value=_mock_completion("report")):
            r = client.post("/report", json={"transcript": long_text}, headers=AUTH)
        assert r.status_code == 200

    def test_unicode_czech_characters(self, client: TestClient) -> None:
        """Czech diacritics must be handled correctly."""
        transcript = "Pacient říká, že má žlučníkové obtíže. Předepsán měsíční penicilín."
        with patch("main.client.chat.completions.create", return_value=_mock_completion("zpráva")):
            r = client.post("/report", json={"transcript": transcript}, headers=AUTH)
        assert r.status_code == 200

    def test_transcript_with_only_newlines_is_rejected(self, client: TestClient) -> None:
        r = client.post("/report", json={"transcript": "\n\n\n"}, headers=AUTH)
        assert r.status_code == 400

    def test_missing_transcript_field(self, client: TestClient) -> None:
        r = client.post("/report", json={}, headers=AUTH)
        assert r.status_code == 422  # Pydantic validation error


# ── GDPR compliance ───────────────────────────────────────────────────────

class TestGDPR:
    """Ensure no patient data leaks in error responses."""

    def test_error_response_does_not_contain_transcript(self, client: TestClient) -> None:
        """When OpenAI fails, the error detail must NOT echo the patient transcript."""
        patient_text = "Pacient Novák má diabetes a užívá metformin 1000mg."
        with patch(
            "main.client.chat.completions.create",
            side_effect=Exception("API timeout"),
        ):
            r = client.post("/report", json={"transcript": patient_text}, headers=AUTH)
        assert r.status_code == 502
        detail = r.json()["detail"]
        assert "Novák" not in detail
        assert "metformin" not in detail
        assert "diabetes" not in detail


# ── Auth variants ─────────────────────────────────────────────────────────

class TestAuth:
    """Authentication edge cases."""

    def test_bearer_case_sensitive(self, client: TestClient) -> None:
        """Token comparison must be exact."""
        r = client.post(
            "/report",
            json={"transcript": "test"},
            headers={"Authorization": "bearer test-token"},  # lowercase 'bearer'
        )
        assert r.status_code == 401

    def test_extra_spaces_in_token_rejected(self, client: TestClient) -> None:
        r = client.post(
            "/report",
            json={"transcript": "test"},
            headers={"Authorization": "Bearer  test-token"},  # double space
        )
        assert r.status_code == 401
