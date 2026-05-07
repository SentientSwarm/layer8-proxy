#!/usr/bin/env bash
# init-site.sh — bootstrap a layer8-proxy site repo from the template.
#
# Usage:
#   ./scripts/init-site.sh <target-dir>
#
# Example:
#   ./scripts/init-site.sh ../my-site
#   cd ../my-site
#   nano .env site.cfg agents.yaml
#   ./deploy.sh
#
# Copies layer8-proxy/examples/site/ to <target-dir>, renames *.example
# files to their canonical names, and runs git init so the operator
# can track their private state from day zero.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <target-dir>

Bootstrap a layer8-proxy site repo from examples/site/. The target
directory must NOT already exist (refuses to clobber existing state).

After running:
  cd <target-dir>
  cp .env.example .env  # (already done if you used this script)
  nano .env site.cfg agents.yaml
  ./deploy.sh
EOF
}

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

TARGET="$1"
if [[ -e "$TARGET" ]]; then
    echo "ERROR: target $TARGET already exists. Refusing to clobber." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$SCRIPT_DIR/examples/site"

if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: template not found at $SOURCE" >&2
    echo "  This script must run from a layer8-proxy checkout." >&2
    exit 1
fi

echo "→ Copying template from $SOURCE to $TARGET ..."
cp -R "$SOURCE/" "$TARGET/"
# .gitkeep files are placeholders; remove on init.
find "$TARGET" -name '.gitkeep' -delete

echo "→ Renaming *.example files ..."
cd "$TARGET"
[[ -f site.cfg.example ]] && mv site.cfg.example site.cfg
[[ -f .env.example ]] && cp .env.example .env  # keep .env.example as schema reference
[[ -f agents.yaml.example ]] && cp agents.yaml.example agents.yaml
[[ -f agents.test.yaml.example ]] && cp agents.test.yaml.example agents.test.yaml

echo "→ Initializing git ..."
git init --quiet
git add .gitignore .env.example site.cfg agents.yaml.example agents.test.yaml.example \
    locksmith pipelock tools cron \
    deploy.sh secrets.bootstrap.sh backup.sh \
    docker-compose.override.yml \
    scripts/bootstrap-operator.py scripts/decrypt-creds.sh \
    scripts/register-agents.sh scripts/render_configs.py \
    scripts/verify_configs.py \
    README.md 2>/dev/null || true

cat <<EOF
✓ Site repo initialized at $TARGET

Next steps:

  1. cd $TARGET

  2. Edit site.cfg:
       site_name=<your-site>
       host=<this-hostname>

  3. Edit .env — provide provider API keys + LF_SCAN_INTERNAL_TOKEN +
     (optional) LOCKSMITH_OAUTH_SEALING_KEY. Never commit .env.

  4. Edit agents.yaml — declare your agents and their allowlists.

  5. Bootstrap sealed creds (lf-scan token + restic password):
       echo -n "\$LF_SCAN_INTERNAL_TOKEN" | ./secrets.bootstrap.sh lf_scan_token --from-stdin
       echo -n "your-restic-passphrase" | ./secrets.bootstrap.sh restic_password --from-stdin

  6. Mint the operator credential (Python path):
       LOCKSMITH_CREDS_PASSPHRASE="..." ./scripts/bootstrap-operator.py
     OR (after deploy, Rust-native path):
       docker exec layer8-locksmith /usr/local/bin/locksmith bootstrap-operator \\
           --name alice > locksmith/operators.yaml

  7. Deploy the stack:
       ./deploy.sh

  8. Register agents:
       ./scripts/register-agents.sh

See $TARGET/README.md for the full template documentation.
EOF
