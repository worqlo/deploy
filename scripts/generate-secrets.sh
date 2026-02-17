#!/bin/bash
# =============================================================================
# Worqlo Secret Generator
# =============================================================================
# Generates cryptographically secure secrets for .env file
# Usage: ./generate-secrets.sh > .env
# =============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Generate a secure random string
generate_secret() {
    local length=${1:-32}
    openssl rand -base64 $((length * 3 / 4)) | tr -d '/+=' | head -c "$length"
}

# Generate a secure password (alphanumeric + special chars)
generate_password() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -d '/+=' | head -c "$length"
}

# Banner and instructions go to stderr so "> .env" only captures the config
echo -e "${BLUE}=============================================================================${NC}" >&2
echo -e "${BLUE}  Worqlo Secure Configuration Generator${NC}" >&2
echo -e "${BLUE}=============================================================================${NC}" >&2
echo "" >&2
echo -e "${YELLOW}⚠️  SECURITY NOTICE:${NC}" >&2
echo -e "   • Save these secrets in a secure password manager" >&2
echo -e "   • Never commit .env to version control (it's in .gitignore)" >&2
echo -e "   • Use different secrets for each environment (dev/staging/prod)" >&2
echo -e "   • Rotate secrets regularly (every 90 days recommended)" >&2
echo "" >&2
echo -e "${BLUE}=============================================================================${NC}" >&2
echo "" >&2

cat << EOF
# =============================================================================
# Worqlo Self-Hosted Configuration - GENERATED $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================
# ⚠️  SECURITY WARNING: This file contains sensitive secrets
# • Keep this file secure and never commit to version control
# • Use different secrets for each environment
# • Rotate secrets every 90 days
# =============================================================================

# -----------------------------------------------------------------------------
# Security [REQUIRED] - CRYPTOGRAPHICALLY GENERATED
# -----------------------------------------------------------------------------
# JWT secret for authentication (48+ chars recommended)
JWT_WS_SECRET=$(generate_secret 64)

# NextAuth secret for frontend sessions (48+ chars recommended)
NEXTAUTH_SECRET=$(generate_secret 64)

# -----------------------------------------------------------------------------
# Database [REQUIRED] - CRYPTOGRAPHICALLY GENERATED
# -----------------------------------------------------------------------------
POSTGRES_USER=worqlo
POSTGRES_PASSWORD=$(generate_password 32)
POSTGRES_DB=worqlo

# -----------------------------------------------------------------------------
# Redis [REQUIRED] - CRYPTOGRAPHICALLY GENERATED
# -----------------------------------------------------------------------------
# ⚠️  Redis password is now REQUIRED for security
REDIS_PASSWORD=$(generate_password 32)

# -----------------------------------------------------------------------------
# MinIO Object Storage [REQUIRED] - CRYPTOGRAPHICALLY GENERATED
# -----------------------------------------------------------------------------
MINIO_ROOT_USER=worqlo
MINIO_ROOT_PASSWORD=$(generate_password 32)
S3_BUCKET_NAME=worqlo
# Public URL for browser access to MinIO (presigned URLs). Use HTTPS in production.
S3_PUBLIC_ENDPOINT_URL=http://localhost:9000

# -----------------------------------------------------------------------------
# LLM Provider Configuration
# -----------------------------------------------------------------------------
# Options: openai, ollama, grok, sglang
LLM_PROVIDER=sglang

# OpenAI (if LLM_PROVIDER=openai)
# Get your API key from: https://platform.openai.com/api-keys
OPENAI_API_KEY=sk-your-openai-api-key-here
OPENAI_MODEL=gpt-4o-mini

# Grok/xAI (if LLM_PROVIDER=grok)
# Get your API key from: https://console.x.ai/
GROK_API_KEY=xai-your-grok-api-key-here
GROK_MODEL=grok-3-mini

# Ollama (if LLM_PROVIDER=ollama)
# Start with: docker compose --profile ollama up -d
OLLAMA_BASE_URL=http://ollama:11434
OLLAMA_MODEL=llama3.1:8b

# SGLang (if LLM_PROVIDER=sglang) - self-hosted inference
SGLANG_BASE_URL=http://your-sglang-host:30000
SGLANG_MODEL=openai/gpt-oss-120b
# SGLANG_REASONING_EFFORT=medium

# -----------------------------------------------------------------------------
# URLs (adjust for your domain)
# -----------------------------------------------------------------------------
# Client-side API URL (browser → nginx reverse proxy → backend)
# For local development (nginx on port 80 proxies /api and /ws):
NEXT_PUBLIC_API_URL=http://localhost/api
NEXT_PUBLIC_WEBSOCKET_URL=ws://localhost/ws
NEXTAUTH_URL=http://localhost

