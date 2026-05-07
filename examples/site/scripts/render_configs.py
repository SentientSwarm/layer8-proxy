"""Render canonical tool definitions into locksmith and pipelock configs.

Reads `tools/*.yaml` (if any exist), writes:
- `rendered/locksmith/tools.yaml` (may be `tools: []` post-Phase-E)
- `rendered/pipelock/allowlist-extras.yaml`

Single source of truth → two consumers. Keeps locksmith and pipelock in
strict alignment by construction.

Phase E.8 (v2.0.0+): the locksmith image now ships a curated seed
catalog (`/etc/locksmith/seed/catalog.yaml`) covering the common
providers — anthropic, openai, openrouter, ai-gateway, ollama,
lmstudio, tavily, github, duckduckgo, wikipedia, lf-scan. Operators
provide credentials via `.env` and override host-specific fields via
the admin API. The site's `tools/` directory is now optional: keep it
only for tools NOT in the seed catalog (or for operators who haven't
migrated to the admin-API workflow). Empty `tools/` is normal and
produces an empty `rendered/locksmith/tools.yaml`.

Canonical tool entries follow the agent-locksmith v1.1.0 schema (see
agent-locksmith/config.example.yaml). Pre-Phase-E entries are migrated
into the registrations table at daemon startup by a transitional
bootstrap shim — see `agent_locksmith::registrations::legacy_bootstrap`.

The renderer adds:
- duplicate-name detection (DuplicateToolError)
- pipelock allowlist derivation from `egress: proxied` upstreams
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import yaml


def _quote_strings(dumper, data):
    """Force all string scalars to double-quoted style.

    Locksmith's serde-based YAML parser is stricter than pyyaml's plain-scalar
    rules — it interprets unquoted scalars containing ${...} or other punctuation
    as candidate enum-tagged maps and rejects them as 'unit value'. Quoting all
    strings makes the legacy-string path unambiguous.
    """
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style='"')


_string_quote_dumper = yaml.SafeDumper
_string_quote_dumper.add_representer(str, _quote_strings)


def _safe_dump(data) -> str:
    return yaml.dump(data, Dumper=_string_quote_dumper, sort_keys=False)


class DuplicateToolError(ValueError):
    """Raised when two canonical tool entries share a name."""


def render_locksmith_tools(canonical_tools: list[dict[str, Any]]) -> dict[str, Any]:
    """Render canonical tool entries into a locksmith tools.yaml dict."""
    seen: set[str] = set()
    for tool in canonical_tools:
        if tool["name"] in seen:
            raise DuplicateToolError(f"duplicate tool name: {tool['name']}")
        seen.add(tool["name"])
    return {"tools": list(canonical_tools)}


def render_pipelock_allowlist_extras(
    canonical_tools: list[dict[str, Any]],
) -> dict[str, Any]:
    """Derive pipelock allowlist contributions from proxied tools."""
    hosts: list[str] = []
    seen: set[str] = set()
    for tool in canonical_tools:
        if tool.get("egress") != "proxied":
            continue
        host = urlparse(tool["upstream"]).hostname
        if host is None:
            raise ValueError(
                f"tool {tool['name']!r}: upstream {tool['upstream']!r} has no hostname"
            )
        if host not in seen:
            seen.add(host)
            hosts.append(host)
    return {"api_allowlist_extras": hosts}


def _load_canonical_tools(tools_dir: Path) -> list[dict[str, Any]]:
    """Load tools/*.yaml entries (skipping _-prefixed files).

    Returns an empty list when the directory does not exist or contains
    no eligible YAML files — both legitimate states post-Phase-E when
    the operator relies entirely on the locksmith seed catalog +
    admin-API overrides.
    """
    if not tools_dir.exists():
        return []
    tools: list[dict[str, Any]] = []
    for yaml_path in sorted(tools_dir.glob("*.yaml")):
        if yaml_path.name.startswith("_"):
            continue  # _defaults.yaml etc. are not tools
        with yaml_path.open() as f:
            tools.append(yaml.safe_load(f))
    return tools


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", required=True, type=Path)
    parser.add_argument("--rendered-dir", required=True, type=Path)
    parser.add_argument(
        "--locksmith-base",
        type=Path,
        default=None,
        help="Optional locksmith base config (listen/egress_proxy/etc.) to merge "
        "with rendered tools into rendered/locksmith/config.yaml. If omitted, "
        "only rendered/locksmith/tools.yaml is written.",
    )
    args = parser.parse_args(argv)

    tools = _load_canonical_tools(args.tools_dir)
    locksmith = render_locksmith_tools(tools)
    pipelock_extras = render_pipelock_allowlist_extras(tools)

    locksmith_dir = args.rendered_dir / "locksmith"
    pipelock_dir = args.rendered_dir / "pipelock"
    locksmith_dir.mkdir(parents=True, exist_ok=True)
    pipelock_dir.mkdir(parents=True, exist_ok=True)

    (locksmith_dir / "tools.yaml").write_text(_safe_dump(locksmith))
    (pipelock_dir / "allowlist-extras.yaml").write_text(_safe_dump(pipelock_extras))

    if args.locksmith_base is not None:
        with args.locksmith_base.open() as f:
            base = yaml.safe_load(f) or {}
        full_config = {
            **base,
            **locksmith,
        }  # tools key from `locksmith` overrides any in base
        (locksmith_dir / "config.yaml").write_text(_safe_dump(full_config))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
