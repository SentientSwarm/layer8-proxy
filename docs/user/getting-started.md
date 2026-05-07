# Getting started

Deploy a layer8-proxy v1.0.0 stack on a fresh host, register your first
agent, and make a real call to a provider — all from the public repos.

This doc takes about 10–15 minutes if you have an Anthropic / OpenAI /
similar API key handy. No prior layer8-proxy experience required.

## Prerequisites

- **Docker** (or Podman) with the `compose` plugin.
  - macOS: Docker Desktop, OrbStack, or Podman Desktop.
  - Linux: `docker-ce` + `docker-compose-plugin` package.
- **Git**.
- **At least one provider API key** to verify with — Anthropic
  (`ANTHROPIC_API_KEY`) is the easiest, but OpenAI, Tavily, GitHub
  also work.
- **A directory you don't mind cloning two repos into** (we'll create
  a sibling site repo).

Optional but recommended:
- `openssl` for generating sealing keys.
- `systemd-creds` (Linux) for sealed-cred storage. macOS dev hosts
  fall back to openssl + a passphrase.

## Step 1: Clone layer8-proxy

```bash
git clone git@github.com:SentientSwarm/layer8-proxy.git
cd layer8-proxy
```

This is the public bundle — Docker Compose definitions for the three
components (locksmith, pipelock, lf-scan) and the build context for
the locksmith image.

## Step 2: Generate a site repo

A *site repo* is the per-host operator state — sealed credentials,
agent manifests, version pins, deploy automation. It's separate from
the bundle so you can update layer8-proxy without touching your
sealed creds, and so multiple deployments can pin different versions.

```bash
./scripts/init-site.sh ../my-site
cd ../my-site
```

The init script:
- Copies the public-shape template at `layer8-proxy/examples/site/`.
- Renames `*.example` → canonical names (`site.cfg.example` →
  `site.cfg`, etc.).
- Runs `git init` so you can track operator state from day zero.

You'll see a checklist of next steps printed to the terminal — they
mirror the rest of this document.

## Step 3: Edit `site.cfg`

```bash
nano site.cfg
```

Fill in:

```
site_name=my-laptop          # any free-form identifier
host=$(hostname)             # this host's name; appears in audit
layer8_path=../layer8-proxy  # already correct from init-site.sh
layer8_version=v1.0.0        # current release; pairs with locksmith v2.0.0
```

## Step 4: Edit `.env`

```bash
nano .env
```

The init script copied `.env.example` to `.env`. Set at minimum:

```bash
# Internal token for locksmith ↔ lf-scan communication.
# Generate fresh with:  openssl rand -hex 32
LF_SCAN_INTERNAL_TOKEN=<paste-32-bytes-hex-here>

# At least one provider API key — Anthropic is the easiest demo.
ANTHROPIC_API_KEY=sk-ant-...
```

If you're on a non-systemd host (macOS dev), also set:

```bash
LOCKSMITH_CREDS_PASSPHRASE=<your-chosen-passphrase>
```

This is the symmetric key for the macOS sealed-cred fallback. Pick
something memorable; you'll need it in step 5 and at every deploy.

## Step 5: Bootstrap sealed credentials

The deployment expects two sealed-cred files:

```bash
echo -n "$LF_SCAN_INTERNAL_TOKEN" | ./secrets.bootstrap.sh lf_scan_token --from-stdin
echo -n "your-restic-passphrase"  | ./secrets.bootstrap.sh restic_password --from-stdin
```

Each command writes a `locksmith/secrets/<name>.creds` file.

The restic password is for backups (`backup.sh`); pick any string —
you only need it if you'll run scheduled backups.

## Step 6: Mint the operator credential

The operator credential is what proves you're the operator when
calling admin endpoints (`locksmith agent register`,
`locksmith model put`, `locksmith audit query`, etc.).

Two paths — both produce the same `operators.yaml` shape.

### Path A — Rust-native (post-deploy, v2.0.0+)

After the stack is up (step 8), run:

```bash
docker exec layer8-locksmith /usr/local/bin/locksmith bootstrap-operator --name alice \
    > locksmith/operators.yaml
# The cleartext wire token is printed to stderr ONCE. Save it now:
#
#   export LOCKSMITH_OP_TOKEN=lkop_<public_id>.<secret>
#
# Or seal it with secrets.bootstrap.sh:
echo -n "$LOCKSMITH_OP_TOKEN" | ./secrets.bootstrap.sh operator_token --from-stdin
```

You'll need to restart locksmith once the operators.yaml file exists
(see step 8b).

### Path B — Python script (pre-deploy)

Or do it before deploy:

```bash
LOCKSMITH_CREDS_PASSPHRASE="$LOCKSMITH_CREDS_PASSPHRASE" \
    ./scripts/bootstrap-operator.py
```

This writes `locksmith/operators.yaml` AND seals the cleartext wire
token into `locksmith/secrets/operator_token.creds`.

## Step 7: Declare your first agent

```bash
cp agents.yaml.example agents.yaml
nano agents.yaml
```

Minimal example:

