#!/usr/bin/env bash
# backup.sh — snapshot proxy-side state (locksmith audit DB + sealed secrets)
# and ship to a configurable destination. Schedule via cron/backup.cron.
#
# Hermes runtime data is backed up separately by hermes-site/backup.sh against
# its own ${HERMES_HOME} on the agent host.
#
# BACKUP_DEST controls where archives go:
#   - Filesystem path  (e.g. /Volumes/nas/layer8-backups, /mnt/backup) —
#     rsync + mtime-based pruning.
#   - restic URI       (s3:..., sftp:..., rest:..., b2:..., azure:..., gs:...,
#                       swift:..., rclone:...) — restic backup + restic forget.

set -euo pipefail

CONTAINER="${CONTAINER:-docker}"
ARCHIVE_DIR="${BACKUP_ARCHIVE_DIR:-/var/backups/layer8}"
: "${BACKUP_DEST:?BACKUP_DEST required (filesystem path or restic URI)}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

mkdir -p "$ARCHIVE_DIR"

# ── Stage 1: produce archives in $ARCHIVE_DIR ──────────────────────────────

# Locksmith audit DB — Docker volume snapshot.
# (Append-only; torn-snapshot worst case is losing recent audit rows.
#  Follow-up improvement: use sqlite3 .backup for true consistency.)
if ${CONTAINER} volume inspect locksmith_data >/dev/null 2>&1; then
    ${CONTAINER} run --rm -v locksmith_data:/data -v "$ARCHIVE_DIR:/backup" \
        alpine tar czf "/backup/locksmith-data-$(date -u +%FT%TZ).tar.gz" /data
fi

# Locksmith JSONL audit mirror, if present.
if ${CONTAINER} volume inspect locksmith_log >/dev/null 2>&1; then
    ${CONTAINER} run --rm -v locksmith_log:/log -v "$ARCHIVE_DIR:/backup" \
        alpine tar czf "/backup/locksmith-log-$(date -u +%FT%TZ).tar.gz" /log
fi

# Sealed secrets — copy the .creds files from the local site repo. They're
# already encrypted at rest; offsite copy is for disaster recovery.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/locksmith/secrets" ]]; then
    tar czf "$ARCHIVE_DIR/secrets-$(date -u +%FT%TZ).tar.gz" \
        -C "$SCRIPT_DIR/locksmith" secrets
fi

# ── Stage 2: ship to BACKUP_DEST ───────────────────────────────────────────

case "$BACKUP_DEST" in
    s3:*|sftp:*|rest:*|b2:*|azure:*|gs:*|swift:*|rclone:*)
        if [[ -n "${RESTIC_PASSWORD_CREDS:-}" ]]; then
            export RESTIC_REPOSITORY="$BACKUP_DEST"
            RESTIC_PASSWORD_FILE=<("$SCRIPT_DIR/scripts/decrypt-creds.sh" "$RESTIC_PASSWORD_CREDS")
            export RESTIC_PASSWORD_FILE
        else
            : "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE or RESTIC_PASSWORD_CREDS required for restic backends}"
            export RESTIC_REPOSITORY="$BACKUP_DEST" RESTIC_PASSWORD_FILE
        fi
        restic init 2>/dev/null || true
        restic backup "$ARCHIVE_DIR"
        restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
        ;;
    *)
        if [[ ! -d "$BACKUP_DEST" ]]; then
            mkdir -p "$BACKUP_DEST" || {
                echo "ERROR: BACKUP_DEST $BACKUP_DEST does not exist and could not be created" >&2
                exit 1
            }
        fi
        if [[ ! -w "$BACKUP_DEST" ]]; then
            echo "ERROR: BACKUP_DEST $BACKUP_DEST is not writable (NAS offline?)" >&2
            exit 1
        fi
        rsync -a "$ARCHIVE_DIR/" "$BACKUP_DEST/"
        find "$BACKUP_DEST" -type f -name '*.tar.gz' \
             -mtime "+$RETENTION_DAYS" -delete
        ;;
esac

echo "✓ layer8-proxy backup complete (dest: $BACKUP_DEST)."
