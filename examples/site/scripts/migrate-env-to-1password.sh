#!/usr/bin/env bash
# migrate-env-to-1password.sh — one-shot migration helper from local .env to
# a 1Password Environment.
#
# Per the 2026-05-09 design ripple sweep: this script does NOT auto-write to
# 1P. The beta CLI's `op environment update` doesn't exist; the supported
# write path (`op item edit` against the Environment's backing vault item)
# has uncertain field semantics for arbitrary KEY=value pairs. So the script:
#
#   1. Parses the source .env (skips comments, blanks, malformed lines)
#   2. Backs up the source to .env.pre-1password.bak (mode 0600)
#   3. Prints the parsed entries in a paste-ready format for the operator
#      to enter into the 1P UI (Developer → Environments → click → Edit)
#
# The migration is a one-shot ceremony per host, so the manual paste step
# is acceptable. When `op environment update` ships, the auto-write step
# can be added without touching the parse/backup logic.
#
# Usage:
#   ./migrate-env-to-1password.sh \
#       --env-file <path>       # path to source .env to migrate
#       --environment <id>      # target 1P Environment UUID (for context)
#
# What it does:
#   - Validates args + source file exists
#   - Idempotent backup: writes .env.pre-1password.bak (mode 0600) only if
#     it doesn't already exist
#   - Prints parsed entries in paste-ready KEY=value format
#   - Does NOT delete the source .env (operator validates first, deletes manually)

set -euo pipefail

# Args -----------------------------------------------------------------------

ENV_FILE=""
ENVIRONMENT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)     ENV_FILE="$2"; shift 2 ;;
        --environment)  ENVIRONMENT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

[[ -n "$ENV_FILE"    ]] || { echo "ERROR: --env-file is required" >&2; exit 1; }
[[ -n "$ENVIRONMENT" ]] || { echo "ERROR: --environment is required" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || { echo "ERROR: source .env file not found: $ENV_FILE" >&2; exit 1; }

# Idempotent backup ----------------------------------------------------------

BACKUP="${ENV_FILE}.pre-1password.bak"
if [[ ! -f "$BACKUP" ]]; then
    umask 0077
    cp "$ENV_FILE" "$BACKUP"
    chmod 0600 "$BACKUP"
    echo "→ Backup written: $BACKUP (mode 0600)" >&2
else
    echo "→ Backup already exists at $BACKUP (skipping — re-run safe)" >&2
fi

# Parse + emit ---------------------------------------------------------------

cat <<EOF

================================================================================
Migration entries for 1Password Environment $ENVIRONMENT
================================================================================

Open 1Password (desktop or web): Developer → Environments → click the
Environment for "$ENVIRONMENT" → Edit. Paste each KEY=value below as a
new entry. Save when done.

The lines below are extracted from $ENV_FILE (comments and blanks dropped):

--------------------------------------------------------------------------------
EOF

# Parse: skip comments (# ...) and blank lines; keep KEY=value lines as-is.
# Awk used over grep -P for portability.
awk '
    /^[[:space:]]*#/   { next }   # comment
    /^[[:space:]]*$/   { next }   # blank
    /^[A-Za-z_][A-Za-z0-9_]*=/ { print; next }   # well-formed KEY=value
    { print "# WARNING: malformed line skipped: " $0 > "/dev/stderr" }
' "$ENV_FILE"

cat <<EOF
--------------------------------------------------------------------------------

After pasting:
  1. Save the Environment in 1P
  2. Verify with: op environment read $ENVIRONMENT
  3. Run render-env-from-1password.sh on the host to produce a fresh .env
     from the 1P Environment
  4. Diff the new .env against $BACKUP to confirm parity
  5. Once you've validated the host runs from the rendered .env, delete the
     original $ENV_FILE manually (this script never deletes it)

================================================================================
EOF
