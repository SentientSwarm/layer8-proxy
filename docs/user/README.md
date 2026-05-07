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

## Tier 2 — depth + day-2 ops (in progress)

| Doc | Status |
|---|---|
| `deploy.md` | Planned — depth companion to getting-started (multi-host, mTLS, sealed creds). |
| `rotate-credentials.md` | Planned — provider keys, agent bearers, operator creds, OAuth refresh tokens. |
| `upgrade.md` | Planned — version-pin bumps, migration story across breaking changes. |
| `backup-and-restore.md` | Planned — locksmith DB + sealed creds + JSONL audit mirror. |
| `smoke-test.md` | Planned — verify.sh deep dive + manual probe recipes. |

## Tier 3 — concepts + architecture (in progress)

| Doc | Status |
|---|---|
| `architecture.md` | Planned — user-level system diagram + component responsibilities. |
| `concepts/topology.md` | Planned — same-host vs neutral-host vs LAN deployment shapes. |

For cross-cutting concepts that span the stack (trust boundary, kind
taxonomy, agent identity + ACL, error envelope), see
[`agent-locksmith/docs/user/concepts/`](https://github.com/SentientSwarm/agent-locksmith/tree/develop/docs/user/concepts).

## Site repo template

Looking for the operator-host site repo shape? See
[`../../examples/site/README.md`](../../examples/site/README.md) and
the `init-site.sh` generator at
[`../../scripts/init-site.sh`](../../scripts/init-site.sh).
