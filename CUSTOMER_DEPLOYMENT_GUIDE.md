# Worqlo Self-Hosted: Customer Deployment Guide

This guide explains how to package and deliver the Worqlo self-hosted platform to customers.

---

## Table of Contents

1. [Packaging Options](#1-packaging-options)
2. [GHCR Package Visibility](#2-ghcr-package-visibility)
3. [Platform-Specific Instructions](#3-platform-specific-instructions)
4. [Recommended Customer Flow](#4-recommended-customer-flow)
5. [Documentation Checklist](#5-documentation-checklist)
6. [Optional: Hosted Installer](#6-optional-hosted-installer)

---

## 1. Packaging Options

### Option A: Minimal Deploy Bundle (Recommended)

Provide only what's needed to run pre-built images—no source code:

- **`deploy/`** folder (docker-compose files, nginx config, init-db.sql, scripts)
- **`env.example`** → customers copy to `.env`
- **`install.sh`** (or simplified installer)
- **Short README** with quick start

Images are pulled from GHCR; no build step required.

### Option B: Full Repository

Distribute the full repo. Customers can either:

- **Build from source:** `docker compose up -d`
- **Use pre-built images:** `docker compose -f docker-compose.yml -f docker-compose.ghcr.yml up -d`

### Option C: One-Line Installer

Host `install.sh` at a stable URL:

```bash
curl -fsSL https://get.worqlo.ai/install.sh | bash
```

The script should:

1. Verify Docker + Docker Compose
2. Create install directory
3. Download deploy files (or clone minimal repo)
4. Run `generate-secrets.sh` → `.env`
5. Set `GHCR_OWNER` and `IMAGE_TAG`
6. Run compose with platform-specific overrides

---

## 2. GHCR Package Visibility

### Public Packages (Recommended)

- **No login required** for customers
- Set packages to **Public** in GitHub: Packages → worqlo-api / worqlo-chat-ui → Package settings → Change visibility → Public

### Private Packages

If packages remain private, customers must authenticate:

1. **Create a Personal Access Token:** GitHub → Settings → Developer settings → Personal access tokens → Generate new token. Enable **read:packages** (and **repo** if the package's backing repo is private).
2. **Log in to GHCR:**
   ```bash
   echo YOUR_GITHUB_PAT | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
   ```
3. Then run compose as usual.

---

## 3. Platform-Specific Instructions

| Platform | Command |
|----------|---------|
| **x86_64 Linux** (Ubuntu, Debian, RHEL, etc.) | `docker compose -f docker-compose.yml -f docker-compose.ghcr.yml up -d` |
| **arm64 Linux** (AWS Graviton, Raspberry Pi 4) | Same as above |
| **Apple Silicon (M1/M2/M3)** | Try base first; if you see `no matching manifest for linux/arm64/v8`, add `-f docker-compose.ghcr.mac.yml` |

### Apple Silicon (Mac M1/M2/M3)

**Option 1 – Native arm64 (no warnings):**

```bash
docker compose -f docker-compose.yml -f docker-compose.ghcr.yml up -d
```

If you see `no matching manifest for linux/arm64/v8`, use Option 2.

**Option 2 – amd64 via Rosetta (fallback):**

```bash
docker compose -f docker-compose.yml -f docker-compose.ghcr.yml -f docker-compose.ghcr.mac.yml up -d
```

Containers will show "AMD64" warnings in Docker Desktop; they are harmless and run via emulation.

---

## 4. Recommended Customer Flow

1. **Prerequisites:** Docker 24+ and Docker Compose v2.17+
2. **Get deploy files:** Clone repo or download deploy bundle
3. **Configure:** `cp env.example .env` and edit (LLM keys, passwords, etc.)
4. **Set image source:** `export GHCR_OWNER=worqlo` and `export IMAGE_TAG=0.0.4` (or `latest`)
5. **Deploy:** Platform-specific compose command from the table above
6. **Initialize tenant:** `POST /api/tenants/initialize` for first tenant

### Example: Full Deployment

**Note:** This repo (`worqlo/deploy`) is for GHCR-based installs only. For building from source, clone `worqlo/backend` and use `backend/deploy/`.

```bash
# 1. Clone deploy bundle (pre-built images from GHCR)
git clone https://github.com/worqlo/deploy.git
cd deploy

# 2. Generate secrets
./scripts/generate-secrets.sh > .env

# 3. Add your LLM API key
nano .env  # Set OPENAI_API_KEY or GROK_API_KEY

# 4. Set GHCR and version
export GHCR_OWNER=worqlo
export IMAGE_TAG=0.0.4

# 5. Deploy (x86_64 / arm64 Linux)
docker compose -f docker-compose.yml -f docker-compose.ghcr.yml up -d

# 6. Verify
curl http://localhost/health
```

### With Observability (Prometheus, Grafana, Loki)

```bash
# Add GRAFANA_ADMIN_PASSWORD to .env
nano .env  # Set GRAFANA_ADMIN_PASSWORD=your-secure-password

# Deploy with observability
docker compose -f docker-compose.yml -f docker-compose.observability.yml -f docker-compose.ghcr.yml up -d

# Grafana on port 3001
open http://localhost:3001
```

### Network Access (IP)

To access Worqlo from other machines on the network (e.g. `http://192.168.1.100`):

**One-line install:**
```bash
BASE_URL=http://192.168.1.100 SGLANG_BASE_URL=http://host:30000 SGLANG_MODEL=openai/gpt-oss-120b curl -fsSL https://get.worqlo.ai/install.sh | bash
```

**Interactive install:** When prompted "How will users access Worqlo?", choose option 2 (IP address). The installer will suggest your server's primary IP.

**Manual .env:** Set `BASE_URL=http://YOUR_IP` before running `generate-secrets.sh`, or edit `.env` and set `NEXT_PUBLIC_API_URL`, `NEXTAUTH_URL`, `CORS_ALLOW_ORIGINS`, etc. to use your IP.

---

## 5. Documentation Checklist

Provide customers with:

- [ ] **Quick Start** – One-page "deploy in 5 minutes"
- [ ] **Platform matrix** – Table like above
- [ ] **GHCR setup** – Public vs private, login if private
- [ ] **Troubleshooting** – Common errors (manifest, auth, ports)
- [ ] **Versioning** – How to pin versions and upgrade (`IMAGE_TAG`)
- [ ] **Production checklist** – Security, backups, monitoring

---

## 6. Optional: Hosted Installer

If you want a hosted installer:

1. Host `install.sh` at a stable URL (e.g. `https://get.worqlo.ai/install.sh`)
2. Publish a minimal tarball or zip of `deploy/` and have the script fetch it, OR
3. Maintain a minimal repo with only `deploy/` and have the script clone it
4. Script runs `generate-secrets.sh`, sets env vars, and runs compose with the correct GHCR override

The `install.sh` uses GHCR by default when `GHCR_OWNER` is set, includes platform-specific compose files for Apple Silicon, and supports `IMAGE_TAG` for version pinning.

---

## Support

- **Documentation:** https://docs.worqlo.com
- **Issues:** https://github.com/worqlo/deploy/issues (deploy) / https://github.com/worqlo/backend/issues (source)
- **Community:** https://discord.gg/worqlo

---

## License

Copyright © 2026 Worqlo. All rights reserved.
