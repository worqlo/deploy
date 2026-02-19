#!/bin/bash
# =============================================================================
# Worqlo SSL/TLS Setup with Let's Encrypt
# =============================================================================
# This script sets up free SSL certificates using Let's Encrypt
# Certificates are valid for 90 days and auto-renewed
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="${1:-}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"  # strip path if present
EMAIL="${2:-}"
SKIP_CONFIRM="${SKIP_CONFIRM:-}"  # Set to non-empty to skip "Continue?" prompt (e.g. when called from install)
# Use INSTALL_DIR when passed from install.sh; otherwise derive from script location
DEPLOY_DIR="${INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SSL_DIR="${DEPLOY_DIR}/nginx/ssl"
CERTBOT_DIR="${DEPLOY_DIR}/certbot"

# Functions
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

show_usage() {
    cat << EOF
${BLUE}=============================================================================
  Worqlo SSL/TLS Setup
=============================================================================${NC}

${YELLOW}Usage:${NC}
  $0 <domain> <email>

${YELLOW}Example:${NC}
  $0 app.yourdomain.com admin@yourdomain.com

${YELLOW}What this script does:${NC}
  1. Validates prerequisites (Docker, domain DNS)
  2. Creates necessary directories
  3. Obtains SSL certificate from Let's Encrypt
  4. Configures nginx for HTTPS
  5. Sets up automatic certificate renewal

${YELLOW}Prerequisites:${NC}
  • Docker and Docker Compose installed
  • Domain DNS pointing to this server (A record)
  • Ports 80 and 443 accessible from the internet
  • Email address for Let's Encrypt notifications

${YELLOW}After setup:${NC}
  • Access your app at: https://<domain>
  • Certificates auto-renew every 60 days
  • Check renewal status: docker run --rm -v certbot/conf:/etc/letsencrypt certbot/certbot certificates

EOF
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    # Check if docker compose is available
    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose is not available. Please install Docker Compose first."
        exit 1
    fi
    
    # Load .env for ENABLE_OBSERVABILITY and HTTP_PORT (needed for health check)
    if [ -f "${DEPLOY_DIR}/.env" ]; then
        set +u
        set -a
        # shellcheck source=/dev/null
        source "${DEPLOY_DIR}/.env" 2>/dev/null || true
        set +a
        set -u
    fi

    # Check if worqlo stack is running (retry: containers may take a moment after compose up)
    # Use health endpoint - more reliable than docker compose ps when .env is sourced
    # (sourcing .env can cause docker compose to fail in subshells on some systems)
    local max_attempts=5
    local attempt=1
    local stack_running=false
    local health_port="${HTTP_PORT:-80}"
    while [ "$attempt" -le "$max_attempts" ]; do
        if curl -sf "http://localhost:${health_port}/health" 2>/dev/null | grep -q '"status"'; then
            stack_running=true
            break
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            log_info "Waiting for Worqlo stack... (attempt $attempt/$max_attempts)"
            sleep 3
        fi
        attempt=$((attempt + 1))
    done
    if [ "$stack_running" != "true" ]; then
        log_error "Worqlo stack is not running. Please start it first:"
        echo "  cd ${DEPLOY_DIR}"
        echo "  docker compose up -d"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Validate domain DNS
validate_domain() {
    local domain=$1
    log_info "Validating DNS for ${domain}..."
    
    # Get public IP of this server
    local server_ip=$(curl -s https://api.ipify.org)
    
    # Get DNS resolution of domain
    local domain_ip=$(dig +short "$domain" A | head -n1)
    
    if [ -z "$domain_ip" ]; then
        log_error "Domain ${domain} does not resolve to any IP address"
        echo ""
        echo "Please configure your DNS:"
        echo "  Type: A"
        echo "  Name: ${domain}"
        echo "  Value: ${server_ip}"
        echo ""
        echo "Wait for DNS propagation (can take up to 24 hours) and try again."
        exit 1
    fi
    
    if [ "$domain_ip" != "$server_ip" ]; then
        log_warn "Domain ${domain} resolves to ${domain_ip}, but this server is ${server_ip}"
        echo ""
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_success "DNS validation passed: ${domain} -> ${server_ip}"
    fi
}

# Create directories
setup_directories() {
    log_info "Creating SSL directories..."
    
    mkdir -p "${SSL_DIR}"
    mkdir -p "${CERTBOT_DIR}/conf"
    mkdir -p "${CERTBOT_DIR}/www"
    
    log_success "Directories created"
}

# Obtain certificate
obtain_certificate() {
    local domain=$1
    local email=$2
    
    log_info "Obtaining SSL certificate from Let's Encrypt..."
    log_info "This may take a few minutes..."
    
    # Run certbot to obtain certificate (webroot mode - nginx serves ACME challenge)
    docker run --rm \
        --name certbot-temp \
        -v "${CERTBOT_DIR}/conf:/etc/letsencrypt" \
        -v "${CERTBOT_DIR}/www:/var/www/certbot" \
        -v "${SSL_DIR}:/etc/nginx/ssl" \
        certbot/certbot \
        certonly \
        --webroot \
        -w /var/www/certbot \
        --preferred-challenges http \
        --agree-tos \
        --no-eff-email \
        --email "${email}" \
        -d "${domain}" \
        --non-interactive
    
    if [ $? -eq 0 ]; then
        log_success "Certificate obtained successfully!"
        
        # Copy certificates to nginx ssl directory
        log_info "Copying certificates to nginx directory..."
        docker run --rm \
            -v "${CERTBOT_DIR}/conf:/etc/letsencrypt" \
            -v "${SSL_DIR}:/ssl" \
            alpine:latest \
            sh -c "cp /etc/letsencrypt/live/${domain}/fullchain.pem /ssl/ && \
                   cp /etc/letsencrypt/live/${domain}/privkey.pem /ssl/ && \
                   cp /etc/letsencrypt/live/${domain}/chain.pem /ssl/ && \
                   chmod 644 /ssl/*.pem"
        
        log_success "Certificates copied"
    else
        log_error "Failed to obtain certificate"
        echo ""
        echo "Common issues:"
        echo "  • Port 80 is not accessible from the internet"
        echo "  • Domain DNS is not pointing to this server"
        echo "  • Firewall is blocking incoming connections"
        exit 1
    fi
}

# Shared utilities (ensure_env, etc.)
ENV_FILE="${DEPLOY_DIR}/.env"
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Configure nginx for SSL and persist NGINX_CONF in .env
configure_nginx() {
    local domain=$1
    
    log_info "Configuring nginx for HTTPS..."
    
    # Determine which nginx config to use based on observability
    local nginx_conf
    if [ -f "${DEPLOY_DIR}/.env" ]; then
        set +u
        set -a
        # shellcheck source=/dev/null
        source "${DEPLOY_DIR}/.env" 2>/dev/null || true
        set +a
        set -u
    fi
    if [[ "${ENABLE_OBSERVABILITY:-}" =~ ^[Yy] ]] && [ -f "${DEPLOY_DIR}/nginx/nginx-with-grafana-ssl.conf" ]; then
        nginx_conf="./nginx/nginx-with-grafana-ssl.conf"
    else
        nginx_conf="./nginx/nginx-ssl.conf"
    fi
    
    # Update server_name in the selected config
    sed -i.bak "s/server_name _;/server_name ${domain};/" "${DEPLOY_DIR}/${nginx_conf#./}"
    
    # Persist NGINX_CONF in .env (docker-compose loads .env)
    ensure_env "NGINX_CONF" "$nginx_conf"
    
    # Update base URL env vars for HTTPS
    ensure_env "NEXT_PUBLIC_API_URL" "https://${domain}/api"
    ensure_env "NEXT_PUBLIC_WEBSOCKET_URL" "wss://${domain}/ws"
    ensure_env "NEXTAUTH_URL" "https://${domain}"
    ensure_env "S3_PUBLIC_ENDPOINT_URL" "https://${domain}/s3"
    ensure_env "FRONTEND_RESET_PASSWORD_URL" "https://${domain}/reset-password"
    ensure_env "FRONTEND_LOGIN_URL" "https://${domain}"
    ensure_env "SALESFORCE_REDIRECT_URI" "https://${domain}/integrations/salesforce/callback"
    ensure_env "HUBSPOT_REDIRECT_URI" "https://${domain}/integrations/hubspot/callback"
    ensure_env "GRAFANA_ROOT_URL" "https://${domain}/grafana/"
    ensure_env "GRAFANA_CSRF_TRUSTED_ORIGINS" "${domain}"
    ensure_env "GRAFANA_COOKIE_SECURE" "true"
    
    log_success "Nginx configured for HTTPS"
}

# Setup auto-renewal
setup_renewal() {
    log_info "Setting up automatic certificate renewal..."
    
    # Create renewal script (DOMAIN interpolated)
    local domain="$1"
    cat > "${DEPLOY_DIR}/scripts/renew-cert.sh" << EOF
#!/bin/bash
# Auto-renewal script for Let's Encrypt certificates
# Run this via cron: 0 3 * * * /path/to/renew-cert.sh

DEPLOY_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
CERTBOT_DIR="\${DEPLOY_DIR}/certbot"
SSL_DIR="\${DEPLOY_DIR}/nginx/ssl"

docker run --rm \\
    -v "\${CERTBOT_DIR}/conf:/etc/letsencrypt" \\
    -v "\${CERTBOT_DIR}/www:/var/www/certbot" \\
    certbot/certbot renew --quiet

# Copy renewed certs to nginx and reload
if [ \$? -eq 0 ]; then
    docker run --rm \\
        -v "\${CERTBOT_DIR}/conf:/etc/letsencrypt" \\
        -v "\${SSL_DIR}:/ssl" \\
        alpine:latest \\
        sh -c "cp /etc/letsencrypt/live/${domain}/fullchain.pem /ssl/ && \\
               cp /etc/letsencrypt/live/${domain}/privkey.pem /ssl/ && \\
               cp /etc/letsencrypt/live/${domain}/chain.pem /ssl/"
    docker exec worqlo-nginx nginx -s reload
fi
EOF
    
    chmod +x "${DEPLOY_DIR}/scripts/renew-cert.sh"
    
    log_success "Renewal script created at: ${DEPLOY_DIR}/scripts/renew-cert.sh"
    echo ""
    echo "To enable automatic renewal, add this to your crontab:"
    echo "  0 3 * * * ${DEPLOY_DIR}/scripts/renew-cert.sh"
}

# Restart services with full down/up so NGINX_CONF from .env is picked up
restart_services() {
    log_info "Restarting services with SSL configuration..."
    
    cd "${DEPLOY_DIR}"
    
    # Load .env for compose file selection
    if [ -f .env ]; then
        set +u
        set -a
        # shellcheck source=/dev/null
        source .env 2>/dev/null || true
        set +a
        set -u
    fi
    
    # Build compose args (match deploy_services logic)
    local compose_args="-f docker-compose.yml"
    if [[ "${ENABLE_OBSERVABILITY:-Y}" =~ ^[Yy] ]] && [ -f "docker-compose.observability.yml" ]; then
        compose_args="$compose_args -f docker-compose.observability.yml"
    fi
    if [ -f "docker-compose.ghcr.yml" ]; then
        compose_args="$compose_args -f docker-compose.ghcr.yml"
    fi
    
    docker compose $compose_args down
    docker compose $compose_args up -d
    
    log_success "Stack restarted with SSL configuration"
}

# Main
main() {
    echo ""
    echo -e "${BLUE}=============================================================================${NC}"
    echo -e "${BLUE}  Worqlo SSL/TLS Setup${NC}"
    echo -e "${BLUE}=============================================================================${NC}"
    echo ""
    
    # Check arguments
    if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
        show_usage
        exit 1
    fi
    
    # Validate email format
    if ! echo "$EMAIL" | grep -E "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$" > /dev/null; then
        log_error "Invalid email format: $EMAIL"
        exit 1
    fi
    
    echo "Domain: ${DOMAIN}"
    echo "Email:  ${EMAIL}"
    echo ""
    
    # Confirm (skip when SKIP_CONFIRM is set, e.g. from install.sh)
    if [ -z "$SKIP_CONFIRM" ]; then
        read -p "Continue with SSL setup? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Setup cancelled"
            exit 0
        fi
    fi
    
    # Run setup steps
    check_prerequisites
    validate_domain "$DOMAIN"
    setup_directories
    obtain_certificate "$DOMAIN" "$EMAIL"
    configure_nginx "$DOMAIN"
    setup_renewal "$DOMAIN"
    restart_services
    
    echo ""
    echo -e "${GREEN}=============================================================================${NC}"
    echo -e "${GREEN}  SSL/TLS Setup Complete!${NC}"
    echo -e "${GREEN}=============================================================================${NC}"
    echo ""
    echo "Your Worqlo instance is now secured with HTTPS!"
    echo ""
    echo "• URL: https://${DOMAIN}"
    echo "• Certificate expires in 90 days"
    echo "• Auto-renewal: ${DEPLOY_DIR}/scripts/renew-cert.sh"
    echo ""
    echo "Next steps:"
    echo "  1. Test your site: https://${DOMAIN}"
    echo "  2. Set up auto-renewal cron job (see above)"
    echo ""
}

main
