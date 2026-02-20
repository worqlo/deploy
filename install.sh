#!/usr/bin/env bash
# =============================================================================
# Worqlo Hosted Installer (GHCR)
# =============================================================================
# One-line install using pre-built Docker images from GitHub Container Registry.
# Usage: curl -fsSL https://raw.githubusercontent.com/worqlo/deploy/main/install.sh | bash
#
# Non-interactive: OPENAI_API_KEY=sk-... DOMAIN=app.example.com curl -fsSL ... | bash
#
# Best practice: Review script before running:
#   curl -fsSL https://raw.githubusercontent.com/worqlo/deploy/main/install.sh -o install.sh && less install.sh && bash install.sh
# =============================================================================

set -euo pipefail

# Cleanup temp files on exit (industry standard: trap for resource cleanup)
cleanup() {
    local exit_code=$?
    [[ -n "${PULL_LOG_FILE:-}" ]] && rm -f "$PULL_LOG_FILE"
    [[ -n "${CLONE_ERR:-}" ]] && rm -f "$CLONE_ERR"
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# Install directory
if [ "$(uname)" = "Darwin" ]; then
    INSTALL_DIR="${INSTALL_DIR:-/tmp/worqlo}"
else
    INSTALL_DIR="${INSTALL_DIR:-/opt/worqlo}"
fi

# Try to source lib.sh early (available when running from deploy directory)
if [[ -f "scripts/lib.sh" ]]; then
    source scripts/lib.sh
elif [[ -n "${INSTALL_DIR:-}" ]] && [[ -f "${INSTALL_DIR}/scripts/lib.sh" ]]; then
    source "${INSTALL_DIR}/scripts/lib.sh"
fi
# Bootstrap fallback: minimal colors/logging before deploy bundle is fetched
if [[ -z "${_WORQLO_LIB_LOADED:-}" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
    log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
    log_success() { echo -e "${GREEN}✓${NC} $1"; }
    log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
    log_error()   { echo -e "${RED}✗${NC} $1"; }
    log_step()    { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }
fi

# Deploy bundle source
# - clone (default): DEPLOY_REPO, DEPLOY_BRANCH
# - tarball: DEPLOY_TARBALL_URL (e.g. https://github.com/worqlo/deploy/releases/download/v1.0.0/worqlo-deploy.tar.gz)
# - cdn: DEPLOY_CDN_URL (e.g. https://cdn.worqlo.ai/deploy/v1.0.0.tar.gz)
DEPLOY_REPO="${DEPLOY_REPO:-worqlo/deploy}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"

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
    # Fallback to $HOME when INSTALL_DIR is root (e.g. /opt) or empty
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

# =============================================================================
# Step 5: Configuration prompts (or use env vars for non-interactive)
# =============================================================================
prompt_config() {
    log_step "Configuration"

    load_env

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

    # LLM provider - ask first when interactive, then collect provider-specific config
    if [ -t 0 ]; then
        echo ""
        echo "Select LLM provider:"
        echo "  [1] OpenAI (requires API key)"
        echo "  [2] SGLang (self-hosted, requires URL + model)"
        echo "  [3] Grok/xAI (requires API key)"
        echo "  [4] Ollama (local, no key needed)"
        read -p "Choice [1]: " LLM_CHOICE </dev/tty
        LLM_CHOICE=${LLM_CHOICE:-1}

        case $LLM_CHOICE in
            1)
                USE_OLLAMA_PROFILE=""
                ensure_env "LLM_PROVIDER" "openai"
                read -p "OpenAI API key: " OPENAI_API_KEY </dev/tty
                if [ -z "$OPENAI_API_KEY" ]; then
                    log_error "OpenAI API key is required"
                    exit 1
                fi
                ensure_env "OPENAI_API_KEY" "$OPENAI_API_KEY"
                ;;
            2)
                USE_OLLAMA_PROFILE=""
                ensure_env "LLM_PROVIDER" "sglang"
                read -p "SGLang base URL (e.g. http://192.168.0.2:30000): " SGLANG_BASE_URL </dev/tty
                read -p "SGLang model (e.g. openai/gpt-oss-120b) [openai/gpt-oss-120b]: " SGLANG_MODEL_INPUT </dev/tty
                SGLANG_MODEL="${SGLANG_MODEL_INPUT:-openai/gpt-oss-120b}"
                if [ -z "$SGLANG_BASE_URL" ]; then
                    log_error "SGLANG_BASE_URL is required"
                    exit 1
                fi
                ensure_env "SGLANG_BASE_URL" "$SGLANG_BASE_URL"
                ensure_env "SGLANG_MODEL" "$SGLANG_MODEL"
                # Embedding config for SGLang
                echo ""
                echo "  Embedding server (for Knowledge Base vector search):"
                echo "    If you have a separate SGLang embedding server, enter its URL."
                echo "    Otherwise, press Enter to use OpenAI embeddings (requires OPENAI_API_KEY)."
                read -p "  Embedding server URL (e.g. http://192.168.0.2:30001/v1) [skip]: " KB_EMBED_URL_INPUT </dev/tty
                if [ -n "$KB_EMBED_URL_INPUT" ]; then
                    ensure_env "KB_EMBEDDING_PROVIDER" "sglang"
                    ensure_env "KB_EMBEDDING_BASE_URL" "$KB_EMBED_URL_INPUT"
                    read -p "  Embedding model [Qwen/Qwen3-Embedding-4B]: " KB_EMBED_MODEL_INPUT </dev/tty
                    ensure_env "KB_EMBEDDING_MODEL" "${KB_EMBED_MODEL_INPUT:-Qwen/Qwen3-Embedding-4B}"
                    read -p "  Embedding dimensions [2560]: " KB_EMBED_DIM_INPUT </dev/tty
                    KB_EMBED_DIM_INPUT="${KB_EMBED_DIM_INPUT:-2560}"
                    if ! [[ "$KB_EMBED_DIM_INPUT" =~ ^[0-9]+$ ]]; then
                        log_error "Embedding dimensions must be a positive integer (got: $KB_EMBED_DIM_INPUT)"
                        exit 1
                    fi
                    ensure_env "KB_EMBEDDING_DIMENSIONS" "$KB_EMBED_DIM_INPUT"
                else
                    ensure_env "KB_EMBEDDING_PROVIDER" "openai"
                    read -p "  OpenAI API key (for embeddings): " OPENAI_API_KEY_FOR_EMBED </dev/tty
                    if [ -n "$OPENAI_API_KEY_FOR_EMBED" ]; then
                        ensure_env "OPENAI_API_KEY" "$OPENAI_API_KEY_FOR_EMBED"
                    else
                        log_warning "No OpenAI API key provided — set OPENAI_API_KEY in .env before using Knowledge Base"
                    fi
                fi
                ;;
            3)
                USE_OLLAMA_PROFILE=""
                ensure_env "LLM_PROVIDER" "grok"
                read -p "Grok API key: " GROK_API_KEY </dev/tty
                if [ -z "$GROK_API_KEY" ]; then
                    log_error "Grok API key is required"
                    exit 1
                fi
                ensure_env "GROK_API_KEY" "$GROK_API_KEY"
                ;;
            4)
                USE_OLLAMA_PROFILE="--profile ollama"
                ensure_env "LLM_PROVIDER" "ollama"
                log_info "Ollama selected (local LLM)"
                ;;
            *)
                log_error "Invalid choice"
                exit 1
                ;;
        esac
    else
        # Non-interactive: require env vars
        if [ -z "${SGLANG_BASE_URL:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${GROK_API_KEY:-}" ] && [ "${LLM_PROVIDER:-}" != "ollama" ]; then
            log_error "No LLM config set. For non-interactive install, set OPENAI_API_KEY (default), SGLANG_BASE_URL+SGLANG_MODEL, or GROK_API_KEY."
            log_error "Example: OPENAI_API_KEY=sk-... curl -fsSL ... | bash"
            exit 1
        fi
        USE_OLLAMA_PROFILE=""
        if [ -n "${OPENAI_API_KEY:-}" ]; then
            ensure_env "LLM_PROVIDER" "openai"
            ensure_env "OPENAI_API_KEY" "$OPENAI_API_KEY"
        elif [ -n "${SGLANG_BASE_URL:-}" ]; then
            ensure_env "LLM_PROVIDER" "sglang"
            ensure_env "SGLANG_BASE_URL" "$SGLANG_BASE_URL"
            ensure_env "SGLANG_MODEL" "${SGLANG_MODEL:-openai/gpt-oss-120b}"
            # Non-interactive embedding config: KB_EMBEDDING_BASE_URL=http://host:30001/v1
            if [ -n "${KB_EMBEDDING_BASE_URL:-}" ]; then
                ensure_env "KB_EMBEDDING_PROVIDER" "sglang"
                ensure_env "KB_EMBEDDING_BASE_URL" "$KB_EMBEDDING_BASE_URL"
                ensure_env "KB_EMBEDDING_MODEL" "${KB_EMBEDDING_MODEL:-Qwen/Qwen3-Embedding-4B}"
                ensure_env "KB_EMBEDDING_DIMENSIONS" "${KB_EMBEDDING_DIMENSIONS:-2560}"
            fi
        elif [ -n "${GROK_API_KEY:-}" ]; then
            ensure_env "LLM_PROVIDER" "grok"
            ensure_env "GROK_API_KEY" "$GROK_API_KEY"
        elif [ -n "${OLLAMA_BASE_URL:-}" ] || [ "${LLM_PROVIDER:-}" = "ollama" ]; then
            USE_OLLAMA_PROFILE="--profile ollama"
            ensure_env "LLM_PROVIDER" "ollama"
        fi
    fi

    # Access URL - how will users reach Worqlo? (localhost / IP / domain)
    if [ -n "${BASE_URL:-}" ]; then
        # Non-interactive: BASE_URL set (e.g. BASE_URL=http://192.168.1.100 curl ... | bash)
        _apply_base_url "$BASE_URL"
        [[ "$BASE_URL" != https://* ]] && log_warning "OAuth (HubSpot/Salesforce) requires a domain with HTTPS."
    elif [ -n "${DOMAIN:-}" ]; then
        # Non-interactive: DOMAIN set (e.g. DOMAIN=worqlo.company.com or DOMAIN=https://...)
        DOMAIN_FOR_SSL="${DOMAIN#https://}"
        DOMAIN_FOR_SSL="${DOMAIN_FOR_SSL#http://}"
        DOMAIN_FOR_SSL="${DOMAIN_FOR_SSL%%/*}"
        _apply_base_url "https://${DOMAIN_FOR_SSL}"
        ensure_env "DOMAIN" "$DOMAIN_FOR_SSL"
    elif [ -t 0 ]; then
        SUGGESTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || \
            ip route get 1 2>/dev/null | awk '{print $7; exit}' || \
            ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
        echo ""
        echo "How will users access Worqlo?"
        echo "  [1] Domain (recommended, e.g. worqlo.company.com)"
        echo "  [2] IP address (network access, e.g. 192.168.1.100)"
        echo "  [3] localhost (single machine, dev only)"
        read -p "Choice [1]: " ACCESS_CHOICE </dev/tty
        ACCESS_CHOICE=${ACCESS_CHOICE:-1}

        case $ACCESS_CHOICE in
            1)
                if [ -n "${DOMAIN:-}" ]; then
                    DOMAIN_FOR_SSL="$(_strip_scheme_and_path "$DOMAIN")"
                    _apply_base_url "https://${DOMAIN_FOR_SSL}"
                else
                    read -p "Domain (e.g. worqlo.company.com): " DOMAIN_INPUT </dev/tty
                    if [ -z "$DOMAIN_INPUT" ]; then
                        log_error "Domain is required."
                        exit 1
                    fi
                    DOMAIN_FOR_SSL="$(_strip_scheme_and_path "$DOMAIN_INPUT")"
                    _apply_base_url "https://${DOMAIN_FOR_SSL}"
                fi
                ensure_env "DOMAIN" "$DOMAIN_FOR_SSL"
                log_success "URLs configured for https://${DOMAIN_FOR_SSL}"
                grep -q "^NEXTAUTH_URL=.*${DOMAIN_FOR_SSL}" .env 2>/dev/null || log_warning "NEXTAUTH_URL may not have updated. Run docker compose from: $(pwd)"
                if [ -t 0 ]; then
                    read -p "Set up HTTPS now? (required for OAuth integrations) [Y/n]: " SSL_YN </dev/tty
                    if [[ "${SSL_YN:-Y}" =~ ^[Yy] ]]; then
                        DO_SSL_SETUP=1
                        read -p "Email for Let's Encrypt notifications: " SSL_EMAIL </dev/tty
                        if [ -z "$SSL_EMAIL" ]; then
                            log_error "Email is required for Let's Encrypt"
                            exit 1
                        fi
                    else
                        log_info "To enable HTTPS later: cd $INSTALL_DIR && ./scripts/setup-ssl.sh $DOMAIN_FOR_SSL <email>"
                    fi
                fi
                ;;
            2)
                if [ -n "${SUGGESTED_IP:-}" ]; then
                    read -p "Server IP address [$SUGGESTED_IP]: " IP_INPUT </dev/tty
                    IP_ADDR="${IP_INPUT:-$SUGGESTED_IP}"
                else
                    read -p "Server IP address (e.g. 192.168.1.100): " IP_ADDR </dev/tty
                fi
                IP_ADDR="$(_strip_scheme_and_path "$IP_ADDR")"
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
                log_success "URLs configured for http://${IP_ADDR}${HTTP_PORT_VAL:+:${HTTP_PORT_VAL}}"
                log_warning "OAuth (HubSpot/Salesforce) requires a domain with HTTPS. Using an IP will limit OAuth integrations."
                ;;
            3)
                log_info "Using localhost (dev mode)"
                log_warning "OAuth (HubSpot/Salesforce) requires a domain with HTTPS. Localhost will limit OAuth integrations."
                HTTP_PORT_VAL="${HTTP_PORT:-80}"
                if [ "$HTTP_PORT_VAL" = "80" ]; then
                    _apply_base_url "http://localhost"
                else
                    _apply_base_url "http://localhost:${HTTP_PORT_VAL}"
                fi
                ;;
            *)
                log_error "Invalid choice"
                exit 1
                ;;
        esac
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
    ensure_env "ENABLE_OBSERVABILITY" "$ENABLE_OBSERVABILITY"
}

