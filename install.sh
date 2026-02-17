#!/usr/bin/env bash
# =============================================================================
# Worqlo Hosted Installer (GHCR)
# =============================================================================
# One-line install using pre-built Docker images from GitHub Container Registry.
# Usage: curl -fsSL https://raw.githubusercontent.com/worqlo/deploy/main/install.sh | bash
#
# Non-interactive: SGLANG_BASE_URL=http://host:30000 SGLANG_MODEL=openai/gpt-oss-120b curl -fsSL ... | bash
#
# Best practice: Review script before running:
#   curl -fsSL https://raw.githubusercontent.com/worqlo/deploy/main/install.sh -o install.sh && less install.sh && bash install.sh
# =============================================================================

set -euo pipefail

# Cleanup temp files on exit (industry standard: trap for resource cleanup)
cleanup() {
    local exit_code=$?
    [[ -n "${PULL_LOG_FILE:-}" ]] && rm -f "$PULL_LOG_FILE"
    [[ -n "${ENV_TMP_FILE:-}" ]] && rm -f "$ENV_TMP_FILE"
    [[ -n "${CLONE_ERR:-}" ]] && rm -f "$CLONE_ERR"
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# Colors (readonly for constants)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# Deploy bundle source
# - clone (default): DEPLOY_REPO, DEPLOY_BRANCH
# - tarball: DEPLOY_TARBALL_URL (e.g. https://github.com/worqlo/deploy/releases/download/v1.0.0/worqlo-deploy.tar.gz)
# - cdn: DEPLOY_CDN_URL (e.g. https://cdn.worqlo.ai/deploy/v1.0.0.tar.gz)
DEPLOY_REPO="${DEPLOY_REPO:-worqlo/deploy}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"

# Install directory
if [ "$(uname)" = "Darwin" ]; then
    INSTALL_DIR="${INSTALL_DIR:-/tmp/worqlo}"
else
    INSTALL_DIR="${INSTALL_DIR:-/opt/worqlo}"
fi

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }
log_step() { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }

# =============================================================================
# Step 1: Prerequisites
# =============================================================================
check_prerequisites() {
    log_step "Checking prerequisites..."

    if ! command -v openssl &> /dev/null; then
        log_error "openssl is required. Install it first."
        exit 1
    fi
    log_success "openssl"

    if ! command -v docker &> /dev/null; then
        log_error "Docker not found. Install from https://docs.docker.com/get-docker/"
        exit 1
    fi
    DOCKER_VER=$(docker --version 2>/dev/null | sed -E 's/.*version ([0-9]+)\.([0-9]+).*/\1.\2/' || echo "0")
    DOCKER_MAJOR=$(echo "$DOCKER_VER" | cut -d. -f1)
    if [ -n "$DOCKER_MAJOR" ] && [ "$DOCKER_MAJOR" -lt 24 ] 2>/dev/null; then
        log_error "Docker 24+ required (you have $DOCKER_VER). Install from https://docs.docker.com/get-docker/"
        exit 1
    fi
    log_success "Docker $DOCKER_VER"

    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose v2 not found. Install from https://docs.docker.com/compose/install/"
        exit 1
    fi
    COMPOSE_VER=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$COMPOSE_VER" ]; then
        MAJOR=$(echo "$COMPOSE_VER" | cut -d. -f1)
        MINOR=$(echo "$COMPOSE_VER" | cut -d. -f2)
        if [ "$MAJOR" -lt 2 ] || { [ "$MAJOR" -eq 2 ] && [ "$MINOR" -lt 17 ]; }; then
            log_error "Docker Compose v2.17+ required (you have $COMPOSE_VER). Install from https://docs.docker.com/compose/install/"
            exit 1
        fi
    fi
    log_success "Docker Compose"

    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
    log_success "Docker daemon running"

    # Ports (warning only; try lsof, fallback to ss on Linux)
    for port in 80 443; do
        port_in_use=false
        if lsof -i "TCP:${port}" -sTCP:LISTEN &> /dev/null 2>/dev/null; then
            port_in_use=true
        elif command -v ss &> /dev/null && ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            port_in_use=true
        fi
        if [ "$port_in_use" = true ]; then
            log_warning "Port ${port} is in use"
        fi
    done

    # Disk space (check install target filesystem; use parent if dir doesn't exist yet)
    DISK_CHECK_DIR="${INSTALL_DIR%/*}"
    [ -z "$DISK_CHECK_DIR" ] || [ "$DISK_CHECK_DIR" = "$INSTALL_DIR" ] && DISK_CHECK_DIR="$HOME"
    if [ "$(uname)" = "Darwin" ]; then
        AVAIL=$(df -g "$DISK_CHECK_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    else
        AVAIL=$(df -BG "$DISK_CHECK_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "0")
    fi
    if [ -n "$AVAIL" ] && [ "$AVAIL" -lt 10 ] 2>/dev/null; then
        log_warning "Low disk space: ${AVAIL}GB (10GB+ recommended)"
    fi

    # RAM (~4GB)
    if [ "$(uname)" = "Linux" ]; then
        TOTAL_RAM=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    else
        TOTAL_RAM=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024/1024)}' || echo "0")
    fi
    if [ -n "$TOTAL_RAM" ] && [ "$TOTAL_RAM" -lt 4 ] 2>/dev/null; then
        log_warning "Low RAM: ${TOTAL_RAM}GB (4GB+ recommended)"
    else
        log_success "RAM: ${TOTAL_RAM}GB"
    fi
}

