#!/usr/bin/env bash
# secrets.bootstrap.sh — encrypt a secret value into locksmith/secrets/<name>.creds
# using systemd-creds (Linux) or a portable openssl fallback (macOS/dev).
#
# v1 stores the lf-scan token in two places (.creds + .env). See
# agents-stack/docs/plans/2026-05-01-layer8-proxy-implementation.md
# follow-up note about consolidating before production.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <secret_name> [--from-env VAR | --from-stdin]

Examples:
  echo -n "ghp_abc123..." | $(basename "$0") github_pat --from-stdin
  GITHUB_TOKEN=ghp_abc123... $(basename "$0") github_pat --from-env GITHUB_TOKEN

Output: locksmith/secrets/<secret_name>.creds (encrypted, mode 0600).
EOF
}

if [[ $# -lt 2 ]]; then
    usage; exit 1
fi

SECRET_NAME="$1"; shift
SOURCE="$1"; shift

case "$SOURCE" in
    --from-stdin)
        VALUE="$(cat)"
        ;;
    --from-env)
        VAR="$1"; shift
        VALUE="${!VAR:?Environment variable $VAR is empty}"
        ;;
    *) usage; exit 1 ;;
esac

DEST="locksmith/secrets/${SECRET_NAME}.creds"
mkdir -p "$(dirname "$DEST")"

if command -v systemd-creds >/dev/null 2>&1; then
    printf '%s' "$VALUE" | systemd-creds encrypt --name="$SECRET_NAME" - "$DEST"
else
    # Dev/macOS fallback — symmetric AES via openssl. Operator must keep the
    # passphrase in $LOCKSMITH_CREDS_PASSPHRASE. Production hosts use
    # systemd-creds.
    : "${LOCKSMITH_CREDS_PASSPHRASE:?Set LOCKSMITH_CREDS_PASSPHRASE for non-systemd hosts}"
    printf '%s' "$VALUE" | openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass "env:LOCKSMITH_CREDS_PASSPHRASE" -out "$DEST"
fi

chmod 0600 "$DEST"
echo "✓ Wrote encrypted secret to $DEST"
