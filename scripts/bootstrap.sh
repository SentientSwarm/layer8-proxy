#!/usr/bin/env bash
# layer8-proxy bootstrap — pulls images, builds local components.
# Site repos call this from their deploy.sh before docker compose up.
#
# To use Podman instead of Docker, set:
#     export COMPOSE="podman compose"
# in your shell before running.

set -euo pipefail

COMPOSE="${COMPOSE:-docker compose}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f .env ]]; then
    echo "ERROR: .env not found. Copy .env.example and fill in values." >&2
    exit 1
fi

echo "→ Building layer8-proxy images..."
${COMPOSE} build --pull

echo "→ Pulling base images already present..."
${COMPOSE} pull --ignore-buildable || true

echo "✓ layer8-proxy bootstrap complete."
echo "  Next: ${COMPOSE} up -d (or use site repo's deploy.sh)"
