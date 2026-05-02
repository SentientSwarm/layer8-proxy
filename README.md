# layer8-proxy

Semantic networking layer (L8) for AI agents — credentials, content, and
inference policy in one Docker Compose bundle.

## Components

- **locksmith** (Rust, `agent-locksmith` v1.1.0) — agent-facing proxy.
  Single namespace `/api/{tool}/{*path}`. Credential injection, audit,
  response controls, SSE streaming.
- **pipelock** (Go, [`luckyPipewrench/pipelock`](https://github.com/luckyPipewrench/pipelock),
  Apache 2.0) — egress chokepoint with allowlist, DLP, and tool-chain
  detection.
- **lf-scan** (Python, ours, transitional) — thin FastAPI wrapper around
  Meta's [`llamafirewall`](https://github.com/meta-llama/PurpleLlama) library,
  exposed as an ordinary locksmith tool. Removed in agent-locksmith M8.

## Quick start

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

For real deployments, layer8-proxy is consumed by a *site* repo
(e.g., `hermes-site`) that pins a version, provides tools and secrets, and
wraps `docker compose up` with a `deploy.sh`.

## Documentation

- [Architecture](docs/architecture.md)
- [Deployment](docs/deployment.md)
- [D-18 Reframe (LlamaFirewall as library)](docs/d18-reframe.md)
- [M8 Handoff (what changes when locksmith ships inline scanners)](docs/m8-handoff.md)

## Design source

The authoritative design lives in
[`agents-stack/docs/specs/2026-05-01-layer8-proxy-design.md`][spec].

[spec]: https://github.com/SentientSwarm/agents-stack/blob/main/docs/specs/2026-05-01-layer8-proxy-design.md

## License

MIT — see [LICENSE](LICENSE).
