# Upgrade

Bumping a layer8-proxy deployment to a new version is a one-config
change in the site repo, plus a redeploy. This doc walks through
the cutover and covers breaking-change migration paths.

## Standard upgrade flow

### 1. Pull the new layer8-proxy version

```bash
cd $LAYER8_PATH       # the layer8-proxy checkout, sibling to your site repo
git fetch
git checkout v1.0.1   # or whatever tag you're upgrading to
```

### 2. Update site.cfg

```bash
cd ../my-site
sed -i 's/^layer8_version=.*/layer8_version=v1.0.1/' site.cfg
```

### 3. Update LOCKSMITH_VERSION

The locksmith image is built from the agent-locksmith repo at
`${LOCKSMITH_VERSION}`. Each layer8-proxy release pins a default
locksmith version — check the layer8-proxy release notes:

```bash
cat $LAYER8_PATH/.env.example | grep LOCKSMITH_VERSION
# LOCKSMITH_VERSION=v2.0.1
```

Update your site's `.env`:

```bash
sed -i 's/^LOCKSMITH_VERSION=.*/LOCKSMITH_VERSION=v2.0.1/' .env
```

### 4. Redeploy

```bash
./deploy.sh
```

`deploy.sh`:
1. Verifies the layer8-proxy checkout matches `layer8_version`
   (warns if they differ).
2. Re-renders configs.
3. Re-builds the locksmith image (multi-stage; cargo cache hits keep
   it fast — typically 30s–2min on a warm cache).
4. `docker compose up -d --build` triggers in-place container
   restart.
5. `verify.sh` confirms `/livez`, `/readyz`, `/version` all 200 with
   the new version.

In-flight streaming responses get the
`shutdown.drain_window_seconds` window (default 30s) to complete
before the old container exits.

### 5. Verify

```bash
docker exec layer8-locksmith /usr/local/bin/locksmith --version
# locksmith 2.0.1

curl -sS http://127.0.0.1:9200/version
# {"name":"agent-locksmith","version":"2.0.1"}
```

Run a smoke call:

```bash
AGENT_TOKEN="lk_..."
curl -sS -X POST http://127.0.0.1:9200/api/anthropic/v1/messages \
    -H "Authorization: Bearer $AGENT_TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d '{"model":"claude-haiku-4-5","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}'
```

## Patch releases (vX.Y.Z → vX.Y.Z+1)

Always safe. Bug fixes only; no schema changes. Roll forward via
the standard flow.

## Minor releases (vX.Y.Z → vX.Y+1.0)

Mostly safe. May add new features (new admin endpoints, new audit
fields, additional seed catalog entries) but don't break existing
contracts.

Things to check:

- Any new `*.md` runbooks added under
  `agent-locksmith/docs/user/`?
- Any new `LOCKSMITH_*` env vars expected? (Check the release notes.)
- Did the seed catalog version bump? If yes, the seed loader will
  apply additive changes on first boot — operator overrides
  (`seed=false` rows) are preserved.

## Major releases (vX.Y.Z → vX+1.0.0)

Breaking changes. Each major release lands with a migration runbook
in the release notes. Common breaking-change patterns:

### Wire shape changes

`/tools` shape changed at v1.0.0 (was homogeneous; now strictly
kind=tool). Pre-v1.0.0 agents that consumed the homogeneous catalog
may need to switch to `/models` for LLM providers.

### Config schema changes

`config.tools` was the source of truth pre-Phase-E; v1.0.0 added the
`registrations` table. The `legacy_bootstrap` shim migrates
`config.tools` entries on first boot — operators don't need to
hand-port. The `config.tools` block is documented as deprecated
and removed in v0.3.

### Required env vars

Phase F added `LOCKSMITH_OAUTH_SEALING_KEY` (optional — only required
if you want OAuth providers). Future releases may add others; check
the release notes' "Required configuration" section.

## Downgrade

**Generally safe within a minor series; risky across minors;
unsupported across majors.**

```bash
# Downgrade to v1.0.0 from v1.0.1:
cd $LAYER8_PATH && git checkout v1.0.0
cd ../my-site
sed -i 's/^layer8_version=.*/layer8_version=v1.0.0/' site.cfg
sed -i 's/^LOCKSMITH_VERSION=.*/LOCKSMITH_VERSION=v2.0.0/' .env
./deploy.sh
```

The locksmith DB schema is forward-compatible (new migrations are
additive within a minor series), so a downgrade typically works.

**Caveat: don't downgrade past a schema-breaking migration.** v0.x →
v1.0.0 is one such boundary (the registrations table was added).
Going the other way means losing all your registrations.

If you must downgrade across a breaking migration:

1. Take a backup first (see [backup-and-restore.md](backup-and-restore.md)).
2. Stop the stack.
3. Replace the DB volume with a known-good pre-migration snapshot.
4. Bring up the older version.

## Rolling restart for zero downtime

Single-host deploys can't do true zero-downtime — there's only one
locksmith. The 30-second drain window is the closest you get.

For cross-host high-availability deployments:

1. Stand up a second locksmith host (different DNS, same DB volume
   via NFS / shared storage — caveats apply).
2. Migrate agents one-by-one to the new host's bearer set.
3. Decommission the old host once drained.

This is HA territory, not v1.0 scope. v0.3+ work explores
multi-locksmith with shared backing store.

## Cross-bundle upgrades (layer8-proxy v0.x → v1.0.0)

The big one. v1.0.0 is the first production-tagged release.
Pre-v1.0.0 deployments (M9-test images, dev clones from main) need:

1. **Backup current state** — DB + sealed creds.
2. **Stop the stack**: `docker compose down`.
3. **Update layer8-proxy + site.cfg + .env** to v1.0.0 / v2.0.0.
4. **Drop the m9-test image**: `docker rmi layer8-proxy/locksmith:m9-test`.
5. **Redeploy**: `./deploy.sh` — v2.0.0 daemon starts; `legacy_bootstrap`
   migrates any `config.tools` entries; seed catalog populates the
   registrations table.
6. **Smoke**: register a fresh agent, call Anthropic, verify audit.
7. **Verify operator credential still works** — operators.yaml shape
   is forward-compat from M9.
8. **Keep old image around for rollback** for 24-72h, then prune.

## Coordinating with site repos

Multiple site repos (e.g., one per host) consume the same
layer8-proxy bundle. Recommended cadence:

- Tag the new layer8-proxy version.
- Update one site repo's `site.cfg` + `.env`, deploy, smoke.
- After that's stable for 24–72h, roll the rest.

This catches any site-specific surprises (custom override files,
non-default mounts, etc.) before all production hosts are on the
new version.

## Rollback recipe

If a post-upgrade smoke fails:

```bash
# 1. Stop.
docker compose ... down

# 2. Revert site.cfg + .env to the prior versions.
git -C my-site checkout -- site.cfg .env

# 3. Revert layer8-proxy checkout.
cd $LAYER8_PATH && git checkout v1.0.0

# 4. Redeploy.
cd ../my-site && ./deploy.sh
```

If the DB schema migrated forward (typical for a major release),
you'll also need to restore the pre-upgrade DB volume from backup.

## See also

- [deploy.md](deploy.md) — depth on the deploy procedure.
- [backup-and-restore.md](backup-and-restore.md) — pre-upgrade
  snapshots.
- [troubleshoot.md](troubleshoot.md) — post-upgrade failure modes.
