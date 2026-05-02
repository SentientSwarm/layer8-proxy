# syntax=docker/dockerfile:1.7
ARG LOCKSMITH_VERSION=v1.1.0

FROM rust:1.83-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

ARG LOCKSMITH_VERSION
WORKDIR /src
RUN git clone --depth 1 --branch "${LOCKSMITH_VERSION}" \
        https://github.com/SentientSwarm/agent-locksmith.git . \
 && cargo build --release --locked

FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10200 locksmith \
 && useradd --system --uid 10200 --gid locksmith --shell /usr/sbin/nologin locksmith \
 && mkdir -p /var/lib/locksmith /etc/locksmith /var/log/locksmith \
 && chown locksmith:locksmith /var/lib/locksmith /etc/locksmith /var/log/locksmith

COPY --from=builder /src/target/release/locksmithd /usr/local/bin/locksmithd
COPY --from=builder /src/target/release/locksmith  /usr/local/bin/locksmith

USER locksmith
EXPOSE 9200
WORKDIR /var/lib/locksmith

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/locksmith", "status"] || exit 1

CMD ["/usr/local/bin/locksmithd", "--config", "/etc/locksmith/config.yaml"]
