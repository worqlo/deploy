# Worqlo Hosted Installer

This document describes how the one-line hosted installer should work for distributing Worqlo self-hosted to customers who deploy from GHCR (no source code access).

---

## Overview

**Goal:** A single command that installs Worqlo using pre-built Docker images from GitHub Container Registry.

```bash
curl -fsSL https://get.worqlo.ai/install.sh | bash
```

**Context:** The backend repository is private. GHCR packages (`worqlo-api`, `worqlo-chat-ui`) are public. Customers need deploy files (docker-compose, nginx, scripts) without cloning the private repo.

**Note:** The existing `install.sh` in this repo builds from source and clones the full backend. The hosted installer described here is a *different* flow: it fetches deploy files from a public source and pulls pre-built images from GHCR.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Customer runs: curl -fsSL https://get.worqlo.ai/install.sh | bash  │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│  install.sh (hosted at get.worqlo.ai)                            │
│  - Fetches deploy bundle from public source                      │
│  - Generates secrets                                             │
│  - Prompts for GHCR_OWNER, LLM key                               │
│  - Runs docker compose with GHCR override                         │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│  Deploy bundle source (one of):                                  │
│  - Public repo: github.com/worqlo/deploy                        │
│  - GitHub Releases tarball: worqlo-deploy-v1.0.0.tar.gz        │
│  - CDN: cdn.worqlo.ai/deploy/v1.0.0.tar.gz                      │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│  Docker pulls images from GHCR (public, no login)                 │
│  ghcr.io/worqlo/worqlo-api:latest                                │
│  ghcr.io/worqlo/worqlo-chat-ui:latest                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Installation Flow

### Step 1: Prerequisites Check

The script verifies:

| Requirement | Check | Failure action |
|-------------|-------|----------------|
| Docker 24+ | `docker --version` | Exit with install link |
| Docker Compose v2.17+ | `docker compose version` | Exit with install link |
| Docker daemon running | `docker info` | Exit |
| Ports 80, 443 free | `lsof` or equivalent | Warning only |
| Disk space ~10GB | `df` | Warning only |
| RAM ~4GB | `free` / `sysctl` | Warning only |
| `openssl` | `command -v openssl` | Exit |

### Step 2: Install Directory

- **macOS:** `INSTALL_DIR` defaults to `$HOME/worqlo` (no sudo)
- **Linux:** `INSTALL_DIR` defaults to `/opt/worqlo` (may require sudo)

Override with `INSTALL_DIR=/custom/path` before the curl command.

### Step 3: Fetch Deploy Bundle

**Option A – Clone public repo:**

```bash
git clone --depth 1 https://github.com/worqlo/deploy.git "$INSTALL_DIR"
cd "$INSTALL_DIR"
```

**Option B – Download tarball:**

```bash
VERSION="${VERSION:-latest}"  # or v1.0.0
curl -fsSL "https://github.com/worqlo/deploy/releases/download/${VERSION}/worqlo-deploy.tar.gz" | tar -xzf - -C "$INSTALL_DIR"
# If tarball has top-level folder (e.g. worqlo-deploy-1.0.0/), add: --strip-components=1
cd "$INSTALL_DIR"
```

**Option C – CDN:**

```bash
curl -fsSL "https://cdn.worqlo.ai/deploy/v1.0.0.tar.gz" | tar -xzf - -C "$INSTALL_DIR"
cd "$INSTALL_DIR"
```

The deploy bundle must contain:

- `docker-compose.yml`
- `docker-compose.ghcr.yml`
- `docker-compose.ghcr.mac.yml` (for Apple Silicon fallback)
- `env.example`
- `nginx/` (config, includes)
- `init-db.sql`
- `scripts/` (`generate-secrets.sh`, `backup.sh`, `restore.sh`, `update-ghcr.sh`, etc.)
- Optional: `docker-compose.observability.yml`, `prometheus/`, `grafana/`, `loki/`, `alloy/`

### Step 4: Generate Secrets

```bash
./scripts/generate-secrets.sh > .env
```

This creates: `JWT_WS_SECRET`, `NEXTAUTH_SECRET`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `MINIO_ROOT_PASSWORD`.

### Step 5: Configuration Prompts

| Variable | Prompt | Default | Required |
|----------|--------|---------|----------|
| `GHCR_OWNER` | "GitHub org for images (e.g. worqlo)"
| `IMAGE_TAG` | "Image tag (latest or v1.0.0)" | `latest` | No |
| LLM provider | Choice: OpenAI, Grok, SGLang, Ollama | |
| `OPENAI_API_KEY` | If OpenAI selected | | Yes for OpenAI |
| `GROK_API_KEY` | If Grok selected | | Yes for Grok |
| `SGLANG_BASE_URL` + `SGLANG_MODEL` | If SGLang selected | | Yes for SGLang |
| Observability | "Enable Grafana/Prometheus? [Y/n]" | Y | No |
| `GRAFANA_ADMIN_PASSWORD` | If observability enabled | | Yes if observability |

**Note:** `generate-secrets.sh` already outputs `GRAFANA_ADMIN_PASSWORD` when run. If using it, only append `GHCR_OWNER`, `IMAGE_TAG`, and the LLM key; otherwise prompt for Grafana password when observability is enabled.

