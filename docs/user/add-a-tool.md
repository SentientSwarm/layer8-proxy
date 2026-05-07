# Add a tool

Three operator scenarios:

1. **Override a seed catalog default** — host-specific upstream URL,
   different auth shape, etc.
2. **Disable a seed catalog default** — your deployment doesn't use
   one of the bundled providers.
3. **Register a custom tool not in the seed catalog** — internal API,
   private model gateway, anything HTTP-shaped.

All three use the same admin API (`locksmith {tool,model,infra} put`)
and share the same registration shape. The only differences are the
flow and what state changes in the registrations table.

## Recap: what's in the seed catalog

At v1.0.0, the locksmith image bakes a 16-entry seed catalog:

| kind | name | auth | notes |
|---|---|---|---|
| model | anthropic | header `x-api-key` | env: `ANTHROPIC_API_KEY` |
| model | openai | bearer | env: `OPENAI_API_KEY` |
| model | openrouter | bearer | env: `OPENROUTER_API_KEY` |
| model | ai-gateway | bearer | env: `AI_GATEWAY_API_KEY` |
| model | ollama | none | LAN-typical authless |
| model | lmstudio | none | host.docker.internal:1234 default |
| model | codex | oauth_device_code | OpenAI ChatGPT plan auth (Phase F) |
| model | copilot | oauth_device_code | GitHub Copilot (Phase F) |
| model | anthropic-oauth | oauth_pkce | Anthropic Console OAuth (Phase F) |
| model | google-gemini-cli | oauth_pkce | Google Gemini CLI (Phase F) |
| model | qwen-cli | oauth_device_code | Alibaba Qwen CLI (Phase F) |
| tool | tavily | bearer | env: `TAVILY_API_KEY` |
| tool | github | bearer | env: `GITHUB_TOKEN` |
| tool | duckduckgo | none | authless instant-answer API |
| tool | wikipedia | none | authless REST API |
| infra | lf-scan | header `X-Internal-Token` | operator-only middleware |

You can see the full state from your locksmith host:

```bash
LOCKSMITH_OP_TOKEN="lkop_..."
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith model list
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith tool list
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith infra list
```

Rows with `seed=true` came from the bundled catalog. `seed=false`
rows are operator-owned (you put them, or you overrode a seed default).
Rows with `disabled=true` are seed entries you've deleted.

## Scenario 1: Override a seed default

Common reason: your LM Studio is on a non-default LAN host and
requires API token auth.

```bash
LOCKSMITH_OP_TOKEN="lkop_..."
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith model put lmstudio \
    --upstream http://mac-server.lan:1234 \
    --auth bearer=LM_STUDIO_API_KEY \
    --description "LM Studio on LAN with token auth"
```

Effect:
- The `lmstudio` row's `seed` flips from `true` to `false` (now operator-owned).
- Image upgrades **preserve** your override — the seed loader skips
  `seed=false` rows when applying diffs.
- `LM_STUDIO_API_KEY` env var must be set on the locksmith container
  (via your `.env`) — locksmith reads it at startup and on admin
  refresh.

The `--auth` flag accepts:

| Form | AuthSpec variant | Effect |
|---|---|---|
| `none` | `None` | No header injection (operator-stated authless). |
| `header:NAME=ENV_VAR` | `Header { header: NAME, env_var: ENV_VAR }` | Inject `NAME: <env-var-value>`. |
| `bearer=ENV_VAR` | `Bearer { env_var: ENV_VAR }` | Inject `Authorization: Bearer <env-var-value>`. |

For OAuth providers — DON'T put OAuth shape via `--auth` directly.
Override fields like `--upstream` if needed; OAuth client metadata
(client_id, scopes, URLs) typically don't need overriding. Use
`locksmith oauth bootstrap <name>` to provide the refresh token.

