#!/usr/bin/env bash
# encrypt-creds.sh — symmetric counterpart to decrypt-creds.sh.
#
# Reads cleartext from stdin (or the second arg if "-") and writes an
# encrypted .creds file. Used by rotation scripts and ad-hoc operator
# updates that don't fit secrets.bootstrap.sh's interactive prompt.
#
# Usage:
#   ./scripts/encrypt-creds.sh <name> <output-path>
#   echo 'plain' | ./scripts/encrypt-creds.sh restic_password locksmith/secrets/restic_password.creds
#
# On Linux: uses systemd-creds (kernel keyring / TPM); the credential
# name is baked into the file via --name=.
# On macOS dev: uses openssl with $LOCKSMITH_CREDS_PASSPHRASE; the
# name argument is informational only (recorded in the file mode but
# not the ciphertext).

set -euo pipefail

if [[ $# -ne 2 ]]; then
    cat >&2 <<EOF
Usage: $(basename "$0") <name> <output-path>
       echo '<cleartext>' | $(basename "$0") <name> <output-path>

Reads cleartext from stdin and writes an encrypted .creds file.
Mode 0600 enforced on output.

Inverse of: ./scripts/decrypt-creds.sh <output-path>
EOF
    exit 2
fi

NAME="$1"
DEST="$2"

if [[ -z "$NAME" ]]; then
    echo "ERROR: name must be non-empty" >&2
    exit 2
fi

DEST_DIR="$(dirname "$DEST")"
mkdir -p "$DEST_DIR"

umask 0077

if command -v systemd-creds >/dev/null 2>&1; then
    systemd-creds encrypt --name="$NAME" - "$DEST"
else
    : "${LOCKSMITH_CREDS_PASSPHRASE:?Set LOCKSMITH_CREDS_PASSPHRASE for non-systemd hosts}"
    openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass "env:LOCKSMITH_CREDS_PASSPHRASE" \
        -out "$DEST"
fi

chmod 0600 "$DEST"
echo "✓ Wrote encrypted secret to $DEST" >&2
