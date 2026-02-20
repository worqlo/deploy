#!/bin/bash
# =============================================================================
# Worqlo Update Script (GHCR)
# =============================================================================
# Safely updates Worqlo using pre-built images from GitHub Container Registry.
# Requires GHCR_OWNER in .env (or export). Optionally set IMAGE_TAG.
#
# Usage: ./update-ghcr.sh [OPTIONS]
#   ./update-ghcr.sh                     # Update to latest
#   ./update-ghcr.sh --version v0.1.0     # Update to specific tag
#   ./update-ghcr.sh --mac                # Apple Silicon (force amd64)
#   ./update-ghcr.sh --observability      # Include Grafana/Prometheus stack
# =============================================================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${DEPLOY_DIR}/.env"
source "${SCRIPT_DIR}/lib.sh"
BACKUP_BEFORE_UPDATE=true
TARGET_VERSION=""
USE_MAC_OVERRIDE=false
USE_OBSERVABILITY=false

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-backup)
            BACKUP_BEFORE_UPDATE=false
            shift
            ;;
        --version)
            TARGET_VERSION="$2"
            shift 2
            ;;
        --mac)
            USE_MAC_OVERRIDE=true
            shift
            ;;
        --observability)
            USE_OBSERVABILITY=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Updates Worqlo using pre-built images from GHCR."
            echo ""
            echo "Options:"
            echo "  --skip-backup       Skip pre-update backup"
            echo "  --version TAG       Update to specific tag (default: latest from .env)"
            echo "  --mac               Use Apple Silicon override (linux/amd64)"
            echo "  --observability     Include Grafana/Prometheus stack"
            echo "  -h, --help          Show this help"
            echo ""
            echo "Environment (.env or export):"
            echo "  GHCR_OWNER          Required. GitHub org or username (e.g. worqlo)"
            echo "  IMAGE_TAG           Image tag (default: latest)"
            echo "  GHCR_REGISTRY       Registry (default: ghcr.io)"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Compose File Selection
# =============================================================================

_build_compose_args() {
    local args
    args=$(build_compose_args)
    if [ "$USE_MAC_OVERRIDE" = true ] && [ -f "$DEPLOY_DIR/docker-compose.ghcr.mac.yml" ]; then
        args="$args -f docker-compose.ghcr.mac.yml"
    fi
    echo "$args"
}

COMPOSE_ARGS=$(_build_compose_args)

# =============================================================================
# Pre-flight Checks
# =============================================================================

