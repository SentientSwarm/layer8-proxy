#!/usr/bin/env bash
# deploy.sh — render canonical configs, validate alignment, bring up the stack.
# Run from inside the hermes-site repo.
#
# To use Podman instead of Docker:
#     export COMPOSE="podman compose"

set -euo pipefail

COMPOSE="${COMPOSE:-docker compose}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
source ./site.cfg

LAYER8="${SCRIPT_DIR}/${layer8_path}"
if [[ ! -d "$LAYER8" ]]; then
    echo "ERROR: layer8-proxy not found at $LAYER8" >&2
    echo "  Run: uv run clone-repos.py from agents-stack/" >&2
    exit 1
fi

# Verify layer8 version matches site.cfg (skipped if pin is empty).
if [[ -n "${layer8_version:-}" ]]; then
    actual=$(git -C "$LAYER8" describe --tags --always 2>/dev/null || echo "unknown")
    if [[ "$actual" != "$layer8_version" ]]; then
        echo "WARNING: site.cfg pins layer8_version=$layer8_version, but $LAYER8 is at $actual" >&2
        read -rp "Continue anyway? [y/N] " yn
        [[ "$yn" =~ ^[Yy] ]] || exit 1
    fi
fi

if [[ ! -f .env ]]; then
    echo "ERROR: .env not found. Copy .env.example and fill in values." >&2
    exit 1
fi

echo "→ Rendering configs from canonical tools/..."
uv run --with pyyaml ./scripts/render_configs.py \
    --tools-dir ./tools \
    --rendered-dir ./rendered \
    --locksmith-base ./locksmith/base.yaml

echo "→ Verifying locksmith ↔ pipelock alignment..."
uv run --with pyyaml ./scripts/verify_configs.py \
    --tools-dir ./tools \
    --pipelock-config ./pipelock/pipelock.yaml \
    --pipelock-extras ./rendered/pipelock/allowlist-extras.yaml \
    --secrets-dir ./locksmith/secrets

echo "→ Building layer8-proxy images..."
( cd "$LAYER8" && cp -n .env.example .env 2>/dev/null || true; ./scripts/bootstrap.sh )

echo "→ Bringing up the stack..."
# Render the override with absolute paths into a temp file. Avoids the
# Docker Compose ambiguity where relative paths in the override resolve
# against the FIRST compose file's directory (layer8-proxy/), not the
# override's directory (hermes-site/). --project-directory would fix mounts
# but would also re-anchor the base compose's build contexts and break them.
TMP_OVERRIDE="$(mktemp -t l8-override.XXXXXX.yml)"
trap 'rm -f "$TMP_OVERRIDE"' EXIT
sed "s|\\./|$SCRIPT_DIR/|g" ./docker-compose.override.yml > "$TMP_OVERRIDE"

${COMPOSE} \
    -f "$LAYER8/docker-compose.yml" \
    -f "$TMP_OVERRIDE" \
    --env-file ./.env \
    up -d --build

echo "→ Verifying stack..."
sleep 10
"$LAYER8/scripts/verify.sh"

echo "✓ Deploy complete. Hermes can now route via http://127.0.0.1:9200/api/<tool>/..."