# =============================================================================
# Step 2 & 3: Install directory and fetch deploy bundle
# =============================================================================
fetch_deploy_bundle() {
    # If already in deploy directory (has docker-compose.ghcr.yml and scripts)
    if [ -f "docker-compose.ghcr.yml" ] && [ -f "scripts/generate-secrets.sh" ]; then
        INSTALL_DIR="$(pwd)"
        log_success "Using current directory as deploy root: $INSTALL_DIR"
        cd "$INSTALL_DIR"
        return 0
    fi

    log_step "Fetching deploy bundle..."

    if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
        log_error "Cannot create $INSTALL_DIR (permission denied). On Linux, try: sudo bash install.sh"
        exit 1
    fi

    if [ -n "${DEPLOY_CDN_URL:-}" ]; then
        # Option C: CDN tarball
        log_info "Downloading from CDN..."
        if curl -fsSL "${DEPLOY_CDN_URL}" | tar -xzf - -C "$INSTALL_DIR" 2>/dev/null; then
            # If tarball has top-level folder, flatten (e.g. worqlo-deploy-1.0.0/ -> .)
            TOPDIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d ! -path "$INSTALL_DIR" | head -1)
            if [ -n "$TOPDIR" ] && [ -f "$TOPDIR/docker-compose.ghcr.yml" ]; then
                mv "$TOPDIR"/* "$INSTALL_DIR"/ 2>/dev/null || true
                rmdir "$TOPDIR" 2>/dev/null || true
            fi
            log_success "Deploy bundle fetched"
        else
            log_error "Failed to download from ${DEPLOY_CDN_URL}"
            exit 1
        fi
    elif [ -n "${DEPLOY_TARBALL_URL:-}" ]; then
        # Option B: GitHub Releases tarball
        log_info "Downloading tarball..."
        if curl -fsSL "${DEPLOY_TARBALL_URL}" | tar -xzf - -C "$INSTALL_DIR" 2>/dev/null; then
            TOPDIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d ! -path "$INSTALL_DIR" | head -1)
            if [ -n "$TOPDIR" ] && [ -f "$TOPDIR/docker-compose.ghcr.yml" ]; then
                mv "$TOPDIR"/* "$INSTALL_DIR"/ 2>/dev/null || true
                rmdir "$TOPDIR" 2>/dev/null || true
            fi
            log_success "Deploy bundle fetched"
        else
            log_error "Failed to download from ${DEPLOY_TARBALL_URL}"
            exit 1
        fi
    else
        # Option A: Git clone
        if [ -d "$INSTALL_DIR/.git" ] && [ -f "$INSTALL_DIR/docker-compose.ghcr.yml" ]; then
            log_info "Updating existing clone..."
            (cd "$INSTALL_DIR" && git pull origin "${DEPLOY_BRANCH}" 2>/dev/null) || true
        else
            # Clone requires empty directory (or non-existent)
            if [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ] && [ ! -f "$INSTALL_DIR/docker-compose.ghcr.yml" ]; then
                log_error "$INSTALL_DIR exists and is not empty. Use a different directory:"
                log_error "  INSTALL_DIR=/tmp/worqlo-other curl -fsSL ... | bash"
                exit 1
            fi
            log_info "Cloning $DEPLOY_REPO..."
            CLONE_ERR=$(mktemp 2>/dev/null) || CLONE_ERR=""
            if ! git clone --depth 1 -b "${DEPLOY_BRANCH}" "https://github.com/${DEPLOY_REPO}.git" "$INSTALL_DIR" 2>"${CLONE_ERR:-/dev/null}"; then
                log_error "Failed to clone $DEPLOY_REPO."
                if [ -n "${CLONE_ERR:-}" ] && [ -s "$CLONE_ERR" ]; then
                    log_error "$(cat "$CLONE_ERR")"
                fi
                log_error "If $INSTALL_DIR exists with other content, use: INSTALL_DIR=/tmp/worqlo-other"
                exit 1
            fi
            log_success "Deploy bundle fetched"
        fi
    fi

    cd "$INSTALL_DIR"
}

# =============================================================================
# Step 4: Generate secrets
# =============================================================================
generate_config() {
    log_step "Generating configuration..."

    if [ ! -f "scripts/generate-secrets.sh" ]; then
        log_error "scripts/generate-secrets.sh not found"
        exit 1
    fi

    if [ -f .env ]; then
        log_info "Using existing .env (skipping secret generation)"
        chmod 600 .env
        return 0
    fi

    ./scripts/generate-secrets.sh > .env
    chmod 600 .env
    log_success "Secrets generated"
}

# Update or append a variable in .env (avoids duplicates on re-run; uses mktemp for security)
ensure_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" .env 2>/dev/null; then
        ENV_TMP_FILE=$(mktemp)
        grep -v "^${key}=" .env > "$ENV_TMP_FILE"
        echo "${key}=${value}" >> "$ENV_TMP_FILE"
        mv "$ENV_TMP_FILE" .env
        ENV_TMP_FILE=""
    else
        # Use printf to ensure newline before append (prevents concatenation when .env lacks trailing newline)
        printf '\n%s=%s\n' "$key" "$value" >> .env
    fi
}

# Apply BASE_URL to all URL-related env vars (for IP or domain access)
_apply_base_url() {
    local base="$1"
    base="${base%/}"  # strip trailing slash
    local scheme host port
    case "$base" in
        https://*)
            scheme="https"
            base="${base#https://}"
            ;;
        http://*)
            scheme="http"
            base="${base#http://}"
            ;;
        *)
            scheme="http"
            ;;
    esac
    if [[ "$base" == *:* ]]; then
        host="${base%%:*}"
        port="${base##*:}"
    else
        host="$base"
        port=""
    fi
    local ws_scheme="ws"
    [ "$scheme" = "https" ] && ws_scheme="wss"

    local base_with_port="$base"
    [ -n "$port" ] && base_with_port="${scheme}://${host}:${port}" || base_with_port="${scheme}://${host}"

    ensure_env "NEXT_PUBLIC_API_URL" "${base_with_port}/api"
    ensure_env "NEXT_PUBLIC_WEBSOCKET_URL" "${ws_scheme}://${host}${port:+:${port}}/ws}"
    ensure_env "NEXTAUTH_URL" "$base_with_port"
    ensure_env "FRONTEND_RESET_PASSWORD_URL" "${base_with_port}/reset-password"
    ensure_env "FRONTEND_LOGIN_URL" "$base_with_port"
    # CORS: base URL plus common variants (port 80, 3000)
    local cors_origins="${base_with_port}"
    [ -n "$host" ] && cors_origins="${base_with_port},${scheme}://${host}:80,${scheme}://${host}:3000"
    ensure_env "CORS_ALLOW_ORIGINS" "$cors_origins"
    ensure_env "S3_PUBLIC_ENDPOINT_URL" "http://${host}:9000"
    ensure_env "SALESFORCE_REDIRECT_URI" "${base_with_port}/integrations/salesforce/callback"
}

# =============================================================================
# Step 5: Configuration prompts (or use env vars for non-interactive)
# =============================================================================
prompt_config() {
    log_step "Configuration"

    # Load .env so we can use HTTP_PORT etc.
    if [ -f .env ]; then
        set +u
        set -a
        # shellcheck source=/dev/null
        source .env 2>/dev/null || true
        set +a
        set -u
    fi

    # Treat generate-secrets placeholders as unset so interactive prompts run
    case "${SGLANG_BASE_URL:-}" in *your-sglang-host*) unset SGLANG_BASE_URL ;; esac
    case "${OPENAI_API_KEY:-}" in *your-openai-api-key*) unset OPENAI_API_KEY ;; esac
    case "${GROK_API_KEY:-}" in *your-grok-api-key*) unset GROK_API_KEY ;; esac

    # GHCR_OWNER
    if [ -z "${GHCR_OWNER:-}" ]; then
        echo ""
        read -p "GitHub org/username for images (e.g. worqlo): " GHCR_OWNER </dev/tty
        if [ -z "$GHCR_OWNER" ]; then
            log_error "GHCR_OWNER is required"
            exit 1
        fi
    fi
    # IMAGE_TAG (prompt in interactive mode; default latest when no TTY)
    if [ -z "${IMAGE_TAG:-}" ]; then
        if [ -t 0 ]; then
            read -p "Image tag (latest or v1.0.0) [latest]: " IMAGE_TAG_INPUT </dev/tty
            IMAGE_TAG="${IMAGE_TAG_INPUT:-latest}"
        else
            IMAGE_TAG=latest
        fi
    fi

    # GHCR config (generate-secrets.sh does not output these; use ensure_env to avoid duplicates on re-run)
    ensure_env "GHCR_OWNER" "$GHCR_OWNER"
    ensure_env "GHCR_REGISTRY" "${GHCR_REGISTRY:-ghcr.io}"
    ensure_env "IMAGE_TAG" "${IMAGE_TAG:-latest}"

    # Access URL - how will users reach Worqlo? (localhost / IP / domain)
    if [ -n "${BASE_URL:-}" ]; then
        # Non-interactive: BASE_URL set (e.g. BASE_URL=http://192.168.1.100 curl ... | bash)
        _apply_base_url "$BASE_URL"
    elif [ -n "${DOMAIN:-}" ]; then
        # Non-interactive: DOMAIN set (e.g. DOMAIN=worqlo.company.com)
        _apply_base_url "https://${DOMAIN}"
    elif [ -t 0 ]; then
        echo ""
        echo "How will users access Worqlo?"
        echo "  [1] localhost (single machine, dev)"
        echo "  [2] IP address (network access, e.g. 192.168.1.100)"
        echo "  [3] Domain (e.g. worqlo.company.com)"
        read -p "Choice [1]: " ACCESS_CHOICE </dev/tty
        ACCESS_CHOICE=${ACCESS_CHOICE:-1}

        case $ACCESS_CHOICE in
            1)
                log_info "Using localhost (default)"
                ;;
            2)
                # Auto-detect primary IPv4 as suggestion (exclude loopback)
                SUGGESTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || \
                    ip route get 1 2>/dev/null | awk '{print $7; exit}' || \
                    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
                if [ -n "$SUGGESTED_IP" ]; then
                    read -p "Server IP address [$SUGGESTED_IP]: " IP_INPUT </dev/tty
                    IP_ADDR="${IP_INPUT:-$SUGGESTED_IP}"
                else
                    read -p "Server IP address (e.g. 192.168.1.100): " IP_ADDR </dev/tty
                fi
                if [ -z "$IP_ADDR" ]; then
                    log_error "IP address is required."
                    exit 1
                fi
                HTTP_PORT_VAL="${HTTP_PORT:-80}"
                if [ "$HTTP_PORT_VAL" = "80" ]; then
                    _apply_base_url "http://${IP_ADDR}"
                else
                    _apply_base_url "http://${IP_ADDR}:${HTTP_PORT_VAL}"
                fi
                ;;
            3)
                if [ -n "${DOMAIN:-}" ]; then
                    _apply_base_url "https://${DOMAIN}"
                else
                    read -p "Domain (e.g. worqlo.company.com): " DOMAIN_INPUT </dev/tty
                    if [ -z "$DOMAIN_INPUT" ]; then
                        log_error "Domain is required."
                        exit 1
                    fi
                    _apply_base_url "https://${DOMAIN_INPUT}"
                fi
                ;;
            *)
                log_error "Invalid choice"
                exit 1
                ;;
        esac
    fi

    # LLM provider
    if [ -z "${SGLANG_BASE_URL:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${GROK_API_KEY:-}" ] && [ -z "${OLLAMA_BASE_URL:-}" ] && [ "${LLM_PROVIDER:-}" != "ollama" ]; then
        if ! [ -t 0 ]; then
            # Non-interactive: default to SGLang, require SGLANG_BASE_URL
            log_error "No LLM config set. For non-interactive install, set SGLANG_BASE_URL+SGLANG_MODEL (default), OPENAI_API_KEY, or GROK_API_KEY."
            log_error "Example: SGLANG_BASE_URL=http://host:30000 SGLANG_MODEL=openai/gpt-oss-120b curl -fsSL ... | bash"
            exit 1
        else
        echo ""
        echo "Select LLM provider:"
        echo "  [1] SGLang (self-hosted, requires BASE_URL + MODEL)"
        echo "  [2] OpenAI (requires API key)"
        echo "  [3] Grok/xAI (requires API key)"
        echo "  [4] Ollama (local, no key needed)"
        read -p "Choice [1]: " LLM_CHOICE </dev/tty
        LLM_CHOICE=${LLM_CHOICE:-1}

        case $LLM_CHOICE in
            1)
                USE_OLLAMA_PROFILE=""
                sed -i.bak 's/^LLM_PROVIDER=.*/LLM_PROVIDER=sglang/' .env 2>/dev/null || sed -i '' 's/^LLM_PROVIDER=.*/LLM_PROVIDER=sglang/' .env
                read -p "SGLang base URL (e.g. http://host:30000): " SGLANG_BASE_URL </dev/tty
                read -p "SGLang model (e.g. openai/gpt-oss-120b): " SGLANG_MODEL </dev/tty
                if [ -z "$SGLANG_BASE_URL" ] || [ -z "$SGLANG_MODEL" ]; then
                    log_error "SGLANG_BASE_URL and SGLANG_MODEL are required"
                    exit 1
                fi
                ensure_env "SGLANG_BASE_URL" "$SGLANG_BASE_URL"
                ensure_env "SGLANG_MODEL" "$SGLANG_MODEL"
                ;;
            2)
                USE_OLLAMA_PROFILE=""
                sed -i.bak 's/^LLM_PROVIDER=.*/LLM_PROVIDER=openai/' .env 2>/dev/null || sed -i '' 's/^LLM_PROVIDER=.*/LLM_PROVIDER=openai/' .env
                read -p "OpenAI API key: " OPENAI_API_KEY </dev/tty
                if [ -z "$OPENAI_API_KEY" ]; then
                    log_error "OpenAI API key is required"
                    exit 1
                fi
                sed -i.bak "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$OPENAI_API_KEY|" .env 2>/dev/null || sed -i '' "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$OPENAI_API_KEY|" .env
                ;;
            3)
                USE_OLLAMA_PROFILE=""
                sed -i.bak 's/^LLM_PROVIDER=.*/LLM_PROVIDER=grok/' .env 2>/dev/null || sed -i '' 's/^LLM_PROVIDER=.*/LLM_PROVIDER=grok/' .env
                read -p "Grok API key: " GROK_API_KEY </dev/tty
                if [ -z "$GROK_API_KEY" ]; then
                    log_error "Grok API key is required"
                    exit 1
                fi
                sed -i.bak "s|^GROK_API_KEY=.*|GROK_API_KEY=$GROK_API_KEY|" .env 2>/dev/null || sed -i '' "s|^GROK_API_KEY=.*|GROK_API_KEY=$GROK_API_KEY|" .env
                ;;
            4)
                USE_OLLAMA_PROFILE="--profile ollama"
                sed -i.bak 's/^LLM_PROVIDER=.*/LLM_PROVIDER=ollama/' .env 2>/dev/null || sed -i '' 's/^LLM_PROVIDER=.*/LLM_PROVIDER=ollama/' .env
                log_info "Ollama selected (local LLM)"
                ;;
            *)
                log_error "Invalid choice"
                exit 1
                ;;
        esac
        rm -f .env.bak
        fi
    else
        # Non-interactive: env vars set (SGLang first as default)
        USE_OLLAMA_PROFILE=""
        if [ -n "${SGLANG_BASE_URL:-}" ]; then
            sed -i.bak 's/^LLM_PROVIDER=.*/LLM_PROVIDER=sglang/' .env 2>/dev/null || sed -i '' 's/^LLM_PROVIDER=.*/LLM_PROVIDER=sglang/' .env
            ensure_env "SGLANG_BASE_URL" "$SGLANG_BASE_URL"
            ensure_env "SGLANG_MODEL" "${SGLANG_MODEL:-openai/gpt-oss-120b}"
        elif [ -n "${OPENAI_API_KEY:-}" ]; then
            sed -i.bak 's/^LLM_PROVIDER=.*/LLM_PROVIDER=openai/' .env 2>/dev/null || sed -i '' 's/^LLM_PROVIDER=.*/LLM_PROVIDER=openai/' .env
            sed -i.bak "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$OPENAI_API_KEY|" .env 2>/dev/null || sed -i '' "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$OPENAI_API_KEY|" .env
        elif [ -n "${GROK_API_KEY:-}" ]; then
            sed -i.bak 's/^LLM_PROVIDER=.*/LLM_PROVIDER=grok/' .env 2>/dev/null || sed -i '' 's/^LLM_PROVIDER=.*/LLM_PROVIDER=grok/' .env
            sed -i.bak "s|^GROK_API_KEY=.*|GROK_API_KEY=$GROK_API_KEY|" .env 2>/dev/null || sed -i '' "s|^GROK_API_KEY=.*|GROK_API_KEY=$GROK_API_KEY|" .env
        elif [ -n "${OLLAMA_BASE_URL:-}" ] || [ "${LLM_PROVIDER:-}" = "ollama" ]; then
            USE_OLLAMA_PROFILE="--profile ollama"
            sed -i.bak 's/^LLM_PROVIDER=.*/LLM_PROVIDER=ollama/' .env 2>/dev/null || sed -i '' 's/^LLM_PROVIDER=.*/LLM_PROVIDER=ollama/' .env
        fi
        rm -f .env.bak
    fi

    # Observability (default Y when no TTY for non-interactive/curl|bash)
    if [ -z "${ENABLE_OBSERVABILITY:-}" ]; then
        if [ -t 0 ]; then
            read -p "Enable Grafana/Prometheus? [Y/n]: " ENABLE_OBSERVABILITY </dev/tty
            ENABLE_OBSERVABILITY=${ENABLE_OBSERVABILITY:-Y}
        else
            ENABLE_OBSERVABILITY=Y
        fi
    fi
}

