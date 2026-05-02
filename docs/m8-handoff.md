# M8 Handoff: What Changes When Locksmith Ships Inline Scanners

When `agent-locksmith` lands milestone M8 — inline scanners in Rust —
the `lf-scan` sidecar in this repo becomes redundant.

## What gets removed

- `lf-scan/` directory (Dockerfile, Python source, tests).
- The `lf-scan` service entry in `docker-compose.yml`.
- The `LF_SCAN_INTERNAL_TOKEN` env var in `.env.example`.

## What changes in site repos

- Remove the `lf-scan.yaml` tool entry from `<site>/tools/`.
- Remove the `lf_scan_token` secret from `<site>/locksmith/secrets/`.
- Add a `scanners:` block to the locksmith config with per-tool
  `prompt_guard` / `code_shield` / `regex` configuration.

## What stays the same

- Hermes routing config — agents still call `/api/<provider>/...`. They
  never knew about lf-scan; the migration is invisible to them.
- AlignmentCheck stays in the agent process. M8 covers network-boundary
  scanning only.
- Pipelock stays as-is.

## Migration trigger

Bump `LOCKSMITH_VERSION` in `.env.example` to the M8 release tag, run
`bootstrap.sh`, redeploy. Operators inspect the rendered locksmith
config and remove the now-redundant lf-scan tool entry.

The M8 design proposal will live at
`agent-locksmith/docs/v2/inline-scanners.md` once drafted.
