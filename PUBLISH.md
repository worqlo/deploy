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

## Sync from backend

When `backend/deploy/` changes, sync to this repo:

```bash
cd /path/to/backend
rsync -av --exclude='.env' --exclude='.pre_update_images.json' --exclude='vocab_cache/*' \
  deploy/ ../worqlo-deploy/
# Then remove backend-specific files from worqlo-deploy (Dockerfile, entrypoint.sh, etc.)
cd ../worqlo-deploy && git add -A && git status
```

Consider adding a CI workflow in `backend` to sync on release tags.
