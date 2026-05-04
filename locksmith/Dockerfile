# syntax=docker/dockerfile:1.7
ARG LOCKSMITH_VERSION=v1.1.0

# 1.85+ required: agent-locksmith uses edition 2024.
# Pin to bookworm explicitly so glibc matches the runtime stage below.
FROM rust:1.90-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

ARG LOCKSMITH_VERSION
WORKDIR /src
RUN git clone --depth 1 --branch "${LOCKSMITH_VERSION}" \
        https://github.com/SentientSwarm/agent-locksmith.git . \
 && cargo build --release --locked

FROM debian:bookworm-slim AS runtime

# `curl` is needed for the unauthenticated /livez HEALTHCHECK below.
# `locksmith status` is NOT a daemon health probe — it's the agent
# self-service "ask the daemon about my agent's state" command and
# requires LOCKSMITH_AGENT_TOKEN, which the daemon container never
# carries. Probing /livez is the contract per INF-3.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10200 locksmith \
 && useradd --system --uid 10200 --gid locksmith --shell /usr/sbin/nologin locksmith \
 && mkdir -p /var/lib/locksmith /etc/locksmith /var/log/locksmith /var/run/locksmith \
 && chown locksmith:locksmith /var/lib/locksmith /etc/locksmith /var/log/locksmith /var/run/locksmith

COPY --from=builder /src/target/release/locksmithd /usr/local/bin/locksmithd
COPY --from=builder /src/target/release/locksmith  /usr/local/bin/locksmith

USER locksmith
EXPOSE 9200
WORKDIR /var/lib/locksmith

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -fsS --max-time 2 http://127.0.0.1:9200/livez || exit 1

CMD ["/usr/local/bin/locksmithd", "--config", "/etc/locksmith/config.yaml"]
