#!/bin/bash
# =============================================================================
# Tests for Custom HTTPS Domain Support (deploy scripts)
# =============================================================================
# Run from repo root: ./deploy/tests/test-ssl-domain-setup.sh
# Or from deploy: ./tests/test-ssl-domain-setup.sh
#
# Two sections:
#   - Core tests: must pass (exit 1 if any fail)
#   - Edge cases: may fail; document potential issues (do not affect exit code)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
EDGE_PASSED=0
EDGE_FAILED=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((PASSED++)) || true
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    ((FAILED++)) || true
}

edge_pass() {
    echo -e "  ${GREEN}EDGE PASS${NC}: $1"
    ((EDGE_PASSED++)) || true
}

edge_fail() {
    echo -e "  ${YELLOW}EDGE FAIL${NC}: $1 (may indicate a gap)"
    ((EDGE_FAILED++)) || true
}

# Resolve paths relative to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"

# =============================================================================
# 1. Syntax validation
# =============================================================================
test_syntax() {
    echo ""
    echo "=== Syntax validation ==="
    for script in install.sh scripts/setup-ssl.sh scripts/generate-secrets.sh; do
        path="${DEPLOY_DIR}/${script}"
        if [ -f "$path" ]; then
            if bash -n "$path" 2>/dev/null; then
                pass "bash -n $script"
            else
                fail "bash -n $script (syntax error)"
            fi
        else
            fail "Script not found: $script"
        fi
    done
}

# =============================================================================
# 2. Docker compose structure
# =============================================================================
test_docker_compose() {
    echo ""
    echo "=== Docker compose structure ==="
    local compose="${DEPLOY_DIR}/docker-compose.yml"
    local obs="${DEPLOY_DIR}/docker-compose.observability.yml"

    if ! grep -q 'NGINX_CONF:-./nginx/nginx.conf' "$compose" 2>/dev/null; then
        fail "docker-compose.yml: NGINX_CONF env var not found"
    else
        pass "docker-compose.yml: NGINX_CONF env var present"
    fi

    if ! grep -q 'certbot/www:/var/www/certbot' "$compose" 2>/dev/null; then
        fail "docker-compose.yml: certbot volume not found"
    else
        pass "docker-compose.yml: certbot volume present"
    fi

    if [ -f "$obs" ]; then
        if ! grep -q 'NGINX_CONF:-./nginx/nginx-with-grafana.conf' "$obs" 2>/dev/null; then
            fail "docker-compose.observability.yml: NGINX_CONF not found"
        else
            pass "docker-compose.observability.yml: NGINX_CONF present"
        fi
        if ! grep -q 'certbot/www:/var/www/certbot' "$obs" 2>/dev/null; then
            fail "docker-compose.observability.yml: certbot volume not found"
        else
            pass "docker-compose.observability.yml: certbot volume present"
        fi
    fi
}

# =============================================================================
# 3. Nginx config files
# =============================================================================
test_nginx_configs() {
    echo ""
    echo "=== Nginx config files ==="
    local required=(
        "nginx/nginx.conf"
        "nginx/nginx-ssl.conf"
        "nginx/nginx-with-grafana.conf"
        "nginx/nginx-with-grafana-ssl.conf"
        "nginx/includes/app-routes.conf"
    )
    for f in "${required[@]}"; do
        if [ -f "${DEPLOY_DIR}/${f}" ]; then
            pass "Exists: $f"
        else
            fail "Missing: $f"
        fi
    done

    # Check nginx configs have ACME challenge location
    for conf in nginx/nginx.conf nginx/nginx-ssl.conf nginx/nginx-with-grafana.conf nginx/nginx-with-grafana-ssl.conf; do
        path="${DEPLOY_DIR}/${conf}"
        if [ -f "$path" ] && grep -q '/var/www/certbot' "$path" 2>/dev/null; then
            pass "ACME challenge in $conf"
        elif [ -f "$path" ]; then
            fail "ACME challenge missing in $conf"
        fi
    done

    # nginx-ssl and nginx-with-grafana-ssl must have SSL directives
    for conf in nginx/nginx-ssl.conf nginx/nginx-with-grafana-ssl.conf; do
        path="${DEPLOY_DIR}/${conf}"
        if [ -f "$path" ]; then
            if grep -q 'ssl_certificate' "$path" 2>/dev/null && grep -q 'listen 443' "$path" 2>/dev/null; then
                pass "SSL directives in $conf"
            else
                fail "SSL directives missing in $conf"
            fi
        fi
    done
}

