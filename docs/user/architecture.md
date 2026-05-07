# Architecture (stack-level)

User-level overview of how layer8-proxy composes its three components
into a coherent stack. For the daemon-level view, see
[`agent-locksmith/docs/user/architecture.md`](https://github.com/SentientSwarm/agent-locksmith/blob/develop/docs/user/architecture.md).
For the formal as-built design, see
[`agents-stack/docs/spec/v0.2.0.md`](https://github.com/SentientSwarm/agents-stack/blob/main/docs/spec/v0.2.0.md).

## The three components

```
                     ┌────────────────────────────────────────┐
                     │  layer8-proxy stack (this repo)        │
                     │                                        │
   agent ─HTTP/HTTPS─┤    ┌──────────────┐                    │
                     │    │  locksmith   │  Rust daemon       │
                     │    │  :9200       │                    │
                     │    │              │                    │
                     │    │  - bearer    │                    │
                     │    │  - ACL       │                    │
                     │    │  - cred inj  │                    │
                     │    │  - audit     │                    │
                     │    └──────┬───────┘                    │
                     │           │                            │
                     │           │ HTTP CONNECT (cloud tools) │
                     │           ▼                            │
                     │    ┌──────────────┐                    │
                     │    │  pipelock    │  Go forward proxy  │
                     │    │  :8888       │                    │
                     │    │              │                    │
                     │    │  - allowlist │                    │
                     │    │  - DLP       │                    │
                     │    │  - SNI verif │                    │
                     │    └──────┬───────┘                    │
                     │           │                            │
                     │           ▼ Internet                   │
                     │     api.anthropic.com, api.openai.com  │
                     │                                        │
                     │    ┌──────────────┐                    │
                     │    │  lf-scan     │  Python sidecar    │
                     │    │  :9100       │                    │
                     │    │              │                    │
                     │    │  - prompt    │                    │
                     │    │    scanning  │                    │
                     │    │  - code scan │                    │
                     │    └──────────────┘                    │
                     │      ▲                                 │
                     │      │ kind=infra; agents NEVER reach  │
                     │      │ this; only locksmith's internal │
                     │      │ middleware does.                │
                     └──────┼─────────────────────────────────┘
                            │
                            │ X-Internal-Token
                            │ (locksmith ↔ lf-scan
                            │  shared secret from .env)
                            │
                       locksmith
```

### locksmith — the credential proxy

Rust daemon. Single namespace `/api/{tool_name}/{*path}` for agents.
Per-agent bearer authentication, per-agent ACL, credential injection,
audit, response controls (size cap, content-type allowlist, regex
redaction).

**What goes in**: an agent's request with the agent's bearer token in
the `Authorization` header.

**What comes out the other side** (to the upstream): the same request
with the agent's auth headers stripped and the configured provider
credential injected.

**What goes back to the agent**: the upstream's response, streamed,
with one audit row written.

### pipelock — the egress firewall

Go forward proxy. HTTP CONNECT chokepoint for cloud-bound traffic.
Hosts an allowlist (configurable per-site) of upstream domains; rejects
CONNECT to anything not on the list. Layered DLP (data-loss
prevention) inspects request bodies for accidental secret leakage.

**Locksmith routes through pipelock** when a registration's
`egress: proxied`. LAN-direct registrations (`egress: direct`) skip
pipelock — typical for `host.docker.internal:1234` (LM Studio) or
`ollama.lan:11434` (Ollama on LAN).

### lf-scan — the prompt/code scanner

Python FastAPI sidecar. Wraps Meta's
[llamafirewall](https://github.com/meta-llama/PurpleLlama) library
(`PromptGuardScanner`, `CodeShieldScanner`, regex). Exposes scan
endpoints over HTTP with an `X-Internal-Token` shared secret.

**v1.0 status**: registered as `kind=infra` in locksmith's seed
catalog. Agents cannot call `/api/lf-scan/...` (kind=infra is invisible
to agent discovery). It exists as scaffolding for v0.3+
middleware-pipeline composition where the proxy hot path can chain
infra-kind services.

The transitional v1.0 use is direct: agents like hermes can call
lf-scan as part of their own scanning pipeline, OR operators can
configure locksmith's response_controls to reference lf-scan for
post-response scanning. Programmable middleware composition is post-v2.

## Wire flow: an agent's request

Step-by-step, what happens when hermes calls
`POST /api/anthropic/v1/messages` through layer8-proxy:

```
1. hermes                                   POST http://layer8.lan:9200/api/anthropic/v1/messages
                                             Authorization: Bearer lk_<agent>
                                             anthropic-version: 2023-06-01
                                             {"model":"claude-...","messages":[...]}

2. axum router → auth middleware             validates lk_<agent> against AgentRepository
                                              ✓ → stamps AgentIdentity in extensions

3. proxy_handler M9 ACL gate                 identity.allows_tool("anthropic")?
                                              ✓ → continue
                                              ✗ → 403 tool_not_allowed + audit row

4. catalog lookup                            state.catalog.lookup_active("anthropic")
                                              ✓ → AuthSpec::Header { header:"x-api-key", env_var:"ANTHROPIC_API_KEY" }

5. header strip                              remove agent's Authorization, x-api-key, host

6. credential injection                      x-api-key: <real-anthropic-key from resolved_creds>

7. egress route                              tool.egress == "proxied" → CONNECT to api.anthropic.com via pipelock :8888

8. pipelock                                  validates api.anthropic.com is in api_allowlist
                                              ✓ → forward CONNECT
                                              ✗ → 403 to locksmith → 502 to agent

9. api.anthropic.com                         processes the request, returns 200 + SSE stream

10. locksmith streams the response back      ≤100ms first-byte added latency

11. audit row written                        {tool:"anthropic", status:200, agent_public_id:..., auth_mode:"header", ...}
```

The agent never holds, sees, or transmits the real Anthropic API key.
The deployment can rotate provider keys with zero agent-side change.

## Trust boundary

| Role | Holds | Sees | Never holds |
|---|---|---|---|
| **Agent operator** (you, running hermes / openclaw) | per-agent bearer | what locksmith returns (provider responses) | provider API keys, OAuth refresh tokens |
| **Proxy operator** (you, running layer8-proxy stack) | provider API keys (sealed at rest) + operator wire token | audit log, ACL configurations | agent bearer cleartext (only argon2 hashes) |
| **Provider** (Anthropic, OpenAI, etc.) | their own platform keys | calls coming from layer8-proxy's IP | operator/agent identities |

When the deployer holds both roles (single-laptop setup), they're the
same person — but the credentials still partition cleanly. Agent's
bearer in `~/.hermes/locksmith.token`; provider keys sealed in
`locksmith/secrets/` or `.env` on the proxy host.

## Compose orchestration

`docker-compose.yml` defines the three services + their dependencies:

```yaml
services:
  locksmith:
    depends_on:
      pipelock:  { condition: service_healthy }
      lf-scan:   { condition: service_healthy }
  pipelock:
    healthcheck: { test: pipelock-healthcheck }
  lf-scan:
    healthcheck: { test: curl /health }
```

Locksmith waits for both upstream services to be healthy before
binding its listener — this prevents 5xx during the brief startup
window when one but not all of the stack is up.

Site repos overlay site-specific tweaks via
`docker-compose.override.yml` (port bindings, volume mounts, env
passthrough). The compose merge order is:
`docker-compose.yml` (bundle) + `docker-compose.override.yml` (site).

## State & persistence

| Component | State location | Survives restart? | Survives image rebuild? |
|---|---|---|---|
| locksmith DB | volume `layer8-proxy_locksmith_data` | Yes | Yes |
| locksmith secrets | bind-mount `locksmith/secrets/` | Yes (host fs) | Yes |
| locksmith logs | volume `layer8-proxy_locksmith_log` | Yes | Yes |
| pipelock logs | volume `pipelock_log` | Yes | Yes |
| lf-scan model cache | image-baked | n/a | No (re-downloads from HF) |
| build artifacts (target dir) | image layer | n/a | No |

Backups capture the volumes (DB + log) and the bind-mounted
secrets tree. See [backup-and-restore.md](backup-and-restore.md).

## Topology variants

See [concepts/topology.md](concepts/topology.md) for same-host vs
neutral-host vs LAN deployment shapes and their trade-offs.

## Component dependency graph

```
agent-locksmith (Rust)              ──── built from upstream agent-locksmith repo
       │                                  pinned by LOCKSMITH_VERSION (default v2.0.0)
       │
       ▼
locksmith Docker image              ──── built locally each deploy via Dockerfile
       │
       │ depends on
       ▼
pipelock Docker image               ──── built from luckyPipewrench/pipelock
       │
lf-scan Docker image                ──── built locally; pip-installs llamafirewall
       │
       │ orchestrated by
       ▼
docker-compose.yml + override       ──── site repo's docker-compose.override.yml
       │
       │ deployed via
       ▼
layer8-proxy-site/deploy.sh         ──── operator-authored or template-derived
```

## Security model

| Property | How it's enforced |
|---|---|
| **Provider key never leaves locksmith** | Resolved from `.env` / sealed creds at startup; lives in `secrecy::SecretString` (zeroized on drop); injected only on outbound HTTP requests. Never logged, never in audit rows, never in HTTP responses to agents. |
| **Per-agent identity** | Bearer tokens are unique per agent + argon2-hashed in DB. Revoke is per-agent. |
| **ACL enforcement** | Every proxy request hits the M9 ACL gate before reaching upstream. Audit rows record the gate decision. |
| **Egress allowlist** | Pipelock rejects CONNECT to non-allowlisted domains. Compromised agents can't exfiltrate via novel domains. |
| **Audit trail** | One row per request + one per admin write. SQLite + optional JSONL mirror. SHA-256 hashes of redacted secrets, never cleartext. |
| **Sealed creds at rest** | systemd-creds (Linux) / openssl-AES (macOS dev) for provider keys + operator credential + OAuth sealing key + restic password. |

## Limitations (v1.0)

- **Single-host single-locksmith**: no multi-locksmith HA. Multi-host
  exploration is post-v2 / v0.3+.
- **Pipelock allowlist not auto-derived from locksmith catalog** —
  D-16 work for v1.1.0. Today: manual coordination between
  `locksmith model put` and `pipelock.yaml` allowlist edits.
- **lf-scan as middleware** is registration-only at v1.0; programmable
  pipeline composition is post-v2.
- **Hot reload of listener-shape config** (mTLS cert paths, bind
  ports) requires a restart. Tools/audit/retention are hot-reloadable.

## See also

- [`agent-locksmith/docs/user/architecture.md`](https://github.com/SentientSwarm/agent-locksmith/blob/develop/docs/user/architecture.md)
  — daemon-level view (what locksmith does internally).
- [`agents-stack/docs/spec/v0.2.0.md`](https://github.com/SentientSwarm/agents-stack/blob/main/docs/spec/v0.2.0.md)
  — formal as-built design.
- [`concepts/topology.md`](concepts/topology.md) — deployment-shape
  trade-offs.
- [`agent-locksmith/docs/user/concepts/trust-boundary.md`](https://github.com/SentientSwarm/agent-locksmith/blob/develop/docs/user/concepts/trust-boundary.md)
  — formal trust-boundary semantics.
