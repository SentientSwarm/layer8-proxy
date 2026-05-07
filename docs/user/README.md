# layer8-proxy — user documentation

Operator-facing documentation for deploying and running the
**layer8-proxy** stack (locksmith + pipelock + lf-scan + compose
orchestration).

Content is **evergreen** (reflects the latest-shipped state) and
**not versioned by filename**. Versioned material — PRD, technical
spec — lives in `agents-stack/docs/{prd,spec}/`. This tree distills
that material into what operators need to *deploy and run* the product.

## Audience

**Operators** running a layer8-proxy stack on one or more hosts.

## Tier 1 — get up and running

Read these first if you've never deployed layer8-proxy:

| Doc | What it covers |
|---|---|
| [getting-started.md](getting-started.md) | 11-step recipe from `git clone` to verified Anthropic call. |
| [add-an-agent.md](add-an-agent.md) | Register an agent + distribute its bearer + ACL semantics. |
| [add-a-tool.md](add-a-tool.md) | Seed catalog override + custom tool registration + OAuth bootstrap. |
| [troubleshoot.md](troubleshoot.md) | Top 12 failure modes with diagnosis recipes. |

## Tier 2 — depth + day-2 ops

| Doc | What it covers |
|---|---|
| [deploy.md](deploy.md) | Depth companion to getting-started: topologies, image pinning, sealed creds (Linux + macOS), mTLS rollout, custom site overrides, two-tier audit storage, production checklist. |
| [rotate-credentials.md](rotate-credentials.md) | Provider keys, agent bearers, operator bearer, OAuth refresh tokens, sealing-key rotation, internal infra tokens, restic password. |
| [upgrade.md](upgrade.md) | Patch / minor / major release flows, downgrade caveats, cross-bundle v0.x → v1.0 upgrade, rollback recipe. |
| [backup-and-restore.md](backup-and-restore.md) | restic-based snapshots, JSONL audit mirror, restore drill, snapshot integrity checks. |
| [smoke-test.md](smoke-test.md) | `verify.sh` deep dive, auth-enforcement env vars, manual probes (discovery, real provider call, ACL deny, audit), continuous verification cron. |

## Tier 3 — concepts + architecture

| Doc | What it covers |
|---|---|
| [architecture.md](architecture.md) | Stack-level component diagram (locksmith + pipelock + lf-scan), wire-flow walkthrough, trust boundary table. |
| [concepts/topology.md](concepts/topology.md) | Same-host vs neutral-host vs LAN-spread deployment shapes and migration paths. |

For cross-cutting concepts that span the stack (trust boundary, kind
taxonomy, agent identity + ACL, error envelope), see
[`agent-locksmith/docs/user/concepts/`](https://github.com/SentientSwarm/agent-locksmith/tree/develop/docs/user/concepts).

## Site repo template

Looking for the operator-host site repo shape? See
[`../../examples/site/README.md`](../../examples/site/README.md) and
the `init-site.sh` generator at
[`../../scripts/init-site.sh`](../../scripts/init-site.sh).