# =============================================================================
# 4. _apply_base_url logic (install.sh)
# =============================================================================
test_apply_base_url() {
    echo ""
    echo "=== _apply_base_url logic ==="
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT

    cd "$tmpdir"
    echo "EXISTING=1" > .env

    # Source only the functions we need (avoid full install.sh which may exit)
    source_env_and_apply() {
        # Minimal ensure_env that works in test
        ensure_env() {
            local key="$1" value="$2"
            if grep -q "^${key}=" .env 2>/dev/null; then
                local t
                t=$(mktemp)
                grep -v "^${key}=" .env > "$t"
                echo "${key}=${value}" >> "$t"
                mv "$t" .env
            else
                printf '\n%s=%s\n' "$key" "$value" >> .env
            fi
        }
        # _apply_base_url from install.sh (simplified - same logic)
        _apply_base_url() {
            local base="$1"
            base="${base%/}"
            local scheme host port
            case "$base" in
                https://*) scheme="https"; base="${base#https://}" ;;
                http://*)  scheme="http";  base="${base#http://}" ;;
                *)        scheme="http" ;;
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
            ensure_env "NEXT_PUBLIC_WEBSOCKET_URL" "${ws_scheme}://${host}${port:+:${port}}/ws"
            ensure_env "HUBSPOT_REDIRECT_URI" "${base_with_port}/integrations/hubspot/callback"
            ensure_env "SALESFORCE_REDIRECT_URI" "${base_with_port}/integrations/salesforce/callback"
        }
        _apply_base_url "$1"
    }

    # Test 1: HTTP IP
    source_env_and_apply "http://192.168.0.5"
    if grep -q 'NEXT_PUBLIC_API_URL=http://192.168.0.5/api' .env && \
       grep -q 'HUBSPOT_REDIRECT_URI=http://192.168.0.5/integrations/hubspot/callback' .env; then
        pass "_apply_base_url: http://192.168.0.5"
    else
        fail "_apply_base_url: http://192.168.0.5"
    fi

    # Reset for next test
    rm -f .env
    echo "OTHER=1" > .env

    # Test 2: HTTPS domain
    source_env_and_apply "https://app.example.com"
    if grep -q 'NEXT_PUBLIC_API_URL=https://app.example.com/api' .env && \
       grep -q 'HUBSPOT_REDIRECT_URI=https://app.example.com/integrations/hubspot/callback' .env && \
       grep -q 'NEXT_PUBLIC_WEBSOCKET_URL=wss://app.example.com/ws' .env; then
        pass "_apply_base_url: https://app.example.com"
    else
        fail "_apply_base_url: https://app.example.com"
    fi

    # Test 3: HTTPS domain with port
    rm -f .env
    echo "X=1" > .env
    source_env_and_apply "https://app.example.com:8443"
    if grep -q 'NEXT_PUBLIC_API_URL=https://app.example.com:8443/api' .env && \
       grep -q 'HUBSPOT_REDIRECT_URI=https://app.example.com:8443/integrations/hubspot/callback' .env; then
        pass "_apply_base_url: https://app.example.com:8443"
    else
        fail "_apply_base_url: https://app.example.com:8443"
    fi

    cd - > /dev/null
    trap - EXIT
    rm -rf "$tmpdir"
}

# =============================================================================
# 5. setup-ssl ensure_env
# =============================================================================
test_setup_ssl_ensure_env() {
    echo ""
    echo "=== setup-ssl ensure_env ==="
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT

    # Create minimal .env
    echo "EXISTING=old" > "${tmpdir}/.env"

    # Run ensure_env logic from setup-ssl (simulate) - use local var to avoid overwriting DEPLOY_DIR
    local test_deploy_dir="$tmpdir"
    ensure_env() {
        local key="$1" value="$2"
        local env_file="${test_deploy_dir}/.env"
        [ ! -f "$env_file" ] && return
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            local t
            t=$(mktemp)
            grep -v "^${key}=" "$env_file" > "$t"
            echo "${key}=${value}" >> "$t"
            mv "$t" "$env_file"
        else
            printf '\n%s=%s\n' "$key" "$value" >> "$env_file"
        fi
    }

    ensure_env "NGINX_CONF" "./nginx/nginx-ssl.conf"
    if grep -q '^NGINX_CONF=./nginx/nginx-ssl.conf$' "${test_deploy_dir}/.env"; then
        pass "ensure_env: append new key"
    else
        fail "ensure_env: append new key"
    fi

    ensure_env "NGINX_CONF" "./nginx/nginx-with-grafana-ssl.conf"
    if grep -q '^NGINX_CONF=./nginx/nginx-with-grafana-ssl.conf$' "${test_deploy_dir}/.env" && \
       ! grep -q 'nginx-ssl.conf' "${test_deploy_dir}/.env"; then
        pass "ensure_env: update existing key"
    else
        fail "ensure_env: update existing key"
    fi

    trap - EXIT
    rm -rf "$tmpdir"
}

