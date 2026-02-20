#!/bin/bash
# =============================================================================
# Worqlo Update Script
# =============================================================================
# Safely updates Worqlo to the latest version with automatic backup
# Usage: ./update.sh [--skip-backup] [--version <tag>]
# =============================================================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${DEPLOY_DIR}/.env"
source "${SCRIPT_DIR}/lib.sh"
BACKUP_BEFORE_UPDATE=true
TARGET_VERSION="latest"

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
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-backup     Skip pre-update backup"
            echo "  --version TAG     Update to specific version (default: latest)"
            echo "  -h, --help        Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Pre-flight Checks
# =============================================================================

preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check Docker
    if ! docker info &> /dev/null; then
        log_error "Docker is not running"
        exit 1
    fi
    log_success "Docker is running"
    
    # Check if services are running
    cd "$DEPLOY_DIR"
    if ! docker compose ps --quiet 2>/dev/null | head -1 &> /dev/null; then
        log_error "Services are not running. Start them first with: docker compose up -d"
        exit 1
    fi
    log_success "Services are running"
    
    # Check disk space
    AVAILABLE=$(df -BG "$DEPLOY_DIR" | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$AVAILABLE" -lt 5 ]; then
        log_error "Insufficient disk space: ${AVAILABLE}GB available (need 5GB+)"
        exit 1
    fi
    log_success "Disk space: ${AVAILABLE}GB available"
}

# =============================================================================
# Backup
# =============================================================================

create_backup() {
    if [ "$BACKUP_BEFORE_UPDATE" = true ]; then
        log_info "Creating pre-update backup..."
        "$SCRIPT_DIR/backup.sh" --output-dir "$DEPLOY_DIR/backups"
        
        # Save backup filename for potential rollback
        BACKUP_FILE=$(ls -t "$DEPLOY_DIR/backups"/*.tar.gz 2>/dev/null | head -1)
        if [ -n "$BACKUP_FILE" ]; then
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

    load_env

    # Save current image tags for rollback
    log_info "Saving current state for rollback..."
    docker compose images --format json > "$DEPLOY_DIR/.pre_update_images.json" 2>/dev/null || true
    
    # Pull new images
    log_info "Pulling latest images..."
    docker compose pull
    
    # Check if we need to rebuild local images
    if [ -f "$DEPLOY_DIR/Dockerfile" ]; then
        log_info "Rebuilding local images..."
        docker compose build --no-cache
    fi
    
    # Stop services gracefully
    log_info "Stopping services..."
    docker compose stop api celery-worker celery-beat chat-ui
    
    # Run database migrations
    log_info "Running database migrations..."
    docker compose run --rm api alembic upgrade head 2>/dev/null || {
        log_warning "Migration command not available or no migrations to run"
    }
    
    # Start services with new images
    log_info "Starting updated services..."
    docker compose up -d
    
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
    
    # Restore from backup if available
    if [ -f "$DEPLOY_DIR/.last_backup" ]; then
        BACKUP_FILE=$(cat "$DEPLOY_DIR/.last_backup")
        if [ -f "$BACKUP_FILE" ]; then
            log_info "Restoring from backup: $BACKUP_FILE"
            "$SCRIPT_DIR/restore.sh" "$BACKUP_FILE"
        fi
    else
        log_warning "No backup file found for rollback"
        log_info "Attempting to restart with previous images..."
        docker compose down
        docker compose up -d
    fi
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    log_info "Cleaning up old images..."
    docker image prune -f
    
    # Remove old backups (keep last 5)
    if [ -d "$DEPLOY_DIR/backups" ]; then
        cd "$DEPLOY_DIR/backups"
        ls -t *.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
        log_success "Cleanup complete"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Worqlo Update"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    preflight_checks
    create_backup
    
    if perform_update; then
        cleanup
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "${GREEN}  Update Complete!${NC}"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "  Your Worqlo instance has been updated successfully."
        echo "  Please verify at: http://localhost"
        echo ""
    else
        rollback
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "${YELLOW}  Update Rolled Back${NC}"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "  The update failed and has been rolled back."
        echo "  Please check the logs: docker compose logs"
        echo ""
        exit 1
    fi
}

main "$@"

