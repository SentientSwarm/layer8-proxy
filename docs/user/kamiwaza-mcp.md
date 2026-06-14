# Kamiwaza MCP tools through locksmith

Make Kamiwaza-hosted MCP tools reachable by your agents **through locksmith**, so
the calls inherit per-agent ACL, audit, egress (pipelock), and response controls —
the same plane every other tool gets. No locksmith code is involved: a Kamiwaza MCP
tool is an ordinary `kind=tool` catalog registration, created and refreshed by a
small **registrar** that runs off the request hot path.

```
MCP-client agent ──bearer──▶ locksmith /api/kamiwaza-<tool>/ ──PAT──▶ Kamiwaza MCP endpoint
                              (auth → ACL → inject PAT → stream → audit)

           registrar (cron) ──discovers──▶ Kamiwaza /tool/deployments + /extensions
                            ──registers──▶ locksmith catalog (kind=tool, provider=kamiwaza)
```

## Why this shape

MCP-over-HTTP is just JSON-RPC over HTTP POST, and Kamiwaza MCP endpoints accept the
**same Kamiwaza bearer** the discovery API uses (`KAMIWAZA_USE_AUTH=true`). So a
Kamiwaza MCP tool registered as a normal catalog entry —

- `upstream` = the tool's MCP endpoint URL
- `auth` = `bearer=KAMIWAZA_MCP_PAT` (locksmith injects it)
- `egress` = `direct` (LAN Kamiwaza) or `proxied` (+ a pipelock allowlist entry)

— is proxied transparently by locksmith's existing hot path. An MCP-client agent
(e.g. hermes) speaks MCP straight through `/api/kamiwaza-<tool>/`; locksmith strips the
agent's auth, injects the PAT, and forwards. `Mcp-Session-Id` and `text/event-stream`
round-trip through the proxy, so MCP session continuity and streaming work unchanged.

The **only** Kamiwaza-specific component is discovery — turning the live MCP servers
into registrations. That lives in the registrar (cron-driven), so the discovery cost
and its outbound-trust surface never touch agent traffic.

> This supersedes the original in-core approach (agent-locksmith PR #89), which put a
> Kamiwaza-specific provider on locksmith's hot path and re-implemented (and partly
> skipped) the audit/egress/size-cap machinery. As registrations, Kamiwaza tools get
> all of it for free, and locksmith stays vendor-neutral. The in-core path only made
> sense for *non-MCP* agents calling MCP tools as plain REST (a translation layer we
> deliberately did not adopt — our agents are MCP clients).

## Prerequisites

1. **A Kamiwaza PAT** for locksmith. Mint a durable one (admin scope, up to 1 year):

   ```bash
   # Authenticate (form body), then create a PAT.
   TOKEN=$(curl -sk https://<kamiwaza-host>/api/auth/token \
       -d "username=<user>&password=<pass>" | jq -r .access_token)
   curl -sk https://<kamiwaza-host>/api/auth/pats -H "Authorization: Bearer $TOKEN" \
       -H 'Content-Type: application/json' \
       -d '{"name":"agent-locksmith-mcp","ttl_seconds":31536000,"scope":"admin","aud":"kamiwaza-platform"}' \
       | jq -r .token
   # The token is shown ONCE — store it immediately.
   ```

2. **The PAT in locksmith's container env.** Registrations reference
   `--auth bearer=KAMIWAZA_MCP_PAT`, and locksmith resolves env vars from its own
   process environment at registration time. Put the PAT in the site `.env` and forward
   it by name in `docker-compose.override.yml`'s locksmith `environment:` list, then
   **recreate locksmith before the first registrar run** (same pattern as the other
   injected bearers):

   ```yaml
   # docker-compose.override.yml → services.locksmith.environment
   KAMIWAZA_MCP_PAT: ${KAMIWAZA_MCP_PAT:-}
   ```

