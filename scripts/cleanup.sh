#!/usr/bin/env bash
# =============================================================================
# cleanup.sh - Full Docker cleanup (containers, images, volumes, build cache)
# =============================================================================
# Removes all containers, images, volumes, networks, and build cache.
# Use before fresh install or when reclaiming disk space.
#
# Usage: worqloctl cleanup OR ./scripts/cleanup.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${DEPLOY_DIR}/.env"
source "${SCRIPT_DIR}/lib.sh"

log_step "Full Docker cleanup (containers, images, volumes, build cache)"

# 1. Stop all running containers
log_info "Stopping running containers..."
docker stop $(docker ps -q) 2>/dev/null || true

# 2. Compose down with volumes (if in deploy dir and compose files exist)
if [[ -f "${DEPLOY_DIR}/docker-compose.yml" ]]; then
    (
        cd "$DEPLOY_DIR"
        load_env 2>/dev/null || true
        compose_args=$(build_compose_args 2>/dev/null) || compose_args="-f docker-compose.yml"
        log_info "Removing compose containers and volumes..."
        docker compose $compose_args down -v 2>/dev/null || true
    )
fi

# 3. System prune: containers, networks, images, volumes
log_info "Pruning system (containers, networks, images, volumes)..."
docker system prune -a --volumes -f

# 4. Remove any remaining volumes (belt and suspenders)
log_info "Removing any remaining volumes..."
docker volume rm $(docker volume ls -q) 2>/dev/null || true

# 5. Build cache
log_info "Pruning build cache..."
docker builder prune -a -f

log_success "Docker cleanup complete"
