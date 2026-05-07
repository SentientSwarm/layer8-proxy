# Topology

Three deployment shapes. Pick based on your trust boundary,
network constraints, and operator/agent role separation.

## Same-host (single-Mac developer)

```
┌─ host ────────────────────────────────────────────────────────┐
│                                                               │
│  hermes / openclaw                                            │
│  (host process)                                               │
│       │                                                       │
│       │ http://127.0.0.1:9200/api/...                         │
│       ▼                                                       │
│  Docker network                                               │
│  ┌─ layer8-proxy_default ──────────────────────────────────┐  │
│  │                                                         │  │
│  │  locksmith ──► pipelock ──► host-network egress         │  │
│  │       │                                                 │  │
│  │       └──► host.docker.internal:1234 (LM Studio)        │  │
│  │                                                         │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

**Locksmith binds**: `127.0.0.1:9200` (loopback only).

**`docker-compose.override.yml`**:
```yaml
services:
  locksmith:
    ports:
      - "127.0.0.1:9200:9200"
```

**Pros:**
- Zero network setup; works behind any firewall.
- Lowest latency (loopback).
- Simplest mental model — everything on one host.

**Cons:**
- Trust boundary is logical only — same uid runs both proxy and
  agent. A compromised agent's process owner is the same as
  locksmith's process owner. Mitigation: operator role is at the
  cleartext-key level (sealed creds), not at the OS-uid level.
- No isolation if multiple users share the host; everyone sees
  the same listener.

**Use when**: solo developer, evaluation, single-user dev box.

## Neutral-host (laptop + LAN server)

```
┌─ laptop ────────────┐         ┌─ server (mac mini, RPi, etc.) ─────────┐
│                     │         │                                        │
│  hermes / openclaw  │         │  layer8-proxy stack                    │
│  (host process)     │         │                                        │
│         │           │         │  ┌──────────────────────────────────┐  │
│         │           │  LAN    │  │ locksmith :9200 (0.0.0.0 bind)   │  │
│         └───────────┼─────────┼─▶│        ↓                         │  │
│                     │  HTTPS  │  │ pipelock                         │  │
│                     │ (mTLS   │  │        ↓                         │  │
│                     │  recom- │  │ Internet (Anthropic, OpenAI)     │  │
│                     │  mended)│  │                                  │  │
│                     │         │  └──────────────────────────────────┘  │
└─────────────────────┘         └────────────────────────────────────────┘
```

**Locksmith binds**: `0.0.0.0:9200` (LAN-reachable). For production,
**enable mTLS** to add an authentication factor in addition to
bearer tokens.

**`docker-compose.override.yml`**:
```yaml
services:
  locksmith:
    ports:
      - "0.0.0.0:9200:9200"
    # Optional: mTLS volumes for agent listener.
    volumes:
      - ./locksmith/ca.crt:/etc/locksmith/ca.crt:ro
      - ./locksmith/server.crt:/etc/locksmith/server.crt:ro
      - ./locksmith/server.key:/etc/locksmith/server.key:ro
```

**Pros:**
- Real role separation: agent operator (laptop user) and proxy
  operator (server admin) are physically different people /
  machines / accounts.
- Provider keys never on the agent host. Stolen laptop gives you a
  bearer; provider keys are still safe on the server.
- Multi-agent: many laptops can share one stack.

**Cons:**
- LAN reachability required (DNS / static IP / Tailscale / VPN).
- More moving parts (cert distribution if mTLS).
- Slightly higher latency (one network hop).

**Use when**: small team, household with multiple users, security-
conscious developer who wants real role separation.

## LAN-spread (production)

```
                       ┌─ ops VLAN ─────────────────────────┐
                       │                                    │
┌─ user-1 host ─┐      │  ┌─ proxy host ─────────────────┐  │      ┌─ external ─┐
│ hermes-alice  │──────┼─▶│ layer8-proxy stack           │──┼─────▶│ Internet   │
└───────────────┘      │  │ - locksmith :9200 (mTLS)     │  │      │ providers  │
                       │  │ - pipelock                   │  │      └────────────┘
┌─ user-2 host ─┐      │  │ - lf-scan                    │  │
│ openclaw-bob  │──────┼─▶│                              │  │
└───────────────┘      │  └──────────────────────────────┘  │
                       │           │                        │
