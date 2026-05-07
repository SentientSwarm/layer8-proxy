# Add an agent

Each "agent" in layer8-proxy is a distinct identity holding its own
bearer token with its own ACL. Multiple agents on the same host get
distinct identities and separate audit trails.

This doc walks through adding a new agent end-to-end.

## When to add an agent

Add an agent when you have **a new identity that should call
providers through locksmith** with a defined access scope. Examples:

- A new hermes / openclaw / custom agent process on the same host.
- A different user's agent on the same shared infrastructure (each
  user gets their own bearer + ACL).
- A test agent with a deliberately narrow allowlist for verification.

You do **not** need to add an agent to call from `curl` for ad-hoc
testing — but a real agent should always have its own bearer.

## Step 1: Edit `agents.yaml`

```bash
cd /path/to/your/site-repo
nano agents.yaml
```

Add an entry:

```yaml
agents:
  - name: hermes-mini-m1                       # required, unique
    description: "hermes on the M1 mini"        # free-form
    allowlist:                                  # required for restricted access
      - anthropic
      - openai
      - lmstudio
      - tavily

  - name: openclaw-laptop                       # second agent, different ACL
    description: "openclaw, alice's laptop"
    allowlist:
      - codex
      - github
```

**Field reference:**

| Field | Required | Description |
|---|---|---|
| `name` | yes | Unique identifier. Appears in audit. |
| `description` | no | Free-form note. |
| `allowlist` | one of allow/deny | Permitted tool/model names (subset of seed catalog + your overrides). |
| `denylist` | one of allow/deny | Inverse — permit everything except these. |
| `cert_identity` | no | mTLS path. Cert's CN/SAN bound to this agent (see mTLS section). |

**Allowlist vs denylist:**

- `allowlist: [a, b]` → agent can ONLY call `a` and `b`.
- `denylist: [c]` → agent can call EVERYTHING except `c`.
- Don't set both. If neither is set, the agent has no permitted
  tools (effectively disabled).

## Step 2: Register

```bash
./scripts/register-agents.sh
```

The script:
1. Reads `agents.yaml`.
2. For each entry, calls `locksmith agent register --name X --allowlist Y`.
3. Prints the resulting bearer token **once per agent**:

```
→ Registering hermes-mini-m1 ...
✓ hermes-mini-m1 registered.
  bearer: lk_yN2vR6jFKNYfIwNjFU2MSA.1TJlTmOgmswZYZx_aQHyjaNiugeJjudytNPFJgT9aqM
  ⚠ Save this token NOW. It cannot be recovered. Re-registration mints a new one.
```

Re-running the script for an already-registered name is **not
idempotent** — locksmith refuses duplicate names. To refresh a
bearer: `locksmith agent revoke <public_id>` then re-register.

## Step 3: Install the bearer on the agent host

The bearer goes wherever the agent expects its locksmith token. Conventions:

### Hermes

```bash
# On the agent host:
mkdir -p ~/.hermes
chmod 700 ~/.hermes
echo "lk_..." > ~/.hermes/locksmith.token
chmod 600 ~/.hermes/locksmith.token
```

Hermes' provider config references `${LOCKSMITH_TOKEN}`; load it from
the file at hermes startup.

### Openclaw

```bash
# On the agent host:
export LOCKSMITH_TOKEN="lk_..."
export ANTHROPIC_BASE_URL="http://layer8.lan:9200/api/anthropic"
export ANTHROPIC_API_KEY="$LOCKSMITH_TOKEN"
export OPENAI_BASE_URL="http://layer8.lan:9200/api/openai"
export OPENAI_API_KEY="$LOCKSMITH_TOKEN"
```

The openclaw SDK uses standard `*_BASE_URL` + `*_API_KEY` conventions
— no openclaw code changes required.

See [`agent-locksmith/docs/user/agent-integration/openclaw.md`](https://github.com/SentientSwarm/agent-locksmith/blob/develop/docs/user/agent-integration/openclaw.md)
for the full openclaw recipe.

### Custom agent

Anything that does HTTP and supports `Authorization: Bearer ...`
works. Set:

```
base_url:    http://layer8.lan:9200/api/<tool-name>
auth_header: Authorization: Bearer <bearer-from-step-2>
```

Locksmith strips your bearer and replaces it with the provider's
real key before forwarding upstream.

## Step 4: Verify

From the agent host:

```bash
# Discovery — should list only the tools/models in your allowlist.
curl -sS -H "Authorization: Bearer lk_..." http://layer8.lan:9200/tools
curl -sS -H "Authorization: Bearer lk_..." http://layer8.lan:9200/models

# Real call — should succeed.
curl -sS -X POST http://layer8.lan:9200/api/anthropic/v1/messages \
    -H "Authorization: Bearer lk_..." \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d '{"model":"claude-haiku-4-5","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}'
```

From the operator side (the host running locksmith):

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith audit query --tool anthropic --since-ms $(($(date +%s) * 1000 - 300000))
```

You should see one `proxy_request` row per agent call with the
correct `agent_public_id` matching your registered agent.

## Rotating an agent's bearer

When the agent host changes hands, gets reimaged, or you suspect the
bearer leaked:

```bash
# Get the agent's public_id (from earlier registration output, or):
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent list

# Revoke + re-register.
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent revoke yN2vR6jFKNYfIwNjFU2MSA

docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent register --name hermes-mini-m1 \
    --allowlist anthropic,openai,lmstudio,tavily
```

The new bearer is unrelated to the old one — install it on the agent
host as in step 3.

## Modifying an agent's ACL

Add or remove tools without re-issuing the bearer:

```bash
# Add a tool to the allowlist:
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent modify --name hermes-mini-m1 \
    --allowlist anthropic,openai,lmstudio,tavily,duckduckgo

# Remove a tool:
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent modify --name hermes-mini-m1 \
    --allowlist anthropic,openai,lmstudio
```

Active sessions reflect the new ACL on the next request — no agent
restart required.

## mTLS-authenticated agents

For higher-security deployments, agents authenticate via mTLS client
certificates instead of bearer tokens.

Setup at agent-register time:

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent register --name hermes-mini-m1 \
    --allowlist anthropic,openai \
    --cert-identity 'CN=hermes-mini-m1.lan,O=YourOrg'
```

The agent presents a client cert whose subject matches; locksmith
maps cert → agent → ACL. See `dist/examples/smallstep-mtls/` in
agent-locksmith for a worked PKI setup.

## Decommissioning an agent

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent revoke <public_id>
```

The agent's bearer stops working immediately. Audit history is
retained per the daemon's `audit.retention_days` setting (default 90
days).

## See also

- [add-a-tool.md](add-a-tool.md) — registering tools the agent's
  ACL can reference.
- [troubleshoot.md](troubleshoot.md#agent-issues) — agent-specific
  failure modes.
- [`agent-locksmith/docs/user/concepts/agent-identity-and-acl.md`](https://github.com/SentientSwarm/agent-locksmith/blob/develop/docs/user/concepts/agent-identity-and-acl.md)
  — conceptual overview.
