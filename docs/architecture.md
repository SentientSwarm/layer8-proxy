# Architecture

This document is a redacted copy of §Architecture from the source spec
[`agents-stack/docs/specs/2026-05-01-layer8-proxy-design.md`][spec].

[spec]: https://github.com/SentientSwarm/agents-stack/blob/main/docs/specs/2026-05-01-layer8-proxy-design.md

## Components

- **`locksmithd`** (Rust, `agent-locksmith` v1.1.0) — agent-facing proxy.
  Single namespace `/api/{tool}/{*path}`. Injects credentials, audits,
  applies response controls, terminates SSE streams, mediates egress.
- **`pipelock`** (Go, third-party — Joshua Waldrep, Apache 2.0) — HTTPS
  CONNECT forward proxy with allowlist/blocklist, DLP, and tool-chain
  detection. Egress chokepoint for cloud-bound traffic.
- **`lf-scan`** (Python, ours, transitional) — thin FastAPI sidecar that
  exposes Meta's `llamafirewall` library as a regular HTTP tool. Removed
  once `agent-locksmith` ships M8 (inline scanners in Rust).

## Two scanning planes

- **Network-boundary** (locksmith) — per-request, deterministic. Today via
  the lf-scan tool entry; M8 brings PG2 + CodeShield + regex inline in
  Rust.
- **Reasoning-loop** (agent process) — per-planning-checkpoint, semantic.
  Hermes calls `import llamafirewall` for AlignmentCheck against a
  configurable teacher model.

## Request flows

1. **Tool call:** `agent → locksmith /api/<tool>/... → pipelock → upstream`
2. **LLM call:** same path; SSE flows back via locksmith's M1 streaming
   passthrough.
3. **In-process scan:** `agent → llamafirewall.scan()` (no network hop).
   Teacher LLM call (if any) flows back through locksmith.

## ADR-01: proxy not firewall

Agents are not containerized inside the layer8-proxy compose project.
They route through locksmith by configuration convention, not network
containment. The strong guarantee is **credential confinement** — agent
processes never hold long-lived API keys. Direct internet egress
prevention is *not* guaranteed in v1; v2 containerization closes that gap.
