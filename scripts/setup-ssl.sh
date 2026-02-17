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
EMAIL="${2:-}"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  • Check renewal status: docker compose exec certbot certbot certificates

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
    
    # Check if worqlo stack is running
    if ! docker ps | grep -q worqlo-nginx; then
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
    
    # Run certbot to obtain certificate
    docker run --rm \
        --name certbot-temp \
        -v "${CERTBOT_DIR}/conf:/etc/letsencrypt" \
        -v "${CERTBOT_DIR}/www:/var/www/certbot" \
        -v "${SSL_DIR}:/etc/nginx/ssl" \
        -p 80:80 \
        certbot/certbot \
        certonly \
        --standalone \
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

# Configure nginx for SSL
configure_nginx() {
    local domain=$1
    
    log_info "Configuring nginx for HTTPS..."
    
    # Update server_name in nginx-ssl.conf
    sed -i.bak "s/server_name _;/server_name ${domain};/" "${DEPLOY_DIR}/nginx/nginx-ssl.conf"
    
    # Update docker-compose to use SSL config
    log_info "Updating docker-compose.yml to use SSL configuration..."
    
    cat > "${DEPLOY_DIR}/.env.ssl" << EOF
# SSL Configuration
NGINX_CONF=./nginx/nginx-ssl.conf
EOF
    
    log_success "Nginx configured for HTTPS"
}

# Setup auto-renewal
setup_renewal() {
    log_info "Setting up automatic certificate renewal..."
    
    # Create renewal script
    cat > "${DEPLOY_DIR}/scripts/renew-cert.sh" << 'EOF'
#!/bin/bash
# Auto-renewal script for Let's Encrypt certificates
# Run this via cron: 0 3 * * * /path/to/renew-cert.sh

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTBOT_DIR="${DEPLOY_DIR}/certbot"

docker run --rm \
    -v "${CERTBOT_DIR}/conf:/etc/letsencrypt" \
    -v "${CERTBOT_DIR}/www:/var/www/certbot" \
    certbot/certbot renew --quiet

# Reload nginx if certificates were renewed
if [ $? -eq 0 ]; then
    docker exec worqlo-nginx nginx -s reload
fi
EOF
    
    chmod +x "${DEPLOY_DIR}/scripts/renew-cert.sh"
    
    log_success "Renewal script created at: ${DEPLOY_DIR}/scripts/renew-cert.sh"
    echo ""
    echo "To enable automatic renewal, add this to your crontab:"
    echo "  0 3 * * * ${DEPLOY_DIR}/scripts/renew-cert.sh"
}

# Restart services
restart_services() {
    log_info "Restarting services with SSL configuration..."
    
    # Update nginx volume mount in docker-compose
    cd "${DEPLOY_DIR}"
    
    # Restart nginx with new config
    docker cp "${DEPLOY_DIR}/nginx/nginx-ssl.conf" worqlo-nginx:/etc/nginx/nginx.conf
    docker exec worqlo-nginx nginx -t
    
    if [ $? -eq 0 ]; then
        docker exec worqlo-nginx nginx -s reload
        log_success "Nginx reloaded with SSL configuration"
    else
        log_error "Nginx configuration test failed"
        exit 1
    fi
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
    
    # Confirm
    read -p "Continue with SSL setup? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Setup cancelled"
        exit 0
    fi
    
    # Run setup steps
    check_prerequisites
    validate_domain "$DOMAIN"
    setup_directories
    obtain_certificate "$DOMAIN" "$EMAIL"
    configure_nginx "$DOMAIN"
    setup_renewal
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
    echo "  1. Update your .env file:"
    echo "     NEXT_PUBLIC_API_URL=https://${DOMAIN}/api"
    echo "     NEXT_PUBLIC_WEBSOCKET_URL=wss://${DOMAIN}/ws"
    echo "     NEXTAUTH_URL=https://${DOMAIN}"
    echo "  2. Restart the stack:"
    echo "     cd ${DEPLOY_DIR} && docker compose restart"
    echo "  3. Test your site: https://${DOMAIN}"
    echo "  4. Set up auto-renewal cron job (see above)"
    echo ""
}

main
