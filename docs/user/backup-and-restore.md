# Backup and restore

What to back up, how often, and how to restore.

## What's backup-worthy

| State | Where | Rebuildable? | Required to back up? |
|---|---|---|---|
| Locksmith SQLite DB | Docker volume `layer8-proxy_locksmith_data` | No — agents/audit are stateful | **YES** |
| Sealed credentials | `locksmith/secrets/*.creds` in site repo | Operator-mintable but tedious | **YES** |
| `operators.yaml` | site repo | From `bootstrap-operator` (re-mints; old token invalidated) | **YES** |
| `agents.yaml` | site repo | Operator-authored | **YES** |
| `.env` | site repo | Operator-authored | **YES** (separately, encrypted) |
| `site.cfg`, configs | site repo | Operator-authored | YES (in git) |
| Audit JSONL mirror | `/var/log/locksmith/audit.jsonl` | Tail-only; superset of DB | **YES** for compliance |
| Built locksmith image | local Docker daemon | Re-buildable from source | No |
| Hermes / openclaw state | `~/.hermes/` etc. on agent hosts | Agent-owned | Per agent's backup story |

The site repo's `backup.sh` covers DB + sealed creds in one snapshot.
JSONL audit mirror needs separate handling (typically logrotate +
external archiver).

## Backup with restic (the bundled approach)

The `backup.sh` shipped with the site template wraps
[restic](https://restic.net) — an encrypted, deduplicated, append-only
backup tool.

### Initialize the repo

One-time setup (per backup destination):

```bash
# 1. Generate a passphrase + seal it.
echo -n "your-strong-passphrase" | ./secrets.bootstrap.sh restic_password --from-stdin

# 2. Configure BACKUP_DEST in .env. Examples:
#    BACKUP_DEST=/Volumes/NAS/layer8-backups        (NAS mount)
#    BACKUP_DEST=rest:https://restic.example.corp:8000/layer8-mini-m1
#    BACKUP_DEST=s3:s3.amazonaws.com/layer8-backups
#    BACKUP_DEST=b2:bucket-name:layer8-mini-m1

# 3. Initialize.
./backup.sh init
```

### Run a backup

```bash
./backup.sh
# Snapshots:
#   - locksmith DB (via docker exec sqlite3 .backup)
#   - locksmith/secrets/ (sealed creds tree)
#   - locksmith/operators.yaml
#   - agents.yaml
#   - site.cfg
#   - pipelock/pipelock.yaml
```

`backup.sh` keeps `BACKUP_RETENTION_DAYS` (default 14) of snapshots.

### Schedule

The site template ships a `cron/backup.cron` you can install:

```bash
crontab cron/backup.cron
# Default: daily at 04:00 local time.
```

For systemd hosts: convert the cron line to a systemd timer
(`backup.service` + `backup.timer`).

### What doesn't get captured

`backup.sh` deliberately **excludes**:

- `.env` cleartext (it has live provider keys; back up separately
  via your secrets-management tool, or seal it AND back up the
  sealed form).
- `rendered/` (regenerated each deploy).
- Docker images (re-buildable from source).
- Audit JSONL mirror (handle via logrotate + external archive).

## Backup the audit JSONL mirror

If `audit.jsonl_path` is configured, the JSONL file rotates by size
(`audit.jsonl_max_bytes`, default 100 MiB) keeping
`audit.jsonl_keep_files` (default 7) rotated copies.

For long-term retention:

```bash
# Cron:
0 5 * * * rsync -a --delete /var/log/locksmith/ \
    backup-host:/srv/audit-archive/$(hostname)/
```

Or push to a SIEM / log-aggregation system (Loki, Splunk, etc.)
that scrapes the file in real-time.

## Backup the operator credential

If you lose `operators.yaml`, you can't talk to the daemon as
operator until you mint a fresh one — but minting fresh
invalidates the existing wire token. So backup is critical.

`backup.sh` snapshots `operators.yaml`. The cleartext wire token
is sealed in `locksmith/secrets/operator_token.creds` — also backed
up. To restore both, you need:

1. The sealed `operator_token.creds` file.
2. The passphrase / sealing key (memorize / password-manager).

Keep the passphrase out-of-band. Without it, the sealed token is
permanently inaccessible.

## Restore

### Full restore from a clean host

```bash
# 1. Install layer8-proxy + clone site repo skeleton.
git clone git@github.com:SentientSwarm/layer8-proxy.git
./scripts/init-site.sh ../my-site
cd ../my-site

# 2. Restore site files from backup.
./backup.sh restore --target-dir . --snapshot latest
# This pulls site.cfg, .env (if you backed it up), agents.yaml,
# locksmith/secrets/, locksmith/operators.yaml, pipelock/pipelock.yaml
# from the latest restic snapshot.

# 3. Restore the locksmith DB volume.
./backup.sh restore-db --snapshot latest
# This recreates layer8-proxy_locksmith_data with the SQLite file.

# 4. Re-deploy.
./deploy.sh
```

### Restore just the DB

```bash
# Stop the stack so the DB isn't mid-write.
docker compose ... stop locksmith

# Restore.
./backup.sh restore-db --snapshot latest

# Restart.
docker compose ... start locksmith
./scripts/verify.sh
```

After restore, all agents (including their bearers) are present.
You don't need to re-register.

### Restore from a specific snapshot

```bash
# List available snapshots.
./backup.sh list

# Restore from a specific ID.
./backup.sh restore --snapshot c4f8e2a1
```

### Disaster recovery (lost backup repo too)

Without a backup repo OR the restic password, the deployment must
be rebuilt from scratch:

1. Clone repos, init site, deploy.
2. Mint a fresh operator credential.
3. Re-register every agent (each gets a NEW bearer; agent hosts
   need to be updated).
4. Re-bootstrap every OAuth session.
5. Audit history is lost.

This is why the JSONL audit mirror to off-host storage matters —
it's the one piece that survives a full DB loss if you set it up.

## Snapshot integrity checks

`restic check` validates the repo:

```bash
restic -r "$BACKUP_DEST" --password-file <(./scripts/decrypt-creds.sh ./locksmith/secrets/restic_password.creds) check
```

Run weekly (cron) to catch silent corruption early:

```cron
0 5 * * 0 cd /path/to/site-repo && ./backup.sh check
```

## Backup hygiene checklist

- [ ] `BACKUP_DEST` is configured + reachable.
- [ ] `restic_password` is sealed + the passphrase is in a password
      manager (you'll need it during restore).
- [ ] `backup.sh` cron is installed.
- [ ] `backup.sh check` runs weekly.
- [ ] At least one **off-host** snapshot destination (not the same
      disk as the live DB).
- [ ] If using JSONL audit mirror, separate rsync / SIEM push for
      that file.
- [ ] Restore drill done at least once (in a sandbox, not on the
      live deployment) to confirm the restic password actually
      works.

## See also

- [deploy.md](deploy.md) — initial deploy.
- [rotate-credentials.md](rotate-credentials.md) — rotating the
  restic password, sealing key, etc.
- [troubleshoot.md](troubleshoot.md) — failure modes.
- [restic.net](https://restic.net) — restic upstream docs.
