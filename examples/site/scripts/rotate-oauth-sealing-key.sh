#!/usr/bin/env bash
# rotate-oauth-sealing-key.sh — rotate LOCKSMITH_OAUTH_SEALING_KEY.
#
# This is the heavyweight rotation. The sealing key is the AES-GCM
# key that encrypts OAuth refresh + access tokens at rest in the
# oauth_sessions table. Rotating it makes every existing
# oauth_sessions row unreadable — there is no key-rotation primitive
# in v2.x of locksmith (per ADR-0005 D2: "richer rotation deferred
# to post-v2"). The flow is:
#
#   1. Stop the locksmith daemon.
#   2. Backup the locksmith DB volume (safety net).
#   3. Drop every row from oauth_sessions.
#   4. Update the sealing key in the operator's sealed-creds store.
#   5. Restart the daemon with the new key.
#   6. Operator manually re-bootstraps every OAuth registration via
#      `locksmith oauth bootstrap <name>` (this script lists which
#      ones need it; the bootstrap itself requires fresh refresh
#      tokens from each provider, so it can't be automated).
#
# After step 6, every agent's first OAuth-tool call refreshes
# transparently from the new sessions.
#
# Use case: leak of the sealing key, or routine rotation per
# operator policy.
#
# This script does NOT touch:
#   - LOCKSMITH_CREDS_PASSPHRASE (use rotate-creds-passphrase.sh).
#   - The operator token (use rotate-operator-token.sh).
#   - Static-credential tools (no sealing-key dependency).

set -euo pipefail

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$SITE_DIR/locksmith/secrets"
SEALING_KEY_CREDS="$SECRETS_DIR/oauth_sealing_key.creds"

LOCKSMITH_CONTAINER="${LOCKSMITH_CONTAINER:-layer8-locksmith}"
LOCKSMITH_BIN="${LOCKSMITH_BIN:-/usr/local/bin/locksmith}"
DB_PATH_IN_CONTAINER="${DB_PATH_IN_CONTAINER:-/var/lib/locksmith/locksmith.db}"

RUNTIME=""
if command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then
    RUNTIME="podman"
elif command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
    RUNTIME="docker"
else
    echo "ERROR: neither podman nor docker is reachable" >&2
    exit 1
fi

if [[ ! -f "$SEALING_KEY_CREDS" ]]; then
    echo "ERROR: $SEALING_KEY_CREDS not found" >&2
    echo "       Either OAuth isn't configured on this site, or the" >&2
    echo "       creds file lives elsewhere. Check secrets.bootstrap.sh." >&2
    exit 1
fi

cat <<EOF

⚠️  HEAVYWEIGHT ROTATION

This script will:
  1. Stop the locksmith container ($LOCKSMITH_CONTAINER)
  2. Backup the locksmith DB to /tmp/locksmith-db-backup-<ts>.tar
  3. DROP every row from oauth_sessions (existing sessions become
     unrecoverable; the OLD sealing key is the only thing that
     could decrypt them, and we're rotating away from it)
  4. Re-encrypt $SEALING_KEY_CREDS with the new key
  5. Restart locksmith
  6. List the OAuth registrations that need re-bootstrap — you do
     this manually with fresh refresh tokens from each provider

After step 5, agents using OAuth-backed tools get 503 envelope
errors until you complete step 6 for each tool.

EOF
read -rp "Proceed with sealing-key rotation? [y/N] " yn
[[ "$yn" =~ ^[Yy] ]] || exit 0

# 1. Stop the daemon.
echo "→ Stopping $LOCKSMITH_CONTAINER"
$RUNTIME stop "$LOCKSMITH_CONTAINER"

# 2. Backup the DB volume.
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_PATH="/tmp/locksmith-db-backup-$TS.tar"
echo "→ Backing up DB volume to $BACKUP_PATH"
# Find the volume backing /var/lib/locksmith. Convention in the
# bundled compose is layer8-proxy_locksmith_data.
DB_VOLUME="${DB_VOLUME:-layer8-proxy_locksmith_data}"
$RUNTIME volume export "$DB_VOLUME" > "$BACKUP_PATH"
echo "  ✓ saved $BACKUP_PATH ($(stat -f%z "$BACKUP_PATH" 2>/dev/null || stat -c%s "$BACKUP_PATH") bytes)"

# 3. Drop oauth_sessions. Run via a one-shot container that mounts
#    the same volume so we don't need the daemon up.
echo "→ Dropping oauth_sessions rows"
NAMES_TO_BOOTSTRAP=$($RUNTIME run --rm \
    -v "$DB_VOLUME:/var/lib/locksmith" \
    keinos/sqlite3:latest \
    sqlite3 "$DB_PATH_IN_CONTAINER" \
    "SELECT DISTINCT name FROM oauth_sessions; DELETE FROM oauth_sessions;" 2>&1 \
    | grep -v "^DELETE" || true)

# 4. Re-encrypt the sealing key creds file with a freshly-generated key.
NEW_KEY=$(openssl rand -base64 32)
echo "→ Re-encrypting $SEALING_KEY_CREDS with new sealing key"
printf '%s' "$NEW_KEY" \
    | "$SITE_DIR/scripts/encrypt-creds.sh" oauth_sealing_key "$SEALING_KEY_CREDS"
unset NEW_KEY

# 5. Restart locksmith. The container's entrypoint reads the
#    sealing key creds file via decrypt-creds.sh on startup.
echo "→ Restarting $LOCKSMITH_CONTAINER"
$RUNTIME start "$LOCKSMITH_CONTAINER"
sleep 3

if $RUNTIME exec "$LOCKSMITH_CONTAINER" curl -fsS -m 5 http://127.0.0.1:9200/livez >/dev/null 2>&1; then
    echo "  ✓ locksmith is live with new sealing key"
else
    echo "  ⚠ locksmith /livez did not respond — check container logs"
    $RUNTIME logs --tail 30 "$LOCKSMITH_CONTAINER" >&2
    cat <<EOF

ROLLBACK: restore from backup
  $RUNTIME stop $LOCKSMITH_CONTAINER
  $RUNTIME volume rm $DB_VOLUME
  $RUNTIME volume create $DB_VOLUME
  $RUNTIME volume import $DB_VOLUME $BACKUP_PATH
  # ... and restore the OLD oauth_sealing_key.creds from your backups
EOF
    exit 1
fi

# 6. Operator action required: re-bootstrap.
cat <<EOF

✓ Sealing key rotated. DB backup at $BACKUP_PATH.

⚠️  OPERATOR ACTION REQUIRED

The following OAuth registrations had sessions before rotation
and need to be re-bootstrapped with fresh refresh tokens:

$NAMES_TO_BOOTSTRAP

For each, obtain a fresh refresh token via the provider's own CLI/
flow, then bootstrap:

  TOKEN=\$($RUNTIME exec $LOCKSMITH_CONTAINER cat /etc/locksmith/secrets/operator_token.cleartext 2>/dev/null \\
           || ./scripts/decrypt-creds.sh ./locksmith/secrets/operator_token.creds)
  $RUNTIME exec -e LOCKSMITH_OP_TOKEN="\$TOKEN" $LOCKSMITH_CONTAINER \\
      $LOCKSMITH_BIN oauth bootstrap <name> --refresh-token <fresh-rt>

Until you do, agent calls to those tools return 503 with envelope
code oauth_session_missing. Audit will record one auth_failure
per dropped session at the next refresh tick (informational; the
session was deliberately removed).

Backup retention: $BACKUP_PATH is yours to manage. Delete it once
you've verified all sessions re-bootstrap successfully and the
backup is no longer needed for rollback.
EOF
