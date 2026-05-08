"""Tests for the /send-report-email endpoint.

Includes:
- Pure-unit body-composition tests for ``_build_email_body`` (TASK-0037).
  These run without any network or running server.
- Integration tests against a live backend on ``localhost:8111`` for the
  health / SMTP / auth / validation paths.
"""
import sys
from pathlib import Path

import httpx

# Make the backend package importable when running pytest from repo root.
_BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(_BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(_BACKEND_DIR))

from main import _build_email_body  # noqa: E402

BASE = "http://localhost:8111"
TOKEN = "Bearer dev-token"


# ---------------------------------------------------------------------------
# Pure-unit body composition tests (no server required) — TASK-0037 / SPEC-0037
# ---------------------------------------------------------------------------

_TODAY = "02. 05. 2026"
_VT_LABEL = "Vstupn\u00ed vy\u0161et\u0159en\u00ed"
_REPORT = "Lékařská zpráva...\nNO: bolest hlavy"
_TRANSCRIPT = "Pacient si stěžuje na bolest hlavy."


def test_build_email_body_with_transcript():
    """AC2: transcript first under '--- Přepis ---', report below under
    '--- Lékařská zpráva ---'. Both inline plain-text in the same body."""
    body = _build_email_body(_REPORT, _TRANSCRIPT, _TODAY, _VT_LABEL)

    # Both Czech section headings present, with the exact spec wording.
    assert "--- P\u0159epis ---" in body
    assert "--- L\u00e9ka\u0159sk\u00e1 zpr\u00e1va ---" in body

    # Order: Přepis heading must come before report heading.
    assert body.index("--- P\u0159epis ---") < body.index(
        "--- L\u00e9ka\u0159sk\u00e1 zpr\u00e1va ---"
    )

    # Both contents inline in the body, transcript before report.
    assert _TRANSCRIPT in body
    assert _REPORT in body
    assert body.index(_TRANSCRIPT) < body.index(_REPORT)

    # Header / footer preserved.
    assert body.startswith(
        "L\u00e9ka\u0159sk\u00e1 zpr\u00e1va vygenerovan\u00e1 aplikac\u00ed ANOTE\n"
    )
    assert body.endswith(
        "Tato zpr\u00e1va byla automaticky odesl\u00e1na aplikac\u00ed ANOTE.\n"
    )
    print("PASS: body composition with transcript")


def test_build_email_body_without_transcript():
    """AC3: empty/missing transcript -> body is byte-for-byte identical to
    the pre-TASK-0037 layout (no Přepis section, no extra blank lines)."""
    expected = (
        "L\u00e9ka\u0159sk\u00e1 zpr\u00e1va vygenerovan\u00e1 aplikac\u00ed ANOTE\n"
        f"Datum: {_TODAY}\n"
        f"Typ n\u00e1v\u0161t\u011bvy: {_VT_LABEL}\n"
        "\n---\n\n"
        f"{_REPORT}\n"
        "\n---\n"
        "Tato zpr\u00e1va byla automaticky odesl\u00e1na aplikac\u00ed ANOTE.\n"
    )
    assert _build_email_body(_REPORT, "", _TODAY, _VT_LABEL) == expected
    # Whitespace-only transcript also collapses to today's exact body.
    assert _build_email_body(_REPORT, "   \n  ", _TODAY, _VT_LABEL) == expected
    # Extra sanity: no Přepis heading leaked in.
    assert "P\u0159epis" not in expected
    print("PASS: body composition without transcript (backwards-compatible)")


# ---------------------------------------------------------------------------
# Integration tests (require a backend running on localhost:8111).
# ---------------------------------------------------------------------------


def test_health():
    r = httpx.get(f"{BASE}/health")
    assert r.status_code == 200
    print("PASS: health =>", r.json())


def test_send_email_no_smtp():
    """Valid request but SMTP not configured => 502."""
    r = httpx.post(
        f"{BASE}/send-report-email",
        json={"report": "Test report text", "email": "test@example.com", "visit_type": "initial"},
        headers={"Authorization": TOKEN},
    )
    assert r.status_code == 502, f"Expected 502, got {r.status_code}: {r.text}"
    assert "Email not configured" in r.json()["detail"]
    print("PASS: no SMTP => 502:", r.json()["detail"])


def test_send_email_empty_report():
    r = httpx.post(
        f"{BASE}/send-report-email",
        json={"report": "", "email": "test@example.com"},
        headers={"Authorization": TOKEN},
    )
    assert r.status_code == 400, f"Expected 400, got {r.status_code}: {r.text}"
    print("PASS: empty report => 400:", r.json()["detail"])


def test_send_email_invalid_email():
    r = httpx.post(
        f"{BASE}/send-report-email",
        json={"report": "Some report", "email": "not-an-email"},
        headers={"Authorization": TOKEN},
    )
    assert r.status_code == 400, f"Expected 400, got {r.status_code}: {r.text}"
    print("PASS: bad email => 400:", r.json()["detail"])


def test_send_email_no_auth():
    r = httpx.post(
        f"{BASE}/send-report-email",
        json={"report": "Some report", "email": "test@example.com"},
    )
    assert r.status_code == 422 or r.status_code == 401, f"Expected 401/422, got {r.status_code}"
    print(f"PASS: no auth => {r.status_code}")


def test_send_email_wrong_token():
    r = httpx.post(
        f"{BASE}/send-report-email",
        json={"report": "Some report", "email": "test@example.com"},
        headers={"Authorization": "Bearer wrong-token"},
    )
    assert r.status_code == 401, f"Expected 401, got {r.status_code}: {r.text}"
    print("PASS: wrong token => 401")


if __name__ == "__main__":
    test_health()
    test_send_email_no_smtp()
    test_send_email_empty_report()
    test_send_email_invalid_email()
    test_send_email_no_auth()
    test_send_email_wrong_token()
    print("\n=== ALL TESTS PASSED ===")
