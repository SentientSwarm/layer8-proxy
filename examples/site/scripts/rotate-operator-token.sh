#!/usr/bin/env bash
# rotate-operator-token.sh — mint a new operator token, update
# operators.yaml, re-encrypt locksmith/secrets/operator_token.creds,
# and reload locksmith.
#
# Use case: the placeholder operator token from initial bootstrap is
# being replaced with a production value, OR an existing operator
# token is being rotated routinely / after a suspected leak.
#
# Workflow:
#   1. Run `locksmith bootstrap-operator` offline to mint a new
#      (public_id, secret) pair + the bcrypt hash.
#   2. Update locksmith/operators.yaml: replace the existing entry's
#      public_id + secret_hash with the new values.
#   3. Re-encrypt operator_token.creds with the new bearer wire form
#      `lk_<public_id>.<secret>`.
#   4. Restart the locksmith container so it reloads operators.yaml.
#
# After step 4, the OLD token is invalid. There's no grace window —
# any background script using the old token must be updated before
# this rotation completes.
#
# This script does NOT touch:
#   - LOCKSMITH_CREDS_PASSPHRASE (use rotate-creds-passphrase.sh).
#   - The OAuth sealing key (use rotate-oauth-sealing-key.sh).
#   - The OAuth sessions DB.

set -euo pipefail

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$SITE_DIR/locksmith/secrets"
OPERATORS_YAML="$SITE_DIR/locksmith/operators.yaml"
CREDS_FILE="$SECRETS_DIR/operator_token.creds"

# Operator-runtime sanity. The container name + the locksmith binary
# inside vary by deployment; defaults match the bundled compose.
LOCKSMITH_CONTAINER="${LOCKSMITH_CONTAINER:-layer8-locksmith}"
LOCKSMITH_BIN="${LOCKSMITH_BIN:-/usr/local/bin/locksmith}"

# Determine container runtime — both `docker` and `podman` work the same.
RUNTIME=""
if command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then
    RUNTIME="podman"
elif command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
    RUNTIME="docker"
else
    echo "ERROR: neither podman nor docker is reachable" >&2
    exit 1
fi

if [[ ! -f "$OPERATORS_YAML" ]]; then
    echo "ERROR: $OPERATORS_YAML not found" >&2
    exit 1
fi
if [[ ! -f "$CREDS_FILE" ]]; then
    echo "ERROR: $CREDS_FILE not found" >&2
    exit 1
fi

OPERATOR_NAME="${OPERATOR_NAME:-alice}"
echo "→ Minting new operator token for: $OPERATOR_NAME"

# Run bootstrap-operator inside the container — it's pure-functional
# (no DB writes, no daemon connection). Returns JSON with public_id,
# secret, and the secret_hash for operators.yaml.
NEW_OP_JSON=$($RUNTIME exec "$LOCKSMITH_CONTAINER" \
    "$LOCKSMITH_BIN" bootstrap-operator \
    --name "$OPERATOR_NAME" --format json)

NEW_PUBLIC_ID=$(printf '%s' "$NEW_OP_JSON" | jq -r .public_id)
NEW_SECRET=$(printf '%s' "$NEW_OP_JSON" | jq -r .secret)
NEW_HASH=$(printf '%s' "$NEW_OP_JSON" | jq -r .secret_hash)

if [[ -z "$NEW_PUBLIC_ID" || -z "$NEW_SECRET" || -z "$NEW_HASH" ]]; then
    echo "ERROR: bootstrap-operator output missing fields" >&2
    echo "Output: $NEW_OP_JSON" >&2
    exit 1
fi

NEW_BEARER="lk_${NEW_PUBLIC_ID}.${NEW_SECRET}"

# Update operators.yaml in-place. The format is:
#   - name: alice
#     public_id: <22-char>
#     secret_hash: <argon2 hash>
# We use yq if available; fall back to sed for simple replacement.
echo "→ Updating $OPERATORS_YAML"
if command -v yq >/dev/null 2>&1; then
    yq eval -i "(.operators[] | select(.name == \"$OPERATOR_NAME\")).public_id = \"$NEW_PUBLIC_ID\"" "$OPERATORS_YAML"
    yq eval -i "(.operators[] | select(.name == \"$OPERATOR_NAME\")).secret_hash = \"$NEW_HASH\"" "$OPERATORS_YAML"