# For production with domain:
# NEXT_PUBLIC_API_URL=https://yourdomain.com/api
# NEXT_PUBLIC_WEBSOCKET_URL=wss://yourdomain.com/ws
# NEXTAUTH_URL=https://yourdomain.com

# Server-side API URL (Next.js API routes → backend in Docker)
# This is set automatically in docker-compose.yml to http://api:8000/api
# Only override if you need a custom internal network URL
# BACKEND_API_URL=http://custom-backend:8000/api

# -----------------------------------------------------------------------------
# Ports
# -----------------------------------------------------------------------------
HTTP_PORT=80
HTTPS_PORT=443

# -----------------------------------------------------------------------------
# JWT Settings
# -----------------------------------------------------------------------------
JWT_ISSUER=worqlo-self-hosted
JWT_AUDIENCE=worqlo-backend-api
JWT_ALGORITHM=HS256
JWT_ACCESS_TOKEN_EXPIRE_HOURS=24

# -----------------------------------------------------------------------------
# Email (optional - for password reset, notifications)
# -----------------------------------------------------------------------------
# Gmail example (requires App Password if 2FA is enabled):
# EMAIL_SMTP_HOST=smtp.gmail.com
# EMAIL_SMTP_PORT=587
# EMAIL_SMTP_USER=your-email@gmail.com
# EMAIL_SMTP_PASSWORD=your-app-password
# EMAIL_FROM_ADDRESS=your-email@gmail.com
# EMAIL_FROM_NAME=Worqlo
# EMAIL_USE_TLS=true

EMAIL_SMTP_HOST=
EMAIL_SMTP_PORT=587
EMAIL_SMTP_USER=
EMAIL_SMTP_PASSWORD=
EMAIL_FROM_ADDRESS=
EMAIL_FROM_NAME=Worqlo
EMAIL_USE_TLS=true

# -----------------------------------------------------------------------------
# CORS (⚠️  Changed for security - no wildcard by default)
# -----------------------------------------------------------------------------
# Comma-separated list of allowed origins
# For local development:
CORS_ALLOW_ORIGINS=http://localhost,http://localhost:80,http://localhost:3000

# For production (replace with your domain):
# CORS_ALLOW_ORIGINS=https://yourdomain.com,https://app.yourdomain.com

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
# Options: DEBUG, INFO, WARNING, ERROR
LOG_LEVEL=INFO

# -----------------------------------------------------------------------------
# LangSmith Observability (optional)
# -----------------------------------------------------------------------------
LANGSMITH_TRACING=false
LANGSMITH_API_KEY=
LANGSMITH_PROJECT=worqlo-self-hosted

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------
STORAGE_BACKEND=s3
S3_REGION=us-east-1

# -----------------------------------------------------------------------------
# Observability Stack (optional)
# -----------------------------------------------------------------------------
# Grafana admin credentials - CHANGE THESE IN PRODUCTION!
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$(generate_password 16)
GRAFANA_ROOT_URL=http://localhost:3001

EOF

# Send instructions to stderr so "> .env" only captures the config above
echo "" >&2
echo -e "${GREEN}✓ Configuration file generated successfully!${NC}" >&2
echo "" >&2
echo -e "${BLUE}=============================================================================${NC}" >&2
echo -e "${BLUE}  Next Steps:${NC}" >&2
echo -e "${BLUE}=============================================================================${NC}" >&2
echo "" >&2
echo -e "  1. Configuration written to stdout (redirect to .env with: ${GREEN}./generate-secrets.sh > .env${NC})" >&2
echo -e "  2. Add your LLM API key to .env (OPENAI_API_KEY, GROK_API_KEY, or SGLANG_BASE_URL + SGLANG_MODEL)" >&2
echo -e "  3. Update URLs in .env if deploying to a custom domain" >&2
echo -e "  4. (Optional) Configure email settings for notifications" >&2
echo -e "  5. Start services: ${GREEN}docker compose up -d${NC}" >&2
echo "" >&2
echo -e "${YELLOW}⚠️  SECURITY REMINDERS:${NC}" >&2
echo -e "   • Never commit .env to git (already in .gitignore)" >&2
echo -e "   • Backup .env securely (encrypted)" >&2
echo -e "   • Different secrets per environment (dev/staging/prod)" >&2
echo -e "   • Rotate all secrets every 90 days" >&2
echo "" >&2