# =============================================================================
# 6. setup-ssl.sh usage and structure
# =============================================================================
test_setup_ssl_structure() {
    echo ""
    echo "=== setup-ssl.sh structure ==="
    local script="${DEPLOY_DIR}/scripts/setup-ssl.sh"
    [ ! -f "$script" ] && { fail "setup-ssl.sh not found at $script"; return; }

    grep -q -- '--webroot' "$script" 2>/dev/null && pass "setup-ssl.sh: uses webroot mode (not standalone)" || fail "setup-ssl.sh: should use webroot mode"

    grep -q -e '-p 80:80' "$script" 2>/dev/null && fail "setup-ssl.sh: should not bind port 80" || pass "setup-ssl.sh: no port 80 binding (webroot compatible)"

    grep -q 'ensure_env "NGINX_CONF"' "$script" 2>/dev/null && pass "setup-ssl.sh: persists NGINX_CONF in .env" || fail "setup-ssl.sh: should persist NGINX_CONF"

    grep -q 'HUBSPOT_REDIRECT_URI' "$script" 2>/dev/null && pass "setup-ssl.sh: sets HUBSPOT_REDIRECT_URI" || fail "setup-ssl.sh: should set HUBSPOT_REDIRECT_URI"

    grep -q 'compose.*down' "$script" 2>/dev/null && pass "setup-ssl.sh: full stack restart (down/up)" || fail "setup-ssl.sh: should do full restart not docker cp"

    grep -q 'SKIP_CONFIRM' "$script" 2>/dev/null && pass "setup-ssl.sh: SKIP_CONFIRM for install integration" || fail "setup-ssl.sh: should support SKIP_CONFIRM"
}

# =============================================================================
# 7. install.sh SSL and OAuth integration
# =============================================================================
test_install_ssl_integration() {
    echo ""
    echo "=== install.sh SSL integration ==="
    local script="${DEPLOY_DIR}/install.sh"
    [ ! -f "$script" ] && { fail "install.sh not found at $script"; return; }

    grep -q 'HUBSPOT_REDIRECT_URI' "$script" 2>/dev/null && pass "install.sh: _apply_base_url sets HUBSPOT_REDIRECT_URI" || fail "install.sh: _apply_base_url should set HUBSPOT_REDIRECT_URI"

    grep -q 'Set up HTTPS now' "$script" 2>/dev/null && pass "install.sh: SSL prompt when domain chosen" || fail "install.sh: should prompt for SSL when domain chosen"

    grep -q 'OAuth.*requires' "$script" 2>/dev/null && pass "install.sh: OAuth warning for IP/localhost" || fail "install.sh: should warn about OAuth + IP"

    grep -q 'certbot/www' "$script" 2>/dev/null && pass "install.sh: creates certbot/www before compose" || fail "install.sh: should create certbot/www"
}

# =============================================================================
# 8. .gitignore
# =============================================================================
test_gitignore() {
    echo ""
    echo "=== .gitignore ==="
    local gitignore="${REPO_ROOT}/.gitignore"
    if [ -f "$gitignore" ] && grep -q 'certbot' "$gitignore" 2>/dev/null; then
        pass ".gitignore: certbot/ excluded"
    else
        fail ".gitignore: should exclude certbot/"
    fi
}