else
    cat >&2 <<EOF
ERROR: yq not found. Manual operators.yaml update required.

Replace the entry for name=$OPERATOR_NAME with:
  - name: $OPERATOR_NAME
    public_id: $NEW_PUBLIC_ID
    secret_hash: $NEW_HASH

Then re-run this script with --skip-yaml-update to continue.
EOF
    exit 1
fi

# Re-encrypt the creds file with the new bearer.
echo "→ Re-encrypting $CREDS_FILE"
printf '%s' "$NEW_BEARER" \
    | "$SITE_DIR/scripts/encrypt-creds.sh" operator_token "$CREDS_FILE"

unset NEW_OP_JSON NEW_SECRET
# NEW_BEARER intentionally NOT unset here — the 1Password write-back hook
# below needs it. It's unset at end of script.

# Reload locksmith so it re-reads operators.yaml. The container's
# entrypoint reads operators.yaml at startup; restarting picks up
# the new hash. operators.yaml is mounted read-only into the
# container so the inside view updates immediately.
echo "→ Restarting locksmith ($LOCKSMITH_CONTAINER) to reload operators.yaml"
$RUNTIME restart "$LOCKSMITH_CONTAINER"

# Brief health check so the operator knows the daemon came back up.
sleep 3
if $RUNTIME exec "$LOCKSMITH_CONTAINER" curl -fsS -m 5 http://127.0.0.1:9200/livez >/dev/null 2>&1; then
    echo "  ✓ locksmith is live"
else
    echo "  ⚠ locksmith /livez did not respond — check container logs"
    $RUNTIME logs --tail 30 "$LOCKSMITH_CONTAINER" >&2
    exit 1
fi

# Phase H (OPI-6) — best-effort 1Password write-back. Local rotation success
# (above) is authoritative; this propagates the new value to 1P so other
# consumers get it on next render. Failure here logs a warning but does NOT
# roll back — operator can retry the 1P write separately.
#
# Gated on op_environment_vault_item being set in site.cfg AND the op CLI
# being installed. See lib/op-writeback.sh + design §4.2.5.
if [[ -f "$SITE_DIR/site.cfg" ]]; then
    # shellcheck source=/dev/null
    . "$SITE_DIR/site.cfg"
fi
if [[ -f "$SITE_DIR/scripts/lib/op-writeback.sh" ]]; then
    # shellcheck source=/dev/null
    . "$SITE_DIR/scripts/lib/op-writeback.sh"
    set +e
    op_writeback "${op_environment_vault_item:-}" "OPERATOR_TOKEN" "$NEW_BEARER"
    OP_WB_RC=$?
    set -e
    case "$OP_WB_RC" in
        0) echo "  ✓ wrote new operator token to 1P (item ${op_environment_vault_item})" ;;
        1) : ;;  # silent skip — no vault item configured or no op CLI
        *)
            echo "  ⚠ rotation succeeded locally but 1P write-back failed" >&2
            echo "     retry manually:" >&2
            echo "     op item edit ${op_environment_vault_item} OPERATOR_TOKEN=<new-value>" >&2
            ;;
    esac
fi
unset NEW_BEARER

cat <<EOF

✓ Operator token rotated successfully.

  Operator name: $OPERATOR_NAME
  New public_id: $NEW_PUBLIC_ID

The OLD token (whatever was previously in operator_token.creds) is
no longer valid. Any background scripts that hold the old token
must be updated to use the new one. Decrypt with:

  ./scripts/decrypt-creds.sh ./locksmith/secrets/operator_token.creds

Verify with:
  TOKEN=\$(./scripts/decrypt-creds.sh ./locksmith/secrets/operator_token.creds)
  $RUNTIME exec -e LOCKSMITH_OP_TOKEN="\$TOKEN" $LOCKSMITH_CONTAINER \\
      $LOCKSMITH_BIN agent list
EOF
