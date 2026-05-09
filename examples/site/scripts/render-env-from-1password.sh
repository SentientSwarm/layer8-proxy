#!/usr/bin/env bash
# render-env-from-1password.sh — materialize .env from a 1Password Environment.
#
# Reads op_environment_id from site.cfg, resolves the SA token from the
# documented sources (env > Keychain > file), runs `op environment read`,
# writes mode-0600 .env atomically. Fail-loud on any error.
#
# Override: --skip-render is handled by the caller (launch-*.sh), not here.
#
# Manual smoke recipe:
#   SITE_DIR=/path/to/site OP_SERVICE_ACCOUNT_TOKEN=ops_xxx ./render-env-from-1password.sh
# Automated tests: examples/site/scripts/tests/render-env-from-1password.bats

set -euo pipefail

SITE_DIR="${SITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SITE_CFG="$SITE_DIR/site.cfg"

[[ -f "$SITE_CFG" ]] || { echo "ERROR: $SITE_CFG not found" >&2; exit 1; }

# shellcheck source=/dev/null
. "$SITE_CFG"
: "${op_environment_id:?ERROR: site.cfg must define op_environment_id (see README §1Password setup)}"

# Capability probe: the `op environment` subcommand must exist. Stable-channel
# `op` (1password-cli cask) does NOT include it as of 2.34.0; only the beta
# cask (1password-cli@beta) does. See ADR-0006 D8 for context. We probe with
# `--help` because it's a cheap, auth-free check.
if ! op environment --help >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: op CLI lacks the \`environment\` subcommand.

  Your op CLI is likely the stable channel cask. Install the beta:
    brew uninstall --cask 1password-cli
    brew install --cask 1password-cli@beta

  Verify: op environment --help

  See ADR-0006 D8 for context.
EOF
    exit 1
fi

# Resolve SA token: env var > Keychain > file. Fail loud if all three miss.
if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    if command -v security >/dev/null 2>&1 \
       && OP_SERVICE_ACCOUNT_TOKEN="$(security find-generic-password \
            -s OP_SERVICE_ACCOUNT_TOKEN -w 2>/dev/null)" \
       && [[ -n "$OP_SERVICE_ACCOUNT_TOKEN" ]]; then
        :    # got it from Keychain
    elif [[ -f "$HOME/.config/op/service-account-token" ]]; then
        OP_SERVICE_ACCOUNT_TOKEN="$(< "$HOME/.config/op/service-account-token")"
    else
        cat >&2 <<EOF
ERROR: 1Password Service Account token not found.

  Tried (in order):
    1. \$OP_SERVICE_ACCOUNT_TOKEN env var (unset)
    2. macOS Keychain (security find-generic-password -s OP_SERVICE_ACCOUNT_TOKEN)
    3. File at $HOME/.config/op/service-account-token

  Provision: see ./scripts/provision-host-sa.sh and the README §1Password setup.
EOF
        exit 1
    fi
fi
export OP_SERVICE_ACCOUNT_TOKEN
