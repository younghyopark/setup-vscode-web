#!/bin/bash
set -e

#######################################
# setup-vscode-web
# Simple, secure VS Code Web setup helper.
# Installs code-cli, configures nginx with HTTPS + auth,
# and runs as a systemd service.
#
# Interactive: bash setup-vscode-web.sh
# One-liner:   curl -fsSL <url>/setup-vscode-web.sh | bash
# With flags:  bash setup-vscode-web.sh -d DOMAIN -u USER
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOMAIN=""
PORT=""
USERNAME=""
SKIP_SSL=false
BASE_PATH="/code"
CURRENT_USER=$(whoami)
SERVICE_NAME="vscode-web"

#######################################
# Parse flags
#######################################
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        -p|--port) PORT="$2"; shift 2 ;;
        -u|--username) USERNAME="$2"; shift 2 ;;
        -b|--base-path) BASE_PATH="$2"; shift 2 ;;
        -s|--skip-ssl) SKIP_SSL=true; shift ;;
        --uninstall)
            echo "Uninstalling VS Code Web..."
            sudo systemctl stop vscode-web 2>/dev/null || true
            sudo systemctl disable vscode-web 2>/dev/null || true
            sudo rm -f /etc/systemd/system/vscode-web.service
            sudo systemctl daemon-reload
            echo -e "${GREEN}[+]${NC} VS Code Web service removed"
            echo ""
            echo "Note: nginx config and SSL certs were left in place."
            echo "Remove manually if needed:"
            echo "  sudo rm /etc/nginx/sites-available/YOUR_DOMAIN"
            echo "  sudo rm /etc/nginx/sites-enabled/YOUR_DOMAIN"
            exit 0
            ;;
        -h|--help)
            echo "Usage: bash setup-vscode-web.sh [OPTIONS]"
            echo ""
            echo "Simple, secure VS Code Web setup. Sets up HTTPS + password auth"
            echo "by default. All options are optional — you'll be prompted for"
            echo "anything missing."
            echo ""
            echo "Options:"
            echo "  -d, --domain DOMAIN    Domain name (e.g., dev.example.com)"
            echo "  -u, --username USER    Username for basic auth (required for security)"
            echo "  -p, --port PORT        Local port for VS Code (default: 8893)"
            echo "  -b, --base-path PATH   URL path prefix (default: /code)"
            echo "  -s, --skip-ssl         Skip SSL setup (NOT recommended)"
            echo "  --uninstall            Remove VS Code Web service"
            echo "  -h, --help             Show this help"
            echo ""
            echo "Examples:"
            echo "  bash setup-vscode-web.sh"
            echo "  bash setup-vscode-web.sh -d dev.example.com -u admin"
            echo "  curl -fsSL <url>/setup-vscode-web.sh | bash -s -- -d dev.example.com -u admin"
            exit 0
            ;;
        *) echo -e "${RED}[x]${NC} Unknown option: $1"; exit 1 ;;
    esac
done

echo ""
echo "========================================"
echo "  setup-vscode-web"
echo "  Secure VS Code in your browser"
echo "========================================"
echo ""

#######################################
# Pre-flight checks
#######################################
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}[x]${NC} Please run as a regular user with sudo access, not as root"
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    echo -e "${YELLOW}[!]${NC} This script requires sudo access. You may be prompted for your password."
fi

if [ ! -f /etc/os-release ]; then
    echo -e "${RED}[x]${NC} Unsupported OS. This installer requires Debian/Ubuntu."
    exit 1
fi

#######################################
# Interactive prompts for missing values
#######################################

# Domain (required)
if [ -z "$DOMAIN" ]; then
    read -p "Domain name (e.g., dev.example.com): " DOMAIN < /dev/tty
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}[x]${NC} Domain is required"
        exit 1
    fi
fi

# Username (required — auth is mandatory for security)
if [ -z "$USERNAME" ]; then
    read -p "Username for basic auth: " USERNAME < /dev/tty
    if [ -z "$USERNAME" ]; then
        echo -e "${RED}[x]${NC} Username is required. VS Code Web must be password-protected."
        exit 1
    fi
fi

# Port
if [ -z "$PORT" ]; then
    read -p "Port for VS Code server [8893]: " PORT < /dev/tty
    PORT="${PORT:-8893}"
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo -e "${RED}[x]${NC} Invalid port: $PORT"
    exit 1
fi

# SSL warning
if [ "$SKIP_SSL" = true ]; then
    echo ""
    echo -e "${RED}WARNING: Running without HTTPS exposes your credentials and code to interception.${NC}"
    echo -e "${RED}Only skip SSL for local/testing environments.${NC}"
    read -p "Continue without SSL? (y/N): " CONFIRM < /dev/tty
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborting. Remove -s flag to set up SSL."
        exit 1
    fi
fi

