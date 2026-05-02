"""lf-scan: thin FastAPI wrapper around llamafirewall library.

Designed to be deleted in agent-locksmith M8 once inline scanners ship.
"""

import os
from importlib.metadata import version as pkg_version
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException
from llamafirewall import (
    AssistantMessage,
    LlamaFirewall,
    Role,
    ScanDecision,
    ScannerType,
    UserMessage,
)
from pydantic import BaseModel

app = FastAPI(title="lf-scan", version="0.1.0")


SUPPORTED_SCANNERS: dict[str, ScannerType] = {
    "promptguard": ScannerType.PROMPT_GUARD,
    "codeshield": ScannerType.CODE_SHIELD,
}


def require_internal_token(
    x_internal_token: Annotated[str | None, Header()] = None,
) -> None:
    expected = os.environ.get("LF_SCAN_INTERNAL_TOKEN")
    if expected and x_internal_token != expected:
        raise HTTPException(
            status_code=401, detail="invalid or missing X-Internal-Token"
        )


class HealthResponse(BaseModel):
    status: str
    llamafirewall_version: str
    scanners_loaded: list[str]


class Message(BaseModel):
    role: str
    content: str


class ScanRequest(BaseModel):
    messages: list[Message]
    scanners: list[str]


class ScanResponse(BaseModel):
    decision: str  # "ALLOW" | "BLOCK"
    scanners_triggered: list[str]
    reason: str


def _loaded_scanner_names() -> list[str]:
    """Return the scanner identifiers configured at startup."""
    return list(SUPPORTED_SCANNERS.keys())


def _validate_scanners(names: list[str]) -> list[ScannerType]:
    resolved: list[ScannerType] = []
    for name in names:
        if name not in SUPPORTED_SCANNERS:
            raise HTTPException(status_code=400, detail=f"unknown scanner: {name}")
        resolved.append(SUPPORTED_SCANNERS[name])
    return resolved


def _to_user_messages(messages: list[Message]) -> list[UserMessage]:
    return [UserMessage(content=m.content) for m in messages if m.role == "user"]


def _to_assistant_messages(messages: list[Message]) -> list[AssistantMessage]:
    return [
        AssistantMessage(content=m.content) for m in messages if m.role == "assistant"
    ]


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        llamafirewall_version=pkg_version("llamafirewall"),
        scanners_loaded=_loaded_scanner_names(),
    )


@app.post(
    "/scan/input",
    response_model=ScanResponse,
    dependencies=[Depends(require_internal_token)],
)
def scan_input(request: ScanRequest) -> ScanResponse:
    scanner_types = _validate_scanners(request.scanners)
    firewall = LlamaFirewall(scanners={Role.USER: scanner_types})
    lf_messages = _to_user_messages(request.messages)

    for msg in lf_messages:
        result = firewall.scan(msg)
        # Treat anything other than ALLOW as a scan-blocker (BLOCK or
        # HUMAN_IN_THE_LOOP_REQUIRED both surface as BLOCK to the agent).
        if result.decision != ScanDecision.ALLOW:
            return ScanResponse(
                decision="BLOCK",
                scanners_triggered=list(request.scanners),
                reason=getattr(result, "reason", None) or "scanner blocked input",
            )

    return ScanResponse(decision="ALLOW", scanners_triggered=[], reason="")


@app.post(
    "/scan/output",
    response_model=ScanResponse,
    dependencies=[Depends(require_internal_token)],
)
def scan_output(request: ScanRequest) -> ScanResponse:
    scanner_types = _validate_scanners(request.scanners)
    firewall = LlamaFirewall(scanners={Role.ASSISTANT: scanner_types})
    lf_messages = _to_assistant_messages(request.messages)

    for msg in lf_messages:
        result = firewall.scan(msg)
        if result.decision != ScanDecision.ALLOW:
            return ScanResponse(
                decision="BLOCK",
                scanners_triggered=list(request.scanners),
                reason=getattr(result, "reason", None) or "scanner blocked output",
            )

    return ScanResponse(decision="ALLOW", scanners_triggered=[], reason="")
