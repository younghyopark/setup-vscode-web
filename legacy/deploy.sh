#!/bin/bash
set -e

#######################################
# rdock Deployment Script
# Deploys remote development environment with nginx, SSL, and basic auth
#######################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# Get script directory (where server.py should be)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY="$SCRIPT_DIR/server.py"

#######################################
# Configuration
#######################################
DOMAIN=""
USERNAME=""
TERMINAL_PORT=8890
VSCODE_PORT=8893
PYTHON_CMD=""
SKIP_SSL=false
SKIP_VSCODE=false
SERVICE_NAME="rdock"
BASE_PATH=""
NGINX_MODE=""  # append, overwrite, or empty for interactive

usage() {
    echo "Usage: $0 -d DOMAIN -u USERNAME [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -d DOMAIN     Domain name (e.g., myserver.example.com)"
    echo "  -u USERNAME   Username for basic authentication"
    echo ""
    echo "Options:"
    echo "  -b PATH       Base URL path (e.g., /rdock). Default: / (root)"
    echo "  --append      Append to existing nginx config (non-interactive)"
    echo "  --overwrite   Overwrite existing nginx config (non-interactive)"
    echo "  -p PORT       Port for terminal server (default: 8890)"
    echo "  -P PYTHON     Python executable path (auto-detected if not specified)"
    echo "  -s            Skip SSL setup (use self-signed or existing cert)"
    echo "  -c            Skip VS Code setup"
    echo "  -h            Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -d myserver.example.com -u admin"
    echo "  $0 -d myserver.example.com -u admin -b /rdock --append"
    exit 1
}

# Parse arguments (supports both short opts and --long flags)
while [[ $# -gt 0 ]]; do
    case $1 in
        -d) DOMAIN="$2"; shift 2 ;;
        -u) USERNAME="$2"; shift 2 ;;
        -b) BASE_PATH="$2"; shift 2 ;;
        -p) TERMINAL_PORT="$2"; shift 2 ;;
        -P) PYTHON_CMD="$2"; shift 2 ;;
        -s) SKIP_SSL=true; shift ;;
        -c) SKIP_VSCODE=true; shift ;;
        --append) NGINX_MODE="append"; shift ;;
        --overwrite) NGINX_MODE="overwrite"; shift ;;
        -h) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Validate required arguments
if [ -z "$DOMAIN" ] || [ -z "$USERNAME" ]; then
    print_error "Domain and username are required"
    usage
fi

# Check if server.py exists
if [ ! -f "$SERVER_PY" ]; then
    print_error "server.py not found in $SCRIPT_DIR"
    exit 1
fi

echo "========================================"
echo "  rdock Deployment"
echo "========================================"
echo "Domain:    $DOMAIN"
echo "Base Path: ${BASE_PATH:-/}"
echo "Username:  $USERNAME"
echo "Terminal:  port $TERMINAL_PORT"
echo "VS Code:   port $VSCODE_PORT"
echo "========================================"
echo ""

#######################################
# Step 1: Detect Python
#######################################
echo "Step 1: Detecting Python environment..."

if [ -n "$PYTHON_CMD" ]; then
    if [ ! -x "$PYTHON_CMD" ]; then
        print_error "Specified Python not found: $PYTHON_CMD"
        exit 1
    fi
elif [ -f "$SCRIPT_DIR/.conda/bin/python" ]; then
    PYTHON_CMD="$SCRIPT_DIR/.conda/bin/python"
elif command -v python3 &> /dev/null; then
    PYTHON_CMD="$(which python3)"
elif command -v python &> /dev/null; then
    PYTHON_CMD="$(which python)"
else
    print_error "Python not found. Please install Python 3.8+ or specify with -P"
    exit 1
fi

print_status "Using Python: $PYTHON_CMD"

#######################################
# Step 2: Install Python dependencies
#######################################
echo ""
echo "Step 2: Installing Python dependencies..."

# Check if requirements.txt exists
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
    $PYTHON_CMD -m pip install --quiet -r "$SCRIPT_DIR/requirements.txt"
    print_status "Python dependencies installed from requirements.txt"
else
    $PYTHON_CMD -m pip install --quiet aiohttp
    print_status "aiohttp installed"
fi

#######################################
# Step 3: Install system packages
#######################################
echo ""
echo "Step 3: Installing system packages..."

if ! command -v nginx &> /dev/null; then
    sudo apt update
    sudo apt install -y nginx
    print_status "nginx installed"
else
    print_status "nginx already installed"
fi

if ! command -v certbot &> /dev/null; then
    sudo apt install -y certbot python3-certbot-nginx
    print_status "certbot installed"
else
    print_status "certbot already installed"
fi

if ! command -v htpasswd &> /dev/null; then
    sudo apt install -y apache2-utils
    print_status "apache2-utils installed"
