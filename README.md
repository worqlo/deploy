# Worqlo Deploy

Deploy assets for self-hosting Worqlo with pre-built Docker images from GitHub Container Registry (GHCR).

## One-Line Install

```bash
curl -fsSL https://get.worqlo.ai/install.sh | bash
```

Or review first:

```bash
curl -fsSL https://get.worqlo.ai/install.sh -o install.sh && less install.sh && bash install.sh
```

## Non-Interactive Install

```bash
GHCR_OWNER=worqlo OPENAI_API_KEY=sk-your-key curl -fsSL https://get.worqlo.ai/install.sh | bash
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

## Documentation

- [Customer Deployment Guide](CUSTOMER_DEPLOYMENT_GUIDE.md)
- [Hosted Installer Spec](HOSTED_INSTALLER.md)

## License

MIT
