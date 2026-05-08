#!/usr/bin/env bash
# rotate-creds-passphrase.sh — re-encrypt every .creds file under
# locksmith/secrets/ with a new LOCKSMITH_CREDS_PASSPHRASE.
#
# Use case: the placeholder/development passphrase is being replaced
# with a strong production value, OR the production passphrase is
# being rotated routinely.
#
# Workflow:
#   1. Operator generates a new strong passphrase.
#   2. This script reads each .creds file with the OLD passphrase,
#      writes a temporary cleartext into memory (never to disk),
#      re-encrypts with the NEW passphrase to a sibling .creds.new,
#      atomically renames each .creds.new → .creds.
#   3. Operator updates their environment / Keychain / sealed-creds
#      store to expose the NEW passphrase.
#
# Step 3 is operator-side and out of scope for this script — different
# operators have different secret stores.
#
# This script does NOT touch:
#   - locksmith's runtime DB (no changes to OAuth sessions, agents).
#   - The values inside the .creds files (the operator token, sealing
#     key, restic password, etc. stay the same — only the wrapping
#     symmetric key changes).
#   - Any running daemon (no restart needed; the passphrase is read
#     by operator-side scripts only).
#
# Usage:
#   OLD_PASSPHRASE="<current>" NEW_PASSPHRASE="<new>" ./scripts/rotate-creds-passphrase.sh
#
# Or interactively:
#   ./scripts/rotate-creds-passphrase.sh
#   (will prompt for both)
#
# On Linux with systemd-creds: this script does NOT apply. systemd-
# creds uses TPM/kernel-keyring sealing; rotation there is a system-
# config-level operation (re-sealing against the new boot identity)
# and outside this script's scope.

set -euo pipefail

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$SITE_DIR/locksmith/secrets"

if command -v systemd-creds >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: This host uses systemd-creds for .creds encryption.
       Passphrase rotation doesn't apply — systemd-creds is sealed
       against the kernel keyring / TPM, not a user passphrase.
       To re-seal against a new identity, see systemd-creds(1).
EOF
    exit 1
fi

if [[ ! -d "$SECRETS_DIR" ]]; then
    echo "ERROR: $SECRETS_DIR not found" >&2
    exit 1
fi

CREDS_FILES=("$SECRETS_DIR"/*.creds)
if [[ ! -e "${CREDS_FILES[0]}" ]]; then
    echo "ERROR: no .creds files found in $SECRETS_DIR" >&2
    exit 1
fi

if [[ -z "${OLD_PASSPHRASE:-}" ]]; then
    read -rsp "Old (current) passphrase: " OLD_PASSPHRASE
    echo
fi
if [[ -z "${NEW_PASSPHRASE:-}" ]]; then
    read -rsp "New passphrase:           " NEW_PASSPHRASE
    echo
    read -rsp "New passphrase (confirm): " NEW_CONFIRM
    echo
    if [[ "$NEW_PASSPHRASE" != "$NEW_CONFIRM" ]]; then
        echo "ERROR: new passphrase confirmation does not match" >&2
        exit 1
    fi
fi

if [[ "$OLD_PASSPHRASE" == "$NEW_PASSPHRASE" ]]; then
    echo "ERROR: old and new passphrases are identical — nothing to rotate" >&2
    exit 1
fi
if [[ ${#NEW_PASSPHRASE} -lt 16 ]]; then
    echo "WARNING: new passphrase is shorter than 16 characters" >&2
    read -rp "Continue anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy] ]] || exit 1
fi

# Verify the OLD passphrase decrypts at least one file before
# proceeding — fail loudly if the operator typo'd, instead of
# silently producing 0-byte cleartexts.
PROBE_FILE="${CREDS_FILES[0]}"
echo "→ Verifying OLD passphrase against $PROBE_FILE"
if ! LOCKSMITH_CREDS_PASSPHRASE="$OLD_PASSPHRASE" \
        openssl enc -aes-256-cbc -pbkdf2 -d \
        -pass "env:LOCKSMITH_CREDS_PASSPHRASE" \
        -in "$PROBE_FILE" >/dev/null 2>&1; then
    echo "ERROR: OLD passphrase fails to decrypt $PROBE_FILE" >&2
    exit 1
fi
echo "  ✓ OLD passphrase verified"

# Re-encrypt each file to .new alongside, then atomically replace.
ROTATED=0
FAILED=0
for f in "${CREDS_FILES[@]}"; do
    NAME="$(basename "$f" .creds)"
    NEW_FILE="$f.new"
    if PLAIN=$(LOCKSMITH_CREDS_PASSPHRASE="$OLD_PASSPHRASE" \
                openssl enc -aes-256-cbc -pbkdf2 -d \
                -pass "env:LOCKSMITH_CREDS_PASSPHRASE" \
                -in "$f" 2>/dev/null) \
       && printf '%s' "$PLAIN" \
            | LOCKSMITH_CREDS_PASSPHRASE="$NEW_PASSPHRASE" \
                openssl enc -aes-256-cbc -pbkdf2 -salt \
                -pass "env:LOCKSMITH_CREDS_PASSPHRASE" \
                -out "$NEW_FILE" 2>/dev/null; then
        chmod 0600 "$NEW_FILE"
        mv "$NEW_FILE" "$f"
        echo "  ✓ rotated $NAME"
        ROTATED=$((ROTATED+1))
        unset PLAIN
    else
        echo "  ✗ FAILED $NAME (left untouched)" >&2
        rm -f "$NEW_FILE"
        FAILED=$((FAILED+1))
    fi
done

unset OLD_PASSPHRASE NEW_PASSPHRASE NEW_CONFIRM PLAIN

echo
echo "Rotated: $ROTATED file(s).  Failed: $FAILED."
if [[ $FAILED -gt 0 ]]; then
    echo "WARNING: failed files still use the OLD passphrase. Investigate before"
    echo "         updating your environment to the NEW passphrase, or you'll"
    echo "         lose access to those secrets." >&2
    exit 1
fi

cat <<EOF

Next step (operator-side, NOT in this script):
  Update your shell environment / Keychain / sealed-creds store to
  expose the NEW passphrase as LOCKSMITH_CREDS_PASSPHRASE.

  macOS Keychain example:
    security add-generic-password -a \$USER -s LOCKSMITH_CREDS_PASSPHRASE \\
        -w '<NEW_PASSPHRASE>' -U

  systemd-creds is not used on this host (this script wouldn't have
  run); see systemd-creds(1) if you migrate.

  Verify after update:
    LOCKSMITH_CREDS_PASSPHRASE='<NEW>' \\
        ./scripts/decrypt-creds.sh locksmith/secrets/operator_token.creds | head -c 10

The .creds files now use the NEW passphrase. The OLD passphrase is
no longer valid for any file in $SECRETS_DIR.
EOF
