#!/bin/bash
# =============================================================================
# Worqlo Rollback Script
# =============================================================================
# Rollback to a previous backup
# Usage: ./rollback.sh [backup-file]
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
# Main
# =============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Worqlo Rollback"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    # Determine backup file
    if [ -n "$1" ]; then
        BACKUP_FILE="$1"
    elif [ -f "$DEPLOY_DIR/.last_backup" ]; then
        BACKUP_FILE=$(cat "$DEPLOY_DIR/.last_backup")
        log_info "Using last backup: $BACKUP_FILE"
    else
        # List available backups
        log_info "Available backups:"
        echo ""
        
        if [ -d "$DEPLOY_DIR/backups" ]; then
            ls -lt "$DEPLOY_DIR/backups"/*.tar.gz 2>/dev/null | head -10 | while read line; do
                echo "  $line"
            done
        else
            log_error "No backups found in $DEPLOY_DIR/backups"
            exit 1
        fi
        
        echo ""
        read -p "Enter backup file path: " BACKUP_FILE
    fi
    
    # Validate backup file
    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi
    
    # Confirm rollback
    echo ""
    log_warning "This will restore from: $BACKUP_FILE"
    log_warning "All current data will be OVERWRITTEN!"
    echo ""
    read -p "Are you sure you want to rollback? [y/N]: " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        log_info "Rollback cancelled"
        exit 0
    fi
    
    # Perform rollback
    log_info "Starting rollback..."
    "$SCRIPT_DIR/restore.sh" "$BACKUP_FILE"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  Rollback Complete!${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

main "$@"

