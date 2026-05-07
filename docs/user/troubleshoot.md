# Troubleshooting

The top failure modes you're likely to hit, with diagnosis recipes
and fixes. Triaged from real session findings during v1.0.0
verification.

## Quick triage cheatsheet

```bash
# Is the daemon up?
curl -sS http://127.0.0.1:9200/livez
# {"status":"live","uptime_seconds":N}

# Is it ready (all credentialed tools have resolved creds)?
curl -sS http://127.0.0.1:9200/readyz
# 200 → ready
# 503 → see "1. /readyz returns 503"

# What version + image are you running?
docker exec layer8-locksmith /usr/local/bin/locksmith --version
docker inspect layer8-locksmith --format '{{.Config.Image}}'

# Container logs (most recent failure usually here):
docker logs --tail 100 layer8-locksmith

# Audit query for a specific tool (operator credential required):
LOCKSMITH_OP_TOKEN="lkop_..." \
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith audit query --since-ms $(($(date +%s) * 1000 - 600000)) --tool anthropic
```

Keep these handy — most issues yield to one of these probes.

## 1. `/readyz` returns 503

**Symptom**: `{"status":"not_ready","reason":"tool_credentials_unresolved","tools":["foo","bar"]}`

**Diagnosis**: the listed tools have an `auth` block but no resolved
credential. Either the env var isn't set in the locksmith container,
or the value resolved to empty.

**Fix**:

```bash
# Confirm the env var is reaching the container.
docker exec layer8-locksmith env | grep ANTHROPIC_API_KEY
# Empty? → set it in the SITE's .env, not layer8-proxy/.env, and redeploy.

# Or list resolved tools (operator):
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith model list --format json | jq '.[] | {name, auth_resolved: .auth | tostring | contains("env_var")}'
```

After fixing the env var, restart locksmith:

```bash
docker compose -f $LAYER8_PATH/docker-compose.yml -f docker-compose.override.yml \
    --env-file ./.env restart locksmith
```

## 2. Agent gets 401 invalid_credential

**Symptom**:

```json
{"error":{"code":"invalid_credential","message":"invalid credential","type":"auth_error"}}
```

**Diagnosis**: the bearer token doesn't match any registered agent.
Either it was never registered, was revoked, or the agent host has a
stale token.

**Fix**:

```bash
# Confirm the agent IS registered:
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent list

# Check the wire format the agent is sending. The bearer should be:
#   lk_<22-char-public-id>.<43-char-secret>
# Common mistake: copying with whitespace, or saving only the public_id.

# Re-register if needed (this mints a NEW bearer; old one stays revoked):
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent register --name X --allowlist Y
```

## 3. Agent gets 403 tool_not_allowed

**Symptom**:

```json
{"error":{"code":"tool_not_allowed","message":"tool access denied","type":"authz_error"}}
```

**Diagnosis**: M9 ACL gate rejected the call. The agent is
authenticated, but the requested tool isn't in its `allowlist` (or
is in its `denylist`).

**Fix**:

```bash
# Check the agent's current ACL:
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent get <public_id>

# Add the tool to the allowlist:
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent modify --name <agent_name> \
    --allowlist anthropic,openai,tavily  # full list, comma-separated
```

The change takes effect on the next request — no agent restart.

## 4. 404 with "Unknown tool"

**Symptom**:

```json
{"error":{"message":"Unknown tool: foo","type":"not_found"}}
```

**Diagnosis**: the tool name in the URL (`/api/foo/...`) isn't
registered. Could be a typo or the tool was disabled/deleted.

**Fix**:

```bash
# List registered names:
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith model list
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith tool list
```

If the name's there but disabled (`disabled=true`):

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith model enable <name>
```

If it's not there at all, see [add-a-tool.md](add-a-tool.md).

## 5. Upstream returns 401

**Symptom**: agent call succeeded through locksmith but the upstream
provider rejected the credential.

```
HTTP 401 from /api/anthropic/v1/messages
{"error":{"type":"authentication_error","message":"invalid x-api-key"}}
```

**Diagnosis**: locksmith forwarded the request, but the credential
it injected is wrong/expired/typo'd. The agent's bearer was fine —
this is the **provider** rejecting the key locksmith holds.

**Fix**:

```bash
# Test the env var directly against the provider:
ANTHROPIC_API_KEY=$(grep ^ANTHROPIC_API_KEY .env | cut -d= -f2) \
    curl -sS https://api.anthropic.com/v1/models -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01"

# If that 401s too, the key is bad — get a fresh one and update .env.
# Then restart locksmith to re-resolve.
```

## 6. LM Studio 401

**Symptom**: locksmith proxies LM Studio calls but they 401.

**Diagnosis**: LM Studio v0.3.0+ ships with API token auth enabled
by default. The seed catalog's `lmstudio` entry has `auth: none`,
which assumes authless LM Studio.

**Fix**: override the seed entry to use bearer auth.

```bash
# 1. Get LM Studio's API key from Settings → Developer → "API Key" tab.
# 2. Add to your .env:
#      LM_STUDIO_API_KEY=<paste-from-LM-Studio-settings>
# 3. Override the seed entry:
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith model put lmstudio \
    --upstream http://host.docker.internal:1234 \
    --auth bearer=LM_STUDIO_API_KEY
