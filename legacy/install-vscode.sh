#!/bin/bash
set -e

#######################################
# Lightweight VS Code Web Server Installer
# Installs code-cli, sets up nginx reverse proxy at /code/,
# configures SSL, and runs as a systemd service.
#
# Interactive: bash install-vscode.sh
# One-liner:   curl ... | bash
# With flags:  bash install-vscode.sh -d DOMAIN -p PORT -u USER
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOMAIN=""
PORT=""
USERNAME=""
SKIP_SSL=""
CURRENT_USER=$(whoami)

#######################################
# Parse flags (all optional - missing ones get prompted)
#######################################
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        -p|--port) PORT="$2"; shift 2 ;;
        -u|--username) USERNAME="$2"; shift 2 ;;
        -s|--skip-ssl) SKIP_SSL=true; shift ;;
        --no-auth) USERNAME="__none__"; shift ;;
        -h|--help)
            echo "Usage: bash install-vscode.sh [OPTIONS]"
            echo ""
            echo "All options are optional - you'll be prompted for anything missing."
            echo ""
            echo "Options:"
            echo "  -d, --domain DOMAIN    Domain name (e.g., myserver.example.com)"
            echo "  -p, --port PORT        Local port for VS Code (default: 8893)"
            echo "  -u, --username USER    Enable basic auth with this username"
            echo "  --no-auth              Skip basic auth setup"
            echo "  -s, --skip-ssl         Skip SSL/certbot setup"
            echo "  -h, --help             Show this help"
            echo ""
            echo "Examples:"
            echo "  bash install-vscode.sh"
            echo "  bash install-vscode.sh -d myserver.com -p 9000 -u admin"
            echo "  curl -fsSL https://raw.githubusercontent.com/.../install-vscode.sh | bash"
            exit 0
            ;;
        *) echo -e "${RED}[x]${NC} Unknown option: $1"; exit 1 ;;
    esac
done

echo ""
echo "========================================"
echo "  VS Code Web Server Installer"
echo "========================================"
echo ""

#######################################
# Interactive prompts for missing values
#######################################

# Domain
if [ -z "$DOMAIN" ]; then
    read -p "Domain name (e.g., myserver.example.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}[x]${NC} Domain is required"
        exit 1
    fi
fi

# Port
if [ -z "$PORT" ]; then
    read -p "Port for VS Code server [8893]: " PORT
    PORT="${PORT:-8893}"
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo -e "${RED}[x]${NC} Invalid port: $PORT"
    exit 1
fi

# Auth
if [ -z "$USERNAME" ]; then
    read -p "Username for basic auth (leave empty to skip): " USERNAME
    [ -z "$USERNAME" ] && USERNAME="__none__"
fi

# SSL
if [ -z "$SKIP_SSL" ]; then
    read -p "Set up SSL with Let's Encrypt? [Y/n]: " SSL_ANSWER
    if [[ "$SSL_ANSWER" =~ ^[Nn]$ ]]; then
        SKIP_SSL=true
    else
        SKIP_SSL=false
    fi
fi

# Normalize
USE_AUTH=true
if [ "$USERNAME" = "__none__" ]; then
    USE_AUTH=false
    USERNAME=""
fi

SCHEME="https"
[ "$SKIP_SSL" = true ] && SCHEME="http"

echo ""
echo "----------------------------------------"
echo "  Domain: $DOMAIN"
echo "  URL:    $SCHEME://$DOMAIN/code/"
echo "  Port:   $PORT (local)"
echo "  Auth:   ${USERNAME:-none}"
echo "  SSL:    $([ "$SKIP_SSL" = true ] && echo "no" || echo "yes")"
echo "----------------------------------------"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}[x]${NC} Please run as a regular user with sudo access, not as root"
    exit 1
fi

#######################################
# 1. Install code-cli
#######################################
if [ ! -f /usr/local/bin/code-cli ]; then
    echo -e "${BLUE}[i]${NC} Downloading VS Code CLI..."
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
echo -e "${BLUE}[i]${NC} Checking system packages..."

if ! command -v nginx &> /dev/null; then
    sudo apt update -qq && sudo apt install -y nginx
    echo -e "${GREEN}[+]${NC} nginx installed"
else
    echo -e "${GREEN}[+]${NC} nginx already installed"
fi

if [ "$SKIP_SSL" = false ] && ! command -v certbot &> /dev/null; then
    sudo apt install -y certbot python3-certbot-nginx
    echo -e "${GREEN}[+]${NC} certbot installed"
fi

if [ "$USE_AUTH" = true ] && ! command -v htpasswd &> /dev/null; then
    sudo apt install -y apache2-utils
    echo -e "${GREEN}[+]${NC} apache2-utils installed"
fi