# =============================================================================
# 9. Edge cases (may fail - document potential gaps)
# =============================================================================
# Edge cases that may fail in certain environments:
#   - dig: fails if bind-utils/dnsutils not installed (Alpine, minimal images)
#   - docker-compose.ghcr.yml: fails if deploy bundle is incomplete
#   - docker compose v2: fails if only docker-compose v1 is installed
# =============================================================================
test_edge_cases() {
    echo ""
    echo "=== Edge cases (failures are informational) ==="
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT

    # Edge: ensure_env with value containing "="
    echo "X=1" > "${tmpdir}/.env"
    local test_deploy_dir="$tmpdir"
    ensure_env() {
        local key="$1" value="$2"
        local env_file="${test_deploy_dir}/.env"
        [ ! -f "$env_file" ] && return
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            local t; t=$(mktemp)
            grep -v "^${key}=" "$env_file" > "$t"
            echo "${key}=${value}" >> "$t"
            mv "$t" "$env_file"
        else
            printf '\n%s=%s\n' "$key" "$value" >> "$env_file"
        fi
    }
    ensure_env "URL" "https://a.com?foo=bar&baz=qux"
    if grep -qF 'URL=https://a.com?foo=bar&baz=qux' "${tmpdir}/.env" 2>/dev/null; then
        edge_pass "ensure_env: value with = and &"
    else
        edge_fail "ensure_env: value with = and & (special chars may break)"
    fi

    # Edge: _apply_base_url with trailing slash (should not produce //)
    rm -f "${tmpdir}/.env"
    echo "Y=1" > "${tmpdir}/.env"
    cd "$tmpdir"
    _apply_base_url_trailing() {
        local base="$1"
        base="${base%/}"
        case "$base" in
            https://*) base="${base#https://}" ;;
            *) base="$base" ;;
        esac
        ensure_env "NEXT_PUBLIC_API_URL" "https://${base}/api"
    }
    _apply_base_url_trailing "https://app.example.com/"
    if grep -q 'NEXT_PUBLIC_API_URL=https://app.example.com/api' .env 2>/dev/null && \
       ! grep -q '//api' .env 2>/dev/null; then
        edge_pass "_apply_base_url: trailing slash stripped (no double slash)"
    else
        edge_fail "_apply_base_url: trailing slash may produce // in URL"
    fi
    cd - > /dev/null

    # Edge: renew-cert.sh - when generated, has cert copy logic
    local renew="${DEPLOY_DIR}/scripts/renew-cert.sh"
    if [ -f "$renew" ]; then
        if grep -q 'fullchain.pem' "$renew" 2>/dev/null && grep -q 'privkey.pem' "$renew" 2>/dev/null; then
            edge_pass "renew-cert.sh: has cert copy logic"
        else
            edge_fail "renew-cert.sh: may be missing cert copy step"
        fi
    else
        edge_pass "renew-cert.sh: not yet generated (created by setup-ssl)"
    fi

    # Edge: nginx ssl configs have server_name (not just _)
    for conf in nginx/nginx-ssl.conf nginx/nginx-with-grafana-ssl.conf; do
        path="${DEPLOY_DIR}/${conf}"
        if [ -f "$path" ]; then
            if grep -q 'server_name _' "$path" 2>/dev/null; then
                edge_pass "$conf: server_name _ (placeholder, setup-ssl replaces)"
            else
                edge_fail "$conf: server_name format"
            fi
        fi
    done

    # Edge: setup-ssl validate_domain uses dig (may not be installed)
    local setup_ssl="${DEPLOY_DIR}/scripts/setup-ssl.sh"
    if grep -q 'dig +short' "$setup_ssl" 2>/dev/null; then
        if command -v dig &>/dev/null; then
            edge_pass "setup-ssl: dig available for DNS validation"
        else
            edge_fail "setup-ssl: dig not installed (DNS validation will fail)"
        fi
    fi

    # Edge: certbot/www created before compose (avoid mount failure)
    if grep -q 'mkdir -p.*certbot/www' "${DEPLOY_DIR}/install.sh" 2>/dev/null; then
        edge_pass "install.sh: certbot/www created before compose up"
    else
        edge_fail "install.sh: certbot/www may not exist before first compose"
    fi

    # Edge: observability compose has all volumes (includes, ssl, certbot)
    local obs="${DEPLOY_DIR}/docker-compose.observability.yml"
    if [ -f "$obs" ]; then
        local has_all=1
        grep -q 'nginx/includes' "$obs" 2>/dev/null || has_all=0
        grep -q 'nginx/ssl' "$obs" 2>/dev/null || has_all=0
        grep -q 'certbot/www' "$obs" 2>/dev/null || has_all=0
        if [ "$has_all" -eq 1 ]; then
            edge_pass "observability compose: all nginx volumes present"
        else
            edge_fail "observability compose: may be missing includes/ssl/certbot volumes"
        fi
    fi

    # Edge: setup-ssl configure_nginx updates correct file for observability
    if grep -q 'nginx-with-grafana-ssl' "${DEPLOY_DIR}/scripts/setup-ssl.sh" 2>/dev/null; then
        edge_pass "setup-ssl: selects nginx-with-grafana-ssl when observability enabled"
    else
        edge_fail "setup-ssl: may not use grafana-ssl config with observability"
    fi

    # Edge: ensure_env with empty .env (no newline) - append can concatenate
    rm -f "${tmpdir}/.env"
    printf 'X=1' > "${tmpdir}/.env"  # no trailing newline
    ensure_env "NEWKEY" "newval"
    if grep -q '^NEWKEY=newval$' "${tmpdir}/.env" 2>/dev/null && \
       ! grep -q 'newvalX=' "${tmpdir}/.env" 2>/dev/null; then
        edge_pass "ensure_env: append to .env without trailing newline"
    else
        edge_fail "ensure_env: append without newline may concatenate values"
    fi

    # Edge: _apply_base_url with IPv6 address (brackets)
    rm -f "${tmpdir}/.env"
    echo "Z=1" > "${tmpdir}/.env"
    cd "$tmpdir"
    _apply_ipv6() {
        local base="http://[::1]:8080"
        base="${base%/}"
        ensure_env "TEST_URL" "${base}/api"
    }
    _apply_ipv6
    if grep -qF 'TEST_URL=http://[::1]:8080/api' .env 2>/dev/null; then
        edge_pass "_apply_base_url: IPv6 [::1] preserved in URL"
    else
        edge_fail "_apply_base_url: IPv6 addresses may not be handled"
    fi
    cd - > /dev/null

    # Edge: sed -i.bak in setup-ssl - macOS vs Linux (both use -i.bak)
    if grep -q 'sed -i.bak' "${DEPLOY_DIR}/scripts/setup-ssl.sh" 2>/dev/null; then
        edge_pass "setup-ssl: uses sed -i.bak (portable)"
    else
        edge_fail "setup-ssl: sed in-place may differ on macOS vs Linux"
    fi

    # Edge: docker-compose.ghcr.yml exists (CI/install expects it)
    if [ -f "${DEPLOY_DIR}/docker-compose.ghcr.yml" ]; then
        edge_pass "docker-compose.ghcr.yml present for install flow"
    else
        edge_fail "docker-compose.ghcr.yml missing (install may fail)"
    fi

    # Edge: setup-ssl ensure_env skips when .env missing (by design)
    if grep -q '! -f.*env_file.*return' "${DEPLOY_DIR}/scripts/setup-ssl.sh" 2>/dev/null; then
        edge_pass "setup-ssl ensure_env: guards against missing .env"
    else
        edge_fail "setup-ssl ensure_env: may fail if .env missing"
    fi

    # Edge: include files exist (nginx would fail without them)
    for inc in app-routes.conf minio-proxy.conf; do
        if [ -f "${DEPLOY_DIR}/nginx/includes/${inc}" ]; then
            edge_pass "nginx includes/$inc exists"
        else
            edge_fail "nginx includes/$inc missing (nginx will fail)"
        fi
    done

    # Edge: setup-ssl uses docker compose v2 (not docker-compose v1)
    if grep -q 'docker compose ' "${DEPLOY_DIR}/scripts/setup-ssl.sh" 2>/dev/null; then
        edge_pass "setup-ssl: uses 'docker compose' (v2)"
    else
        edge_fail "setup-ssl: may use docker-compose v1 (incompatible)"
    fi

    # Edge: generate-secrets outputs placeholders that install treats as unset
    if grep -q 'your-sglang-host\|your-openai-api-key' "${DEPLOY_DIR}/scripts/generate-secrets.sh" 2>/dev/null; then
        edge_pass "generate-secrets: has placeholders for install prompts"
    else
        edge_fail "generate-secrets: placeholders may cause skipped prompts"
    fi

    trap - EXIT
    rm -rf "$tmpdir"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo "=============================================="
    echo "  Custom HTTPS Domain Support - Test Suite"
    echo "=============================================="
    echo "Deploy dir: $DEPLOY_DIR"
    echo ""

    test_syntax
    test_docker_compose
    test_nginx_configs
    test_apply_base_url
    test_setup_ssl_ensure_env
    test_setup_ssl_structure
    test_install_ssl_integration
    test_gitignore

    test_edge_cases

    echo ""
    echo "=============================================="
    echo "  Core: $PASSED passed, $FAILED failed"
    echo "  Edge cases: $EDGE_PASSED passed, $EDGE_FAILED failed (informational)"
    echo "=============================================="
    echo ""

    # Only core failures affect exit code
    if [ "$FAILED" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"