# =============================================================================
# Step 6 & 7: Platform detection and deploy
# =============================================================================
deploy_services() {
    local compose_args profile_args arch os use_mac_override=false

    log_step "Starting services..."

    # Order per doc: base, observability, ghcr (so GHCR overrides images last)
    compose_args="-f docker-compose.yml"
    if [[ "${ENABLE_OBSERVABILITY:-Y}" =~ ^[Yy] ]] && [ -f "docker-compose.observability.yml" ]; then
        compose_args="$compose_args -f docker-compose.observability.yml"
    fi
    compose_args="$compose_args -f docker-compose.ghcr.yml"
    profile_args="${USE_OLLAMA_PROFILE:-}"

    # Apple Silicon: try native first; fallback to mac override if pull fails
    arch=$(uname -m)
    os=$(uname -s)
    if [ "$os" = "Darwin" ] && [ "$arch" = "arm64" ] && [ -f "docker-compose.ghcr.mac.yml" ]; then
        log_info "Apple Silicon detected; trying native arm64 first..."
        PULL_LOG_FILE=$(mktemp)
        if ( set -o pipefail 2>/dev/null; ! docker compose $compose_args $profile_args pull 2>&1 | tee "$PULL_LOG_FILE" ); then
            if grep -q "no matching manifest\|manifest unknown" "$PULL_LOG_FILE" 2>/dev/null; then
                log_info "arm64 manifest not found; using amd64 override"
                use_mac_override=true
                compose_args="$compose_args -f docker-compose.ghcr.mac.yml"
            else
                log_error "Pull failed"
                exit 1
            fi
        fi
    fi

    if [ "$use_mac_override" != "true" ]; then
        log_info "Pulling images from GHCR..."
        docker compose $compose_args $profile_args pull
    fi

    log_info "Starting containers..."
    docker compose $compose_args $profile_args up -d

    log_success "Services started"
}

