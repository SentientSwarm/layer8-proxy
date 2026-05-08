# Rotate credentials

Recipes for rotating each credential type in a layer8-proxy deployment.

There are six credential surfaces. Each rotates independently:

| Credential | Lifetime | Rotation triggered by | Toolkit script |
|---|---|---|---|
| `LOCKSMITH_CREDS_PASSPHRASE` (the wrapper) | until rotated | Placeholder→production, routine policy, suspected leak | [`rotate-creds-passphrase.sh`](#-locksmith_creds_passphrase-the-wrapping-passphrase) |
| Provider API keys (`ANTHROPIC_API_KEY` etc.) | provider-defined; usually long | Provider key rotation policy, suspected leak | (manual — varies per provider) |
| Agent bearer (`lk_...`) | provider-of-deploy-defined | Agent host change-of-hands, suspected leak | `register-agents.sh` (regenerate) |
| Operator bearer (`lkop_...` / `lk_...`) | until rotated | Operator role change, suspected leak | [`rotate-operator-token.sh`](#operator-bearer) |
| OAuth refresh tokens | provider-defined | Provider revoked the session, suspected leak | (manual — `locksmith oauth bootstrap`) |
| OAuth sealing key (`LOCKSMITH_OAUTH_SEALING_KEY`) | until rotated | Compromise, routine policy | [`rotate-oauth-sealing-key.sh`](#sealing-key-rotation) |
| Internal infra tokens (`LF_SCAN_INTERNAL_TOKEN`) | until rotated | Compromise, audit recommendation | (manual) |

## Tooling — automated rotation scripts (v1.4.0+)

v1.4.0 ships three rotation helpers in `examples/site/scripts/`
(also present in any site repo bootstrapped via `init-site.sh`):

- **`rotate-creds-passphrase.sh`** — re-encrypt every `.creds` file
  under `locksmith/secrets/` with a new symmetric passphrase. No
  daemon restart. Operator updates their environment / Keychain
  separately as the final step. Linux/systemd-creds hosts are
  detected and rejected with a pointer to `systemd-creds(1)` for
  re-sealing.
- **`rotate-operator-token.sh`** — mint a fresh operator bearer,
  patch `operators.yaml` (in-place via `yq`), re-encrypt
  `operator_token.creds`, restart the locksmith container, run a
  health check. Old token is invalid the moment the container
  reloads (no grace window).
- **`rotate-oauth-sealing-key.sh`** — heavyweight: stop daemon,
  back up DB volume, drop `oauth_sessions`, generate new sealing
  key, restart, then list which OAuth registrations need
  re-bootstrapping. The bootstrap step itself stays manual (each
  provider needs a fresh refresh token from a human-driven flow).

All three are interactive by default and accept env-var overrides
for non-interactive runs (CI, scripted operator workflows).

The sections below describe each rotation type in detail. Each one
has a "Quick path" that calls the script and a manual recipe that
shows what the script does internally — useful for operators on
hosts where the script doesn't apply (e.g., systemd-creds), or for
debugging when the script reports a failure.

## `LOCKSMITH_CREDS_PASSPHRASE` (the wrapping passphrase)

This is the symmetric passphrase used by `decrypt-creds.sh` and
`secrets.bootstrap.sh` to wrap/unwrap every `.creds` file under
`locksmith/secrets/`. It does NOT directly authenticate anything
to the daemon — it's the operator-side wrapper around all the
other secrets.

**Common case:** the placeholder/development value (`locksmith` or
similar) needs to be replaced with a strong production value
during initial hardening, OR the production passphrase is being
rotated routinely.

### Quick path

```bash
./scripts/rotate-creds-passphrase.sh
# Prompts for old + new passphrase (with confirmation).
# Re-encrypts every .creds file in place.
# Prints follow-up instructions for updating your environment.
```

Then update your environment (the script doesn't — different
operators have different secret stores):

```bash
# macOS Keychain
security add-generic-password -a $USER -s LOCKSMITH_CREDS_PASSPHRASE \
    -w '<NEW>' -U

# Or simply re-export in your shell rc:
export LOCKSMITH_CREDS_PASSPHRASE='<NEW>'
```

### Manual recipe

```bash
NEW=$(openssl rand -base64 24)
cd locksmith/secrets
for f in *.creds; do
    PLAIN=$(LOCKSMITH_CREDS_PASSPHRASE="<OLD>" \
        ../../scripts/decrypt-creds.sh "$f")
    printf '%s' "$PLAIN" \
        | LOCKSMITH_CREDS_PASSPHRASE="$NEW" \
            ../../scripts/encrypt-creds.sh "${f%.creds}" "$f"
done
unset PLAIN
```

No daemon restart needed. The passphrase is operator-side only; the
daemon never sees it (the entrypoint decrypts each .creds and
passes the cleartext via env to locksmithd).

### Linux / systemd-creds hosts

systemd-creds doesn't use a user passphrase — it's sealed against
the kernel keyring or TPM. Rotation in that mode is a system-config
operation; see `systemd-creds(1)`. The `rotate-creds-passphrase.sh`
script detects systemd-creds and exits early with a pointer.

## Provider API keys

**No daemon downtime needed.** Locksmith reads from `resolved_creds`
in memory; admin writes can refresh.

### Step 1: Update the cleartext source

In your site repo:

```bash
# Update .env (or whichever sealed-cred mechanism you use):
sed -i 's/^ANTHROPIC_API_KEY=.*/ANTHROPIC_API_KEY=sk-ant-NEW-KEY-HERE/' .env
```

### Step 2: Restart locksmith (or trigger admin refresh)

The simplest path is restart:

```bash
docker compose -f $LAYER8_PATH/docker-compose.yml -f docker-compose.override.yml \
    --env-file ./.env restart locksmith
```

`resolved_creds` is rebuilt at startup from the new env. Active
streaming responses survive the restart's drain window
(`shutdown.drain_window_seconds`, default 30s).

For zero-restart rotation:

```bash
LOCKSMITH_OP_TOKEN="lkop_..."
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" \
    -e ANTHROPIC_API_KEY="$NEW_ANTHROPIC_KEY" layer8-locksmith \
    /usr/local/bin/locksmith model put anthropic \
    --upstream https://api.anthropic.com \
    --auth header:x-api-key=ANTHROPIC_API_KEY
# This re-resolves the env var as part of the admin write.
```

### Step 3: Verify

Send a test call from any registered agent — confirm 200 from the
provider. Check audit:

```bash
locksmith audit query --tool anthropic --since-ms $(($(date +%s) * 1000 - 60000))
```

### When the old key is still valid

Most providers support overlapping keys (you can have several
active simultaneously). Recommended pattern:

1. Mint new key (`NEW`) at provider.
2. Update locksmith env to `NEW`.
3. Verify.
4. Revoke old key (`OLD`) at provider.

This avoids a rotation window where calls fail.

## Agent bearer

Agent hosts get new bearers. **The old bearer stops working
immediately** when revoked.

### Standard rotation

```bash
LOCKSMITH_OP_TOKEN="lkop_..."

# 1. Note the agent's public_id.
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent list

# 2. Revoke + re-register.
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent revoke <public_id>

docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith agent register --name <agent-name> \
    --allowlist <same-allowlist-as-before>

# 3. Distribute the new bearer to the agent host.
#    Replace ~/.hermes/locksmith.token (hermes) or LOCKSMITH_TOKEN
#    in the agent's env (openclaw / custom).
```

### Self-service rotation (if enabled)

Agents can rotate their own bearer using the existing one:

```bash
# On the agent host, with the OLD bearer in env:
export LOCKSMITH_AGENT_TOKEN="lk_<old-token>"
locksmith --admin-url http://layer8.lan:9200 rotate
# Prints the new token.
```

The old bearer is invalidated immediately on success. If the call
fails, the old bearer remains valid — safe to retry.

Self-service rotation requires `agent_self_service_rotate: true` in
locksmith's config (off by default for production). For operator-
controlled environments, leave it off and rotate via the admin path.

### Bearer leaked

If you suspect a bearer leaked, revoke first then notify:

```bash
locksmith agent revoke <public_id>
# Old bearer → 401 immediately.
# Issue new bearer + redistribute via your secure channel.
```

## Operator bearer

Operator credential rotation requires daemon restart since the
operator credentials file (`operators.yaml`) is read at startup.

### Quick path (v1.4.0+)

```bash
OPERATOR_NAME=alice ./scripts/rotate-operator-token.sh
# Mints a new bearer, patches operators.yaml in place via yq,
# re-encrypts operator_token.creds, restarts locksmith,
# health-checks /livez, prints verification recipe.
```

The OLD token is invalid the moment locksmith restarts — there is
no grace window. Update any background scripts holding the old
token simultaneously.

### Rust-native path (manual)

```bash
# 1. Mint new operator credential.
docker exec layer8-locksmith /usr/local/bin/locksmith bootstrap-operator \
    --name alice > /tmp/new-operators.yaml
# Cleartext wire token to stderr — capture it.

# 2. Replace operators.yaml + restart.
cp /tmp/new-operators.yaml locksmith/operators.yaml
docker compose ... restart locksmith

# 3. Update LOCKSMITH_OP_TOKEN everywhere it's used (operator's shell,
#    ./scripts/register-agents.sh, cron jobs, etc.).
```

### Python path

```bash
LOCKSMITH_CREDS_PASSPHRASE="..." ./scripts/bootstrap-operator.py
# Re-seals operator_token.creds with the new wire token.
docker compose ... restart locksmith
```

### Multi-operator setups

If `operators.yaml` has multiple entries, rotate them one at a time —
the file accepts an array, and you can keep N-1 operators valid while
swapping the Nth.

```yaml
operators:
  - name: alice
    public_id: <existing>
    token_hash: <existing argon2 hash>
  - name: bob-NEW
    public_id: <fresh>
    token_hash: <fresh argon2 hash>
  # Drop bob-OLD here when bob switches to bob-NEW.
```

## OAuth refresh tokens

OAuth sessions need re-bootstrap when the provider's refresh token
expires or is revoked.

### When does this happen?

- Provider security event ("re-authenticate to continue").
- Refresh token TTL elapsed (provider-defined; typically 30–90 days).
- Operator manually revoked at provider's dashboard.
- The session was marked degraded after a refresh failure (look for
  `oauth_refresh_failed` in audit).

### Re-bootstrap

```bash
LOCKSMITH_OP_TOKEN="lkop_..."

# 1. Get a fresh refresh token from the provider's CLI / OAuth flow.
#    For codex (ChatGPT plan): codex auth login
#    For copilot:               gh auth login --web
#    For anthropic-oauth:       claude auth login
#    Extract the refresh token from the provider's storage.

REFRESH_TOKEN="<paste-from-provider>"

# 2. Bootstrap.
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith oauth bootstrap codex \
    --refresh-token "$REFRESH_TOKEN"
# This UPSERTs the session — old refresh token replaced atomically.
```

### Check status

```bash
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith oauth status codex
# {"name":"codex","present":true,"degraded":false,
#  "access_token_expires_at":1762531200,"scope":"...","audit_session_id":"abcd1234..."}
```

`degraded: false` confirms the new session is healthy.

### Sealing-key rotation

The `LOCKSMITH_OAUTH_SEALING_KEY` itself can be rotated. **Doing so
invalidates ALL OAuth sessions** (the existing AES-GCM ciphertext
can't be unsealed with a different key).

Plan sealing-key rotation around scheduled maintenance — agents
calling OAuth providers will see 503 between key change and
re-bootstrap.

#### Quick path (v1.4.0+)

```bash
./scripts/rotate-oauth-sealing-key.sh
# Confirms the heavyweight workflow with the operator.
# Stops locksmith, backs up the DB volume to /tmp/, drops every
# row from oauth_sessions, generates + seals a new key, restarts
# locksmith, lists which OAuth registrations need re-bootstrap.
# Re-bootstrap itself stays manual (each provider needs a fresh
# refresh token from a human-driven flow).
```

#### Manual recipe

```bash
# 1. Generate the new sealing key.
NEW_KEY="$(openssl rand -base64 32)"

# 2. Save it via your sealed-cred mechanism.
echo -n "$NEW_KEY" | ./secrets.bootstrap.sh oauth_sealing_key --from-stdin

# 3. Restart locksmith (the env var changes).
docker compose ... restart locksmith

# 4. All existing OAuth sessions are now degraded — re-bootstrap each.
docker exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" layer8-locksmith \
    /usr/local/bin/locksmith oauth list --degraded
# For each name, re-run `locksmith oauth bootstrap <name> --refresh-token ...`.
```

## Internal infra tokens (lf-scan, etc.)

`LF_SCAN_INTERNAL_TOKEN` is the locksmith ↔ lf-scan shared secret.
Rotate by:

```bash
# 1. Generate new.
NEW_TOKEN="$(openssl rand -hex 32)"

# 2. Update both .env and the sealed-cred:
sed -i 's/^LF_SCAN_INTERNAL_TOKEN=.*/LF_SCAN_INTERNAL_TOKEN='"$NEW_TOKEN"'/' .env
echo -n "$NEW_TOKEN" | ./secrets.bootstrap.sh lf_scan_token --from-stdin

# 3. Restart both services together.
docker compose ... restart lf-scan locksmith
```

The two services must restart together because they validate the
shared secret on every internal call. Mid-rotation calls between
unsynchronised services 401.

## Backup encryption key (restic_password)

Restic snapshots can be re-keyed without losing existing snapshots:

```bash
# 1. Add a new password to the existing repo.
restic -r "$BACKUP_DEST" \
    --password-file <(./scripts/decrypt-creds.sh ./locksmith/secrets/restic_password.creds) \
    key add

# 2. Verify both keys work.
# 3. Update sealed-cred:
echo -n "<new-passphrase>" | ./secrets.bootstrap.sh restic_password --from-stdin

# 4. Remove old key from repo.
restic -r "$BACKUP_DEST" key remove <old-key-id>
```

Re-keying is safe — existing snapshots remain readable as long as
ANY current key works.

## Auditing rotation events

Every credential rotation that goes through admin endpoints emits an
audit row:

```bash
locksmith audit query --event-class admin --since-ms $(($(date +%s) * 1000 - 86400000))
```

Look for `agent_revoked`, `agent_registered`, `tool_put`,
`oauth_bootstrap_complete`, etc. to confirm rotation actions
landed.

## See also

- [add-an-agent.md](add-an-agent.md) — registration + ACL semantics.
- [add-a-tool.md](add-a-tool.md) — tool/model registration + OAuth
  bootstrap.
- [troubleshoot.md](troubleshoot.md) — failure modes during rotation.