┌─ ci runner ────┐     │           │ admin HTTPS :9201      │
│ ci-pipeline    │─────┼───────────┘ (operator clients)     │
└────────────────┘     │                                    │
                       └────────────────────────────────────┘
```

**Locksmith binds**:
- Agent listener: `0.0.0.0:9200` (mTLS-only — `auth_mode: mtls`).
- Admin HTTPS: `0.0.0.0:9201` (operator clients connect from
  workstations, CI runners, etc.).

**Operator credentials**: stored in a password manager / vault /
sealed-creds; loaded at admin-CLI invocation time. NOT on the proxy
host alongside the daemon.

**`docker-compose.override.yml`**:
```yaml
services:
  locksmith:
    ports:
      - "0.0.0.0:9200:9200"   # agent listener
      - "0.0.0.0:9201:9201"   # admin HTTPS (M4)
    volumes:
      - ./locksmith/ca.crt:/etc/locksmith/ca.crt:ro
      - ./locksmith/server.crt:/etc/locksmith/server.crt:ro
      - ./locksmith/server.key:/etc/locksmith/server.key:ro
      - ./locksmith/admin.crt:/etc/locksmith/admin.crt:ro
      - ./locksmith/admin.key:/etc/locksmith/admin.key:ro
```

**Pros:**
- Three-way role separation: agents, agent operators, proxy
  operators.
- Audit trail attributes calls to per-agent identities.
- mTLS gives strong cryptographic agent identity (vs bearer
  which can leak).
- Operator host can be rebuilt without affecting agents (only the
  agent-listener cert + bearer config are agent-side).

**Cons:**
- PKI overhead (CA, cert minting, rotation). Mitigated by tooling
  like `step-ca` — see `agent-locksmith/dist/examples/smallstep-mtls/`.
- Network plumbing (DNS, firewall rules, possibly VPN).
- More to monitor (admin HTTPS, agent listener, internal services).

**Use when**: multi-user organization, regulated workload, anything
that needs real audit isolation across users.

## Choosing between them

| Factor | Same-host | Neutral-host | LAN-spread |
|---|---|---|---|
| Setup complexity | Lowest | Medium | High |
| Agent ↔ proxy latency | <1 ms | 1–5 ms (LAN) | 1–5 ms (LAN) |
| Provider-key isolation | Logical | Physical (different host) | Physical + mTLS attestation |
| Multi-agent support | Yes (separate registrations) | Yes | Yes |
| Multi-user support | Single-user (same uid) | Multi-user (separate hosts) | Multi-user (separate identities) |
| Cert management | None | Optional | Required |
| Best for | Dev / eval | Household / small team | Org / production |

You can also **mix** — e.g., two same-host installs (one per user
on one Mac, both with their own locksmith container — different
ports, different DBs). But typically pick one shape per
deployment unit.

## Migration paths

### Same-host → neutral-host

1. Stand up the neutral-host stack on the server.
2. Mint operator credential on the server.
3. Re-register all agents (each gets a new bearer; agent hosts
   need to update their token).
4. Decommission the same-host stack.

The DB doesn't trivially migrate — different host, different
volume. Best approach: re-create state via the new admin endpoints
(re-register agents, re-bootstrap OAuth sessions). Audit history
restarts on the new host.

### Neutral-host → LAN-spread

Mostly a config change on the existing proxy host:

1. Mint a CA + server cert + per-agent client certs.
2. Add admin HTTPS to `docker-compose.override.yml`.
3. Flip `auth_mode: bearer` → `auth_mode: both`.
4. Distribute client certs to agents; register cert identities
   alongside existing bearers.
5. Once agents are presenting certs, flip `auth_mode: both` →
   `auth_mode: mtls`.

See [deploy.md](../deploy.md#mtls-rollout) for the full mTLS rollout
recipe.

## See also

- [deploy.md](../deploy.md) — production deploy recipes for each
  topology.
- [architecture.md](../architecture.md) — stack-level component
  diagram.
- [`agent-locksmith/dist/examples/smallstep-mtls/`](https://github.com/SentientSwarm/agent-locksmith/tree/develop/dist/examples/smallstep-mtls)
  — worked PKI setup.
