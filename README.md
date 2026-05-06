# layer8-proxy

Semantic networking layer (L8) for AI agents — credential proxy + egress
firewall + scanner sidecar in one Docker Compose bundle. Agents proxy
their outbound HTTP through layer8-proxy and never see provider API keys.

**Current version: v1.0.0** ([release notes](https://github.com/SentientSwarm/layer8-proxy/releases/tag/v1.0.0))

## Components

- **locksmith** ([`agent-locksmith`](https://github.com/SentientSwarm/agent-locksmith) v2.0.0)
  — agent-facing proxy. Credential injection, per-agent bearer + ACL,
  audit, response controls, OAuth credential variant. Single namespace
  `/api/{tool}/{*path}`.
- **pipelock** ([`luckyPipewrench/pipelock`](https://github.com/luckyPipewrench/pipelock),
  Apache 2.0) — egress chokepoint with allowlist, DLP, and tool-chain
  detection.
- **lf-scan** (Python, ours) — thin FastAPI wrapper around Meta's
  [`llamafirewall`](https://github.com/meta-llama/PurpleLlama) library,
  exposed as a `kind=infra` middleware service. Removed when locksmith
  ships inline scanners (post-v1.0).

## Highlights (v1.0.0)

- **16-entry seed catalog** baked into the locksmith image: anthropic,
  openai, openrouter, ai-gateway, ollama, lmstudio, tavily, github,
  duckduckgo, wikipedia, lf-scan + 5 OAuth providers (codex, copilot,
  anthropic-oauth, google-gemini-cli, qwen-cli). Operators provide
  `.env` credentials and override site-specific fields via the admin API.
- **Per-agent bearer + ACL** on the proxy hot path. Each agent
  registration carries an allowlist; cross-tool access requires explicit
  operator grant.
- **Kind-discriminated discovery** — `GET /tools` (kind=tool) and
  `GET /models` (kind=model) split. Operator-only middleware
  (`kind=infra`) is invisible to agents.
- **OAuth credential variant** — codex / copilot / anthropic-oauth /
  google-gemini-cli / qwen-cli. Refresh tokens sealed at rest with
  AES-GCM (`LOCKSMITH_OAUTH_SEALING_KEY`); access tokens auto-refresh.
- **mTLS feature flag** for the agent listener and admin HTTPS.
- **§4.7.9 uniform error envelope** across all admin + proxy errors.

## Quick start (development)

```bash
git clone git@github.com:SentientSwarm/layer8-proxy.git
cd layer8-proxy
cp .env.example .env
# Edit .env to set LF_SCAN_INTERNAL_TOKEN to a secure random string.
./scripts/bootstrap.sh
docker compose up -d
./scripts/verify.sh
```

For Podman: `export COMPOSE="podman compose"` before running.

After the stack is up:

1. Bootstrap the operator credential — see
   [`layer8-proxy-site`](https://github.com/SentientSwarm/layer8-proxy-site)'s
   `scripts/bootstrap-operator.py` (run from a site repo, not this one).
2. Register your first agent —
   `locksmith agent register --name my-agent --allowlist anthropic,openai`.
3. Install the printed bearer on the agent host (mode 0600 file or
   sealed-cred). The agent calls
   `http://layer8.lan:9200/api/<tool>/<path>` with the bearer.

For real deployments, layer8-proxy is consumed by a *site* repo
(`layer8-proxy-site` for the proxy operator,
`hermes-site` / `openclaw-site` for the agent operator) that pins a
version, supplies sealed creds, and wraps `docker compose up` with
a `deploy.sh`.

## OAuth providers (v1.0.0+)

OAuth providers (codex, copilot, anthropic-oauth, google-gemini-cli,
qwen-cli) are in the seed catalog but disabled until the operator
provides a sealing key:

```bash
# Generate a sealing key once at install time.
LOCKSMITH_OAUTH_SEALING_KEY="$(openssl rand -base64 32)"

# Stash it in your sealed-creds store and reference it in the daemon's env.
# The daemon will mount the OAuth admin endpoints on first start.

# Bootstrap a session once per provider (operator gets a refresh token
# via the provider's own CLI, then registers it with locksmith).
docker exec layer8-locksmith /usr/local/bin/locksmith oauth bootstrap codex \
    --refresh-token "<paste-from-provider's-flow>"

# Status / revoke as needed.
docker exec layer8-locksmith /usr/local/bin/locksmith oauth status codex
docker exec layer8-locksmith /usr/local/bin/locksmith oauth revoke codex
```

Without `LOCKSMITH_OAUTH_SEALING_KEY`, OAuth registrations exist in
discovery but proxy calls return 503 `oauth_sealing_key_unset`.

## Documentation

- **Stack design**: [`agents-stack/docs/spec/v0.2.0.md`][spec] (formal
  as-built spec) + [`prd/v0.2.0.md`][prd] (user-facing requirements).
- **Decision records**: [`agents-stack/docs/adrs/`][adrs] — kind
  taxonomy (ADR-0004), OAuth credentials (ADR-0005), etc.
- **Locksmith user docs**:
  [`agent-locksmith/docs/user/`](https://github.com/SentientSwarm/agent-locksmith/tree/develop/docs/user)
  — concepts, agent integration recipes (hermes, openclaw).
- **Operator user docs (this repo)**:
  [`docs/user/`](docs/user) — getting started, deploy, add an agent,
  add a tool, troubleshoot.

[spec]: https://github.com/SentientSwarm/agents-stack/blob/main/docs/spec/v0.2.0.md
[prd]: https://github.com/SentientSwarm/agents-stack/blob/main/docs/prd/v0.2.0.md
[adrs]: https://github.com/SentientSwarm/agents-stack/blob/main/docs/adrs/

## Version pairing

| layer8-proxy | agent-locksmith | Notes |
|---|---|---|
| v1.0.0 | v2.0.0 | Catalog substrate + OAuth + per-agent ACL + mTLS. **Current.** |
| v0.x   | v1.x    | Pre-Phase-E homogeneous tools list. Migrate via `legacy_bootstrap` shim on first v1.0.0 boot. |

Operators can stay pinned to v0.x by setting `LOCKSMITH_VERSION=v1.1.0`
in their site repo's `.env` until they're ready to migrate. v1.0.0 is
wire-breaking for `/tools` (now strictly kind=tool) — see
[`agents-stack/docs/spec/v0.2.0.md`][spec] for the migration story.

## License

MIT — see [LICENSE](LICENSE).