#######################################
# 3. Basic auth (optional)
#######################################
if [ "$USE_AUTH" = true ]; then
    echo -e "${BLUE}[i]${NC} Setting up basic auth for user: $USERNAME"
    if [ ! -f /etc/nginx/.htpasswd ]; then
        sudo htpasswd -c /etc/nginx/.htpasswd "$USERNAME"
    else
        sudo htpasswd /etc/nginx/.htpasswd "$USERNAME"
    fi
    echo -e "${GREEN}[+]${NC} Basic auth configured"
fi

#######################################
# 4. Nginx config
#######################################
echo -e "${BLUE}[i]${NC} Configuring nginx..."

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

AUTH_BLOCK=""
if [ "$USE_AUTH" = true ]; then
    AUTH_BLOCK="
    auth_basic \"VS Code Access\";
    auth_basic_user_file /etc/nginx/.htpasswd;"
fi

# Check if config already exists
if [ -f "$NGINX_CONF" ]; then
    # Check if /code/ location already exists
    if grep -q "location /code/" "$NGINX_CONF"; then
        echo -e "${YELLOW}[!]${NC} /code/ location already in nginx config - updating port"
        sudo sed -i "s|proxy_pass http://127\.0\.0\.1:[0-9]*/code/;|proxy_pass http://127.0.0.1:$PORT/code/;|g" "$NGINX_CONF"
        if sudo nginx -t; then
            sudo systemctl reload nginx
            echo -e "${GREEN}[+]${NC} nginx port updated"
        else
            echo -e "${RED}[x]${NC} nginx config test failed"
            exit 1
        fi
    else
        # Append /code/ location to existing config
        echo -e "${BLUE}[i]${NC} Appending /code/ location to existing nginx config..."

        LOCATION_BLOCK=$(cat << 'INNEREOF'

    # VS Code Web
    location /code/ {
        proxy_pass http://127.0.0.1:VSCODE_PORT/code/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Accept-Encoding gzip;
        proxy_read_timeout 86400;
        proxy_connect_timeout 60;
    }
INNEREOF
)
        LOCATION_BLOCK="${LOCATION_BLOCK//VSCODE_PORT/$PORT}"

        # Insert before the first "listen" directive
        sudo cp "$NGINX_CONF" "${NGINX_CONF}.bak"
        sudo awk -v loc="$LOCATION_BLOCK" '/listen [0-9]/ && !inserted { print loc; inserted=1 } {print}' "${NGINX_CONF}.bak" | sudo tee "$NGINX_CONF" > /dev/null

        if sudo nginx -t; then
            sudo systemctl reload nginx
            echo -e "${GREEN}[+]${NC} /code/ location appended to nginx config"
        else
            echo -e "${RED}[x]${NC} nginx config test failed, restoring backup"
            sudo cp "${NGINX_CONF}.bak" "$NGINX_CONF"
            sudo nginx -t && sudo systemctl reload nginx
            exit 1
        fi
    fi
else
    # Create new config
    sudo tee "$NGINX_CONF" > /dev/null << EOF
server {
    server_name $DOMAIN;
$AUTH_BLOCK

    # VS Code Web
    location /code/ {
        proxy_pass http://127.0.0.1:$PORT/code/;
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
    echo -e "${GREEN}[+]${NC} nginx configured"
fi

#######################################
# 5. SSL
#######################################
if [ "$SKIP_SSL" = true ]; then
    echo -e "${YELLOW}[!]${NC} Skipping SSL"
else
    if grep -q "listen 443 ssl" "$NGINX_CONF" 2>/dev/null; then
        echo -e "${GREEN}[+]${NC} SSL already configured"
    else
        echo -e "${BLUE}[i]${NC} Setting up SSL with Let's Encrypt..."
        sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
        echo -e "${GREEN}[+]${NC} SSL configured"
    fi
fi

#######################################
# 6. Systemd service
#######################################
echo -e "${BLUE}[i]${NC} Creating systemd service..."

sudo tee /etc/systemd/system/vscode-web.service > /dev/null << EOF
[Unit]
Description=VS Code Web Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
Environment=HOME=/home/$CURRENT_USER
ExecStart=/usr/local/bin/code-cli serve-web --host 127.0.0.1 --port $PORT --without-connection-token --accept-server-license-terms --server-base-path /code
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable vscode-web
sudo systemctl restart vscode-web

sleep 2

#######################################
# 7. Verify
#######################################
if systemctl is-active --quiet vscode-web; then
    echo ""
    echo -e "${GREEN}========================================"
    echo -e "  VS Code is running!"
    echo -e "========================================${NC}"
    echo ""
    echo -e "  URL: ${BLUE}${SCHEME}://$DOMAIN/code/${NC}"
    echo ""
    echo "Commands:"
    echo "  Logs:      sudo journalctl -u vscode-web -f"
    echo "  Restart:   sudo systemctl restart vscode-web"
    echo "  Stop:      sudo systemctl stop vscode-web"
    echo ""
else
    echo -e "${RED}[x] Failed to start. Check: sudo journalctl -u vscode-web -f${NC}"
    exit 1
fi
