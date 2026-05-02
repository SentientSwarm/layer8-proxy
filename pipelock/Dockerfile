# syntax=docker/dockerfile:1.7
#
# Pipelock is third-party software (Joshua Waldrep, Apache 2.0).
# Releases at https://github.com/luckyPipewrench/pipelock/releases.
# Artifact naming: pipelock_<VERSION>_linux_{amd64,arm64}.tar.gz
#
# TARGETARCH is auto-set by BuildKit/Buildah from the build platform
# (amd64 on x86_64, arm64 on Apple Silicon).
ARG PIPELOCK_VERSION=2.3.0

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10300 pipelock \
 && useradd --system --uid 10300 --gid pipelock --shell /usr/sbin/nologin pipelock \
 && mkdir -p /etc/pipelock /var/log/pipelock \
 && chown pipelock:pipelock /etc/pipelock /var/log/pipelock

ARG PIPELOCK_VERSION
ARG TARGETARCH
RUN URL="https://github.com/luckyPipewrench/pipelock/releases/download/v${PIPELOCK_VERSION}/pipelock_${PIPELOCK_VERSION}_linux_${TARGETARCH}.tar.gz" \
 && echo "Downloading $URL" \
 && curl -fsSL "$URL" -o /tmp/pipelock.tar.gz \
 && tar -xzf /tmp/pipelock.tar.gz -C /usr/local/bin pipelock \
 && chmod 0755 /usr/local/bin/pipelock \
 && rm /tmp/pipelock.tar.gz

USER pipelock
EXPOSE 8888

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/pipelock", "healthcheck"]

CMD ["/usr/local/bin/pipelock", "run", "--config", "/etc/pipelock/pipelock.yaml"]
