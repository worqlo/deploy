# Worqlo Deploy

Deploy assets for self-hosting Worqlo with pre-built Docker images from GitHub Container Registry (GHCR).

## One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/worqlo/deploy/main/install.sh | bash
```

## Interactive Install

Run the script directly (not piped) to get prompts for each setting:

```bash
curl -fsSL https://raw.githubusercontent.com/worqlo/deploy/main/install.sh -o install.sh
bash install.sh
```

You'll be prompted for:
- **GHCR owner** (e.g. worqlo)
- **Image tag** (latest or v1.0.0)
- **LLM provider**: SGLang, OpenAI, Grok, or Ollama
- **Enable Grafana/Prometheus?** (Y/n)

Best practice: review before running: `less install.sh` then `bash install.sh`

## Non-Interactive Install

Requires an LLM config. SGLang (default):

```bash
SGLANG_BASE_URL=http://your-sglang-host:30000 SGLANG_MODEL=openai/gpt-oss-120b curl -fsSL https://raw.githubusercontent.com/worqlo/deploy/main/install.sh | bash
```

Or OpenAI / Grok:

```bash
GHCR_OWNER=worqlo OPENAI_API_KEY=sk-your-key curl -fsSL https://raw.githubusercontent.com/worqlo/deploy/main/install.sh | bash
```

Custom install directory:

```bash
INSTALL_DIR=/opt/worqlo SGLANG_BASE_URL=http://host:30000 SGLANG_MODEL=openai/gpt-oss-120b curl -fsSL ... | bash
```

## Manual Setup

If you prefer to clone and configure manually:

```bash
git clone https://github.com/worqlo/deploy.git
cd deploy
./scripts/generate-secrets.sh > .env
# Edit .env: set OPENAI_API_KEY (or GROK_API_KEY, OLLAMA_*, SGLANG_*)
docker compose -f docker-compose.yml -f docker-compose.ghcr.yml up -d
```

## Requirements

- Docker 24+ with Docker Compose v2.17+
- openssl
- 4GB+ RAM, 10GB+ disk

## What's Included

- `install.sh` – Hosted installer (clones this repo, generates secrets, pulls images)
- `docker-compose.yml` – Service definitions
- `docker-compose.ghcr.yml` – Override to use pre-built images (no build from source)
- `scripts/generate-secrets.sh` – Secure secret generation
- `scripts/update-ghcr.sh` – Update to newer image tags
- `nginx/` – Reverse proxy config
- `env.example` – Configuration template

## Updating

```bash
git pull origin main
./scripts/update-ghcr.sh
```

## Third-Party Licenses and SBOM

For customer compliance and audit:

- **License list**: `THIRD_PARTY_LICENSES.md` is included in the API Docker image at `/app/THIRD_PARTY_LICENSES.md`
- **SBOM**: When you push a version tag (e.g. `v1.0.0`), the release workflow produces `sbom-backend.json` and `sbom-chat-ui.json` as workflow artifacts. Download them from the [GitHub Actions run](https://github.com/worqlo/backend/actions) or from the release page.

## Documentation

- [Customer Deployment Guide](CUSTOMER_DEPLOYMENT_GUIDE.md)
- [Hosted Installer Spec](HOSTED_INSTALLER.md)

## License

MIT
