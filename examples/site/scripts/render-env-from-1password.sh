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
