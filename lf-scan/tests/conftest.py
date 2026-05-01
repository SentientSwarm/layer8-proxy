"""Shared pytest fixtures for lf-scan tests."""

import pytest
from fastapi.testclient import TestClient

from app import app


@pytest.fixture
def client() -> TestClient:
    return TestClient(app)
