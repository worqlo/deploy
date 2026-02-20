#!/bin/bash
# =============================================================================
# Worqlo Backup Script
# =============================================================================
# Creates backups of:
# - PostgreSQL database
# - Redis data
# - MinIO S3 storage
# - Configuration files
#
# Usage: ./backup.sh [output_directory]
# Example: ./backup.sh /backups/worqlo
# =============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/lib.sh"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${1:-${DEPLOY_DIR}/backups/worqlo_backup_${TIMESTAMP}}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"  # Default: keep 7 days of backups

# Containers
POSTGRES_CONTAINER="worqlo-postgres"
REDIS_CONTAINER="worqlo-redis"
MINIO_CONTAINER="worqlo-minio"

# Check if Docker is running
check_docker() {
    if ! docker info &> /dev/null; then
        log_error "Docker is not running"
        exit 1
    fi
}

# Check if containers are running
check_containers() {
    local containers=("$@")
    for container in "${containers[@]}"; do
        if ! docker ps | grep -q "$container"; then
            log_warn "Container $container is not running, skipping..."
            return 1
        fi
    done
    return 0
}

# Create backup directory
create_backup_dir() {
    log_info "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"  # Secure permissions
}

# Backup PostgreSQL database
backup_postgres() {
    log_info "Backing up PostgreSQL database..."
    
    if ! check_containers "$POSTGRES_CONTAINER"; then
        return
    fi
    
    local db_backup="$BACKUP_DIR/database.dump"
    
    # Get database credentials from container environment
    local db_user=$(docker exec "$POSTGRES_CONTAINER" printenv POSTGRES_USER || echo "worqlo")
    local db_name=$(docker exec "$POSTGRES_CONTAINER" printenv POSTGRES_DB || echo "worqlo")
    
    # Create compressed database dump
    docker exec -t "$POSTGRES_CONTAINER" pg_dump \
        -U "$db_user" \
        -d "$db_name" \
        --format=custom \
        --compress=9 \
        --no-owner \
        --no-acl \
        > "$db_backup"
    
    if [ $? -eq 0 ]; then
        local size=$(du -h "$db_backup" | cut -f1)
        log_success "PostgreSQL backup created: $db_backup ($size)"
    else
        log_error "PostgreSQL backup failed"
        return 1
    fi
}

# Backup Redis data
backup_redis() {
    log_info "Backing up Redis data..."
    
    if ! check_containers "$REDIS_CONTAINER"; then
        return
    fi
    
    local redis_backup="$BACKUP_DIR/redis.rdb"
    
    # Trigger Redis BGSAVE and wait for completion
    docker exec "$REDIS_CONTAINER" redis-cli BGSAVE > /dev/null
    
    # Wait for background save to complete
    local max_wait=30
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local status=$(docker exec "$REDIS_CONTAINER" redis-cli LASTSAVE)
        sleep 1
        local new_status=$(docker exec "$REDIS_CONTAINER" redis-cli LASTSAVE)
        if [ "$status" != "$new_status" ]; then
            break
        fi
        waited=$((waited + 1))
    done
    
    # Copy RDB file from container
    docker cp "$REDIS_CONTAINER:/data/dump.rdb" "$redis_backup" 2>/dev/null || {
        log_warn "Redis RDB file not found, skipping..."
        return
    }
    
    if [ -f "$redis_backup" ]; then
        local size=$(du -h "$redis_backup" | cut -f1)
        log_success "Redis backup created: $redis_backup ($size)"
    fi
}

# Backup MinIO S3 data
backup_minio() {
    log_info "Backing up MinIO S3 data..."
    
    if ! check_containers "$MINIO_CONTAINER"; then
        return
    fi
    
    local minio_backup="$BACKUP_DIR/minio_data.tar.gz"
    
    # Create tarball of MinIO data directory
    docker exec "$MINIO_CONTAINER" tar czf - /data 2>/dev/null > "$minio_backup" || {
        log_warn "Failed to backup MinIO data"
        return
    }
    
    if [ -f "$minio_backup" ] && [ -s "$minio_backup" ]; then
        local size=$(du -h "$minio_backup" | cut -f1)
        log_success "MinIO backup created: $minio_backup ($size)"
    else
        log_warn "MinIO backup is empty or failed"
        rm -f "$minio_backup"
    fi
}

