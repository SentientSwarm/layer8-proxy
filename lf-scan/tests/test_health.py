"""Tests for the /health endpoint."""


def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"


def test_health_reports_scanner_inventory(client):
    response = client.get("/health")
    body = response.json()
    assert "scanners_loaded" in body
    assert isinstance(body["scanners_loaded"], list)


def test_health_reports_llamafirewall_version(client):
    response = client.get("/health")
    body = response.json()
    assert "llamafirewall_version" in body
    assert body["llamafirewall_version"]  # non-empty
