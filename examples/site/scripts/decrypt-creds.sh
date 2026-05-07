#!/usr/bin/env bash
# decrypt-creds.sh — symmetric inverse of secrets.bootstrap.sh.
# Reads an encrypted .creds file and prints the cleartext to stdout.
#
# Usage:
#   ./scripts/decrypt-creds.sh ./locksmith/secrets/restic_password.creds
#
# Used by backup.sh's RESTIC_PASSWORD_CREDS path:
#   --password-file <(./scripts/decrypt-creds.sh ./locksmith/secrets/restic_password.creds)
#
# On Linux: uses systemd-creds (kernel keyring / TPM).
# On macOS dev: uses openssl with $LOCKSMITH_CREDS_PASSPHRASE.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $(basename "$0") <path-to-.creds-file>" >&2
    exit 2
fi

CREDS_PATH="$1"

if [[ ! -f "$CREDS_PATH" ]]; then
    echo "ERROR: $CREDS_PATH not found" >&2
    exit 1
fi

if command -v systemd-creds >/dev/null 2>&1; then
    # systemd-creds remembers the credential's name from --name= at encrypt
    # time, so we don't have to thread it through here.
    systemd-creds decrypt "$CREDS_PATH" -
else
    : "${LOCKSMITH_CREDS_PASSPHRASE:?Set LOCKSMITH_CREDS_PASSPHRASE for non-systemd hosts}"
    openssl enc -aes-256-cbc -pbkdf2 -d \
        -pass "env:LOCKSMITH_CREDS_PASSPHRASE" \
        -in "$CREDS_PATH"
fi
