# layer8-proxy — user documentation

Operator-facing documentation for deploying and running the **layer8-proxy** stack (locksmith + pipelock + lf-scan + compose orchestration).

Content is **evergreen** (reflects the latest-shipped state) and **not versioned by filename**. Versioned material — PRD, technical spec — lives in `agents-stack/docs/{prd,spec}/`. This tree distills that material into what operators need to *deploy and run* the product.

## Audience

**Operators** running a layer8-proxy stack on one or more hosts.

## Layout

- `getting-started.md` — the 5-minute deploy.
- `deploy.md` — full deploy procedure, including site-repo bootstrap.
- `add-an-agent.md` — register an agent + distribute its bearer token.
- `add-a-tool.md` — override or disable a seed catalog entry; register a custom tool.
- `rotate-credentials.md` — provider keys, agent bearers, operator credentials.
- `upgrade.md` — version-pinning + cutover recipe.
- `backup-and-restore.md` — locksmith state, hermes state.
- `smoke-test.md` — `verify.sh` invocation + manual probes.
- `troubleshoot.md` — common failure modes and fixes.
- `architecture.md` — user-level system overview.
- `concepts/topology.md` — same-host vs neutral-host vs LAN.