3. **Trust Kamiwaza's CA in locksmith** (HTTPS upstream behind a private CA).
   Kamiwaza serves its MCP endpoints over HTTPS with an internal CA (e.g. "Kamiwaza
   Application Intermediate CA"). locksmith's HTTP client uses rustls + webpki bundled
   roots, which ignore the system store, so it will not verify that cert unless the CA
   is named explicitly. Mount the Kamiwaza CA bundle into the locksmith container and
   point `tls.upstream_ca_bundle` at it (agent-locksmith ≥ v2.7.0):

   ```yaml
   # locksmith config.yaml
   tls:
     upstream_ca_bundle: "/etc/locksmith/ca/kamiwaza-ca.pem"
   ```

   The bundle needs the cert(s) that anchor the chain — trusting the intermediate is
   enough to verify the endpoint. Extract it with:
   `echo | openssl s_client -connect <kamiwaza-host>:443 -servername <kamiwaza-host> -showcerts | awk '/BEGIN CERT/,/END CERT/'`
   (keep the intermediate / root, drop the leaf). Verification is never disabled.

## Run the registrar

```bash
KAMIWAZA_API_URL=https://<kamiwaza-host> \
KAMIWAZA_MCP_PAT=<pat> \
LOCKSMITH_OP_TOKEN=$(./scripts/decrypt-creds.sh locksmith/secrets/operator_token.creds) \
  ./scripts/kamiwaza-mcp-registrar.py --dry-run    # preview first
```

Drop `--dry-run` to apply. Each pass:

- discovers live MCP tools from `/api/tool/deployments` (Tool Shed) and `/api/extensions`,
- resolves each tool's external MCP URL and its per-tool MCP path (see below),
- creates/updates a `kamiwaza-<slug>` registration (`metadata: provider=kamiwaza`),
- **removes** registrations whose tool is no longer running.

It's idempotent — schedule it via cron (e.g. every minute or two) so the catalog
tracks Kamiwaza's live tool set.

### Configuration (env)

| Var | Default | Meaning |
|---|---|---|
| `KAMIWAZA_API_URL` | — (required) | Kamiwaza base URL |
| `KAMIWAZA_MCP_PAT` | — (required) | discovery bearer; **also** set in locksmith's env |
| `KAMIWAZA_PAT_ENV` | `KAMIWAZA_MCP_PAT` | env-var NAME locksmith injects as the upstream bearer |
| `KAMIWAZA_EGRESS` | `direct` | `direct` (LAN) or `proxied` (+ pipelock allowlist) |
| `KAMIWAZA_TIMEOUT_REQUEST` | `600` | per-registration total-stream timeout (MCP calls can be long) |
| `KAMIWAZA_MCP_PATH` | `/mcp` | fallback MCP sub-path |
| `KAMIWAZA_MCP_PATH_<SLUG>` | — | per-tool MCP-path override |
| `KAMIWAZA_VERIFY_TLS` | `true` | discovery TLS verification (disable only for dev self-signed) |

### Per-tool MCP path

The registrar resolves each tool's MCP sub-path: explicit `MCP_PATH` (deployment env,
then template `env_defaults`) wins; otherwise it defaults to `/mcp`. Confirmed live
against `kamiwaza-dde` — even with `strip_path_prefix: true` and no `MCP_PATH`, the MCP
server mounts at `/mcp` (root 404s), so `/mcp` is the right default. Use
`KAMIWAZA_MCP_PATH_<SLUG>` to override a specific tool that genuinely differs.

## Agent-facing URL

The registration's **upstream is the tool's base runtime URL** (no MCP path), because
locksmith's `/api/{tool}/{*path}` route requires a path segment. The agent's MCP client
points at:

```
${layer8_endpoint}/api/kamiwaza-<slug><mcp_path>     # e.g. .../api/kamiwaza-dde/mcp
```

locksmith forwards `<mcp_path>` onto the base upstream and injects the PAT. The resolved
`<mcp_path>` is stored on the registration as `metadata.mcp_path` (default `/mcp`).

## Verify

```bash
# The discovered tools appear as catalog registrations:
docker exec layer8-locksmith locksmith tool list | grep kamiwaza-

# An MCP-client agent allowlisted to the tool reaches it through locksmith at
#   ${layer8_endpoint}/api/kamiwaza-<slug>/mcp
# initialize → tools/list → tools/call round-trip, PAT injected, audited.
```

Audit rows for Kamiwaza tool calls carry `tool: kamiwaza-<slug>` and the calling
agent's identity, like any other registration.

> **Validated live (2026-06-13)** against the running `kamiwaza-dde` tool: an MCP
> `initialize → notifications/initialized → tools/list` round-trip through a locksmith
> built with the `tls.upstream_ca_bundle` feature succeeded — TLS verified against the
> Kamiwaza private CA, the PAT was injected (dummy client bearer stripped), the
> `Mcp-Session-Id` round-tripped, and all 36 DDE tools were returned.

## Notes / current limits

- **MCP-client agents only.** Agents call these tools by speaking MCP through
  locksmith. Non-MCP agents would need a translation layer (not provided here).
- **Tool images must actually expose MCP.** Some Kamiwaza tool images are MCP-tagged
  but REST-only (omniparse 2.2.0); `kamiwaza-dde` is genuinely MCP-native. The registrar
  registers whatever is live and reachable — confirm a new tool's `upstream` resolves
  to a working MCP endpoint after first registration.
- **Egress.** For a LAN Kamiwaza, `direct` matches the `lmstudio` precedent. For an
  internet-reachable Kamiwaza, use `proxied` and add the host to pipelock's allowlist.