## Scenario 2: Disable a seed default

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith model delete openrouter
```

Effect:
- For seed rows: sets `disabled=true`. The row stays in the table
  (so the seed loader knows you suppressed it) but `lookup_active`
  returns `None` and the row vanishes from `/tools` / `/models` /
  proxy hot path.
- For operator-owned rows (`seed=false`): hard-deletes the row.

To bring it back:

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith model enable openrouter
```

## Scenario 3: Register a custom tool

Register a new tool that's not in the seed catalog — e.g., a private
internal API.

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith tool put internal-api \
    --upstream https://api.internal.corp \
    --auth header:X-Internal-Key=INTERNAL_API_KEY \
    --description "Internal corp API" \
    --metadata capability=custom \
    --metadata provider=internal
```

Set `INTERNAL_API_KEY` in your `.env` and restart locksmith
(or `locksmith refresh-creds` if hot-reload is wired).

To grant agents access:

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent modify --name hermes-mini-m1 \
    --allowlist anthropic,openai,internal-api
```

Per-kind validation rules:

- `kind=tool` — `auth: <something>` is required (use `auth: none`
  for deliberately authless). Implicit absence → 400.
- `kind=model` — same as `kind=tool`. `auth: none` is accepted (for
  LAN-local self-hosted models like Ollama).
- `kind=infra` — operator-only middleware (lf-scan-shaped). Not
  exposed in agent discovery (`/tools`, `/models`).

## Reserved names

These names are rejected at register-time with `400 / reserved_name`:

```
livez, readyz, version, health, skill, tools, models, admin, api,
metrics, audit
```

They conflict with locksmith's own routes.

## Cross-kind name reuse

A name belongs to exactly one `kind`. You can't have a `tool` named
`anthropic` if a `model` already has that name (409 `name_in_use`).
This keeps the agent-side ACL flat — agents reference names directly,
locksmith resolves the kind at request time.

## OAuth providers

The five OAuth providers (codex, copilot, anthropic-oauth,
google-gemini-cli, qwen-cli) are seeded but **disabled until you
provide a sealing key**.

### Enable OAuth

```bash
# 1. Generate a sealing key once at install time.
SEALING=$(openssl rand -base64 32)

# 2. Stash it in your sealed-cred store.
echo -n "$SEALING" | ./secrets.bootstrap.sh oauth_sealing_key --from-stdin

# 3. Wire LOCKSMITH_OAUTH_SEALING_KEY into the locksmith container's env
#    via docker-compose.override.yml. The default override uses
#    decrypt-creds.sh to unwrap at deploy time.

# 4. Restart locksmith.
./deploy.sh
```

### Bootstrap a session

```bash
# Get a refresh token via the provider's own OAuth flow (codex auth login,
# claude auth, gh auth login, etc.).
REFRESH_TOKEN="<paste-refresh-token-here>"

docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith oauth bootstrap codex \
    --refresh-token "$REFRESH_TOKEN"
```

The daemon does an inline refresh against the provider's token
endpoint to verify the refresh token works, then seals both the
refresh and access tokens.

### Status / revoke

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith oauth status codex
# {"name":"codex","present":true,"degraded":false,"access_token_expires_at":...}

docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith oauth revoke codex
# Clears local state. Provider-side revocation deferred to v1.1+.
```

### Degraded sessions

If a refresh fails (e.g., provider invalidated the refresh token),
the session is marked `degraded=true`. Subsequent proxy calls return
503 with `oauth_refresh_failed`. Recovery: re-run
`locksmith oauth bootstrap <name> --refresh-token <new-token>` after
re-authenticating with the provider.

## See also

- [add-an-agent.md](add-an-agent.md) — granting agents access to tools.
- [`agent-locksmith/docs/user/concepts/kind-taxonomy.md`](https://github.com/SentientSwarm/agent-locksmith/blob/develop/docs/user/concepts/kind-taxonomy.md)
  — kind=model vs kind=tool vs kind=infra rationale.
- [`agent-locksmith/docs/adrs/0005-oauth-credentials.md`](https://github.com/SentientSwarm/agent-locksmith/blob/develop/docs/adrs/0005-oauth-credentials.md)
  — OAuth credential design.