# =============================================================================
# Step 8: Health check
# =============================================================================
wait_for_health() {
    log_step "Waiting for services..."

    if [ -f .env ]; then
        set +u
        set -a
        # shellcheck source=/dev/null
        source .env 2>/dev/null || true
        set +a
        set -u
    fi

    HEALTH_URL="http://localhost:${HTTP_PORT:-80}/health"
    for i in $(seq 1 60); do
        if curl -sf "$HEALTH_URL" 2>/dev/null | grep -q '"status"'; then
            if [ -n "${HTTP_PORT:-}" ] && [ "${HTTP_PORT:-}" != "80" ]; then
                log_success "Ready at http://localhost:${HTTP_PORT}"
            else
                log_success "Ready at http://localhost"
            fi
            return 0
        fi
        sleep 2
        echo -n "."
    done
    echo ""
    log_warning "Health check timed out (services may still be starting)"
}

# =============================================================================
# Step 9: Post-install summary
# =============================================================================
print_summary() {
    if [ -f .env ]; then
        set +u
        set -a
        # shellcheck source=/dev/null
        source .env 2>/dev/null || true
        set +a
        set -u
    fi
    DISPLAY_URL="http://localhost"
    if [ -n "${NEXTAUTH_URL:-}" ] && [ "${NEXTAUTH_URL:-}" != "http://localhost" ]; then
        DISPLAY_URL="$NEXTAUTH_URL"
    elif [ -n "${DOMAIN:-}" ]; then
        DISPLAY_URL="https://${DOMAIN}"
    elif [ -n "${HTTP_PORT:-}" ] && [ "${HTTP_PORT:-}" != "80" ]; then
        DISPLAY_URL="http://localhost:${HTTP_PORT}"
    fi
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Worqlo installed successfully!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  URL:      $DISPLAY_URL"
    echo "  Location: $INSTALL_DIR"
    echo "  Update:   cd $INSTALL_DIR && ./scripts/update-ghcr.sh"
    LOGS_FILES="-f docker-compose.yml"
    [[ "${ENABLE_OBSERVABILITY:-Y}" =~ ^[Yy] ]] && [ -f "docker-compose.observability.yml" ] && LOGS_FILES="$LOGS_FILES -f docker-compose.observability.yml"
    echo "  Logs:     docker compose $LOGS_FILES -f docker-compose.ghcr.yml logs -f api"
    echo ""
}