# =============================================================================
# Step 6 & 7: Platform detection and deploy
# =============================================================================
deploy_services() {
    local compose_args profile_args arch os use_mac_override=false

    log_step "Starting services..."

    # Ensure certbot/www exists for ACME challenges (nginx volume mount)
    mkdir -p ./certbot/www

    compose_args=$(build_compose_args)
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

    log_info "Pulling images from GHCR..."
    docker compose $compose_args $profile_args pull

    log_info "Starting containers..."
    docker compose $compose_args $profile_args up -d

    log_success "Services started"
}

# =============================================================================
# Step 8: Health check
# =============================================================================
wait_for_health() {
    load_env
    log_step "Waiting for services (up to 2 min)..."
    wait_healthy 60 || log_warning "Services may still be starting. Check: docker compose $(build_compose_args) ps"
}

# =============================================================================
# Step 8b: Configure host-level nginx (if present)
# =============================================================================
configure_host_nginx() {
    # Skip on macOS (development only, no host nginx expected)
    [ "$(uname)" = "Darwin" ] && return 0

    # Detect host-level nginx (not the Dockerized one)
    local nginx_bin=""
    if [ -x /usr/sbin/nginx ]; then
        nginx_bin="/usr/sbin/nginx"
    elif command -v nginx &>/dev/null; then
        nginx_bin=$(command -v nginx)
    fi
    [ -z "$nginx_bin" ] && return 0

    local nginx_conf="/etc/nginx/nginx.conf"
    [ -f "$nginx_conf" ] || return 0

    log_step "Host nginx detected ($nginx_bin) - checking configuration..."

    local needs_reload=false

    # Check client_max_body_size in http block
    if grep -qE '^\s*client_max_body_size' "$nginx_conf" 2>/dev/null; then
        local current_size
        current_size=$(grep -oE 'client_max_body_size[[:space:]]+[0-9]+[mMkKgG]?' "$nginx_conf" | head -1 | awk '{print $2}')
        log_info "Host nginx client_max_body_size is: ${current_size:-default (1M)}"

        # Parse to bytes for comparison (anything < 50M needs updating)
        local size_bytes=0
        case "${current_size}" in
            *[gG]) size_bytes=$(( ${current_size%[gG]} * 1073741824 )) ;;
            *[mM]) size_bytes=$(( ${current_size%[mM]} * 1048576 )) ;;
            *[kK]) size_bytes=$(( ${current_size%[kK]} * 1024 )) ;;
            *)     size_bytes=$(( current_size )) 2>/dev/null || size_bytes=0 ;;
        esac

        if [ "$size_bytes" -lt 52428800 ] 2>/dev/null; then
            log_warning "Host nginx client_max_body_size ($current_size) is below 50M - updating..."
            sed -i.bak "s/client_max_body_size[[:space:]]*[0-9][0-9]*[mMkKgG]*/client_max_body_size 50M/" "$nginx_conf"
            needs_reload=true
        else
            log_success "Host nginx client_max_body_size is sufficient ($current_size)"
        fi
    else
        log_warning "Host nginx has no client_max_body_size set (defaults to 1M) - adding 50M..."
        # Insert client_max_body_size inside the http block, after the opening brace
        sed -i.bak '/^http[[:space:]]*{/a\    client_max_body_size 50M;' "$nginx_conf"
        needs_reload=true
    fi

    if [ "$needs_reload" = true ]; then
        # Validate config before reload
        if $nginx_bin -t 2>/dev/null; then
            if systemctl is-active --quiet nginx 2>/dev/null; then
                systemctl reload nginx
                log_success "Host nginx reloaded with client_max_body_size 50M"
            elif service nginx status &>/dev/null; then
                service nginx reload
                log_success "Host nginx reloaded with client_max_body_size 50M"
            else
                log_warning "Host nginx config updated but could not reload automatically. Run: nginx -s reload"
            fi
        else
            log_error "Host nginx config test failed after modification. Restoring backup..."
            [ -f "${nginx_conf}.bak" ] && mv "${nginx_conf}.bak" "$nginx_conf"
        fi
    fi
}

