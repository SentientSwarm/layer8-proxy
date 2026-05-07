#!/usr/bin/env bash
# register-agents.sh — register the agents declared in agents.yaml with
# locksmith, applying per-agent ACLs (allowlist of tools).
#
# Authenticates to locksmith's admin UDS using the operator wire token
# sealed at locksmith/secrets/operator_token.creds (run
# ./scripts/bootstrap-operator.py first).
#
# Each successful registration prints the agent's bearer token in
# cleartext. The token is shown ONCE — copy it and install on the agent
# host immediately (see hermes-site/README.md).
#
# Re-running the script is NOT idempotent: locksmith refuses duplicate
# agent names. To re-issue a token, run `locksmith agent revoke <id>`
# followed by re-registering.

set -euo pipefail

CONTAINER="${CONTAINER:-docker}"
LOCKSMITH_CONTAINER="${LOCKSMITH_CONTAINER:-layer8-locksmith}"
LOCKSMITH_BIN="${LOCKSMITH_BIN:-/usr/local/bin/locksmith}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

MANIFEST="${AGENTS_MANIFEST:-./agents.yaml}"
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: $MANIFEST not found. Copy agents.yaml.example and edit." >&2
    exit 1
fi

if ! ${CONTAINER} ps --filter "name=^${LOCKSMITH_CONTAINER}$" --format '{{.Names}}' \
        | grep -q "^${LOCKSMITH_CONTAINER}$"; then
    echo "ERROR: locksmith container ${LOCKSMITH_CONTAINER} is not running. Run ./deploy.sh first." >&2
    exit 1
fi

# Decrypt the operator wire token from the sealed-secret store.
OPERATOR_CREDS="locksmith/secrets/operator_token.creds"
if [[ ! -f "$OPERATOR_CREDS" ]]; then
    echo "ERROR: $OPERATOR_CREDS not found." >&2
    echo "       Run ./scripts/bootstrap-operator.py first." >&2
    exit 1
fi

if [[ -z "${LOCKSMITH_OP_TOKEN:-}" ]]; then
    LOCKSMITH_OP_TOKEN=$(./scripts/decrypt-creds.sh "$OPERATOR_CREDS")
    export LOCKSMITH_OP_TOKEN
fi

# Parse the manifest with python (avoids needing yq). Emits one agent per
# line as: name|description|comma-separated-allowlist
python3 - "$MANIFEST" <<'PY' | while IFS='|' read -r NAME DESC ALLOWLIST; do
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
for a in doc.get("agents", []):
    name = a["name"]
    desc = a.get("description", "")
    allow = ",".join(a.get("allowlist", []))
    print(f"{name}|{desc}|{allow}")
PY
    [[ -z "$NAME" ]] && continue
    echo
    echo "→ Registering agent: $NAME"
    echo "  Allowlist: $ALLOWLIST"
    ARGS=( "$LOCKSMITH_BIN" agent register --name "$NAME" --format json )
    [[ -n "$DESC" ]]      && ARGS+=( --description "$DESC" )
    [[ -n "$ALLOWLIST" ]] && ARGS+=( --allowlist "$ALLOWLIST" )
    if RESULT=$(${CONTAINER} exec -e LOCKSMITH_OP_TOKEN="$LOCKSMITH_OP_TOKEN" \
                "$LOCKSMITH_CONTAINER" "${ARGS[@]}" 2>&1); then
        echo "$RESULT"
        echo
        echo "  ⚠️  Copy the 'token' field above and install on the agent host."
        echo "      For hermes: write to ~/.hermes/locksmith.token (mode 0600)."
    else
        echo "✗ Failed to register $NAME:" >&2
        echo "$RESULT" >&2
        echo "  (If the agent already exists, revoke first or rotate via 'locksmith agent revoke <id>'.)" >&2
    fi
done
