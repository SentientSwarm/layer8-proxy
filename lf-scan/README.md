# lf-scan

Thin FastAPI sidecar that exposes Meta's
[llamafirewall](https://github.com/meta-llama/PurpleLlama/tree/main/LlamaFirewall)
library as an HTTP tool. Registered in locksmith as an ordinary tool entry
(D-18 corollary).

**Status:** transitional. Removed in agent-locksmith M8 once inline scanners ship.

## API

- `POST /scan/input` — scan agent-bound input messages
- `POST /scan/output` — scan model-bound output messages
- `GET /health` — readiness, scanner inventory

All `/scan/*` endpoints require `X-Internal-Token` (injected by locksmith).

## Local development

```bash
uv sync --extra dev
uv run pytest
uv run uvicorn app:app --reload
```
