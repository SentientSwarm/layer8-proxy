# Smoke test

`verify.sh` is the canonical post-deploy smoke. This doc covers what
it actually checks, the env vars that switch on auth-enforcement
checks, and how to extend it for site-specific assertions.

## What `verify.sh` does

```bash
$LAYER8_PATH/scripts/verify.sh
```

By default (no env vars set), checks:

- `GET /livez` returns 200
- `GET /readyz` returns 200
- `GET /version` returns 200 with `{"name":"agent-locksmith","version":"X.Y.Z"}`
- pipelock healthcheck via `docker exec`
- (lf-scan check skipped — no lf-scan tool registered yet)

This proves the daemon is up and responsive. It does NOT prove auth
enforcement works.

## Auth-enforcement checks

To enable the auth-allowlist checks, set three env vars before
calling `verify.sh`:

```bash
LOCKSMITH_VERIFY_TOKEN="lk_<bearer-of-the-test-agent>"
LOCKSMITH_VERIFY_ALLOWED_TOOL="lmstudio"      # in the test agent's allowlist
LOCKSMITH_VERIFY_DENIED_TOOL="anthropic"      # NOT in the test agent's allowlist
$LAYER8_PATH/scripts/verify.sh
```

Adds:

- `GET /api/<allowed-tool>/...` returns ≠ 401, ≠ 403 (proxy reached
  the upstream, even if upstream returned 4xx for other reasons —
  the *gate* worked).
- `GET /api/<denied-tool>/...` returns 403 with code
  `tool_not_allowed` (proves the ACL deny path works).
- No-token call to the same endpoint returns 401 with code
  `missing_credential`.

## Recommended: a smoke-test agent

The site template ships `agents.test.yaml.example`:

```yaml
agents:
  - name: hermes-test
    description: "Smoke test agent (lmstudio only)"
    allowlist:
      - lmstudio
```

Use this for the smoke checks — the allowlist is deliberately narrow
so the deny-path check has a target.

```bash
# Register the test agent.
cp agents.test.yaml.example agents.test.yaml
AGENTS_MANIFEST=./agents.test.yaml ./scripts/register-agents.sh
# Capture the bearer; export as LOCKSMITH_VERIFY_TOKEN.

# Run with auth enforcement on.
LOCKSMITH_VERIFY_TOKEN="lk_..." \
LOCKSMITH_VERIFY_ALLOWED_TOOL=lmstudio \
LOCKSMITH_VERIFY_DENIED_TOOL=anthropic \
    $LAYER8_PATH/scripts/verify.sh
```

Don't reuse a production agent's bearer for verify — keep the
smoke-test agent isolated.

## Manual probes

Beyond `verify.sh`, useful one-shots:

### Discovery

```bash
AGENT_TOKEN="lk_..."
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" http://127.0.0.1:9200/tools
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" http://127.0.0.1:9200/models
```

Expected: ACL-filtered list of registrations the agent's allowlist
permits. `kind=infra` registrations (lf-scan) should NOT appear.

### Real provider call

```bash
curl -sS -X POST http://127.0.0.1:9200/api/anthropic/v1/messages \
    -H "Authorization: Bearer $AGENT_TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d '{"model":"claude-haiku-4-5","max_tokens":40,"messages":[{"role":"user","content":"Reply: SMOKE TEST PASS"}]}'
```

Expected: 200 from Anthropic with `"text":"SMOKE TEST PASS"` in the
content array.

### ACL deny

```bash
# Use a tool the agent does NOT have in allowlist.
curl -sS -X POST http://127.0.0.1:9200/api/openai/v1/chat/completions \
    -H "Authorization: Bearer $AGENT_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}]}'
```

Expected: 403 with `{"error":{"code":"tool_not_allowed",...}}`.

### Audit verification

```bash
LOCKSMITH_OP_TOKEN="lkop_..."
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith audit query \
    --since-ms $(($(date +%s) * 1000 - 600000)) --format json | jq '.[] | {event, decision, tool, status, agent: .agent_public_id}'
```

Expected rows from the smoke calls above:

| event | decision | tool | status |
|---|---|---|---|
| proxy_request | allowed | anthropic | 200 |
| authz_denied | denied | openai | 403 |

### Latency probe

```bash
time curl -sS http://127.0.0.1:9200/livez
# real    0m0.005s — a few ms is normal
```

Anything > 100ms on `/livez` warrants investigation (DNS, container
networking, or daemon slowness).

### Streaming probe

```bash
curl -N -sS -X POST http://127.0.0.1:9200/api/anthropic/v1/messages \
    -H "Authorization: Bearer $AGENT_TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d '{"model":"claude-haiku-4-5","max_tokens":300,"stream":true,"messages":[{"role":"user","content":"count to 20"}]}' \
    | head -50
```

Expected: SSE frames (`data: {...}\n\n`) flow chunk-by-chunk; no
buffering. R-N6: ≤100ms first-byte added latency.

## Continuous verification (production cron)

For production hosts, run a slimmed `verify.sh` every 5 minutes:

```bash
*/5 * * * * /path/to/layer8-proxy/scripts/verify.sh > /var/log/layer8-verify.log 2>&1 || \
    /path/to/notify-oncall.sh "layer8-proxy verify failed on $(hostname)"
```

`verify.sh` exits 0 on green, non-zero on any check failure — wire
that into your alerting system.

For deeper checks (real provider call, ACL gates), use a separate
script with the smoke-test agent's bearer; running real provider
calls every 5 minutes burns API budget.

## Per-tool smoke

If you want to verify each registered tool individually (e.g., as
part of a pre-prod sign-off):

```bash
# All in agent's allowlist.
for tool in anthropic openai tavily lmstudio; do
    echo "→ $tool"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $AGENT_TOKEN" \
        "http://127.0.0.1:9200/api/$tool/v1/models")
    echo "    HTTP $code"
done
```

Expected: 200 (or 4xx for tools that don't have `/v1/models`, like
duckduckgo) for every name in the allowlist. 404 indicates the
tool isn't registered. 403 indicates ACL drift.

## Extending verify.sh

`verify.sh` is a plain bash script — site-specific assertions just
go after the bundle's checks:

```bash
# Add to the end of your site's deploy.sh, or wrap verify.sh:
$LAYER8_PATH/scripts/verify.sh

# Site-specific extras:
echo "→ Verifying our internal API is reachable..."
INTERNAL_KEY=$(./scripts/decrypt-creds.sh ./locksmith/secrets/internal_api_key.creds)
ANTHROPIC_API_KEY="$INTERNAL_KEY" \
    curl -sS https://api.internal.corp/health || exit 1
echo "✓ Internal API reachable"
```

## Failure → diagnosis flow

If `verify.sh` fails, [troubleshoot.md](troubleshoot.md) has the top
12 failure modes mapped to fixes. The first three steps:

1. `docker logs --tail 100 layer8-locksmith`
2. `curl http://127.0.0.1:9200/readyz` (look for unresolved
   credentials)
3. `docker exec -e LOCKSMITH_OP_TOKEN="$OP" layer8-locksmith locksmith audit query --decision denied --since-ms ...`
   (look for hidden auth/ACL failures).

Most issues yield to one of those probes.

## See also

- [troubleshoot.md](troubleshoot.md) — failure modes by symptom.
- [`scripts/verify.sh`](../../scripts/verify.sh) — the script source.
- [getting-started.md](getting-started.md) — first-time deploy
  walkthrough; uses verify.sh in step 8.
