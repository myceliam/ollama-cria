# ==============================================================================
# Stage 1 — Builder
# ==============================================================================
FROM python:3.12-slim AS builder

WORKDIR /build

# Install dependencies into a virtual environment
COPY requirements.txt .
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# ==============================================================================
# Stage 2 — Runtime
# ==============================================================================
FROM python:3.12-slim AS runtime

# Create a non-root user to run the app
RUN groupadd --system appuser && \
    useradd --system --no-create-home --gid appuser appuser

# Copy the virtual environment from the builder stage
COPY --from=builder /opt/venv /opt/venv

# Set PATH so that python/uvicorn from the venv are used by default
ENV PATH="/opt/venv/bin:$PATH"

# Application code
WORKDIR /app
COPY main.py monitor.py database.py ./
COPY static/ ./static/

# Create the data directory for SQLite and give appuser write access
RUN mkdir -p /app/data && chown appuser:appuser /app/data

# Install the Tailscale CLI so we can query the local daemon via
#   tailscale --socket /var/run/tailscale/tailscaled.sock status --json
# Also install iputils-ping: python:3.12-slim does NOT ship a ping binary,
# and without it every latency probe silently returns None.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates iputils-ping && \
    curl -fsSL https://tailscale.com/install.sh | sh && \
    apt-get remove -y curl && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Switch to the unprivileged user
USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/status')" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]