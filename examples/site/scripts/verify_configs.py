"""Validate canonical tool definitions and the rendered output.

Run before `docker compose up`. Refuses the deploy if locksmith and
pipelock would be out of alignment.
"""

from __future__ import annotations

import argparse
import fnmatch
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import yaml


class AlignmentError(ValueError):
    """Raised when a proxied tool's host is not allowed by pipelock."""


class SecretResolutionError(ValueError):
    """Raised when a tool references a secret that does not exist."""


class DuplicateToolError(ValueError):
    """Raised when two tools share a name."""


class RedactionPatternError(ValueError):
    """Raised when a redaction pattern is not valid regex."""


def check_no_duplicate_tools(canonical_tools: list[dict[str, Any]]) -> None:
    seen: set[str] = set()
    for tool in canonical_tools:
        if tool["name"] in seen:
            raise DuplicateToolError(f"duplicate tool name: {tool['name']}")
        seen.add(tool["name"])


def check_redaction_patterns(canonical_tools: list[dict[str, Any]]) -> None:
    for tool in canonical_tools:
        patterns = tool.get("response", {}).get("redaction_patterns", [])
        for entry in patterns:
            try:
                re.compile(entry["pattern"])
            except re.error as exc:
                raise RedactionPatternError(
                    f"tool {tool['name']!r}: redaction pattern {entry['id']!r} invalid: {exc}"
                ) from exc


_SECRET_REF_PREFIX = "secret_ref://"


def check_secret_references(
    canonical_tools: list[dict[str, Any]], secrets_dir: Path
) -> None:
    """Raise SecretResolutionError if any tool references a missing secret file."""
    for tool in canonical_tools:
        value = tool.get("auth", {}).get("value")
        if not isinstance(value, str) or not value.startswith(_SECRET_REF_PREFIX):
            continue
        secret_name = value[len(_SECRET_REF_PREFIX) :]
        candidates = [
            secrets_dir / f"{secret_name}.creds",
            secrets_dir / f"{secret_name}.cred",
        ]
        if not any(c.exists() for c in candidates):
            raise SecretResolutionError(
                f"tool {tool['name']!r}: secret {secret_name!r} not found in {secrets_dir}"
            )


def _matches_pipelock_pattern(host: str, pattern: str) -> bool:
    """Pipelock supports * wildcards (e.g., *.example.com)."""
    return fnmatch.fnmatchcase(host, pattern)


def check_alignment(
    canonical_tools: list[dict[str, Any]], pipelock_allowlist: list[str]
) -> None:
    """Raise AlignmentError if any proxied tool's host is not allowed."""
    for tool in canonical_tools:
        if tool.get("egress") != "proxied":
            continue
        host = urlparse(tool["upstream"]).hostname
        if host is None:
            raise AlignmentError(
                f"tool {tool['name']!r}: upstream {tool['upstream']!r} has no hostname"
            )
        if not any(_matches_pipelock_pattern(host, pat) for pat in pipelock_allowlist):
            raise AlignmentError(
                f"tool {tool['name']!r}: host {host!r} not in pipelock allowlist"
            )


def _load_canonical_tools(tools_dir: Path) -> list[dict[str, Any]]:
    """Load tools/*.yaml; tolerate a missing directory (Phase E.8+).

    Post-Phase-E sites that rely entirely on the locksmith seed catalog
    + admin-API overrides may omit `tools/` entirely. Sites still in
    the transition keep their pre-Phase-E entries for the legacy
    bootstrap path to migrate.
    """
    if not tools_dir.exists():
        return []
    tools: list[dict[str, Any]] = []
    for yaml_path in sorted(tools_dir.glob("*.yaml")):
        if yaml_path.name.startswith("_"):
            continue
        with yaml_path.open() as f:
            tools.append(yaml.safe_load(f))
    return tools


def _load_yaml(path: Path) -> dict[str, Any]:
    with path.open() as f:
        return yaml.safe_load(f) or {}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", required=True, type=Path)
    parser.add_argument("--pipelock-config", required=True, type=Path)
    parser.add_argument("--pipelock-extras", required=True, type=Path)
    parser.add_argument("--secrets-dir", required=True, type=Path)
    args = parser.parse_args(argv)

    tools = _load_canonical_tools(args.tools_dir)
    base_allowlist = _load_yaml(args.pipelock_config).get("api_allowlist") or []
    extras = _load_yaml(args.pipelock_extras).get("api_allowlist_extras") or []
    full_allowlist = list(base_allowlist) + list(extras)

    errors: list[str] = []
    try:
        check_no_duplicate_tools(tools)
    except DuplicateToolError as exc:
        errors.append(str(exc))
    try:
        check_alignment(tools, full_allowlist)
    except AlignmentError as exc:
        errors.append(str(exc))
    try:
        check_secret_references(tools, args.secrets_dir)
    except SecretResolutionError as exc:
        errors.append(str(exc))
    try:
        check_redaction_patterns(tools)
    except RedactionPatternError as exc:
        errors.append(str(exc))

    if errors:
        for e in errors:
            print(f"✗ {e}", file=sys.stderr)
        return 1

    if tools:
        print(f"✓ {len(tools)} tools verified.")
    else:
        print(
            "✓ no site-local tools/ entries (locksmith seed catalog supplies the "
            "default registrations; operator override via admin API)."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
