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

# ─── Per-agent bearer + ACL enforcement (M9 / B1, locksmith ≥ v2.0.0) ───────
#
# These assertions prove that the proxy hot path is rejecting unauthenticated,
# wrong-token, and disallowed-tool requests with the correct status codes.
#
# Operator-supplied fixture, all four required to enable:
#   LOCKSMITH_VERIFY_TOKEN          per-agent bearer (lk_<pid>.<secret>)
#   LOCKSMITH_VERIFY_ALLOWED_TOOL   tool name in this agent's allowlist
#   LOCKSMITH_VERIFY_DENIED_TOOL    tool name NOT in this agent's allowlist
#   LOCKSMITH_VERIFY_PROBE_PATH     a path under the tool that returns a
#                                   non-error response with valid auth
#                                   (e.g. /v1/models for lmstudio). Defaults
#                                   to /
#
# Convention: register a verify-test agent via agents.test.yaml in the site
# repo with a deliberately narrow allowlist, capture the token returned by
# `locksmith agent register --format json`, and export it before running
# verify.sh. Skipped (with a notice, not a failure) if any required env
# var is missing — verify.sh remains useful on stacks where the operator
# hasn't bootstrapped the test agent yet.

http_status() {
    # Print the HTTP status code for a GET request. Captures only the status
    # so a 401/403 body doesn't end up on stdout.
    local url="$1"; shift
    curl -s -o /dev/null -w "%{http_code}" "$@" "$url"
}

if [[ -n "${LOCKSMITH_VERIFY_TOKEN:-}" \
   && -n "${LOCKSMITH_VERIFY_ALLOWED_TOOL:-}" \
   && -n "${LOCKSMITH_VERIFY_DENIED_TOOL:-}" ]]; then
    PROBE="${LOCKSMITH_VERIFY_PROBE_PATH:-/}"
    ALLOWED_URL="${LOCKSMITH_URL}/api/${LOCKSMITH_VERIFY_ALLOWED_TOOL}${PROBE}"
    DENIED_URL="${LOCKSMITH_URL}/api/${LOCKSMITH_VERIFY_DENIED_TOOL}${PROBE}"

    # 1. No auth header at all → 401
    code=$(http_status "$ALLOWED_URL")
    [[ "$code" == "401" ]] || fail "no-auth probe expected 401, got $code"
    pass "auth: no Authorization header → 401"

    # 2. Malformed token → 401 (don't distinguish from missing/unknown — Q-8)
    code=$(http_status "$ALLOWED_URL" -H "Authorization: Bearer not_a_real_token")
    [[ "$code" == "401" ]] || fail "wrong-token probe expected 401, got $code"
    pass "auth: malformed bearer → 401"

    # 3. Valid token, denied tool → 403 (authz_error / tool_not_allowed)
    code=$(http_status "$DENIED_URL" -H "Authorization: Bearer ${LOCKSMITH_VERIFY_TOKEN}")
    [[ "$code" == "403" ]] || fail "denied-tool probe expected 403, got $code"
    pass "auth: valid token, denied tool ($LOCKSMITH_VERIFY_DENIED_TOOL) → 403"

    # 4. Valid token, allowed tool → not a 401/403 (could be 200 or any
    # upstream status; the point is the proxy let it through).
    code=$(http_status "$ALLOWED_URL" -H "Authorization: Bearer ${LOCKSMITH_VERIFY_TOKEN}")
    case "$code" in
        401|403) fail "allowed-tool probe should not return $code" ;;
        000)     fail "allowed-tool probe got transport error (000)" ;;
    esac
    pass "auth: valid token, allowed tool ($LOCKSMITH_VERIFY_ALLOWED_TOOL) → $code (not 401/403)"
else
    echo "  (skipping auth-enforcement checks — set LOCKSMITH_VERIFY_TOKEN,"
    echo "   LOCKSMITH_VERIFY_ALLOWED_TOOL, LOCKSMITH_VERIFY_DENIED_TOOL to enable)"
fi

echo "✓ Stack verified."
