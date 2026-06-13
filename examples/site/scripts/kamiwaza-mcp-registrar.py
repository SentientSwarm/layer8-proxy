#!/usr/bin/env python3
"""kamiwaza-mcp-registrar — reconcile Kamiwaza-hosted MCP tools into the
locksmith catalog as ordinary kind=tool registrations.

WHY THIS EXISTS (design, agents-stack ADR-0007 family):
    Kamiwaza runs MCP tool servers dynamically (Tool Shed deployments +
    Extensions). We want agents to reach them THROUGH locksmith so the
    calls inherit locksmith's per-agent ACL, audit, egress (pipelock),
    and response controls — exactly what a credential proxy is for.

    MCP-over-HTTP is just JSON-RPC over HTTP POST, and Kamiwaza MCP
    endpoints accept the same Kamiwaza bearer (KAMIWAZA_USE_AUTH=true).
    So a Kamiwaza MCP tool registered as a normal catalog entry
    (upstream = the MCP endpoint, auth = bearer=KAMIWAZA_MCP_PAT,
    egress = direct|proxied) is proxied transparently by locksmith's
    existing hot path — no locksmith code change, no MCP code in the
    proxy. MCP-client agents (e.g. hermes) speak MCP straight through
    /api/<tool>/ and locksmith injects the PAT.

    This registrar is the ONLY Kamiwaza-specific piece: it discovers the
    live MCP tools and creates/updates/removes their registrations. It
    runs OFF the hot path (cron / timer), so per-request latency and the
    SSRF/availability surface of discovery never touch agent traffic.

CREDENTIAL TOPOLOGY:
    - This script needs KAMIWAZA_MCP_PAT (to call the Kamiwaza discovery
      API) and the locksmith operator token (to register).
    - The SAME KAMIWAZA_MCP_PAT must also exist in the locksmith
      CONTAINER's env (forwarded via docker-compose.override.yml), because
      the registrations reference `--auth bearer=KAMIWAZA_MCP_PAT` and
      locksmith resolves env vars from its own process environment at
      registration time. Put the PAT in the site .env + the override's
      locksmith environment list, then recreate locksmith before the
      first run (see README / expose-an-agent.md).

USAGE:
    KAMIWAZA_API_URL=https://kamiwaza-host \\
    KAMIWAZA_MCP_PAT=<pat> \\
    LOCKSMITH_OP_TOKEN=<op-token> \\
      ./kamiwaza-mcp-registrar.py [--dry-run] [--once]

    Typically invoked from cron via a thin wrapper that decrypts the
    operator token (see register-agents.sh for the decrypt pattern).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

# ── Configuration (all overridable via env) ──────────────────────────────
KAMIWAZA_API_URL = os.environ.get("KAMIWAZA_API_URL", "").rstrip("/")
KAMIWAZA_MCP_PAT = os.environ.get("KAMIWAZA_MCP_PAT", "")
# Env-var NAME (not value) that locksmith injects as the upstream bearer.
# Must match a var present in the locksmith container's environment.
KAMIWAZA_PAT_ENV = os.environ.get("KAMIWAZA_PAT_ENV", "KAMIWAZA_MCP_PAT")
KAMIWAZA_VERIFY_TLS = os.environ.get("KAMIWAZA_VERIFY_TLS", "true").lower() != "false"
# Default MCP path when a tool template doesn't declare MCP_PATH.
DEFAULT_MCP_PATH = os.environ.get("KAMIWAZA_MCP_PATH", "/mcp")

CONTAINER = os.environ.get("CONTAINER", "docker")
LOCKSMITH_CONTAINER = os.environ.get("LOCKSMITH_CONTAINER", "layer8-locksmith")
LOCKSMITH_BIN = os.environ.get("LOCKSMITH_BIN", "/usr/local/bin/locksmith")
LOCKSMITH_OP_TOKEN = os.environ.get("LOCKSMITH_OP_TOKEN", "")

# Registration shape.
NAME_PREFIX = os.environ.get("KAMIWAZA_NAME_PREFIX", "kamiwaza-")
# LAN Kamiwaza → direct (lmstudio precedent); internet/proxied Kamiwaza →
# 'proxied' + a pipelock allowlist entry for the host.
EGRESS = os.environ.get("KAMIWAZA_EGRESS", "direct")
# MCP tool calls can be long-running (parsing, inference); size well above
# the 30s default total-request timeout.
TIMEOUT_REQUEST = os.environ.get("KAMIWAZA_TIMEOUT_REQUEST", "600")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def die(msg: str) -> None:
    log(f"ERROR: {msg}")
    sys.exit(1)


# ── Kamiwaza discovery ────────────────────────────────────────────────────


@dataclass
class McpTool:
    """A discovered Kamiwaza MCP tool, normalized across Tool Shed and
    Extensions sources."""

    slug: str  # locksmith registration name suffix ([a-z0-9-])
    mcp_url: str  # externally-reachable MCP endpoint URL (the upstream)
    source: str  # "tool-shed" | "extension"
    source_id: str  # deployment id / extension name (for audit metadata)
    description: str


def _kamiwaza_get(path: str) -> Any:
    url = f"{KAMIWAZA_API_URL}{path}"
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {KAMIWAZA_MCP_PAT}"}
    )
    ctx = None
    if not KAMIWAZA_VERIFY_TLS:
        import ssl

        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None  # endpoint family absent on this instance
        raise


def slugify(name: str) -> str:
    """Registration name component: lowercase, [a-z0-9-], collapse runs,
    strip leading/trailing dashes. Mirrors locksmith's name validator
    ([a-z0-9-], <=64)."""
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    s = re.sub(r"-{2,}", "-", s)
    return s or "tool"


def _external_mcp_url(base_external: str, mcp_path: str) -> str:
    """Join a tool's external base URL with its MCP path. An empty
    mcp_path means MCP is served at the route root (strip_path_prefix
    tools); return the base with a trailing slash."""
    base = base_external.rstrip("/")
    return f"{base}/" if not mcp_path.strip("/") else f"{base}/{mcp_path.lstrip('/')}"


_TEMPLATE_CACHE: dict[str, dict[str, Any]] | None = None


def _tool_templates() -> dict[str, dict[str, Any]]:
    """Index tool templates by id AND name (for MCP-path resolution).
    Cached for the run."""
    global _TEMPLATE_CACHE
    if _TEMPLATE_CACHE is None:
        templates = _kamiwaza_get("/api/tool/templates") or []
        idx: dict[str, dict[str, Any]] = {}
        for t in templates:
            for key in ("id", "name"):
                if t.get(key):
                    idx[str(t[key])] = t
        _TEMPLATE_CACHE = idx
    return _TEMPLATE_CACHE


def _mcp_path_override(slug: str) -> str | None:
    """Per-tool operator escape hatch: KAMIWAZA_MCP_PATH_<SLUG> env."""
    return os.environ.get(f"KAMIWAZA_MCP_PATH_{slug.upper().replace('-', '_')}")


def resolve_mcp_path(
    env: dict[str, Any], template: dict[str, Any] | None, override: str | None
) -> str:
    """Resolve a tool's MCP sub-path. The MCP mount point is genuinely
    per-tool — DDE serves MCP at the route ROOT via strip_path_prefix,
    while omniparse-style tools declare MCP_PATH=/mcp — so this must be
    resolved, never assumed. Precedence:
      1. operator override (KAMIWAZA_MCP_PATH_<SLUG>),
      2. explicit MCP_PATH in the deployment env,
      3. explicit MCP_PATH in the template env_defaults,
      4. strip_path_prefix tools → root (empty),
      5. DEFAULT_MCP_PATH (/mcp)."""
    if override is not None:
        return override
    if "MCP_PATH" in env:
        return env["MCP_PATH"]
    tmpl = template or {}
    tmpl_env = tmpl.get("env_defaults") or {}
    if "MCP_PATH" in tmpl_env:
        return tmpl_env["MCP_PATH"]
    if tmpl.get("strip_path_prefix"):
        return ""
    return DEFAULT_MCP_PATH


def discover_tool_shed() -> list[McpTool]:
    """Tool Shed deployments (Docker-Compose-backed). The raw `url` field
    is node-internal (host.docker.internal:<port>) and NOT reachable from
    the proxy host; the externally-routable form is the Traefik path
    <base>/runtime/tools/<deployment-name>/<mcp_path>. Prefer any https
    external URL the API surfaces; else construct it."""
    deployments = _kamiwaza_get("/api/tool/deployments") or []
    tools: list[McpTool] = []
    for dep in deployments:
        status = (dep.get("status") or "").lower()
        if status not in ("running", "deployed"):
            continue
        name = dep.get("name") or dep.get("id", "")
        dep_id = dep.get("id", name)
        env = dep.get("env_vars") or {}
        template = _tool_templates().get(str(dep.get("template_id", "")))
        mcp_path = resolve_mcp_path(env, template, _mcp_path_override(slugify(name)))
        # Prefer an https external URL if the API provides one; else build
        # the Traefik runtime route from the deployment name.
        raw_url = dep.get("url", "")
        if raw_url.startswith("https://") and "host.docker.internal" not in raw_url:
            mcp_url = (
                raw_url
                if raw_url.rstrip("/").endswith(mcp_path.strip("/"))
                else _external_mcp_url(raw_url, mcp_path)
            )
        else:
            runtime_name = dep.get("runtime_name") or f"{name}-{dep_id.split('-')[0]}"
            base = f"{KAMIWAZA_API_URL}/runtime/tools/{runtime_name}"
            mcp_url = _external_mcp_url(base, mcp_path)
        tools.append(
            McpTool(
                slug=slugify(name),
                mcp_url=mcp_url,
                source="tool-shed",
                source_id=str(dep_id),
                description=dep.get("description") or f"Kamiwaza Tool Shed MCP: {name}",
            )
        )
    return tools


def discover_extensions() -> list[McpTool]:
    """Extensions (K8s-CR-backed). endpoints.external is API-provided and
    externally routable; append the tool's MCP_PATH."""
    extensions = _kamiwaza_get("/api/extensions") or []
    tools: list[McpTool] = []
    for ext in extensions:
        if (ext.get("type") or "") != "tool":
            continue
        if (ext.get("phase") or "").lower() != "running":
            continue
        name = ext.get("name", "")
        endpoints = ext.get("endpoints") or {}
        external = endpoints.get("external")
        if not external:
            log(f"  skip extension {name}: no endpoints.external")
            continue
        # The Extension schema doesn't carry MCP_PATH; resolve it from the
        # backing template (strip_path_prefix → root, else MCP_PATH default)
        # with the per-tool operator override as the escape hatch.
        template = _tool_templates().get(str(ext.get("template_name", "")))
        mcp_path = resolve_mcp_path({}, template, _mcp_path_override(slugify(name)))
        tools.append(
            McpTool(
                slug=slugify(name),
                mcp_url=_external_mcp_url(external, mcp_path),
                source="extension",
                source_id=name,
                description=ext.get("description") or f"Kamiwaza extension MCP: {name}",
            )
        )
    return tools


