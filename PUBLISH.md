# Publishing worqlo/deploy

This document is for maintainers. It describes how to create and publish the `worqlo/deploy` repo.

## Create the GitHub repo

1. **Via GitHub web UI**
   - Go to https://github.com/new
   - Repository name: `deploy`
   - Owner: `worqlo` (or your org)
   - Visibility: Public
   - Do **not** initialize with README (we already have one)
   - Create repository

2. **Via GitHub CLI** (if installed)
   ```bash
   gh repo create worqlo/deploy --public --source=. --remote=origin --push
   ```

## Push from local

```bash
cd /Users/sajlibeqiri/Documents/worqlo-deploy
git remote add origin https://github.com/worqlo/deploy.git
git push -u origin main
```

## One-line install URL

The install script references `https://get.worqlo.ai/install.sh`. Configure one of:

- **Option A:** Redirect `https://get.worqlo.ai/install.sh` → `https://raw.githubusercontent.com/worqlo/deploy/main/install.sh`
- **Option B:** Serve install.sh from your CDN/domain
- **Option C:** Users can run: `curl -fsSL https://raw.githubusercontent.com/worqlo/deploy/main/install.sh | bash`

## Updating from backend

The `deploy/` directory is a submodule of `worqlo/backend`. To publish changes to `worqlo/deploy`:

```bash
cd /path/to/backend/deploy
git add -A && git status
git commit -m "Your changes"
git push origin main
```

The backend's `release-images.yml` workflow builds and pushes Docker images to GHCR when you push a version tag (e.g. `v1.0.0`). Ensure deploy assets are pushed to `worqlo/deploy` before tagging a backend release.
