#!/bin/bash
# =============================================================================
# Worqlo Restore Script
# =============================================================================
# Restores from a backup created by backup.sh
# Usage: ./restore.sh /path/to/backup.tar.gz
# =============================================================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# =============================================================================
# Validation
# =============================================================================

if [ -z "$1" ]; then
    echo "Usage: $0 <backup-file>"
    echo ""
    echo "Examples:"
    echo "  $0 ./backups/worqlo_backup_20240115_120000.tar.gz"
    echo "  $0 ./backups/worqlo_backup_20240115_120000.tar.gz.gpg"
    exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

# =============================================================================
# Main Restore Process
# =============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Worqlo Restore"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Backup file: $BACKUP_FILE"
    echo ""
    
    # Confirm
    read -p "This will OVERWRITE existing data. Continue? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        log_info "Restore cancelled"
        exit 0
    fi
    
    # Create temp directory
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    
    # Handle encrypted backups
    if [[ "$BACKUP_FILE" == *.gpg ]]; then
        log_info "Decrypting backup..."
        gpg --decrypt "$BACKUP_FILE" > "$TEMP_DIR/backup.tar.gz"
        ARCHIVE="$TEMP_DIR/backup.tar.gz"
    else
        ARCHIVE="$BACKUP_FILE"
    fi
    
    # Extract archive
    log_info "Extracting backup..."
    tar -xzf "$ARCHIVE" -C "$TEMP_DIR"
    
    # Find the backup directory
    BACKUP_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "worqlo_backup_*" | head -1)
    if [ -z "$BACKUP_DIR" ]; then
        log_error "Invalid backup archive structure"
        exit 1
    fi
    
    # Verify backup contents
    if [ ! -f "$BACKUP_DIR/database.dump" ]; then
        log_error "Database dump not found in backup"
        exit 1
    fi
    
    if [ ! -f "$BACKUP_DIR/metadata.json" ]; then
        log_warning "Metadata file not found (older backup format)"
    else
        log_info "Backup metadata:"
        cat "$BACKUP_DIR/metadata.json" | grep -E '"timestamp"|"version"' | sed 's/[",]//g'
    fi
    
    # Load environment
    if [ -f "$DEPLOY_DIR/.env" ]; then
        source "$DEPLOY_DIR/.env"
    else
        log_error "Environment file not found: $DEPLOY_DIR/.env"
        exit 1
    fi
    
    # Stop services (except database)
    log_info "Stopping application services..."
    cd "$DEPLOY_DIR"
    docker compose stop api celery-worker celery-beat chat-ui nginx 2>/dev/null || true
    
    # Restore PostgreSQL
    log_info "Restoring PostgreSQL database..."
    
    # Drop and recreate database
    docker exec worqlo-postgres psql -U "${POSTGRES_USER:-worqlo}" -d postgres -c \
        "DROP DATABASE IF EXISTS ${POSTGRES_DB:-worqlo};" 2>/dev/null || true
    docker exec worqlo-postgres psql -U "${POSTGRES_USER:-worqlo}" -d postgres -c \
        "CREATE DATABASE ${POSTGRES_DB:-worqlo};"
    
    # Restore from dump
    cat "$BACKUP_DIR/database.dump" | docker exec -i worqlo-postgres pg_restore \
        -U "${POSTGRES_USER:-worqlo}" \
        -d "${POSTGRES_DB:-worqlo}" \
        --no-owner \
        --no-acl \
        --clean \
        --if-exists 2>/dev/null || true
    
    log_success "Database restored"
    
    # Restore MinIO
    if [ -d "$BACKUP_DIR/minio" ] && [ "$(ls -A "$BACKUP_DIR/minio" 2>/dev/null)" ]; then
        log_info "Restoring MinIO storage..."
        
        docker run --rm \
            --network worqlo_worqlo-network \
            -v "$BACKUP_DIR/minio:/backup:ro" \
            minio/mc:latest \
            /bin/sh -c "
                mc alias set restore http://minio:9000 ${MINIO_ROOT_USER:-worqlo} ${MINIO_ROOT_PASSWORD} &&
                mc mirror /backup/ restore/${S3_BUCKET_NAME:-worqlo}/
            " 2>/dev/null
        
        log_success "MinIO storage restored"
    else
        log_warning "No MinIO files to restore"
    fi
    
    # Restart services
    log_info "Starting services..."
    docker compose up -d
    
    # Wait for health
    log_info "Waiting for services to be healthy..."
    sleep 10
    
    for i in {1..30}; do
        if curl -s "http://localhost:${HTTP_PORT:-80}/health" &> /dev/null; then
            break
        fi
        sleep 2
    done
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  Restore Complete!${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Services have been restarted. Please verify:"
    echo "  - Application: http://localhost"
    echo "  - Health:      http://localhost:${HTTP_PORT:-80}/health"
    echo ""
}

main "$@"

