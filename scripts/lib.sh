#!/usr/bin/env bash
# =============================================================================
# Shared utilities for Worqlo deploy scripts
# =============================================================================
# Sourced by install.sh, setup-ssl.sh, update-ghcr.sh, backup.sh, etc.
#
# Conventions:
#   - Set ENV_FILE before sourcing to control which .env is modified (default: .env)
#   - DEPLOY_DIR is auto-detected from the sourcing script's location
# =============================================================================

# Avoid double-sourcing
[[ -n "${_WORQLO_LIB_LOADED:-}" ]] && return 0
_WORQLO_LIB_LOADED=1

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
if [[ -t 2 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m'
    readonly BOLD='\033[1m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC='' BOLD=''
fi

# -----------------------------------------------------------------------------
# Logging (icon-based, consistent across all scripts)
# -----------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }

# Aliases used by some scripts
log_warn() { log_warning "$@"; }

# -----------------------------------------------------------------------------
# Path defaults
# -----------------------------------------------------------------------------
: "${ENV_FILE:=.env}"

# Auto-detect DEPLOY_DIR from the sourcing script's location.
# BASH_SOURCE[0] = lib.sh, BASH_SOURCE[1] = the script that sourced lib.sh.
# install.sh overrides DEPLOY_DIR via INSTALL_DIR before sourcing.
if [[ -z "${DEPLOY_DIR:-}" ]]; then
    if [[ -n "${INSTALL_DIR:-}" ]]; then
        DEPLOY_DIR="$INSTALL_DIR"
    elif [[ -n "${BASH_SOURCE[1]:-}" ]]; then
        DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
    else
        DEPLOY_DIR="$(pwd)"
    fi
fi

# -----------------------------------------------------------------------------
# ensure_env - Update or append a variable in the .env file
# -----------------------------------------------------------------------------
ensure_env() {
    local key="$1" value="$2"
    [[ ! -f "$ENV_FILE" ]] && return
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        grep -v "^${key}=" "$ENV_FILE" > "$tmp"
        echo "${key}=${value}" >> "$tmp"
        mv "$tmp" "$ENV_FILE"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

# -----------------------------------------------------------------------------
# load_env - Safely source a .env file (handles unset vars)
# -----------------------------------------------------------------------------
load_env() {
    local f="${1:-$ENV_FILE}"
    [[ ! -f "$f" ]] && return 0
    set +u
    set -a
    # shellcheck source=/dev/null
    source "$f" 2>/dev/null || true
    set +a
    set -u
}

# -----------------------------------------------------------------------------
# sed_inplace - Portable in-place sed (GNU Linux vs BSD macOS)
# Usage: sed_inplace 's/foo/bar/' file.txt
# -----------------------------------------------------------------------------
sed_inplace() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# -----------------------------------------------------------------------------
# build_compose_args - Build the docker compose -f chain
# Reads ENABLE_OBSERVABILITY from env; appends ghcr overlay if present.
# Usage: local args; args=$(build_compose_args)
# -----------------------------------------------------------------------------
build_compose_args() {
    local args="-f docker-compose.yml"
    if [[ "${ENABLE_OBSERVABILITY:-Y}" =~ ^[Yy] ]] && [[ -f "${DEPLOY_DIR}/docker-compose.observability.yml" ]]; then
        args="$args -f docker-compose.observability.yml"
    fi
    if [[ -f "${DEPLOY_DIR}/docker-compose.ghcr.yml" ]]; then
        args="$args -f docker-compose.ghcr.yml"
    fi
    echo "$args"
}

# -----------------------------------------------------------------------------
# wait_healthy - Poll health endpoint until ready
# Usage: wait_healthy [max_attempts]   (default 60, 2s between = 2 min)
# -----------------------------------------------------------------------------
wait_healthy() {
    local max="${1:-60}"
    local url="http://localhost:${HTTP_PORT:-80}/health"

    for i in $(seq 1 "$max"); do
        if curl -sf --connect-timeout 5 "$url" 2>/dev/null | grep -q '"status"'; then
            log_success "Healthy: $url"
            return 0
        fi
        sleep 2
        printf "."
        [[ "$(( i % 15 ))" -eq 0 ]] && echo " ${i}/${max}"
    done
    echo ""
    log_warning "Health check timed out after ${max} attempts: $url"
    return 1
}

# -----------------------------------------------------------------------------
# _strip_scheme_and_path - Strip http(s):// and path from a URL
# -----------------------------------------------------------------------------
_strip_scheme_and_path() {
    local d="${1:-}"
    d="${d#https://}"
    d="${d#http://}"
    echo "${d%%/*}"
}

# -----------------------------------------------------------------------------
# _apply_base_url - Set all URL-related env vars from a base URL
# Usage: _apply_base_url "https://app.example.com"
# -----------------------------------------------------------------------------
_apply_base_url() {
    local base="$1"
    base="${base%/}"
    local scheme host port
    case "$base" in
        https://*) scheme="https"; base="${base#https://}" ;;
        http://*)  scheme="http";  base="${base#http://}" ;;
        *)         scheme="http" ;;
    esac
    if [[ "$base" == *:* ]]; then
        host="${base%%:*}"
        port="${base##*:}"
    else
        host="$base"
        port=""
    fi
    local ws_scheme="ws"
    [[ "$scheme" = "https" ]] && ws_scheme="wss"

    local base_with_port
    [[ -n "$port" ]] && base_with_port="${scheme}://${host}:${port}" || base_with_port="${scheme}://${host}"

    ensure_env "NEXT_PUBLIC_API_URL" "${base_with_port}/api"
    ensure_env "NEXT_PUBLIC_WEBSOCKET_URL" "${ws_scheme}://${host}${port:+:${port}}/ws"
    ensure_env "NEXTAUTH_URL" "$base_with_port"
    ensure_env "FRONTEND_RESET_PASSWORD_URL" "${base_with_port}/reset-password"
    ensure_env "FRONTEND_LOGIN_URL" "$base_with_port"

    local cors_origins="${base_with_port}"
    if [[ "$scheme" = "http" ]] && [[ -n "$host" ]]; then
        cors_origins="${base_with_port},${scheme}://${host}:80,${scheme}://${host}:3000"
    fi
    ensure_env "CORS_ALLOW_ORIGINS" "$cors_origins"

    if [[ "$scheme" = "https" ]]; then
        ensure_env "S3_PUBLIC_ENDPOINT_URL" "https://${host}/s3"
    else
        ensure_env "S3_PUBLIC_ENDPOINT_URL" "http://${host}:9000"
    fi
    ensure_env "SALESFORCE_REDIRECT_URI" "${base_with_port}/integrations/salesforce/callback"
    ensure_env "HUBSPOT_REDIRECT_URI" "${base_with_port}/integrations/hubspot/callback"
    ensure_env "GRAFANA_ROOT_URL" "${base_with_port}/grafana/"
    ensure_env "GRAFANA_CSRF_TRUSTED_ORIGINS" "${host}"
    if [[ "$scheme" = "https" ]]; then
        ensure_env "GRAFANA_COOKIE_SECURE" "true"
    else
        ensure_env "GRAFANA_COOKIE_SECURE" "false"
    fi
}
