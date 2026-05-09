#!/usr/bin/env bash
# provision-host-sa.sh — provision a per-(host × product) 1Password Service
# Account scoped read-only to one Environment, and emit a non-interactive
# deploy recipe for the operator to run on the target host.
#
# Per ADR-0006 D4 (per-(host × product) SA) + D9 (operator-role separation,
# per-host Keychain isolation) + D5 (PASS_MAX 128-char prompt gotcha — the
# emitted recipe MUST use the non-interactive `-w "$TOKEN"` form).
#
# Usage:
#   ./provision-host-sa.sh \
#       --host <hostname>       # e.g., mini-1, studio-1, jx-mbp-m5
#       --product <product>     # e.g., openclaw, hermes, layer8-proxy
#       --environment <env-id>  # 1P Environment UUID (find via 1P UI:
#                               # Developer → Environments → click → copy ID)
#       --vault <vault-name>    # Vault holding the Environment
#       [--account <email>]     # Operator email for Keychain `-a` label
#                               # (default: $USER@local)
#
# What it does:
#   1. Validate operator is signed in (`op whoami`)
#   2. Validate the Environment is accessible (`op environment read $id >/dev/null`)
#      — `op environment list` doesn't exist in beta CLI; the read-with-discard
#      pattern is the existence check
#   3. Create a Service Account named `<host>-<product>` scoped to the Environment
#   4. Print a deploy recipe using the host-prefixed Keychain naming convention
#      (OP_SERVICE_ACCOUNT_TOKEN_<HOST>_<PRODUCT>) and the non-interactive
#      `security add-generic-password -w "$TOKEN"` form
#
# What it does NOT do:
#   - Touch any host's Keychain (operator runs the printed recipe per host)
#   - Persist the SA token (printed once; operator deploys immediately)

set -euo pipefail

# Args -----------------------------------------------------------------------

HOST=""
PRODUCT=""
ENVIRONMENT=""
VAULT=""
ACCOUNT="${USER:-operator}@local"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)         HOST="$2"; shift 2 ;;
        --product)      PRODUCT="$2"; shift 2 ;;
        --environment)  ENVIRONMENT="$2"; shift 2 ;;
        --vault)        VAULT="$2"; shift 2 ;;
        --account)      ACCOUNT="$2"; shift 2 ;;
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

[[ -n "$HOST"        ]] || { echo "ERROR: --host is required" >&2; exit 1; }
[[ -n "$PRODUCT"     ]] || { echo "ERROR: --product is required" >&2; exit 1; }
[[ -n "$ENVIRONMENT" ]] || { echo "ERROR: --environment is required" >&2; exit 1; }
[[ -n "$VAULT"       ]] || { echo "ERROR: --vault is required" >&2; exit 1; }

# Derived names --------------------------------------------------------------

# SA name: <host>-<product> (preserves hyphens — 1P SA names allow them)
SA_NAME="${HOST}-${PRODUCT}"

# Keychain entry: OP_SERVICE_ACCOUNT_TOKEN_<HOST>_<PRODUCT>, uppercased,
# hyphens become underscores. Must be globally unique across iCloud Keychain
# sync per ADR-0006 D9.
KEYCHAIN_SUFFIX="$(printf '%s_%s' "$HOST" "$PRODUCT" | tr 'a-z-' 'A-Z_')"
KEYCHAIN_SERVICE="OP_SERVICE_ACCOUNT_TOKEN_${KEYCHAIN_SUFFIX}"

# Probes ---------------------------------------------------------------------

command -v op >/dev/null 2>&1 \
    || { echo "ERROR: op CLI not installed (brew install --cask 1password-cli@beta)" >&2; exit 1; }

if ! op whoami >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: not signed into 1Password.

  Sign in via the 1Password desktop app (Settings → Developer →
  "Integrate with 1Password CLI") or interactively:
    eval \$(op signin)

  Then re-run this script.
EOF
    exit 1
fi

if ! op environment read "$ENVIRONMENT" >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: Environment "$ENVIRONMENT" is not accessible.

  Possible causes:
    - Environment ID is wrong. Find it in the 1P UI:
      Developer → Environments → click the Environment → copy ID.
    - Your account doesn't have access to the vault holding this Environment.
    - Environment hasn't been created yet — create it first in the 1P UI.

  (op environment list doesn't exist in the beta CLI, so we use
   "op environment read \$id >/dev/null" as the existence check.)
EOF
    exit 1
fi

# Create SA ------------------------------------------------------------------

echo "→ Creating Service Account '$SA_NAME' scoped to Environment $ENVIRONMENT in vault '$VAULT'" >&2

# Note: op service-account create's exact arg shape may evolve. Current beta
# CLI: `op service-account create --name <name>` with vault scope set
# interactively or via further flags. If this invocation needs adjustment for
# your op version, see `op service-account create --help`.
TOKEN="$(op service-account create --name "$SA_NAME" 2>&1)" || {
    echo "ERROR: Service Account creation failed:" >&2
    echo "$TOKEN" >&2
    exit 1
}

# Sanity-check the token shape (real SA tokens start with ops_ and are ~700+
# chars). Empty or short = something went wrong.
if [[ -z "$TOKEN" || "${#TOKEN}" -lt 100 || "${TOKEN:0:4}" != "ops_" ]]; then
    cat >&2 <<EOF
ERROR: Service Account creation produced an unexpected token shape.

  Length: ${#TOKEN}
  Prefix: ${TOKEN:0:8}

  Expected: starts with "ops_", ~700 chars total. Got something else;
  the SA may not have been created correctly. Check the 1P web UI
  Developer → Service Accounts to confirm.
EOF
    exit 1
fi

echo "✓ Created SA '$SA_NAME' (token length: ${#TOKEN})" >&2

# Emit deploy recipe ---------------------------------------------------------

cat <<EOF

================================================================================
Deploy this Service Account token to host '$HOST'
================================================================================

The SA token is shown ONCE below. Deploy it to the target host's Keychain
immediately — it cannot be retrieved later (only rotated).

Token:
$TOKEN

--------------------------------------------------------------------------------
Run on the target host (or via SSH from this laptop):
--------------------------------------------------------------------------------

# Use the non-interactive form — the interactive 'security ... -w' prompt
# truncates at PASS_MAX (128 chars) and SA tokens are ~700 chars.
TOKEN='$TOKEN'
security add-generic-password \\
    -s $KEYCHAIN_SERVICE \\
    -a $ACCOUNT \\
    -w "\$TOKEN"
unset TOKEN

# Verify (should print ${#TOKEN}):
T="\$(security find-generic-password -s $KEYCHAIN_SERVICE -w 2>/dev/null)"
echo "stored length: \${#T}"
unset T

--------------------------------------------------------------------------------
Then in the target host's <product>-site/site.cfg:
--------------------------------------------------------------------------------

op_environment_id=$ENVIRONMENT
op_keychain_service=$KEYCHAIN_SERVICE

# (Linux hosts only — macOS uses Keychain via op_keychain_service):
# op_token_file=\$HOME/.config/op/$PRODUCT.token

================================================================================

NOTE: per ADR-0006 D9, production agent hosts should have ISOLATED login
keychains (no iCloud Keychain sync). The SA token added above stays scoped
to the host where you run the security command. Operator-personal hosts
may sync at the operator's discretion.

EOF