def discover() -> list[McpTool]:
    tools = discover_tool_shed() + discover_extensions()
    # De-dupe by registration name (slug); last wins. Extensions are the
    # newer system, so they sort after Tool Shed and win on collision.
    by_name: dict[str, McpTool] = {}
    for t in tools:
        by_name[f"{NAME_PREFIX}{t.slug}"] = t
    return list(by_name.values())


# ── locksmith catalog reconciliation ──────────────────────────────────────


def run_locksmith(args: list[str]) -> subprocess.CompletedProcess:
    cmd = [
        CONTAINER,
        "exec",
        "-e",
        f"LOCKSMITH_OP_TOKEN={LOCKSMITH_OP_TOKEN}",
        LOCKSMITH_CONTAINER,
        LOCKSMITH_BIN,
        *args,
    ]
    return subprocess.run(cmd, capture_output=True, text=True)


def existing_kamiwaza_registrations() -> set[str]:
    """Names of current catalog entries this registrar owns (metadata
    provider=kamiwaza, or the name prefix as a fallback)."""
    proc = run_locksmith(["tool", "list", "--format", "json"])
    if proc.returncode != 0:
        die(f"locksmith tool list failed: {proc.stderr.strip()}")
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError:
        die(f"locksmith tool list returned non-JSON: {proc.stdout[:200]}")
    owned = set()
    for r in rows:
        meta = r.get("metadata") or {}
        if meta.get("provider") == "kamiwaza" or r.get("name", "").startswith(
            NAME_PREFIX
        ):
            owned.add(r["name"])
    return owned


