# Routing hermes-agent through layer8-proxy

Hermes routes outbound HTTP via locksmith using its native multi-provider
config. ADR-01 in the design spec — this is configuration convention, not
network enforcement.

## Provider config (hermes.config.yaml)

```yaml
providers:
  anthropic:
    base_url: http://127.0.0.1:9200/api/anthropic
    api_key: not-required
  openai:
    base_url: http://127.0.0.1:9200/api/openai
    api_key: not-required
  lmstudio:
    base_url: http://127.0.0.1:9200/api/lmstudio
    api_key: not-required
```

`api_key: not-required` — locksmith strips agent-sent auth and injects
the real credential from its sealed-secret backend.

## In-process scanning (AlignmentCheck)

Hermes calls the llamafirewall library directly at planning checkpoints.
The teacher LLM call (e.g., Qwen3.5-35B-A3B via LM Studio) flows through
locksmith like any other inference request — recursive but legitimate;
the judge call is also credentialed, audited, egress-controlled.

```yaml
scanners:
  alignment_check:
    enabled: true
    teacher: qwen3.5-35b-a3b
    teacher_provider: lmstudio
    invoke_at: [pre_tool_call, post_tool_result]
  prompt_guard:
    enabled: false   # owned by network-boundary plane (lf-scan today, M8 tomorrow)
  code_shield:
    enabled: false   # same reasoning
```

See `agents-stack/docs/specs/2026-05-01-layer8-proxy-design.md` §Hermes
routing config for the full schema.
