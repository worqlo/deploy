# =============================================================================
# Worqlo Backend - Multi-stage Dockerfile
# =============================================================================
# Stage 1: Build dependencies
# Stage 2: Production runtime
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Builder
# -----------------------------------------------------------------------------
FROM python:3.12-slim AS builder

# Security & Supply Chain Labels (OCI/SBOM)
LABEL org.opencontainers.image.title="Worqlo Backend"
LABEL org.opencontainers.image.description="FastAPI + LangGraph AI Agent Backend"
LABEL org.opencontainers.image.vendor="Worqlo"
LABEL org.opencontainers.image.version="1.0"
LABEL org.opencontainers.image.created="2026-01-14"
LABEL org.opencontainers.image.source="https://github.com/worqlo/backend"
LABEL org.opencontainers.image.documentation="https://github.com/worqlo/backend#readme"
LABEL org.opencontainers.image.base.name="python:3.12-slim"

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install Python dependencies
WORKDIR /build

# Copy dependency files first for better caching
COPY pyproject.toml ./

# Install dependencies (production only)
RUN pip install --no-cache-dir --upgrade pip setuptools wheel && \
    pip install --no-cache-dir .

# -----------------------------------------------------------------------------
# Stage 2: Production Runtime
# -----------------------------------------------------------------------------
FROM python:3.12-slim AS production

# Security & Supply Chain Labels
LABEL org.opencontainers.image.title="Worqlo Backend"
LABEL org.opencontainers.image.description="FastAPI + LangGraph AI Agent Backend"
LABEL org.opencontainers.image.vendor="Worqlo"
LABEL org.opencontainers.image.version="1.0"
LABEL org.opencontainers.image.created="2026-01-14"
LABEL org.opencontainers.image.source="https://github.com/worqlo/backend"
LABEL org.opencontainers.image.documentation="https://github.com/worqlo/backend#readme"
LABEL org.opencontainers.image.base.name="python:3.12-slim"
LABEL org.opencontainers.image.authors="Worqlo Team"
LABEL org.opencontainers.image.url="https://worqlo.com"
LABEL org.opencontainers.image.licenses="MIT"

# Install runtime dependencies only (fonts-dejavu-core for PDF Unicode rendering)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    postgresql-client \
    curl \
    fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create non-root user for security
RUN groupadd --gid 1000 worqlo && \
    useradd --uid 1000 --gid worqlo --shell /bin/bash --create-home worqlo

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Set working directory
WORKDIR /app

# Copy application code (connectors are app.connectors under app/)
COPY --chown=worqlo:worqlo app/ ./app/
# Third-party license attribution (generated in CI; placeholder for local builds)
COPY --chown=worqlo:worqlo deploy/THIRD_PARTY_LICENSES.md ./
COPY --chown=worqlo:worqlo migrations/ ./migrations/
# Seed script required for startup (creates admin/user roles)
COPY --chown=worqlo:worqlo deploy/scripts/seed.py ./deploy/scripts/seed.py
COPY --chown=worqlo:worqlo deploy/entrypoint.sh ./entrypoint.sh
COPY --chown=worqlo:worqlo alembic.ini ./
COPY --chown=worqlo:worqlo pyproject.toml ./

# Create directories for uploads, logs, and Harmony/tiktoken vocab cache
RUN mkdir -p /app/uploads/knowledge_base /app/logs /app/backups /app/.cache/tiktoken_rs

# Optional: copy host-pre-downloaded Harmony vocab (run deploy/scripts/download_harmony_vocab.sh from repo root first)
COPY --chown=worqlo:worqlo deploy/vocab_cache/ /app/.cache/tiktoken_rs/

RUN chown -R worqlo:worqlo /app && chmod +x /app/entrypoint.sh

# Harmony encoding vocab cache (runtime uses same path; vocab is already in image)
ENV TIKTOKEN_RS_CACHE_DIR=/app/.cache/tiktoken_rs

# Environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=/app

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Switch to non-root user
USER worqlo

# Expose port
EXPOSE 8000

# Entrypoint runs migrations and seeds before starting
ENTRYPOINT ["/app/entrypoint.sh"]

# Default command (can be overridden in docker-compose)
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