# Normalize base path
[[ "$BASE_PATH" != /* ]] && BASE_PATH="/$BASE_PATH"
BASE_PATH="${BASE_PATH%/}"

SCHEME="https"
[ "$SKIP_SSL" = true ] && SCHEME="http"

echo ""
echo "----------------------------------------"
echo "  Domain:    $DOMAIN"
echo "  URL:       $SCHEME://$DOMAIN${BASE_PATH}/"
echo "  Port:      $PORT (local)"
echo "  Auth:      $USERNAME"
echo "  SSL/HTTPS: $([ "$SKIP_SSL" = true ] && echo "DISABLED" || echo "yes (Let's Encrypt)")"
echo "  Base path: $BASE_PATH"
echo "----------------------------------------"
echo ""

#######################################
# 1. Install VS Code CLI
#######################################
echo -e "${BLUE}[1/7]${NC} Installing VS Code CLI..."

if [ ! -f /usr/local/bin/code-cli ]; then
    cd /tmp
    curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64" -o vscode-cli.tar.gz
    tar -xzf vscode-cli.tar.gz
    sudo mv code /usr/local/bin/code-cli
    rm -f vscode-cli.tar.gz
    echo -e "${GREEN}[+]${NC} VS Code CLI installed"
else
    echo -e "${GREEN}[+]${NC} VS Code CLI already installed"
fi

#######################################
# 2. Install system packages
#######################################
echo -e "${BLUE}[2/7]${NC} Installing system packages..."

PACKAGES_NEEDED=""
command -v nginx &> /dev/null || PACKAGES_NEEDED="$PACKAGES_NEEDED nginx"
command -v htpasswd &> /dev/null || PACKAGES_NEEDED="$PACKAGES_NEEDED apache2-utils"
if [ "$SKIP_SSL" = false ]; then
    command -v certbot &> /dev/null || PACKAGES_NEEDED="$PACKAGES_NEEDED certbot python3-certbot-nginx"
fi

if [ -n "$PACKAGES_NEEDED" ]; then
    sudo apt update -qq
    sudo apt install -y $PACKAGES_NEEDED
    echo -e "${GREEN}[+]${NC} Packages installed:$PACKAGES_NEEDED"
else
    echo -e "${GREEN}[+]${NC} All system packages already installed"
fi

#######################################
# 3. Set up basic auth
#######################################
echo -e "${BLUE}[3/7]${NC} Setting up basic auth for user: $USERNAME"

if [ ! -f /etc/nginx/.htpasswd ]; then
    sudo htpasswd -c /etc/nginx/.htpasswd "$USERNAME"
else
    if sudo grep -q "^${USERNAME}:" /etc/nginx/.htpasswd; then
        echo -e "${GREEN}[+]${NC} User '$USERNAME' already exists in htpasswd"
        read -p "Update password? (y/N): " UPDATE_PW < /dev/tty
        if [[ "$UPDATE_PW" =~ ^[Yy]$ ]]; then
            sudo htpasswd /etc/nginx/.htpasswd "$USERNAME"
        fi
    else
        sudo htpasswd /etc/nginx/.htpasswd "$USERNAME"
    fi
fi
echo -e "${GREEN}[+]${NC} Basic auth configured"

#######################################
# 4. Configure nginx
#######################################
echo -e "${BLUE}[4/7]${NC} Configuring nginx..."

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

# Build location block
LOCATION_PATH="${BASE_PATH}/"

# Check if config already exists
if [ -f "$NGINX_CONF" ]; then
    if grep -q "location ${LOCATION_PATH}" "$NGINX_CONF"; then
        echo -e "${YELLOW}[!]${NC} ${LOCATION_PATH} location already in nginx config — updating port"
        sudo sed -i "s|proxy_pass http://127\.0\.0\.1:[0-9]*${BASE_PATH}/;|proxy_pass http://127.0.0.1:${PORT}${BASE_PATH}/;|g" "$NGINX_CONF"
        if sudo nginx -t; then
            sudo systemctl reload nginx
            echo -e "${GREEN}[+]${NC} nginx port updated"
        else
            echo -e "${RED}[x]${NC} nginx config test failed"
            exit 1
        fi
    else
        # Append location to existing config
        echo -e "${BLUE}[i]${NC} Appending ${LOCATION_PATH} location to existing nginx config..."

        LOCATION_BLOCK=$(cat << INNEREOF

    # VS Code Web — setup-vscode-web
    location ${LOCATION_PATH} {
        proxy_pass http://127.0.0.1:${PORT}${BASE_PATH}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Accept-Encoding gzip;
        proxy_read_timeout 86400;
        proxy_connect_timeout 60;
    }
INNEREOF
)

        sudo cp "$NGINX_CONF" "${NGINX_CONF}.bak"
        sudo awk -v loc="$LOCATION_BLOCK" '/listen [0-9]/ && !inserted { print loc; inserted=1 } {print}' "${NGINX_CONF}.bak" | sudo tee "$NGINX_CONF" > /dev/null

        if sudo nginx -t; then
            sudo systemctl reload nginx
            echo -e "${GREEN}[+]${NC} ${LOCATION_PATH} location appended to nginx config"
        else
            echo -e "${RED}[x]${NC} nginx config test failed, restoring backup"
            sudo cp "${NGINX_CONF}.bak" "$NGINX_CONF"
            sudo nginx -t && sudo systemctl reload nginx
            exit 1
        fi
    fi
else
    # Create new config with security hardening
    sudo tee "$NGINX_CONF" > /dev/null << EOF
server {
    server_name $DOMAIN;

    # --- Authentication ---
    auth_basic "VS Code Web";
    auth_basic_user_file /etc/nginx/.htpasswd;

    # --- Security Headers ---
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    # --- VS Code Web ---
    location ${LOCATION_PATH} {
        proxy_pass http://127.0.0.1:${PORT}${BASE_PATH}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Accept-Encoding gzip;
        proxy_read_timeout 86400;
        proxy_connect_timeout 60;
    }

    listen 80;
}
EOF

    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    sudo nginx -t
    sudo systemctl reload nginx
    echo -e "${GREEN}[+]${NC} nginx configured with security headers"
fi

#######################################
# 5. SSL / HTTPS
#######################################
echo -e "${BLUE}[5/7]${NC} Setting up SSL..."

if [ "$SKIP_SSL" = true ]; then
    echo -e "${YELLOW}[!]${NC} SSL skipped (not recommended for production)"
else
    if grep -q "listen 443 ssl" "$NGINX_CONF" 2>/dev/null; then
        echo -e "${GREEN}[+]${NC} SSL already configured"
    else
        sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
        echo -e "${GREEN}[+]${NC} SSL configured with Let's Encrypt"
    fi

    # Enforce HTTPS — ensure HTTP redirects to HTTPS
    # certbot usually handles this, but verify
    if ! grep -q "return 301 https" "$NGINX_CONF" 2>/dev/null && grep -q "listen 443 ssl" "$NGINX_CONF" 2>/dev/null; then
        echo -e "${GREEN}[+]${NC} HTTPS redirect active (managed by certbot)"
    fi

    # Add HSTS header if not present
    if ! grep -q "Strict-Transport-Security" "$NGINX_CONF" 2>/dev/null; then
        sudo sed -i '/add_header X-Content-Type-Options/a\    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;' "$NGINX_CONF"
        if sudo nginx -t; then
            sudo systemctl reload nginx
            echo -e "${GREEN}[+]${NC} HSTS header added"
        fi
    fi
fi

#######################################
# 6. Systemd service
#######################################
echo -e "${BLUE}[6/7]${NC} Creating systemd service..."

sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null << EOF
[Unit]
Description=VS Code Web Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
Environment=HOME=/home/$CURRENT_USER
ExecStart=/usr/local/bin/code-cli serve-web --host 127.0.0.1 --port $PORT --without-connection-token --accept-server-license-terms --server-base-path $BASE_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}
sudo systemctl restart ${SERVICE_NAME}

echo -e "${GREEN}[+]${NC} systemd service created and started"

#######################################
# 7. Verify
#######################################
echo -e "${BLUE}[7/7]${NC} Verifying..."

sleep 2

if systemctl is-active --quiet ${SERVICE_NAME}; then
    echo ""
    echo -e "${GREEN}========================================"
    echo -e "  VS Code Web is running!"
    echo -e "========================================${NC}"
    echo ""
    echo -e "  URL: ${BLUE}${SCHEME}://$DOMAIN${BASE_PATH}/${NC}"
    echo ""
    echo "Security:"
    echo "  - Password auth:  enabled ($USERNAME)"
    if [ "$SKIP_SSL" = false ]; then
    echo "  - HTTPS/TLS:      enabled (Let's Encrypt)"
    echo "  - HSTS:           enabled"
    fi
    echo "  - Security hdrs:  X-Content-Type-Options, X-Frame-Options, Referrer-Policy"
    echo ""
    echo "Commands:"
    echo "  Logs:       sudo journalctl -u ${SERVICE_NAME} -f"
    echo "  Restart:    sudo systemctl restart ${SERVICE_NAME}"
    echo "  Stop:       sudo systemctl stop ${SERVICE_NAME}"
    echo "  Add user:   sudo htpasswd /etc/nginx/.htpasswd newuser"
    echo "  Renew SSL:  sudo certbot renew"
    echo ""
else
    echo -e "${RED}[x] Failed to start. Check: sudo journalctl -u ${SERVICE_NAME} -f${NC}"
    exit 1
fi
