"""lf-scan: thin FastAPI wrapper around llamafirewall library.

Designed to be deleted in agent-locksmith M8 once inline scanners ship.
"""

from importlib.metadata import version as pkg_version

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="lf-scan", version="0.1.0")


class HealthResponse(BaseModel):
    status: str
    llamafirewall_version: str
    scanners_loaded: list[str]


def _loaded_scanner_names() -> list[str]:
    """Return the scanner identifiers configured at startup."""
    return ["promptguard", "codeshield"]


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        llamafirewall_version=pkg_version("llamafirewall"),
        scanners_loaded=_loaded_scanner_names(),
    )