def put_registration(name: str, tool: McpTool, dry_run: bool) -> None:
    args = [
        "tool",
        "put",
        name,
        "--upstream",
        tool.mcp_url,
        "--auth",
        f"bearer={KAMIWAZA_PAT_ENV}",
        "--egress",
        EGRESS,
        "--timeout-request",
        TIMEOUT_REQUEST,
        "--metadata",
        "provider=kamiwaza",
        "--metadata",
        "role=mcp-tool",
        "--metadata",
        f"source={tool.source}",
        "--metadata",
        f"source_id={tool.source_id}",
        "--description",
        tool.description[:200],
    ]
    if dry_run:
        log(f"  [dry-run] put {name} -> {tool.mcp_url}")
        return
    proc = run_locksmith(args)
    if proc.returncode != 0:
        log(f"  FAILED put {name}: {proc.stderr.strip()}")
    else:
        log(f"  put {name} -> {tool.mcp_url}")


def delete_registration(name: str, dry_run: bool) -> None:
    if dry_run:
        log(f"  [dry-run] delete {name}")
        return
    proc = run_locksmith(["tool", "delete", name])
    if proc.returncode != 0:
        log(f"  FAILED delete {name}: {proc.stderr.strip()}")
    else:
        log(f"  delete {name} (no longer running in Kamiwaza)")