# =============================================================================
# Step 9: Post-install summary
# =============================================================================
print_summary() {
    load_env
    DISPLAY_URL="http://localhost"
    if [ -n "${NEXTAUTH_URL:-}" ] && [ "${NEXTAUTH_URL:-}" != "http://localhost" ]; then
        DISPLAY_URL="$NEXTAUTH_URL"
    elif [ -n "${DOMAIN:-}" ]; then
        DOMAIN_STRIP="${DOMAIN#https://}"
        DOMAIN_STRIP="${DOMAIN_STRIP#http://}"
        DISPLAY_URL="https://${DOMAIN_STRIP}"
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
    echo ""
    echo "  Commands (from $INSTALL_DIR):"
    echo "    worqloctl status    - Show service status"
    echo "    worqloctl update    - Update to latest version"
    echo "    worqloctl logs -f   - Stream logs"
    echo "    worqloctl backup    - Create a backup"
    echo "    worqloctl ssl       - Set up HTTPS"
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
    echo "Canonical: https://get.worqlo.ai/install.sh (redirects to GitHub raw)"
    echo ""
    echo "Options:"
    echo "  --help    Show this help"
    echo ""
    echo "Environment variables (non-interactive):"
    echo "  GHCR_OWNER, IMAGE_TAG, DOMAIN, BASE_URL, OPENAI_API_KEY, SGLANG_BASE_URL,"
    echo "  SGLANG_MODEL, KB_EMBEDDING_BASE_URL, GROK_API_KEY, ENABLE_OBSERVABILITY,"
    echo "  INSTALL_DIR, DEPLOY_REPO, DEPLOY_BRANCH, DEPLOY_TARBALL_URL, DEPLOY_CDN_URL"
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
    echo -e "${CYAN}║     Worqlo Hosted Installer (GHCR)                            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"

    check_prerequisites
    fetch_deploy_bundle
    cd "$INSTALL_DIR"
    # shellcheck source=scripts/lib.sh
    source scripts/lib.sh
    generate_config
    prompt_config
    deploy_services
    wait_for_health
    configure_host_nginx
    if [ -n "${DO_SSL_SETUP:-}" ] && [ -n "${DOMAIN_FOR_SSL:-}" ] && [ -n "${SSL_EMAIL:-}" ]; then
        log_step "Setting up SSL with Let's Encrypt..."
        INSTALL_DIR="$INSTALL_DIR" SKIP_CONFIRM=1 ./scripts/setup-ssl.sh "$DOMAIN_FOR_SSL" "$SSL_EMAIL" || true
    fi

    # Write VERSION file for tracking
    cat > "$INSTALL_DIR/VERSION" <<VEOF
deploy_rev=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
image_tag=${IMAGE_TAG:-latest}
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VEOF

    # Symlink worqloctl into PATH (Linux only; macOS users run from deploy dir)
    if [ "$(uname)" != "Darwin" ] && [ -d /usr/local/bin ]; then
        ln -sf "$INSTALL_DIR/scripts/worqloctl" /usr/local/bin/worqloctl 2>/dev/null || true
    fi

    print_summary
}

main "$@"
