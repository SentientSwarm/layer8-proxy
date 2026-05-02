# D-18 Reframe: LlamaFirewall as Library

`agent-locksmith` PRD decision **D-18** rejects the
"cognitive-scanner-on-the-wire anti-pattern" — running a foreign
vendor-shipped HTTP service that duplicates locksmith's identity,
credential, and audit responsibilities. The rejection is correct *for that
pattern*.

Empirical findings during the layer8-proxy design:

1. **Upstream LlamaFirewall (Meta / PurpleLlama) is a Python library**, not
   a service. `pip install llamafirewall` provides
   `LlamaFirewall(scanners={...}).scan(messages)` and nothing more.
2. **The HTTP wrapper that lives in `openclaw-hardened` is our own code**
   (commit `b9978b2`, ~250 LoC FastAPI in
   `roles/llamafirewall/templates/llamafirewall_proxy.py.j2`). The
   credential-injection, multi-provider routing, budget tracking, and
   pipelock egress logic are duties the wrapper acquired *because openclaw
   was Node.js and didn't go through locksmith*.

The D-18 anti-pattern describes a peer system whose responsibilities
overlap locksmith's. LlamaFirewall, properly understood, is a library
whose HTTP shape was a workaround. The two compose differently: a library
can be embedded in locksmith (M8) without reproducing the identity /
credential / audit duplications D-18 was right to reject.

For pipelock, D-18 *does* apply. Pipelock is third-party software with its
own configuration system, hot-reload, DLP patterns, URL scanner, and
tool-chain detection. We compose with it as a peer — we do not absorb it.

**Corrected one-line summary:** D-18 is right about pipelock and wrong
about LlamaFirewall — and v2 (M8) gets to act on the correction.
