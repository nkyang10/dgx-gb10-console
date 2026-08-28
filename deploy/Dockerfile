# Multi-arch Dockerfile for the DGX Spark status exporter.
# DGX OS is Ubuntu 24.04 arm64. We use the official python slim image pinned to
# the same codebase (noble = Ubuntu 24.04) so libc/glibc match the host.
# Runtime is designed to be run with `--network host` + host /proc,/sys mounts
# (see compose file) because this service reads HOST-level telemetry.

# Build stage (gives us a pinned wheelhouse for reproducible, offline-ish installs)
FROM python:3.12-slim-noble AS builder
# Remove build warnings noise; keep CA certs for PyPI
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /build
COPY requirements.txt .
# Install into a target dir we can copy wholesale (no system pollute)
RUN python -m pip install --no-cache-dir \
        --target=/wheels \
        -r requirements.txt

# --- Runtime ----------------------------------------------------------------
FROM python:3.12-slim-noble
ENV TZ=Etc/UTC \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Container needs host system tools to report host telemetry. On DGX OS these
# exist on the host but not necessarily in the image; we vendor the cli wrappers
# by bind-mounting host /usr/bin and /usr/sbin read-only (see compose). So the
# image itself stays tiny.
RUN groupadd -r status && useradd -r -g status -d /app status

WORKDIR /app
COPY --from=builder /wheels /usr/local/lib/python3.12/site-packages
COPY app/ ./app/
COPY config.yaml ./config.yaml
COPY requirements.txt .

# NoENN root: run as unprivileged user; all data paths are volumes.
USER status

# Status API + Prometheus /metrics endpoint (same uvicorn process)
EXPOSE 9101
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
    CMD python -c "import urllib.request,sys; \
        sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:9101/health').status==200 else 1)"

# NOTE: CMD is overridden by compose to set --host 0.0.0.0 (required even with network host).
CMD ["/usr/local/bin/python", "-m", "uvicorn", "app.main:app", \
     "--host", "127.0.0.1", "--port", "9101", "--workers", "1"]