preflight_checks() {
    log_info "Running pre-flight checks..."

    load_env

    # Check GHCR_OWNER
    if [ -z "${GHCR_OWNER:-}" ]; then
        log_error "GHCR_OWNER is required. Set it in deploy/.env or export GHCR_OWNER=your-github-org"
        exit 1
    fi
    log_success "GHCR_OWNER=$GHCR_OWNER"

    # Set IMAGE_TAG from --version if provided
    if [ -n "$TARGET_VERSION" ]; then
        export IMAGE_TAG="$TARGET_VERSION"
        log_info "Using IMAGE_TAG=$IMAGE_TAG"
    else
        export IMAGE_TAG="${IMAGE_TAG:-latest}"
    fi

    # Check Docker
    if ! docker info &> /dev/null; then
        log_error "Docker is not running"
        exit 1
    fi
    log_success "Docker is running"

    # Check if services are running
    cd "$DEPLOY_DIR"
    if ! docker compose $COMPOSE_ARGS ps --quiet 2>/dev/null | head -1 &> /dev/null; then
        log_error "Services are not running. Start them first with:"
        echo "  cd deploy && docker compose $COMPOSE_ARGS up -d"
        exit 1
    fi
    log_success "Services are running"

    # Check disk space
    AVAILABLE=$(df -BG "$DEPLOY_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "999")
    if [ "${AVAILABLE:-0}" -lt 5 ] 2>/dev/null; then
        log_warning "Low disk space: ${AVAILABLE}GB available (5GB+ recommended)"
    else
        log_success "Disk space: ${AVAILABLE}GB available"
    fi
}

# =============================================================================
# Backup
# =============================================================================

create_backup() {
    if [ "$BACKUP_BEFORE_UPDATE" = true ]; then
        log_info "Creating pre-update backup..."
        "$SCRIPT_DIR/backup.sh"

        BACKUP_DIR=$(ls -td "$DEPLOY_DIR/backups"/worqlo_backup_* 2>/dev/null | head -1)
        if [ -n "$BACKUP_DIR" ]; then
            # Create tar.gz for restore compatibility
            BACKUP_FILE="${BACKUP_DIR}.tar.gz"
            tar -czf "$BACKUP_FILE" -C "$DEPLOY_DIR/backups" "$(basename "$BACKUP_DIR")"
            echo "$BACKUP_FILE" > "$DEPLOY_DIR/.last_backup"
            log_success "Backup saved: $BACKUP_FILE"
        fi
    else
        log_warning "Skipping backup (--skip-backup flag used)"
    fi
}

# =============================================================================
# Update Process
# =============================================================================

perform_update() {
    cd "$DEPLOY_DIR"

    # Save current image tags for rollback
    log_info "Saving current state for rollback..."
    docker compose $COMPOSE_ARGS images --format json > "$DEPLOY_DIR/.pre_update_images.json" 2>/dev/null || true

    # Pull new images from GHCR
    log_info "Pulling images from GHCR (${GHCR_REGISTRY:-ghcr.io}/${GHCR_OWNER}:${IMAGE_TAG})..."
    docker compose $COMPOSE_ARGS pull

    # Stop app services gracefully
    log_info "Stopping app services..."
    docker compose $COMPOSE_ARGS stop api celery-worker celery-beat chat-ui 2>/dev/null || true

    # Run database migrations
    log_info "Running database migrations..."
    docker compose $COMPOSE_ARGS run --rm api alembic upgrade head 2>/dev/null || {
        log_warning "Migration command not available or no migrations to run"
    }

    # Start services with new images
    log_info "Starting updated services..."
    docker compose $COMPOSE_ARGS up -d

    # Wait for health checks
    log_info "Waiting for services to be healthy..."
    if wait_healthy 60; then
        return 0
    else
        log_error "Health check failed"
        return 1
    fi
}

# =============================================================================
# Rollback
# =============================================================================

rollback() {
    log_error "Update failed! Initiating rollback..."

    cd "$DEPLOY_DIR"

    if [ -f "$DEPLOY_DIR/.last_backup" ]; then
        BACKUP_FILE=$(cat "$DEPLOY_DIR/.last_backup")
        if [ -f "$BACKUP_FILE" ]; then
            log_info "Restoring from backup: $BACKUP_FILE"
            echo "y" | "$SCRIPT_DIR/restore.sh" "$BACKUP_FILE" || {
                log_warning "Restore failed, attempting restart with previous images..."
                docker compose $COMPOSE_ARGS down
                docker compose $COMPOSE_ARGS up -d
            }
        else
            log_warning "Backup file not found: $BACKUP_FILE"
            log_info "Attempting to restart with previous images..."
            docker compose $COMPOSE_ARGS down
            docker compose $COMPOSE_ARGS up -d
        fi
    else
        log_warning "No backup file found for rollback"
        log_info "Attempting to restart with previous images..."
        docker compose $COMPOSE_ARGS down
        docker compose $COMPOSE_ARGS up -d
    fi
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    log_info "Cleaning up old images..."
    docker image prune -f

    if [ -d "$DEPLOY_DIR/backups" ]; then
        cd "$DEPLOY_DIR/backups"
        ls -td worqlo_backup_* 2>/dev/null | tail -n +6 | while read -r d; do
            rm -rf "$d" "${d}.tar.gz" 2>/dev/null || true
        done
        log_success "Cleanup complete"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Worqlo Update (GHCR)"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    preflight_checks
    create_backup

    if perform_update; then
        cleanup

        # Update VERSION file
        cat > "$DEPLOY_DIR/VERSION" <<VEOF
deploy_rev=$(git -C "$DEPLOY_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
image_tag=${IMAGE_TAG:-latest}
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VEOF

        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "${GREEN}  Update Complete!${NC}"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "  Your Worqlo instance has been updated to ${IMAGE_TAG}."
        echo "  Check status: worqloctl status"
        echo ""
    else
        rollback
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "${YELLOW}  Update Rolled Back${NC}"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "  The update failed and has been rolled back."
        echo "  Please check the logs: docker compose $COMPOSE_ARGS logs"
        echo ""
        exit 1
    fi
}

main "$@"