```yaml
agents:
  - name: my-first-agent
    description: "My laptop's hermes/openclaw"
    allowlist:
      - anthropic   # the agent can only call /api/anthropic/...
```

The allowlist enforces what tools each agent can reach. Add more
names from the seed catalog (`openai`, `tavily`, `github`, etc.) as
you need them.

## Step 8: Deploy

```bash
./deploy.sh
```

The deploy script:
1. Renders any site-local `tools/*.yaml` overrides into compose mounts.
2. Verifies render output against pipelock allowlist (refuses drift).
3. Builds the layer8-proxy images (locksmith from agent-locksmith
   v2.0.0 source).
4. Brings the stack up: `docker compose up -d --build`.
5. Runs `verify.sh` — checks `/livez`, `/readyz`, `/version`,
   pipelock health.

You should see:

```
✓ locksmith /livez
✓ locksmith /readyz
✓ locksmith /version
✓ pipelock healthcheck (via docker exec)
✓ Stack verified.
✓ Deploy complete.
```

### 8b — first deploy operator credential dance

If you took **Path A** in step 6 (Rust-native, post-deploy), do it now:

```bash
docker exec layer8-locksmith /usr/local/bin/locksmith bootstrap-operator --name alice \
    > locksmith/operators.yaml
docker compose -f $LAYER8/docker-compose.yml -f docker-compose.override.yml \
    --env-file ./.env restart locksmith
```

The restart re-reads `operators.yaml`. Save the wire token to
`LOCKSMITH_OP_TOKEN` for step 9.

## Step 9: Register your agent

```bash
./scripts/register-agents.sh
```

This reads `agents.yaml`, calls `locksmith agent register --name X --allowlist Y`
for each entry, and prints the resulting bearer token **once per
agent**. Sample output:

```
✓ my-first-agent registered.
  bearer: lk_yN2vR6jFKNYfIwNjFU2MSA.1TJlTmOgmswZYZx_aQHyjaNiugeJjudytNPFJgT9aqM
  Save this token NOW. It cannot be recovered.
```

Save the bearer — you'll use it as your agent's locksmith token.

## Step 10: Make your first call

Use the bearer to call a provider through locksmith:

```bash
AGENT_TOKEN="lk_yN2v..."  # from step 9

# 10.1 — verify discovery (kind=model, ACL-filtered)
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" http://127.0.0.1:9200/models
# {"models":[{"name":"anthropic","path":"/api/anthropic","type":"api","description":"..."}]}

# 10.2 — real Anthropic call (no ANTHROPIC_API_KEY needed by your client)
curl -sS -X POST http://127.0.0.1:9200/api/anthropic/v1/messages \
    -H "Authorization: Bearer $AGENT_TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d '{
          "model":"claude-haiku-4-5",
          "max_tokens":40,
          "messages":[{"role":"user","content":"Say SMOKE TEST PASS"}]
        }'
```

If you see `{"content":[{"type":"text","text":"SMOKE TEST PASS"}], ...}`
back from Anthropic — **the stack works end-to-end**:

- Your client sent the agent's locksmith bearer.
- Locksmith authenticated the bearer, checked the ACL, stripped the
  agent's headers, injected the real `x-api-key` from your sealed
  `.env`, and forwarded to Anthropic.
- Anthropic returned a real completion.
- Locksmith streamed it back to your client + wrote one audit row.

## Step 11: Inspect the audit trail

```bash
LOCKSMITH_OP_TOKEN="lkop_..."
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith audit query --since-ms $(($(date +%s) * 1000 - 300000)) --tool anthropic
```

You'll see rows like:

| event | decision | tool | status | auth_method | agent_public_id |
|---|---|---|---|---|---|
| proxy_request | allowed | anthropic | 200 | bearer | yN2vR6jFKNYfI... |

The `auth_method=bearer` means the agent authenticated to locksmith
with a bearer token. The `details.auth_mode=header` (visible in
`--format json` output) means locksmith injected an `x-api-key`
header to Anthropic.

## What's next

- **Add a tool not in the seed catalog**:
  [add-a-tool.md](add-a-tool.md).
- **Override a seed default** (e.g., LM Studio on a non-default
  host): same doc.
- **Add another agent**: [add-an-agent.md](add-an-agent.md).
- **Wire openclaw or hermes through this proxy**: see
  [`agent-locksmith/docs/user/agent-integration/`](https://github.com/SentientSwarm/agent-locksmith/tree/develop/docs/user/agent-integration).
- **Hit a snag**: [troubleshoot.md](troubleshoot.md).
- **Production hardening** (real provider mTLS, sealed-creds
  rotation, multi-host topology): [deploy.md](deploy.md).

## See also

- [`agent-locksmith/docs/user/concepts/`](https://github.com/SentientSwarm/agent-locksmith/tree/develop/docs/user/concepts)
  — kind taxonomy, trust boundary, agent identity + ACL,
  error envelope.
- [`agents-stack/docs/spec/v0.2.0.md`](https://github.com/SentientSwarm/agents-stack/blob/main/docs/spec/v0.2.0.md)
  — formal stack spec.
- [`examples/site/README.md`](../../examples/site/README.md) — site
  template structure walkthrough.
