# CLAUDE.md

Substantive context for coding agents working on **layer8-proxy** — the Docker Compose deployment bundle that wraps `agent-locksmith` (credential proxy + ACL), `pipelock` (egress firewall + DLP), and `lf-scan` (prompt/code scanner sidecar).

## What this repo is

Public-facing deployable artifact. **Not** a credential store, **not** a per-host config repo (those are operator-private site repos like `layer8-proxy-site` for SentientSwarm; OS consumers spin up their own from `examples/site/`).

This repo provides the docker-compose definitions, image build context for the locksmith container, smoke-test scripts, operator-facing user docs, and a public-shape **site template** at `examples/site/` plus a `scripts/init-site.sh` generator. Per-host operator config (sealed creds, agents.yaml, etc.) lives in the site repo, not here.

## Working branch

`main` is the working branch. Cut feature branches from `main`. Versioned via git tags. **Current: v1.3.0** (paired with agent-locksmith v2.3.0 — Phase G3 codex Responses body fixup).

Phase G (per-agent credential overrides + OAuth session labels) shipped in v1.1.0 / agent-locksmith v2.1.0. Phase G2 (codex `ChatGPT-Account-ID` injection) shipped in v1.2.0 / agent-locksmith v2.2.0. Phase G3 (codex Responses body fixup — `store: false`, `stream: true`, default `instructions`) shipped in v1.3.0 / agent-locksmith v2.3.0. All three are downstream consumers — no layer8-proxy code change beyond the pinned `LOCKSMITH_VERSION` bump.

## File layout

```
docker-compose.yml             # The stack definition: locksmith, pipelock, lf-scan
locksmith/
  Dockerfile                   # Multi-stage build: agent-locksmith binary + seed catalog + runtime image
  docker-entrypoint.sh
pipelock/                      # pipelock config defaults
lf-scan/                       # lf-scan sidecar config defaults
scripts/
  verify.sh                    # Stack smoke test (used by site repos' deploy.sh)
  bootstrap.sh                 # First-boot bootstrap helper
  init-site.sh                 # Generate a site repo from examples/site/ template
examples/
  site/                        # Public-shape site repo template; copy + customize
docs/
  user/                        # Operator-facing user documentation
  user/concepts/               # Deployment-shape concepts (topology etc.)
.env.example                   # Required env vars (LOCKSMITH_VERSION=v2.3.0 default, ...)
```

The authoritative stack spec lives at `agents-stack/docs/spec/v<X.Y.Z>.md`. The PRD lives at `agents-stack/docs/prd/v<X.Y.Z>.md`. Cumulative cross-repo decisions live at `agents-stack/docs/adrs/`.

## Common commands

```bash
# Bootstrap a new operator's site repo from the public template.
./scripts/init-site.sh ../my-site

# Build the locksmith image with a specific version (defaults to v2.1.0).
LOCKSMITH_VERSION=v2.3.0 docker compose build locksmith

# Bring up the stack (typically invoked from a site repo's deploy.sh).
docker compose up -d

# Smoke test (auth assertions enabled when env fixture is set).
LOCKSMITH_VERIFY_TOKEN=lk_... \
LOCKSMITH_VERIFY_ALLOWED_TOOL=lmstudio \
LOCKSMITH_VERIFY_DENIED_TOOL=anthropic \
./scripts/verify.sh

# Stack down (operator hosts).
docker compose down
```

## Conventions

- **Image versioning**: locksmith container is pinned by `${LOCKSMITH_VERSION}` (default `v2.3.0` at v1.3.0 of this bundle; site repo's `.env` overrides). Bumping it is the ordinary upgrade path. Site repos pin `layer8_version=vX.Y.Z` in `site.cfg` against this repo's tag.
- **Locksmith Dockerfile**: multi-stage with a `seed-extractor` stage that conditionally stages `seed/catalog.yaml` from the cloned source. v2.0.0+ tags ship the catalog; pre-v2.0.0 tags get an empty staging dir (graceful fallback).
- **Healthcheck**: locksmith image's HEALTHCHECK uses `curl -fsS /livez`. Pre-v2.0.0 images had a broken `locksmith status` check; the override hatch in `docker-compose.override.yml` lets operators disable it if pinning a stale version.
- **Pipelock + lf-scan**: bundled but minimally configured here. Site repos override config via volume mounts.
- **`examples/site/` is the canonical public site template.** Keep the public-shape files (deploy.sh, secrets.bootstrap.sh, scripts/*.py, etc.) consistent with `layer8-proxy-site` (the SentientSwarm production site repo). Drift triage: documented in `examples/site/README.md`.

## Don't do

- Don't commit credentials, tokens, or `.env` (use `.env.example` for the schema).
- Don't add per-host config here — that belongs in a site repo.
- Don't bypass `verify.sh` when adding new functionality — extend it.

## Devloop / coordination

This repo is one of several worked on together via the `agents-stack` meta-repo. See `agents-stack/AGENTS.md` for cross-repo orchestration. When a change spans repos (e.g., locksmith API change → layer8-proxy image bump → site repo cutover), use the devloop framework + Linear tickets to coordinate.
