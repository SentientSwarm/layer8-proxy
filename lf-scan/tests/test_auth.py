"""Tests for X-Internal-Token authentication."""

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def authed_client(monkeypatch):
    monkeypatch.setenv("LF_SCAN_INTERNAL_TOKEN", "test-token-xyz")
    import importlib

    import app as app_module

    importlib.reload(app_module)
    return TestClient(app_module.app)


def test_scan_input_requires_token(authed_client):
    response = authed_client.post(
        "/scan/input",
        json={
            "messages": [{"role": "user", "content": "hi"}],
            "scanners": ["promptguard"],
        },
    )
    assert response.status_code == 401


def test_scan_input_accepts_valid_token(authed_client):
    response = authed_client.post(
        "/scan/input",
        headers={"X-Internal-Token": "test-token-xyz"},
        json={
            "messages": [{"role": "user", "content": "hi"}],
            "scanners": ["promptguard"],
        },
    )
    assert response.status_code == 200


def test_scan_input_rejects_wrong_token(authed_client):
    response = authed_client.post(
        "/scan/input",
        headers={"X-Internal-Token": "wrong"},
        json={
            "messages": [{"role": "user", "content": "hi"}],
            "scanners": ["promptguard"],
        },
    )
    assert response.status_code == 401


def test_health_does_not_require_token(authed_client):
    """/health is reachable without a token so Docker healthchecks work."""
    response = authed_client.get("/health")
    assert response.status_code == 200
