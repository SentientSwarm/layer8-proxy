# syntax=docker/dockerfile:1.7
ARG LOCKSMITH_VERSION=v2.0.0

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

# Stage the seed catalog so the runtime COPY succeeds for both v2.0.0+
# (catalog present) and pre-v2.0.0 (file absent → empty staging dir).
# Without this stage, runtime COPY would hard-fail on tags that don't
# yet ship the seed catalog file.
FROM builder AS seed-extractor
RUN mkdir -p /seed-out \
 && if [ -f /src/seed/catalog.yaml ]; then \
        cp /src/seed/catalog.yaml /seed-out/catalog.yaml; \
    fi

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
 && mkdir -p /var/lib/locksmith /etc/locksmith /etc/locksmith/seed \
        /var/log/locksmith /var/run/locksmith \
 && chown locksmith:locksmith /var/lib/locksmith /etc/locksmith /etc/locksmith/seed \
        /var/log/locksmith /var/run/locksmith

COPY --from=builder /src/target/release/locksmithd /usr/local/bin/locksmithd
COPY --from=builder /src/target/release/locksmith  /usr/local/bin/locksmith
# Phase E.7 / v2.0.0+: ship the curated seed catalog. First-boot loads
# it into the registrations table; operators provide credentials via
# .env and override fields via the admin API. Catalog version is
# tracked in registrations_meta.seed_version, so image upgrades that
# bump the version apply additive changes idempotently without
# clobbering operator overrides. The seed-extractor stage above stages
# either the real catalog (v2.0.0+) or an empty directory (pre-v2.0.0,
# where the seed loader gracefully skips with an INFO log).
COPY --from=seed-extractor /seed-out/ /etc/locksmith/seed/

USER locksmith
EXPOSE 9200
WORKDIR /var/lib/locksmith

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -fsS --max-time 2 http://127.0.0.1:9200/livez || exit 1

CMD ["/usr/local/bin/locksmithd", "--config", "/etc/locksmith/config.yaml"]
