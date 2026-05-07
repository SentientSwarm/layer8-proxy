# layer8-proxy site template

This directory is a **template** for a proxy-operator site repo. It's
the public-shape skeleton of [`layer8-proxy-site`][lps] — copy it out,
rename, fill in your host-specific values, and `git init`.

[lps]: https://github.com/SentientSwarm/layer8-proxy-site

## What a site repo is

The layer8-proxy bundle (`docker-compose.yml` in the parent dir) is
**vendor-neutral**: same image, same compose definition for every
deployment. A site repo holds the per-host operator state that goes
on top of it:

- **Pinned bundle version** in `site.cfg` (`layer8_version=v1.0.0`).
- **Sealed credentials** at rest (`locksmith/secrets/`,
  `locksmith/operators.yaml`).
- **Per-agent ACL manifest** (`agents.yaml`) — declares which agents
  exist and what tools each can call.
- **Site-specific overrides** to the bundle's compose definition
  (`docker-compose.override.yml`) — port bindings, volume paths,
  environment passthrough.
- **Deploy automation** (`deploy.sh`) — wraps render + verify + bring-up.
- **Backup automation** (`backup.sh`, `cron/`).

Public site repos exist (e.g., `layer8-proxy-site` is the SentientSwarm
production site repo, currently private). This template provides the
shape so anyone — open-source consumers, internal teams, contractors —
can bootstrap their own.

## Bootstrap

The fastest path is the init script in the parent layer8-proxy repo:

```bash
cd /path/to/layer8-proxy
./scripts/init-site.sh ../my-site
cd ../my-site
```

That script:
1. Copies this directory to the target.
2. Renames `*.example` → `*` (so `site.cfg.example` becomes `site.cfg`).
3. Runs `git init` so you can track your private operator state.

Or copy manually:

```bash
cp -r layer8-proxy/examples/site/ ../my-site/
cd ../my-site
mv site.cfg.example site.cfg
mv .env.example .env
mv agents.yaml.example agents.yaml
git init
```

## File layout

| Path | Purpose | Edit it? |
|---|---|---|
| `site.cfg` | Site identity + layer8-proxy version pin. | **Yes** — set `site_name`, `host`, confirm `layer8_version`. |
| `.env` | Operator-supplied env vars (provider keys, sealing keys). | **Yes** — never commit. |
| `agents.yaml` | Per-agent ACL manifest. | **Yes** — declare your agents. |
| `agents.test.yaml.example` | Smoke-test agent template. | Optional copy → `agents.test.yaml`. |
| `docker-compose.override.yml` | Site-specific compose overrides. | Adjust port bindings + volume paths. |
| `locksmith/base.yaml` | Daemon config (listen, audit, shutdown). | Adjust if your topology requires non-defaults. |
| `pipelock/pipelock.yaml` | Egress allowlist + DLP rules. | **Yes** — add upstreams your site needs. |
| `deploy.sh` | Render → verify → bring-up. | Don't edit by default. |
| `secrets.bootstrap.sh` | Encrypt a value into `locksmith/secrets/<name>.creds`. | Don't edit. |
| `backup.sh`, `cron/backup.cron` | Daily restic snapshot of locksmith state. | Adjust `BACKUP_DEST`. |
| `scripts/bootstrap-operator.py` | Mints the operator credential at first boot. | Don't edit. |
| `scripts/decrypt-creds.sh` | Sealed-cred → cleartext (used by deploy + backup). | Don't edit. |
| `scripts/register-agents.sh` | Registers agents from `agents.yaml`. | Don't edit. |
| `scripts/render_configs.py` | Renders `tools/*.yaml` (if any) into compose mounts. | Don't edit. |
| `scripts/verify_configs.py` | Pre-deploy validation. | Don't edit. |
| `tools/_defaults.yaml` | Per-tool defaults for legacy custom tools. | Adjust if you author custom tools. |

## Bootstrap-operator alternatives

`scripts/bootstrap-operator.py` is the Python-based path. v2.0.0 of
agent-locksmith ships an equivalent **Rust-native** subcommand:

```bash
docker exec layer8-locksmith /usr/local/bin/locksmith bootstrap-operator \
    --name alice > locksmith/operators.yaml
# Wire token printed to stderr ONCE. Save to your sealed-cred store.
```

Either path produces an `operators.yaml` the daemon consumes at
startup.

## OAuth providers

To enable codex / copilot / anthropic-oauth / google-gemini-cli /
qwen-cli, add a sealing key to your `.env`:

```bash
LOCKSMITH_OAUTH_SEALING_KEY="$(openssl rand -base64 32)"
```

Then bootstrap each provider's session post-deploy (operator obtains
the refresh token via the provider's own OAuth flow):

```bash
docker exec layer8-locksmith /usr/local/bin/locksmith oauth bootstrap codex \
    --refresh-token "<refresh-token-from-providers-flow>"
```

See [`agent-locksmith/docs/adrs/0005-oauth-credentials.md`][adr5] for
the design rationale.

[adr5]: https://github.com/SentientSwarm/agent-locksmith/blob/develop/docs/adrs/0005-oauth-credentials.md

## Adding tools

Most providers (16 at v1.0.0) live in the locksmith image's seed
catalog — no per-tool YAML required. To override a seed default:

```bash
docker exec layer8-locksmith /usr/local/bin/locksmith model put lmstudio \
    --upstream http://mac-server.lan:1234 --auth bearer=LM_STUDIO_API_KEY
```

For tools not in the seed catalog: write `tools/<name>.yaml` (legacy
shape, see `tools/_defaults.yaml` for the schema) — the daemon's
`legacy_bootstrap` shim migrates it into the registrations table on
first boot. OR use the admin API directly:

```bash
docker exec layer8-locksmith /usr/local/bin/locksmith tool put internal-api \
    --upstream https://api.internal.corp \
    --auth header:X-Internal-Key=INTERNAL_KEY
```

## Documentation

- [`agent-locksmith/docs/user/`][lockuser] — concepts (kind taxonomy,
  trust boundary, agent identity + ACL, error envelope) + agent
  integration recipes (hermes, openclaw).
- [`agents-stack/docs/spec/v0.2.0.md`][spec] — formal stack spec.
- [`agents-stack/docs/prd/v0.2.0.md`][prd] — user-facing requirements.

[lockuser]: https://github.com/SentientSwarm/agent-locksmith/tree/develop/docs/user
[spec]: https://github.com/SentientSwarm/agents-stack/blob/main/docs/spec/v0.2.0.md
[prd]: https://github.com/SentientSwarm/agents-stack/blob/main/docs/prd/v0.2.0.md
