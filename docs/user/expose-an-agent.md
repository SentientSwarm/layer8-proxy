# Expose an agent through locksmith

Make a deployed agent's OpenAI-compatible API reachable by chat clients
(Obsidian, OpenWebUI, scripts) through locksmith — one base URL per agent,
per-client bearers, ACL, audit, and SSE streaming. No locksmith code involved:
an agent endpoint is an ordinary `kind=model` registration (agents-stack
ADR-0007).

```
chat client ──bearer──▶ locksmith /api/<agent>-<host>/v1/* ──agent key──▶ agent api_server
                         (auth → ACL → inject → stream → audit)
```

## Prerequisites

- The agent host publishes the agent's api_server port on an interface
  locksmith can reach (LAN), **bearer-gated** (e.g. hermes refuses a
  non-loopback api_server without a key). See hermes-site's
  "Agent-endpoint exposure" README section for the compose pattern.
- The agent's API key is available to put in the locksmith host's `.env`.

## 1. Register the agent endpoint (operator, proxy host)

Naming convention: `<profile>-<host>` (names must match `[a-z0-9-]`, ≤64).

```bash
# a. Put the agent's API key in the site .env + forward it by name in
#    docker-compose.override.yml's locksmith environment list.
# b. Recreate locksmith FIRST — registrations resolve env vars from the
#    daemon's process environment; a put against a missing var leaves the
#    registration silently degraded (forwards without injection → 401s).
# c. Then register:
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith model put mira-mini-1 \
    --upstream "http://mini-1.kale.wemodulate.com:8642" \
    --auth bearer=MIRA_MINI1_API_KEY \
    --egress direct \
    --timeout-request 2100 \
    --metadata provider=hermes --metadata role=agent-endpoint \
    --metadata host=mini-1 --metadata profile=mira \
    --description "Mira (hermes root profile) on mini-1 — agent endpoint"
```

Two flags matter more than they look:

- **`--timeout-request 2100`** — this is locksmith's TOTAL stream duration
  bound; the 30s default kills any real agent turn mid-stream. 2100s is a
  floor, not a ceiling — agent frameworks like hermes place no wall-clock
  bound on an actively-working turn; raise per registration if real turns
  exceed it. The 60s idle default is fine when the agent sends SSE
  keepalives (hermes: every 30s).
- **`--egress direct`** — LAN upstreams skip pipelock (see below).

Never configure a `response:` block with `redaction_patterns` for an agent
endpoint — redaction forces full-response buffering and destroys streaming
(ADR-0007 D4).

Record the put in your site's `register-operator-tools.sh` so redeploys
re-assert it.

## 2. Register the chat client

Each client is a locksmith *agent* (client) with its own bearer and an
allowlist naming exactly the endpoints it may reach:

```yaml
# agents.yaml
  - name: obsidian
    description: "Obsidian Copilot on the operator laptop"
    allowlist:
      - mira-mini-1
      - jones-mini-1
      - larry-mini-1
```

Register via `./scripts/register-agents.sh` (bearer prints once — install it
in the client's settings; the client never holds agent keys). Revoking the
client bearer cuts that client only.

Client config: base URL `http://<proxy-host>:9200/api/<endpoint>/v1`, API
key = the client bearer. One connection per agent endpoint.

> **CORS:** locksmith serves no CORS headers and 401s preflights (they carry
> no Authorization). Browser-context `fetch` will not work — clients must
> use native/Electron-side requests (Obsidian plugins: enable the
> CORS-bypass/native request option for the model).

## 3. Verify

```bash
# Through locksmith (expect the agent's model list):
curl -H "Authorization: Bearer $CLIENT_BEARER" \
    http://<proxy-host>:9200/api/mira-mini-1/v1/models

# No bearer → 401. Endpoint not in the client's allowlist → 403
# {"error":{"code":"tool_not_allowed",...}} + a security/authz_denied
# audit row.

# Streaming: POST /v1/chat/completions with "stream": true — chunks must
# arrive incrementally (locksmith streams SSE natively).
```

## 4. Audit queries

```bash
SINCE=$(( ($(date +%s) - 86400) * 1000 ))   # last 24h, unix-millis

# Who talked to this agent, when, status + latency:
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith audit query --tool mira-mini-1 --since-ms $SINCE

# Denied attempts (ACL misses, bad bearers):
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith audit query --event-class security --since-ms $SINCE
```

The client's human-readable name appears as `agent_name`; the agent endpoint
as `tool`.

## Pipelock and `--egress`

`--egress direct` dials the upstream straight from locksmith — the right
posture for LAN agent hosts (same as the `lmstudio` precedent). `--egress
proxied` routes through pipelock's chokepoint, which then **requires the
upstream hostname in pipelock's allowlist** (`pipelock/pipelock.yaml
api_allowlist` or rendered allowlist-extras) — the allowlist is NOT derived
from the catalog automatically (upstream D-16). For internet upstreams use
proxied; for LAN agent endpoints, direct.

## Troubleshooting

| Symptom | Check |
|---|---|
| 401 from locksmith | Client bearer wrong/revoked |
| 403 `tool_not_allowed` | Endpoint not in the client's allowlist (`locksmith agent show <client>`) |
| 502 | Agent host/port unreachable from the proxy host, or agent api_server down |
| 401 recorded as upstream status | Injection degraded — env var missing at locksmith start (recreate, then re-put) |
| Stream cuts at ~30s | `--timeout-request` left at default |

## See also

- agents-stack `docs/spec/v0.4.0-agent-connectivity.md` — full design
  (Phase I), trust boundary, break-glass runbook.
- agents-stack `docs/adrs/0007-agent-endpoints-as-model-registrations.md` —
  why `kind=model`, naming, the no-A2A guard.
- [`add-a-tool.md`](add-a-tool.md) — general registration mechanics.
- [`add-an-agent.md`](add-an-agent.md) — client (caller) onboarding details.
