#!/usr/bin/env bash
# layer8-proxy verify — smoke test the running stack.

set -euo pipefail

LOCKSMITH_URL="${LOCKSMITH_URL:-http://127.0.0.1:9200}"
CONTAINER="${CONTAINER:-docker}"

fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

echo "→ Verifying layer8-proxy stack..."

curl -fsS "${LOCKSMITH_URL}/livez"   >/dev/null || fail "locksmith /livez unreachable"
pass "locksmith /livez"

curl -fsS "${LOCKSMITH_URL}/readyz"  >/dev/null || fail "locksmith /readyz failing — tools likely missing credentials"
pass "locksmith /readyz"

curl -fsS "${LOCKSMITH_URL}/version" >/dev/null || fail "locksmith /version unreachable"
pass "locksmith /version"

# Pipelock has no host-side port (intra-compose only). Check via docker exec
# using its bundled healthcheck command. If the container isn't named
# layer8-pipelock locally, set PIPELOCK_CONTAINER.
PIPELOCK_CONTAINER="${PIPELOCK_CONTAINER:-layer8-pipelock}"
${CONTAINER} exec "$PIPELOCK_CONTAINER" /usr/local/bin/pipelock healthcheck >/dev/null \
    || fail "pipelock healthcheck failed (container $PIPELOCK_CONTAINER)"
pass "pipelock healthcheck (via docker exec)"

# lf-scan is reachable via locksmith only — try via the lf-scan tool entry.
# This requires the operator to have configured a `lf-scan` tool. Skip if not.
if curl -fsS "${LOCKSMITH_URL}/api/lf-scan/health" >/dev/null 2>&1; then
    pass "lf-scan /health (via locksmith)"
else
    echo "  (skipping lf-scan check — no lf-scan tool registered in locksmith yet)"
fi

echo "✓ Stack verified."
