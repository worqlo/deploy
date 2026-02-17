#!/bin/bash
# =============================================================================
# Worqlo Backend Entrypoint
# =============================================================================
# This script runs on container startup to:
# 1. Wait for PostgreSQL to be ready
# 2. Run database migrations (Alembic)
# 3. Seed reference data (roles, domains, connectors)
# 4. Start the FastAPI application
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse database URL to get host and port
parse_database_url() {
    # DATABASE_URL format: postgresql://user:password@host:port/database
    if [[ -z "$DATABASE_URL" ]]; then
        log_error "DATABASE_URL not set"
        exit 1
    fi
    
    # Extract host and port using bash string manipulation
    local url_without_protocol="${DATABASE_URL#*://}"
    local url_without_credentials="${url_without_protocol#*@}"
    DB_HOST="${url_without_credentials%%:*}"
    DB_PORT="${url_without_credentials#*:}"
    DB_PORT="${DB_PORT%%/*}"
}

# Wait for PostgreSQL to be ready
wait_for_postgres() {
    log_info "Waiting for PostgreSQL at $DB_HOST:$DB_PORT..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if pg_isready -h "$DB_HOST" -p "$DB_PORT" -q 2>/dev/null; then
            log_success "PostgreSQL is ready!"
            return 0
        fi
        
        log_info "Attempt $attempt/$max_attempts - PostgreSQL not ready, waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    log_error "PostgreSQL failed to become ready after $max_attempts attempts"
    exit 1
}

# Wait for S3/MinIO to be ready (only when STORAGE_BACKEND=s3)
wait_for_minio() {
    if [[ "$STORAGE_BACKEND" != "s3" ]]; then
        return 0
    fi

    log_info "Waiting for S3/MinIO storage..."

    python -c "
import boto3, os, sys, time

endpoint = os.environ.get('S3_ENDPOINT_URL', '')
access_key = os.environ.get('S3_ACCESS_KEY', '')
secret_key = os.environ.get('S3_SECRET_KEY', '')
region = os.environ.get('S3_REGION', 'us-east-1')
bucket = os.environ.get('S3_BUCKET_NAME', '')

if not bucket:
    print('S3_BUCKET_NAME not set, skipping MinIO check')
    sys.exit(0)

for i in range(30):
    try:
        s3 = boto3.client(
            's3',
            endpoint_url=endpoint or None,
            aws_access_key_id=access_key or None,
            aws_secret_access_key=secret_key or None,
            region_name=region,
        )
        s3.head_bucket(Bucket=bucket)
        print(f'S3/MinIO ready! Bucket \"{bucket}\" exists.')
        sys.exit(0)
    except Exception as e:
        if i < 29:
            time.sleep(2)
        else:
            print(f'WARNING: S3/MinIO not ready after 60s: {e}')
            sys.exit(0)  # Don't block startup; ensure_bucket_exists() will retry
" && log_success "S3/MinIO is ready!" || log_warn "S3/MinIO check had issues, continuing..."
}

# Create core tables (before Alembic migrations)
create_tables() {
    log_info "Creating core database tables..."
    
    python -c "
import asyncio
from app.domain.models import Base
from sqlalchemy.ext.asyncio import create_async_engine
import os

async def create():
    url = os.environ.get('DATABASE_URL', '')
    if url.startswith('postgresql://'):
        url = url.replace('postgresql://', 'postgresql+asyncpg://', 1)
    if url.startswith('postgres://'):
        url = url.replace('postgres://', 'postgresql+asyncpg://', 1)
    engine = create_async_engine(url)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    await engine.dispose()
    print('Tables created!')

asyncio.run(create())
" && log_success "Core tables created!" || log_warn "Table creation had issues, continuing..."
}

# Run Alembic migrations
run_migrations() {
    log_info "Running database migrations..."
    
    if [ -f "alembic.ini" ]; then
        if alembic upgrade head; then
            log_success "Migrations completed successfully!"
        else
            log_warn "Migration command returned non-zero, but continuing..."
        fi
    else
        log_warn "alembic.ini not found, skipping migrations"
    fi
}

# Run seed script
run_seeds() {
    log_info "Running database seeds..."
    
    local seed_script="deploy/scripts/seed.py"
    
    if [ -f "$seed_script" ]; then
        if python "$seed_script"; then
            log_success "Seeding completed!"
        else
            log_warn "Seeding returned non-zero, but continuing..."
        fi
    else
        log_warn "Seed script not found at $seed_script, skipping"
    fi
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo "=========================================="
echo "  Worqlo Backend Startup"
echo "=========================================="
echo ""

# Skip migrations/seeds if SKIP_STARTUP_TASKS is set (useful for celery workers)
if [[ "$SKIP_STARTUP_TASKS" == "true" ]]; then
    log_info "SKIP_STARTUP_TASKS=true, skipping migrations and seeds"
else
    # Parse database URL
    parse_database_url
    
    # Wait for PostgreSQL
    wait_for_postgres
    
    # Wait for S3/MinIO (if using S3 storage backend)
    wait_for_minio
    
    # Create core tables first (required before Alembic migrations)
    create_tables
    
    # Run migrations (incremental changes)
    run_migrations
    
    # Run seeds
    run_seeds
fi

echo ""
echo "=========================================="
echo "  Starting Application"
echo "=========================================="
echo ""

# Execute the main command (passed as arguments to this script)
exec "$@"

