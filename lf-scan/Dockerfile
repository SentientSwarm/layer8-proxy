# syntax=docker/dockerfile:1.7
FROM python:3.11-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /opt/lf-scan

COPY pyproject.toml ./
RUN pip install --prefix=/install .

FROM python:3.11-slim AS runtime

RUN groupadd --system --gid 10100 lfscan \
 && useradd --system --uid 10100 --gid lfscan --shell /usr/sbin/nologin lfscan

ENV PYTHONUNBUFFERED=1

COPY --from=builder /install /usr/local
COPY app.py /opt/lf-scan/app.py

WORKDIR /opt/lf-scan
USER lfscan
EXPOSE 9100

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9100/health').read()" || exit 1

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9100"]
