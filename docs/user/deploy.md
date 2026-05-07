# Deploy (depth)

Companion to [getting-started.md](getting-started.md). This doc covers
the production deploy story: multi-host topologies, mTLS, sealed
credential storage, image build pinning, and the layer8-proxy-site
override system.

## Topologies

### Same-host (developer / single-Mac)

Locksmith, pipelock, lf-scan, and the agent (hermes / openclaw) all
run on one host.

```
agent (host process) ──HTTPS──► locksmith :9200 (Docker, loopback) ──► pipelock ──► Internet
                                       │
                                       └──► host.docker.internal:1234 (LM Studio on host)
```

`docker-compose.override.yml` binds locksmith only to `127.0.0.1`:

```yaml
services:
  locksmith:
    ports:
      - "127.0.0.1:9200:9200"
```

### Neutral-host (laptop + LAN server)

Locksmith on a dedicated server; agents on user laptops over LAN.

```
agent laptop ──HTTPS────────► locksmith :9200 (server, mTLS recommended) ──► pipelock ──► Internet
                                       │
                                       └──► ollama.lan, mac-server.lan (other LAN services)
```

`docker-compose.override.yml`:

```yaml
services:
  locksmith:
    ports:
      - "0.0.0.0:9200:9200"   # bind public for LAN clients
```

For neutral-host production, **enable mTLS** on the agent listener
(see "mTLS rollout" below).

### Multi-tenant (one stack, many agents)

One locksmith stack serves multiple agents (different users on the
same Mac, multiple hermes/openclaw instances). Each gets its own
registration + bearer + ACL.

```bash
locksmith agent register --name hermes-alice --allowlist anthropic,openai
locksmith agent register --name hermes-bob   --allowlist anthropic,lmstudio
locksmith agent register --name openclaw-laptop --allowlist codex,github
```

Audit rows include `agent_public_id` so per-agent activity is clean
to attribute.

## Image build pinning

`layer8-proxy/locksmith/Dockerfile` clones `agent-locksmith` from
`${LOCKSMITH_VERSION}` (default `v2.0.0` at v1.0.0 of this bundle).

Site repos pin in `.env`:

```bash
LOCKSMITH_VERSION=v2.0.0
PIPELOCK_VERSION=2.3.0
```

The locksmith Dockerfile uses a multi-stage `seed-extractor` that
conditionally stages `seed/catalog.yaml` from the cloned source —
v2.0.0+ tags ship the catalog; pre-v2.0.0 tags get an empty staging
dir (graceful fallback). Don't downgrade below v2.0.0 — your
deployment loses the seed catalog and falls back to whatever
`config.tools` you supply.

## Sealed credentials at rest

Provider API keys in your `.env` are cleartext. Production deploys
should use sealed-cred storage.

### Linux (systemd-creds)

The `secrets.bootstrap.sh` helper uses `systemd-creds` when available:

```bash
echo -n "$ANTHROPIC_API_KEY" | ./secrets.bootstrap.sh anthropic_api_key --from-stdin
# Writes locksmith/secrets/anthropic_api_key.creds — encrypted with
# kernel-keyring or TPM-backed key.
```

`decrypt-creds.sh` unseals at deploy time:

```bash
ANTHROPIC_API_KEY=$(./scripts/decrypt-creds.sh ./locksmith/secrets/anthropic_api_key.creds)
export ANTHROPIC_API_KEY
docker compose ... up -d
```

`docker-compose.override.yml` can wire this via `env_file:` or
`environment:` blocks that source from the unsealed env at compose
time.

### macOS (openssl + Keychain)

`secrets.bootstrap.sh` falls back to `openssl enc -aes-256-cbc -pbkdf2`
when `systemd-creds` isn't present. Symmetric key:
`LOCKSMITH_CREDS_PASSPHRASE` (set in your shell or stored in macOS
Keychain).

For convenience, store the passphrase in Keychain:

```bash
security add-generic-password \
    -a "$USER" -s "locksmith-creds" -w "<your-passphrase>" -U
```

Retrieve at deploy time:

```bash
export LOCKSMITH_CREDS_PASSPHRASE=$(security find-generic-password \
    -a "$USER" -s "locksmith-creds" -w)
./deploy.sh
```

### What to seal

At minimum:

- `lf_scan_token` — locksmith ↔ lf-scan internal token.
- `restic_password` — backup encryption key.
- `oauth_sealing_key` — Phase F (OAuth tokens at rest).
- `operator_token` — operator wire token (the `bootstrap-operator.py`
  output).

Provider API keys (`ANTHROPIC_API_KEY`, etc.) can stay in `.env`
when `.env` itself is on encrypted storage (FileVault, LUKS); seal
them only if your threat model requires it.

## mTLS rollout

For neutral-host production, encrypt + authenticate the agent listener
with mTLS.

### 1. Mint a CA + agent / server certs

The `dist/examples/smallstep-mtls/` directory in agent-locksmith has
a worked example using `step-ca`. Summary:

```bash
step ca init --name="layer8-CA" ...
step ca certificate "layer8-server" server.crt server.key \
    --provisioner=layer8 --san=layer8.lan
step ca certificate "hermes-mini-m1" hermes.crt hermes.key \
    --provisioner=layer8 --san=hermes-mini-m1.lan
```

### 2. Configure locksmith for `auth_mode: mtls` or `both`

In `locksmith/base.yaml`:

```yaml
listen:
  host: "0.0.0.0"
  port: 9200
  auth_mode: both          # accept either bearer OR mtls
  mtls:
    ca_bundle_path: /etc/locksmith/ca.crt
    server_cert_path: /etc/locksmith/server.crt
    server_key_path: /etc/locksmith/server.key
```

Volume-mount the CA/server cert/key in `docker-compose.override.yml`.

### 3. Bind agent registrations to cert identities

```bash
locksmith agent register --name hermes-mini-m1 \
    --allowlist anthropic,openai \
    --cert-identity 'CN=hermes-mini-m1,O=YourOrg'
```

The agent presents `hermes.crt` + `hermes.key` on every TLS
handshake; locksmith's `MtlsAuthenticator` extracts the cert subject,
maps to the agent record, applies ACL.

For agent-side mTLS in hermes:

```yaml
# hermes config (path A)
providers:
  anthropic:
    base_url: https://layer8.lan:9200/api/anthropic
    api_key: ""                  # not used in mtls-only mode
    tls:
      ca_path: /etc/hermes/ca.crt
      cert_path: /etc/hermes/hermes.crt
      key_path: /etc/hermes/hermes.key
```

### Rolling migration: bearer → both → mtls

1. **Phase 0** — `auth_mode: bearer`. All agents on bearer tokens.
2. **Phase 1** — flip to `auth_mode: both`. Existing bearer agents
   keep working; new agents can use mTLS or bearer.
3. **Phase 2** — distribute certs, register cert identities for each
   agent.
4. **Phase 3** — verify all agents are presenting certs.
5. **Phase 4** — flip to `auth_mode: mtls`. Bearer agents now 401.

## Operator credential bootstrapping

Two paths.

### Python script (pre-deploy)

```bash
LOCKSMITH_CREDS_PASSPHRASE="..." ./scripts/bootstrap-operator.py
# Writes locksmith/operators.yaml + locksmith/secrets/operator_token.creds
```

### Rust-native CLI (post-deploy)

```bash
docker exec layer8-locksmith /usr/local/bin/locksmith bootstrap-operator \
    --name alice > locksmith/operators.yaml
# Wire token printed to stderr — seal it:
echo -n "$LOCKSMITH_OP_TOKEN" | ./secrets.bootstrap.sh operator_token --from-stdin
docker compose ... restart locksmith
```

The Rust path is preferred for new deploys (no Python dependency).
Pre-existing deploys can keep using the Python script — the
`operators.yaml` shape is identical.

## Custom site overrides

`docker-compose.override.yml` is the layer for site-specific tweaks.
Common patterns:

```yaml
services:
  locksmith:
    environment:
      LOCKSMITH_OAUTH_SEALING_KEY_FILE: /etc/locksmith/secrets/oauth_sealing_key
    volumes:
      - ./locksmith/secrets/oauth_sealing_key:/etc/locksmith/secrets/oauth_sealing_key:ro

  pipelock:
    volumes:
      - ./pipelock/pipelock.yaml:/etc/pipelock/pipelock.yaml:ro
      - ./rendered/pipelock/allowlist-extras.yaml:/etc/pipelock/allowlist-extras.yaml:ro

  lf-scan:
    environment:
      HF_TOKEN: ${HF_TOKEN}
```

The override is concatenated with the bundle's `docker-compose.yml`;
`deploy.sh` handles path-rewriting so relative paths resolve from
the site repo, not the bundle dir.

## Two-tier audit storage

Locksmith's audit table is in SQLite (`locksmith.db`). For long-term
retention or off-host archival, enable the JSONL mirror:

```yaml
audit:
  retention_days: 90
  sweep_interval_seconds: 3600
  jsonl_path: "/var/log/locksmith/audit.jsonl"
  jsonl_max_bytes: 104857600       # 100 MiB rotate trigger
  jsonl_keep_files: 7              # keep 7 rotated files
```

Mirror lines are written one per audit row; logrotate-compatible.
Volume-mount `/var/log/locksmith/` so JSONL survives container
recreation.

## Production checklist

Before going live:

- [ ] `.env` does NOT contain placeholder values; real provider keys.
- [ ] Sealed-creds bootstrapped: `lf_scan_token`, `restic_password`,
      `oauth_sealing_key` (if using OAuth), `operator_token`.
- [ ] `operators.yaml` exists; passphrase / sealing mechanism known.
- [ ] `agents.yaml` reflects actual agent identities.
- [ ] `pipelock.yaml` `api_allowlist` includes every upstream you
      proxy to.
- [ ] mTLS enabled if cross-host (not loopback-only).
- [ ] `audit.jsonl_path` configured + log volume mounted.
- [ ] `backup.sh` cron installed.
- [ ] `verify.sh` passes after `deploy.sh`.
- [ ] First-agent end-to-end smoke (Anthropic real-API call returns
      a real completion).
- [ ] Audit row appears with correct `agent_public_id`,
      `auth_method=bearer|mtls`, `auth_mode=header|bearer|oauth_*`.

## See also

- [getting-started.md](getting-started.md) — first-time deploy walkthrough.
- [rotate-credentials.md](rotate-credentials.md) — operational
  rotation recipes.
- [upgrade.md](upgrade.md) — version-pin bump procedure.
- [troubleshoot.md](troubleshoot.md) — failure modes.
- [`agent-locksmith/dist/examples/smallstep-mtls/`](https://github.com/SentientSwarm/agent-locksmith/tree/develop/dist/examples/smallstep-mtls)
  — worked mTLS PKI example.