# =============================================================================
# Help
# =============================================================================
show_help() {
    echo "Worqlo Hosted Installer (GHCR)"
    echo ""
    echo "Usage: curl -fsSL https://get.worqlo.ai/install.sh | bash"
    echo "       bash install.sh [--help]"
    echo ""
    echo "Options:"
    echo "  --help    Show this help"
    echo ""
    echo "Environment variables (non-interactive):"
    echo "  GHCR_OWNER, IMAGE_TAG, BASE_URL, DOMAIN, SGLANG_BASE_URL, SGLANG_MODEL,"
    echo "  OPENAI_API_KEY, GROK_API_KEY, ENABLE_OBSERVABILITY, INSTALL_DIR, DEPLOY_REPO,"
    echo "  DEPLOY_BRANCH, DEPLOY_TARBALL_URL, DEPLOY_CDN_URL"
    echo ""
    echo "Best practice: curl -fsSL URL -o install.sh && less install.sh && bash install.sh"
}

# =============================================================================
# Main
# =============================================================================
main() {
    [[ "${1:-}" = "--help" ]] || [[ "${1:-}" = "-h" ]] && { show_help; exit 0; }
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Worqlo Hosted Installer (GHCR)                           ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"

    check_prerequisites
    fetch_deploy_bundle
    cd "$INSTALL_DIR"
    generate_config
    prompt_config
    deploy_services
    wait_for_health
    print_summary
}

main "$@"