# Backup configuration files
backup_configs() {
    log_info "Backing up configuration files..."
    
    local config_backup="$BACKUP_DIR/configs"
    mkdir -p "$config_backup"
    
    # Copy important configuration files (excluding secrets)
    cp -r "$DEPLOY_DIR/nginx" "$config_backup/" 2>/dev/null || true
    cp -r "$DEPLOY_DIR/prometheus" "$config_backup/" 2>/dev/null || true
    cp -r "$DEPLOY_DIR/grafana" "$config_backup/" 2>/dev/null || true
    cp -r "$DEPLOY_DIR/loki" "$config_backup/" 2>/dev/null || true
    cp -r "$DEPLOY_DIR/alloy" "$config_backup/" 2>/dev/null || true
    
    cp "$DEPLOY_DIR/docker-compose.yml" "$config_backup/" 2>/dev/null || true
    cp "$DEPLOY_DIR/docker-compose.observability.yml" "$config_backup/" 2>/dev/null || true
    cp "$DEPLOY_DIR/env.example" "$config_backup/" 2>/dev/null || true
    
    # DO NOT backup .env (contains secrets)
    
    log_success "Configuration files backed up"
}

# Create backup manifest
create_manifest() {
    log_info "Creating backup manifest..."
    
    local manifest="$BACKUP_DIR/manifest.txt"
    
    cat > "$manifest" << EOF
Worqlo Backup Manifest
=====================================================
Timestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')
Backup Directory: $BACKUP_DIR
Hostname: $(hostname)
Docker Version: $(docker --version)

Contents:
EOF
    
    # List all files with sizes
    cd "$BACKUP_DIR"
    find . -type f -exec ls -lh {} \; | awk '{print $9, "("$5")"}' >> "$manifest"
    
    # Calculate total size
    local total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    echo "" >> "$manifest"
    echo "Total Backup Size: $total_size" >> "$manifest"
    
    log_success "Manifest created: $manifest"
}

# Cleanup old backups
cleanup_old_backups() {
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."
    
    local backup_parent=$(dirname "$BACKUP_DIR")
    
    # Find and delete old backup directories
    find "$backup_parent" -maxdepth 1 -type d -name "worqlo_backup_*" -mtime +$RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null || true
    
    log_success "Old backups cleaned up"
}

# Test backup integrity
test_backup() {
    log_info "Testing backup integrity..."
    
    local errors=0
    
    # Test PostgreSQL dump
    if [ -f "$BACKUP_DIR/database.dump" ]; then
        if ! docker exec "$POSTGRES_CONTAINER" pg_restore --list "$BACKUP_DIR/database.dump" &>/dev/null 2>&1; then
            log_warn "PostgreSQL backup may be corrupted (integrity check failed)"
            errors=$((errors + 1))
        fi
    fi
    
    # Test tar archives
    for archive in "$BACKUP_DIR"/*.tar.gz; do
        if [ -f "$archive" ]; then
            if ! tar tzf "$archive" &>/dev/null; then
                log_warn "Archive $archive may be corrupted"
                errors=$((errors + 1))
            fi
        fi
    done
    
    if [ $errors -eq 0 ]; then
        log_success "Backup integrity checks passed"
    else
        log_warn "Some integrity checks failed ($errors issues)"
    fi
}

# Main backup function
main() {
    echo ""
    echo -e "${BLUE}=============================================================================${NC}"
    echo -e "${BLUE}  Worqlo Backup${NC}"
    echo -e "${BLUE}=============================================================================${NC}"
    echo ""
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Backup Directory: $BACKUP_DIR"
    echo "Retention: $RETENTION_DAYS days"
    echo ""
    
    # Pre-flight checks
    check_docker
    
    # Create backup directory
    create_backup_dir
    
    # Perform backups
    backup_postgres
    backup_redis
    backup_minio
    backup_configs
    
    # Create manifest
    create_manifest
    
    # Test backup
    test_backup
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Summary
    local total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    
    echo ""
    echo -e "${GREEN}=============================================================================${NC}"
    echo -e "${GREEN}  Backup Complete!${NC}"
    echo -e "${GREEN}=============================================================================${NC}"
    echo ""
    echo "Backup Location: $BACKUP_DIR"
    echo "Total Size: $total_size"
    echo ""
    echo "Backup contents:"
    ls -lh "$BACKUP_DIR" | grep -v "^total" | awk '{print "  " $9, "(" $5 ")"}'
    echo ""
    echo -e "${YELLOW}⚠️  Important:${NC}"
    echo "  • Store backups in a secure, off-site location"
    echo "  • Test restore procedures regularly"
    echo "  • Encrypt backups before transferring"
    echo ""
    echo "To restore from this backup:"
    echo "  ./restore.sh $BACKUP_DIR"
    echo ""
}

# Run main function
main
