"""Tests for the ANOTE backend /report and /health endpoints."""

import os
from typing import Any
from unittest.mock import MagicMock, patch

# Set environment variables before importing main so module-level initialisation
# (AzureOpenAI client, API_TOKEN) succeeds without real credentials.
os.environ.setdefault("AZURE_OPENAI_KEY", "test-key")
os.environ.setdefault("AZURE_OPENAI_ENDPOINT", "https://test.openai.azure.com")
os.environ.setdefault("AZURE_OPENAI_DEPLOYMENT", "gpt-4o-mini")
os.environ.setdefault("APP_API_TOKEN", "test-token")

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from main import app  # noqa: E402

VALID_TOKEN = "test-token"
AUTH_HEADER = {"Authorization": f"Bearer {VALID_TOKEN}"}


def _make_mock_completion(content: str) -> Any:
    """Create a minimal mock object that mimics an OpenAI chat completion response.

    Args:
        content: The text content to place in ``choices[0].message.content``.

    Returns:
        A :class:`~unittest.mock.MagicMock` shaped like an OpenAI response.
    """
    mock_response = MagicMock()
    mock_response.choices[0].message.content = content
    return mock_response


@pytest.fixture()
def client() -> TestClient:
    """Return a synchronous TestClient wrapping the FastAPI app.

    Returns:
        :class:`~fastapi.testclient.TestClient` instance.
    """
    return TestClient(app)


# ---------------------------------------------------------------------------
# 1. Valid transcript + valid bearer token → 200
# ---------------------------------------------------------------------------

def test_report_valid_request(client: TestClient) -> None:
    """POST /report with a valid transcript and correct token returns 200 with a report."""
    mock_completion = _make_mock_completion("Structured Czech medical report text.")

    with patch("main.client.chat.completions.create", return_value=mock_completion):
        response = client.post(
            "/report",
            json={"transcript": "Pacient přišel s bolestí hlavy."},
            headers=AUTH_HEADER,
        )

    assert response.status_code == 200
    body = response.json()
    assert "report" in body
    assert len(body["report"]) > 0


# ---------------------------------------------------------------------------
# 2. Empty transcript → 400
# ---------------------------------------------------------------------------

def test_report_empty_transcript(client: TestClient) -> None:
    """POST /report with an empty transcript returns 400."""
    response = client.post(
        "/report",
        json={"transcript": ""},
        headers=AUTH_HEADER,
    )
    assert response.status_code == 400


# ---------------------------------------------------------------------------
# 3. Whitespace-only transcript → 400
# ---------------------------------------------------------------------------

def test_report_whitespace_transcript(client: TestClient) -> None:
    """POST /report with a whitespace-only transcript returns 400."""
    response = client.post(
        "/report",
        json={"transcript": "   \t\n  "},
        headers=AUTH_HEADER,
    )
    assert response.status_code == 400


# ---------------------------------------------------------------------------
# 4. Missing Authorization header → 401 or 422
# ---------------------------------------------------------------------------

def test_report_missing_auth_header(client: TestClient) -> None:
    """POST /report without an Authorization header returns 401 or 422."""
    response = client.post(
        "/report",
        json={"transcript": "Pacient má horečku."},
    )
    assert response.status_code in (401, 422)


# ---------------------------------------------------------------------------
# 5. Wrong bearer token → 401
# ---------------------------------------------------------------------------

def test_report_wrong_token(client: TestClient) -> None:
    """POST /report with an incorrect bearer token returns 401."""
    response = client.post(
        "/report",
        json={"transcript": "Pacient má horečku."},
        headers={"Authorization": "Bearer wrong-token"},
    )
    assert response.status_code == 401


# ---------------------------------------------------------------------------
# 6. GET /health → 200 {"status": "ok"}
# ---------------------------------------------------------------------------

def test_health_check(client: TestClient) -> None:
    """GET /health returns 200 with status ok (no authentication required)."""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


# ---------------------------------------------------------------------------
# 7. Azure OpenAI raises an exception → 502
# ---------------------------------------------------------------------------

def test_report_azure_openai_error(client: TestClient) -> None:
    """POST /report returns 502 when Azure OpenAI raises an exception."""
    with patch(
        "main.client.chat.completions.create",
        side_effect=Exception("Service unavailable"),
    ):
        response = client.post(
            "/report",
            json={"transcript": "Pacient má bolest v krku."},
            headers=AUTH_HEADER,
        )

    assert response.status_code == 502
    assert "Azure OpenAI error" in response.json()["detail"]