# 4. Restart locksmith:
docker compose ... restart locksmith
```

## 7. Daemon won't start

**Symptom**: `docker compose up` shows locksmith exiting immediately.

**Common causes:**

| Symptom in logs | Cause | Fix |
|---|---|---|
| `operator credentials path not configured` | `operator_credentials_path` missing in config | Add to `locksmith/base.yaml`, default `/etc/locksmith/operators.yaml`. |
| `operator credentials: file not found` | `operators.yaml` doesn't exist | Run `bootstrap-operator.py` (or the Rust subcommand) to create it. |
| `operator credentials: invalid YAML` | `operators.yaml` is malformed | Re-run bootstrap-operator (overwrites). |
| `database open: ...` | DB path not writable | Check volume mount + filesystem permissions. |
| `oauth sealing key: ...` | `LOCKSMITH_OAUTH_SEALING_KEY` malformed (must be base64-encoded 32 bytes) | Regenerate: `openssl rand -base64 32`. |
| `seed catalog load failed` | Bundled catalog YAML in image is corrupt | Re-pull/rebuild the locksmith image. |

```bash
# Inspect the actual error:
docker logs layer8-locksmith 2>&1 | tail -30
```

## 8. Healthcheck fails on stale image

**Symptom**: `docker ps` shows locksmith as `(unhealthy)` but `/livez`
returns 200 manually.

**Diagnosis**: pre-v2.0.0 locksmith images had a HEALTHCHECK that
called `locksmith status` (which requires a token the daemon
container doesn't carry). The check fails despite the daemon being
healthy. Fixed in v2.0.0+ — uses `curl -fsS /livez`.

**Fix**: bump `LOCKSMITH_VERSION` to `v2.0.0` (or later) in your
site's `.env`. Or as a workaround, override `healthcheck:` in
`docker-compose.override.yml` to disable.

## 9. `deploy.sh` fails on render

**Symptom**: `render_configs.py` errors with "tool name conflict"
or "duplicate tool" or "yaml.scanner.ScannerError".

**Diagnosis**: `tools/*.yaml` in your site repo has malformed YAML
or duplicate entries.

**Fix**: validate each file:

```bash
for f in tools/*.yaml; do
    [[ "$f" == *_defaults.yaml ]] && continue
    python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "OK: $f"
done
```

Post-Phase-E, the seed catalog handles the 16 default providers —
you typically don't need any `tools/*.yaml` at all. If you have
holdovers from a pre-v2.0.0 deploy, consider deleting them and
using `locksmith {tool,model} put` instead.

## 10. Pipelock blocks an upstream

**Symptom**: agent call → locksmith proxies → pipelock returns 403
with a message about disallowed host.

**Diagnosis**: the upstream's hostname isn't in pipelock's
`api_allowlist` or `api_allowlist_extras`.

**Fix**: add the host to `pipelock/pipelock.yaml`:

```yaml
api_allowlist:
  - "*.anthropic.com"
  - "*.openai.com"
  - "your-internal-api.corp"   # add this
  ...
```

Restart pipelock:

```bash
docker compose ... restart pipelock
```

For tools added via `locksmith tool put`, the host is NOT
auto-added to pipelock — that's the D-16 work scoped for v2.1.0.
For now, manual coordination.

## 11. OAuth bootstrap fails

**Symptom**: `locksmith oauth bootstrap codex --refresh-token ...`
returns 502 `oauth_bootstrap_failed`.

**Diagnosis**: the daemon successfully sealed your refresh token
but the inline first-refresh failed against the provider.

**Common causes**:

| Provider response | Meaning | Fix |
|---|---|---|
| 401 invalid_grant | Refresh token expired or revoked | Get a fresh refresh token from the provider's CLI. |
| 401 invalid_client | client_id mismatch (rare with seed catalog values) | Confirm the seed catalog hasn't been overridden incorrectly. |
| Network error | Provider unreachable | Check pipelock allowlist + connectivity. |
| 5xx | Provider-side outage | Wait + retry. |

The half-bootstrapped session row is rolled back automatically — you
can retry without `revoke` first.

## 12. Audit log has no rows

**Symptom**: `locksmith audit query` returns empty even though
agents are calling locksmith.

**Diagnosis**: most likely the agent calls aren't actually
authenticated, or the daemon was restarted with a fresh DB volume.

**Fix**:

```bash
# Confirm the daemon is the same DB volume as before:
docker volume inspect layer8-proxy_locksmith_data

# Check audit table directly:
docker exec layer8-locksmith ls -la /var/lib/locksmith/locksmith.db*

# Look for failed-auth rows (those get audited too):
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith audit query --decision denied --since-ms $(($(date +%s) * 1000 - 600000))
```

If the volume was recreated, you've lost prior audit history. Set
up `audit.jsonl_path` in `locksmith/base.yaml` for a JSONL mirror
that survives volume recreation.

## Getting help

- Open an issue at
  [github.com/SentientSwarm/layer8-proxy/issues](https://github.com/SentientSwarm/layer8-proxy/issues)
  with a redacted `docker logs --tail 100 layer8-locksmith` output.
- For agent-locksmith bugs:
  [github.com/SentientSwarm/agent-locksmith/issues](https://github.com/SentientSwarm/agent-locksmith/issues).
- The full stack design: [`agents-stack/docs/spec/v0.2.0.md`](https://github.com/SentientSwarm/agents-stack/blob/main/docs/spec/v0.2.0.md).
