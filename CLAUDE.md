# CLAUDE.md

Substantive context for coding agents working on **layer8-proxy** — the Docker Compose deployment bundle that wraps `agent-locksmith` (credential proxy + ACL), `pipelock` (egress firewall + DLP), and `lf-scan` (prompt/code scanner sidecar).

## What this repo is

Public-facing deployable artifact. **Not** a credential store, **not** a per-host config repo (those are `layer8-proxy-site` and `hermes-site`).

This repo provides the docker-compose definitions, image build context for the locksmith container, smoke-test scripts, and operator-facing user docs. Per-host config (sealed creds, agents.yaml, tool definitions) lives in private site repos that consume the bundle by version pin.

## Working branch

`main` is the working branch. Cut feature branches from `main`. Versioned via git tags `v0.1.0`, `v0.2.0`, …

## File layout

```
docker-compose.yml             # The stack definition: locksmith, pipelock, lf-scan
locksmith/
  Dockerfile                   # Multi-stage build: agent-locksmith binary + runtime image
  docker-entrypoint.sh
pipelock/                      # pipelock config defaults
lf-scan/                       # lf-scan sidecar config defaults
scripts/
  verify.sh                    # Stack smoke test (used by site repos' deploy.sh)
  bootstrap.sh                 # First-boot bootstrap helper
docs/
  user/                        # Operator-facing user documentation
  user/concepts/               # Deployment-shape concepts (topology etc.)
.env.example                   # Required env vars (LOCKSMITH_VERSION, BACKUP_DEST, ...)
```

The authoritative stack spec lives at `agents-stack/docs/spec/v<X.Y.Z>.md`. The PRD lives at `agents-stack/docs/prd/v<X.Y.Z>.md`. Cumulative cross-repo decisions live at `agents-stack/docs/adrs/`.

## Common commands

```bash
# Build the locksmith image with a specific version
LOCKSMITH_VERSION=v1.1.0 docker compose build locksmith

# Bring up the stack (typically invoked from a site repo's deploy.sh)
docker compose up -d

# Smoke test (auth assertions enabled when env fixture is set)
LOCKSMITH_VERIFY_TOKEN=lk_... \
LOCKSMITH_VERIFY_ALLOWED_TOOL=lmstudio \
LOCKSMITH_VERIFY_DENIED_TOOL=anthropic \
./scripts/verify.sh

# Stack down (operator hosts)
docker compose down
```

## Conventions

- **Image versioning**: locksmith container is pinned by `${LOCKSMITH_VERSION}` (set in site repo's `.env`). Bumping it is the ordinary upgrade path. Site repos pin `layer8_version=vX.Y.Z` in `site.cfg` against this repo's tag.
- **Healthcheck**: locksmith image's HEALTHCHECK uses `curl -fsS /livez`. Older images (pre-v2.0.0) had a broken `locksmith status` check; the override hatch in `docker-compose.override.yml` of site repos lets operators disable it if pinning a stale version.
- **Pipelock + lf-scan**: bundled but minimally configured here. Site repos override config via volume mounts.

## Don't do

- Don't commit credentials, tokens, or `.env` (use `.env.example` for the schema).
- Don't add per-host config here — that belongs in a site repo.
- Don't bypass `verify.sh` when adding new functionality — extend it.

## Devloop / coordination

This repo is one of several worked on together via the `agents-stack` meta-repo. See `agents-stack/AGENTS.md` for cross-repo orchestration. When a change spans repos (e.g., locksmith API change → layer8-proxy image bump → site repo cutover), use the devloop framework + Linear tickets to coordinate.
