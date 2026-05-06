# Concepts (operator)

User-level mental models for operating a layer8-proxy stack. Distilled from the stack technical spec at `agents-stack/docs/spec/v<X.Y.Z>.md`.

Cross-cutting concepts that span the stack (trust boundary, kind taxonomy, agent identity + ACL, error envelope) live in `agent-locksmith/docs/user/concepts/` since locksmith is the keystone enforcing them. This directory holds operator-facing concepts specific to deployment topology and stack composition.

Planned pages:

- `topology.md` — same-host, neutral-host, LAN-spread deployment shapes; tradeoffs and when to use each.