else
    print_status "apache2-utils already installed"
fi

#######################################
# Step 3b: Install VS Code CLI (Official)
#######################################
if [ "$SKIP_VSCODE" = false ]; then
    echo ""
    echo "Step 3b: Installing VS Code CLI..."
    
    if [ ! -f /usr/local/bin/code-cli ]; then
        cd /tmp
        curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64" -o vscode-cli.tar.gz
        tar -xzf vscode-cli.tar.gz
        sudo mv code /usr/local/bin/code-cli
        rm -f vscode-cli.tar.gz
        print_status "VS Code CLI installed"
    else
        print_status "VS Code CLI already installed"
    fi
fi

#######################################
# Step 4: Create nginx configuration
#######################################
echo ""
echo "Step 4: Configuring nginx..."

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
CURRENT_USER=$(whoami)
APPEND_MODE=false

# Normalize base path (ensure it starts with / and doesn't end with /)
if [ -n "$BASE_PATH" ]; then
    # Ensure starts with /
    [[ "$BASE_PATH" != /* ]] && BASE_PATH="/$BASE_PATH"
    # Remove trailing slash
    BASE_PATH="${BASE_PATH%/}"
fi

# Determine location paths
TERMINAL_LOCATION="${BASE_PATH:-}/"
VSCODE_LOCATION_PATH="${BASE_PATH:-}/code/"

# Check if nginx config already exists
if [ -f "$NGINX_CONF" ]; then
    echo ""
    print_warning "Nginx configuration already exists for $DOMAIN"
    echo ""
    echo "Existing config: $NGINX_CONF"
    echo ""
    
    if [ -z "$BASE_PATH" ]; then
        # No base path - would conflict with root location
        if [ "$NGINX_MODE" = "overwrite" ]; then
            print_warning "Overwriting existing config (--overwrite flag)"
        else
            print_error "Cannot install at root (/) when config already exists."
            echo "Options:"
            echo "  1. Use a base path: -b /rdock"
            echo "  2. Use a different domain/subdomain"
            echo "  3. Manually edit the nginx config"
            echo ""
            read -p "Continue anyway and OVERWRITE existing config? (y/N): " OVERWRITE
            if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
                echo "Aborted. Use -b /rdock to install at a sub-path."
                exit 1
            fi
        fi
    else
        # Base path specified - can safely append
        echo "rdock will be installed at: ${BASE_PATH}/"
        echo "VS Code will be at: ${BASE_PATH}/code/"
        echo ""
        
        if [ "$NGINX_MODE" = "append" ]; then
            APPEND_MODE=true
            print_info "Appending rdock locations to existing config (--append flag)"
        elif [ "$NGINX_MODE" = "overwrite" ]; then
            print_warning "Overwriting existing config (--overwrite flag)"
        else
            # Interactive mode
            echo "Options:"
            echo "  1) Append - Add rdock locations to existing config (recommended)"
            echo "  2) Overwrite - Replace entire config with rdock only"
            echo "  3) Cancel"
            echo ""
            read -p "Choose [1/2/3]: " CHOICE
            case $CHOICE in
                1)
                    APPEND_MODE=true
                    print_info "Will append rdock locations to existing config"
                    ;;
                2)
                    print_warning "Will overwrite existing config"
                    ;;
                *)
                    echo "Aborted."
                    exit 1
                    ;;
            esac
        fi
    fi
fi

# Check if rdock locations already exist in the config
if [ "$APPEND_MODE" = true ] && [ -f "$NGINX_CONF" ]; then
    if grep -q "location ${TERMINAL_LOCATION} {" "$NGINX_CONF" || grep -q "# rdock Terminal" "$NGINX_CONF"; then
        print_warning "rdock locations already exist in the nginx config"
        
        # Check if port needs updating
        CURRENT_PORT=$(grep -oP 'proxy_pass http://127\.0\.0\.1:\K[0-9]+' "$NGINX_CONF" | head -1)
        if [ -n "$CURRENT_PORT" ] && [ "$CURRENT_PORT" != "$TERMINAL_PORT" ]; then
            print_info "Updating port from $CURRENT_PORT to $TERMINAL_PORT"
            sudo sed -i "s/127\.0\.0\.1:$CURRENT_PORT/127.0.0.1:$TERMINAL_PORT/g" "$NGINX_CONF"
            if sudo nginx -t; then
                sudo systemctl reload nginx
                print_status "Nginx port updated to $TERMINAL_PORT"
            else
                print_error "Nginx config test failed after port update"
                exit 1
            fi
        else
            print_info "Port already set to $TERMINAL_PORT"
        fi
        
        APPEND_MODE=false
        SKIP_NGINX_CONFIG=true
    fi
fi

# Build location blocks
# Add redirect from /basepath to /basepath/ if base path is set
REDIRECT_BLOCK=""
if [ -n "$BASE_PATH" ]; then
    REDIRECT_BLOCK="
    # Redirect /rdock to /rdock/
    location = $BASE_PATH {
        return 301 \$scheme://\$host$BASE_PATH/;
    }"
fi

TERMINAL_LOCATION_BLOCK="$REDIRECT_BLOCK
    # rdock Terminal
    location $TERMINAL_LOCATION {
        proxy_pass http://127.0.0.1:$TERMINAL_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_read_timeout 86400;
        proxy_connect_timeout 60;
    }"

VSCODE_LOCATION_BLOCK=""
if [ "$SKIP_VSCODE" = false ]; then
    # Determine the proxy pass path based on base path
    VSCODE_PROXY_PATH="${BASE_PATH}/code/"
    [[ -z "$BASE_PATH" ]] && VSCODE_PROXY_PATH="/code/"
    
    VSCODE_LOCATION_BLOCK="
    # rdock VS Code
    location ${VSCODE_LOCATION_PATH} {
        proxy_pass http://127.0.0.1:$VSCODE_PORT${VSCODE_PROXY_PATH};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Accept-Encoding gzip;
        proxy_read_timeout 86400;
        proxy_connect_timeout 60;
    }"
fi

if [ "$SKIP_NGINX_CONFIG" = true ]; then
    print_status "Nginx config unchanged (rdock already configured)"
elif [ "$APPEND_MODE" = true ]; then
    # Append mode: Insert location blocks into existing server block
    # Create a temporary file with the location blocks
    LOCATIONS_TMP=$(mktemp)
    echo "$VSCODE_LOCATION_BLOCK" > "$LOCATIONS_TMP"
    echo "$TERMINAL_LOCATION_BLOCK" >> "$LOCATIONS_TMP"
    
    # Find the line with "listen 443" or "listen 80" in the HTTPS server block and insert before it
    # We'll insert after the auth_basic lines if they exist, otherwise after server_name
    if grep -q "listen 443" "$NGINX_CONF"; then
        # Has SSL - insert before "listen 443"
        sudo sed -i "/listen 443/r $LOCATIONS_TMP" "$NGINX_CONF"
        # Actually we need to insert BEFORE, not after. Let's use a different approach.
        # Create backup and rebuild
        sudo cp "$NGINX_CONF" "${NGINX_CONF}.bak"
        
        # Use awk to insert before "listen 443"
        sudo awk -v locations="$(cat $LOCATIONS_TMP)" '
            /listen 443/ && !inserted {
                print locations
                inserted=1
            }
            {print}
        ' "${NGINX_CONF}.bak" | sudo tee "$NGINX_CONF" > /dev/null
    else
        # No SSL yet - insert before "listen 80"
        sudo cp "$NGINX_CONF" "${NGINX_CONF}.bak"
        sudo awk -v locations="$(cat $LOCATIONS_TMP)" '
            /listen 80/ && !inserted {
                print locations
                inserted=1
            }
            {print}
        ' "${NGINX_CONF}.bak" | sudo tee "$NGINX_CONF" > /dev/null
    fi
    
    rm -f "$LOCATIONS_TMP"
    
    # Test and reload
    if sudo nginx -t; then
        sudo systemctl reload nginx
        print_status "rdock locations appended to existing nginx config"
    else
        print_error "Nginx config test failed! Restoring backup..."
        sudo cp "${NGINX_CONF}.bak" "$NGINX_CONF"
        sudo nginx -t && sudo systemctl reload nginx
        exit 1
    fi
else
    # Overwrite mode: Create new config
    sudo tee "$NGINX_CONF" > /dev/null << EOF
server {
    server_name $DOMAIN;

    # Basic Authentication
    auth_basic "Terminal Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
$VSCODE_LOCATION_BLOCK
$TERMINAL_LOCATION_BLOCK

    listen 80;
}
EOF

    # Enable site
    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    sudo nginx -t
    sudo systemctl reload nginx
    print_status "nginx configured"
fi

#######################################
# Step 5: Set up SSL with Let's Encrypt
#######################################
echo ""
echo "Step 5: Setting up SSL..."

if [ "$SKIP_SSL" = true ]; then
    print_warning "Skipping SSL setup (--skip-ssl flag)"
elif [ "$APPEND_MODE" = true ]; then
    # In append mode, SSL should already be configured
    if grep -q "listen 443 ssl" "$NGINX_CONF"; then
        print_status "SSL already configured (append mode)"
    else
        print_warning "Existing config doesn't have SSL. Run certbot manually if needed."
    fi
else
    sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    print_status "SSL certificate obtained and configured"
fi

#######################################
# Step 6: Set up basic authentication
#######################################
echo ""
echo "Step 6: Setting up basic authentication..."

if [ "$APPEND_MODE" = true ]; then
    # In append mode, check if auth is already configured
    if grep -q "auth_basic" "$NGINX_CONF"; then
        print_status "Basic auth already configured in existing config"
    else
        print_warning "Existing config doesn't have auth. rdock locations will be unprotected!"
        echo "Consider adding auth_basic to your nginx config."
    fi
elif [ ! -f /etc/nginx/.htpasswd ]; then
    echo "Creating password for user: $USERNAME"
    sudo htpasswd -c /etc/nginx/.htpasswd "$USERNAME"
    print_status "Basic auth configured"
    sudo systemctl reload nginx
else
    echo "Adding/updating password for user: $USERNAME"
    sudo htpasswd /etc/nginx/.htpasswd "$USERNAME"
    print_status "Basic auth configured"
    sudo systemctl reload nginx
fi

#######################################
# Step 7: Create systemd services
#######################################
echo ""
echo "Step 7: Creating systemd services..."

# Terminal service
sudo tee "/etc/systemd/system/$SERVICE_NAME.service" > /dev/null << EOF
[Unit]
Description=rdock Remote Development Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$PYTHON_CMD $SERVER_PY
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=RDOCK_PORT=$TERMINAL_PORT
Environment=RDOCK_BASE_PATH=$BASE_PATH

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"
print_status "rdock service created and started"

# VS Code service
if [ "$SKIP_VSCODE" = false ]; then
    echo ""
    echo "Step 7b: Creating VS Code service..."
    
    # Determine VS Code base path
    VSCODE_BASE_PATH="${BASE_PATH}/code"
    [[ -z "$BASE_PATH" ]] && VSCODE_BASE_PATH="/code"
    
    sudo tee "/etc/systemd/system/vscode-web.service" > /dev/null << EOF
[Unit]
Description=VS Code Official Web Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
Environment=HOME=/home/$CURRENT_USER
ExecStart=/usr/local/bin/code-cli serve-web --host 127.0.0.1 --port $VSCODE_PORT --without-connection-token --accept-server-license-terms --server-base-path $VSCODE_BASE_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable vscode-web
    sudo systemctl restart vscode-web
    print_status "VS Code service created and started"
fi

#######################################
# Step 8: Verify deployment
#######################################
echo ""
echo "Step 8: Verifying deployment..."

sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_status "rdock service is running"
else
    print_error "rdock service failed to start. Check: sudo journalctl -u $SERVICE_NAME -f"
    exit 1
fi

# Test HTTP response
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$TERMINAL_PORT/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    print_status "rdock server responding"
else
    print_warning "Terminal server returned HTTP $HTTP_CODE (may be normal)"
fi

# Verify VS Code
if [ "$SKIP_VSCODE" = false ]; then
    if systemctl is-active --quiet "vscode-web"; then
        print_status "VS Code service is running"
    else
        print_warning "VS Code may not be running. Check: sudo journalctl -u vscode-web -f"
    fi
fi

#######################################
# Done!
#######################################
echo ""
echo "========================================"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo "========================================"
echo ""
echo "Access your services at:"
if [ "$SKIP_SSL" = true ]; then
    echo "  rdock:     http://$DOMAIN${TERMINAL_LOCATION}"
    if [ "$SKIP_VSCODE" = false ]; then
        echo "  VS Code:   http://$DOMAIN${VSCODE_LOCATION_PATH}"
    fi
else
    echo "  rdock:     https://$DOMAIN${TERMINAL_LOCATION}"
    if [ "$SKIP_VSCODE" = false ]; then
        echo "  VS Code:   https://$DOMAIN${VSCODE_LOCATION_PATH}"
    fi
fi
echo ""
echo "Credentials:"
echo "  Username: $USERNAME"
echo "  Password: (the one you just entered)"
echo ""
echo "Useful commands:"
echo "  View logs:       sudo journalctl -u $SERVICE_NAME -f"
echo "  Restart service: sudo systemctl restart $SERVICE_NAME"
if [ "$SKIP_VSCODE" = false ]; then
    echo "  VS Code logs:    sudo journalctl -u vscode-web -f"
    echo "  VS Code restart: sudo systemctl restart vscode-web"
fi
echo "  Add user:        sudo htpasswd /etc/nginx/.htpasswd newuser"
echo "  Renew SSL:       sudo certbot renew"
echo ""
echo "Terminal keyboard shortcuts:"
echo "  Ctrl+Shift+T    New tab"
echo "  Ctrl+Shift+W    Close tab"
echo "  Ctrl+Tab        Next tab"
echo "  Ctrl+Shift+Tab  Previous tab"
echo ""