Append these to `.env`.

### Step 6: Platform Detection

| Platform | Compose files |
|----------|---------------|
| x86_64 Linux | `docker-compose.yml` + `docker-compose.ghcr.yml` |
| arm64 Linux | Same |
| Apple Silicon | Same; if `no matching manifest for linux/arm64/v8`, add `docker-compose.ghcr.mac.yml` |

Detection:

```bash
ARCH=$(uname -m)
OS=$(uname -s)
if [ "$OS" = "Darwin" ] && [ "$ARCH" = "arm64" ]; then
  USE_MAC_OVERRIDE=true  # Try native first; fallback to mac override if pull fails
fi
```

### Step 7: Deploy

```bash
# Base
docker compose -f docker-compose.yml -f docker-compose.ghcr.yml up -d

# With observability
docker compose -f docker-compose.yml -f docker-compose.observability.yml -f docker-compose.ghcr.yml up -d

# Apple Silicon fallback
docker compose -f docker-compose.yml -f docker-compose.ghcr.yml -f docker-compose.ghcr.mac.yml up -d
```

### Step 8: Health Check

The `/health` endpoint returns JSON with `"status": "ok"` (no auth required). Use `HTTP_PORT` if overridden:

```bash
HEALTH_URL="http://localhost:${HTTP_PORT:-80}/health"
for i in $(seq 1 60); do
  if curl -sf "$HEALTH_URL" | grep -q '"status"'; then
    echo "Ready at http://localhost"
    exit 0
  fi
  sleep 2
done
echo "Health check timed out"
```

### Step 9: Post-Install Summary

Print:

- URL: `http://localhost` (or `https://$DOMAIN` if configured)
- Location: `$INSTALL_DIR`
- Update: `./scripts/update-ghcr.sh`
- Logs: `docker compose -f docker-compose.yml -f docker-compose.ghcr.yml logs -f api`

---

## Hosting the Installer Script

### URL Options

| Option | URL | Notes |
|--------|-----|-------|
| GitHub raw | `https://raw.githubusercontent.com/worqlo/deploy/main/install.sh` | Needs public deploy repo |
| Custom domain | `https://get.worqlo.ai/install.sh` | Redirect or proxy to raw |
| CDN | `https://cdn.worqlo.ai/install.sh` | Served from S3/CloudFront |

### Redirect Setup (get.worqlo.ai)

1. Create `get.worqlo.ai` → redirect to `https://raw.githubusercontent.com/worqlo/deploy/main/install.sh`
2. Or host a minimal HTML page that serves the script with correct `Content-Type: application/x-sh`

---

## Deploy Bundle Source

The installer must obtain deploy files from a **public** source:

| Option | Pros | Cons |
|--------|------|------|
| **Public repo `worqlo/deploy`** | Versioned, `git pull` for updates | Must keep in sync with backend releases |
| **GitHub Releases tarball** | Versioned, no git | Manual release step |
| **CDN tarball** | Fast, controlled | Extra hosting |

**Recommended:** Public `worqlo/deploy` repo. On each backend release, sync deploy assets to that repo and tag the release.

---

## Environment Variables (Summary)

**Required (no defaults):**

- `GHCR_OWNER` – e.g. `worqlo`
- `JWT_WS_SECRET`, `NEXTAUTH_SECRET`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `MINIO_ROOT_PASSWORD` (from `generate-secrets.sh`)

**Required by LLM provider:**

- OpenAI: `OPENAI_API_KEY`
- Grok: `GROK_API_KEY`
- SGLang: `SGLANG_BASE_URL`, `SGLANG_MODEL`
- Ollama: `OLLAMA_BASE_URL` (default in compose)

**Optional:**

- `IMAGE_TAG` (default: `latest`)
- `GHCR_REGISTRY` (default: `ghcr.io`)

---

## Non-Interactive Mode

For automation, support env vars to skip prompts:

```bash
GHCR_OWNER=worqlo IMAGE_TAG=v0.1.1 OPENAI_API_KEY=sk-xxx curl -fsSL https://get.worqlo.ai/install.sh | bash
```

If `GHCR_OWNER` and the LLM key are set, skip prompts and proceed.

---

## Security Considerations

1. **Script integrity:** Consider serving over HTTPS and pinning a checksum (e.g. SHA256) in docs.
2. **Pipe to bash:** Document that `curl | bash` runs remote code; users should review the script before running (e.g. `curl -fsSL https://get.worqlo.ai/install.sh` to inspect).
3. **Best practice:** Download, inspect, then run: `curl -fsSL https://get.worqlo.ai/install.sh -o install.sh && less install.sh && bash install.sh`
4. **Secrets:** `.env` has `600` permissions; never log secrets.
5. **Updates:** `update-ghcr.sh` pulls new images; no re-clone of deploy bundle needed.

---

## Implementation Checklist

- [ ] Create public `worqlo/deploy` repo with deploy assets (or use tarball)
- [ ] Add/adapt `install.sh` to that repo
- [ ] Configure `get.worqlo.ai` → installer script URL
- [ ] Document one-line install in customer docs
- [ ] Add release workflow to sync deploy bundle on backend tag
- [ ] Test on: macOS (Intel, Apple Silicon), Ubuntu, Debian
