#!/usr/bin/env bash
# =============================================================================
# Shared utilities for Worqlo deploy scripts
# =============================================================================
# Sourced by install.sh and setup-ssl.sh.
# Set ENV_FILE before sourcing to control which .env is modified (default: .env)
# =============================================================================

: "${ENV_FILE:=.env}"

# Update or append a variable in the .env file (avoids duplicates on re-run)
ensure_env() {
    local key="$1" value="$2"
    [ ! -f "$ENV_FILE" ] && return
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