def reconcile(dry_run: bool) -> int:
    discovered = discover()
    desired = {f"{NAME_PREFIX}{t.slug}": t for t in discovered}
    existing = existing_kamiwaza_registrations()

    log(
        f"discovered {len(desired)} live Kamiwaza MCP tool(s); "
        f"{len(existing)} currently registered"
    )

    for name, tool in sorted(desired.items()):
        put_registration(name, tool, dry_run)

    for name in sorted(existing - set(desired)):
        delete_registration(name, dry_run)

    log("reconcile complete")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Reconcile Kamiwaza MCP tools into the locksmith catalog."
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="show actions without mutating the catalog",
    )
    ap.add_argument(
        "--once",
        action="store_true",
        help="run a single reconcile pass (default; cron drives repetition)",
    )
    args = ap.parse_args()

    if not KAMIWAZA_API_URL:
        die("KAMIWAZA_API_URL is required")
    if not KAMIWAZA_MCP_PAT:
        die("KAMIWAZA_MCP_PAT is required (Kamiwaza discovery bearer)")
    if not KAMIWAZA_VERIFY_TLS:
        log(
            "WARNING: KAMIWAZA_VERIFY_TLS=false — discovery calls skip cert "
            "verification (MITM-exposed). Dev/self-signed only; in production "
            "add the Kamiwaza CA to the trust store or use a real cert. This "
            "affects ONLY this registrar's discovery; locksmith still verifies "
            "the MCP upstream when proxying agent traffic."
        )
    if not LOCKSMITH_OP_TOKEN and not args.dry_run:
        die("LOCKSMITH_OP_TOKEN is required to register (or use --dry-run)")

    return reconcile(args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
