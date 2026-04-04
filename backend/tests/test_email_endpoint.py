"""Tests for the /send-report-email endpoint."""
import httpx

BASE = "http://localhost:8111"
TOKEN = "Bearer dev-token"


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
