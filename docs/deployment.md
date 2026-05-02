# Deployment

## Prerequisites

- Container runtime: Docker Engine 24+ / Docker Desktop on macOS / Podman 5+.
- A site repo (e.g., `hermes-site`) that pins a layer8-proxy version and
  provides per-host configs.
- restic (or equivalent) for offsite encrypted backups, if you intend to
  run the bundled `backup.sh` cron.

## One-time setup

1. Clone `agents-stack` and run `uv run clone-repos.py` to pull
   `layer8-proxy`, your site repo, and the upstream agents you intend to
   deploy.
2. Pin `layer8-proxy` version in your site repo's `site.cfg` (e.g.,
   `layer8_version=v0.1.0`).
3. Provision secrets in the site repo via its `secrets.bootstrap.sh`.
4. Edit canonical tool definitions in `<site>/tools/*.yaml`.
5. Run `<site>/deploy.sh` — renders configs, validates alignment, brings
   up the compose project.

## macOS Docker Desktop notes

- `host.docker.internal` is the standard mechanism for reaching host
  services. The compose file maps it to `host-gateway` in `extra_hosts`,
  so it also resolves on Podman and Linux Docker.
- Performance for SQLite-backed components (locksmith audit, hermes
  memory) is meaningfully better when their state lives on a Docker
  named volume rather than a bind-mounted host path.
- Locksmith and pipelock bind to `127.0.0.1` only, consistent with
  single-operator-per-host expectations.

## Using Podman instead of Docker

Layer8-proxy is runtime-agnostic. To use Podman:

```bash
export COMPOSE="podman compose"
export CONTAINER=podman
./scripts/bootstrap.sh
${COMPOSE} up -d
```

The compose file's `extra_hosts: ["host.docker.internal:host-gateway"]`
makes `host.docker.internal` resolve identically on Docker and Podman.

**On macOS, Podman 5.x with the `applehv` provider has known boot
issues on macOS 26 ("Tahoe").** If `podman machine start` hangs with no
serial output, use the `libkrun` provider instead (`brew install krunkit`,
then `CONTAINERS_MACHINE_PROVIDER=libkrun podman machine init`). Docker
Desktop is the more reliable path on macOS 26 right now.

## Updating

- Edit `site.cfg` to bump `layer8_version`.
- Re-run `<site>/deploy.sh`. Docker Compose will rebuild affected
  services; volume data persists.
