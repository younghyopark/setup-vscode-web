#!/bin/bash
set -e

#######################################
# rdock One-Line Installer
# Usage: curl -fsSL <url>/install.sh | bash -s -- -d domain.com -u admin
#######################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# Default installation directory
INSTALL_DIR="$HOME/.rdock"
REPO_URL="https://github.com/younghyopark/rdock"
BRANCH="main"

echo ""
echo "========================================"
echo "  🚀 rdock Installer"
echo "========================================"
echo ""

#######################################
# Parse arguments
#######################################
DOMAIN=""
USERNAME=""
SKIP_SSL=false
SKIP_VSCODE=false
TERMINAL_PORT=8890
BASE_PATH=""
NGINX_MODE=""  # append, overwrite, or empty for interactive

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -u|--username)
            USERNAME="$2"
            shift 2
            ;;
        -b|--base-path)
            BASE_PATH="$2"
            shift 2
            ;;
        --append)
            NGINX_MODE="append"
            shift
            ;;
        --overwrite)
            NGINX_MODE="overwrite"
            shift
            ;;
        -s|--skip-ssl)
            SKIP_SSL=true
            shift
            ;;
        -c|--skip-vscode)
            SKIP_VSCODE=true
            shift
            ;;
        -p|--port)
            TERMINAL_PORT="$2"
            shift 2
            ;;
        --uninstall)
            echo "Uninstalling rdock..."
            sudo systemctl stop rdock 2>/dev/null || true
            sudo systemctl disable rdock 2>/dev/null || true
            sudo systemctl stop vscode-web 2>/dev/null || true
            sudo systemctl disable vscode-web 2>/dev/null || true
            sudo rm -f /etc/systemd/system/rdock.service
            sudo rm -f /etc/systemd/system/vscode-web.service
            sudo systemctl daemon-reload
            rm -rf "$INSTALL_DIR"
            print_status "Uninstalled successfully"
            exit 0
            ;;
        -h|--help)
            echo "Usage: curl -fsSL <url>/install.sh | bash -s -- [OPTIONS]"
            echo ""
            echo "Required:"
            echo "  -d, --domain DOMAIN       Domain name (e.g., terminal.example.com)"
            echo "  -u, --username USERNAME   Username for authentication"
            echo ""
            echo "Options:"
            echo "  -b, --base-path PATH     URL path prefix (e.g., /rdock). Default: / (root)"
            echo "  --append                 Append to existing nginx config (use with -b)"
            echo "  --overwrite              Overwrite existing nginx config"
            echo "  -p, --port PORT          Port for terminal server (default: 8890)"
            echo "  -s, --skip-ssl           Skip SSL/HTTPS setup"
            echo "  -c, --skip-vscode        Skip VS Code installation"
            echo "  --uninstall              Remove web-terminal"
            echo "  -h, --help               Show this help"
            echo ""
            echo "Example:"
            echo "  curl -fsSL <url>/install.sh | bash -s -- -d terminal.example.com -u admin"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$DOMAIN" ] || [ -z "$USERNAME" ]; then
    print_error "Domain and username are required"
    echo ""
    echo "Usage: curl -fsSL <url>/install.sh | bash -s -- -d DOMAIN -u USERNAME"
    echo "Example: curl -fsSL <url>/install.sh | bash -s -- -d terminal.example.com -u admin"
    echo ""
    echo "Use -h for full help"
    exit 1
fi

#######################################
# Check prerequisites
#######################################
print_info "Checking prerequisites..."

# Check if running as non-root with sudo access
if [ "$EUID" -eq 0 ]; then
    print_error "Please run as a regular user with sudo access, not as root"
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    print_warning "This script requires sudo access. You may be prompted for your password."
fi

# Check OS
if [ ! -f /etc/os-release ]; then
    print_error "Unsupported OS. This installer is designed for Debian/Ubuntu."
    exit 1
fi

print_status "Prerequisites checked"

#######################################
# Download/Update repository
#######################################
print_info "Downloading rdock..."

if [ -d "$INSTALL_DIR/.git" ]; then
    print_info "Existing installation found. Updating..."
    cd "$INSTALL_DIR"
    git pull origin "$BRANCH"
    print_status "Updated to latest version"
else
    # Clone repository
    if command -v git &> /dev/null; then
        git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
        print_status "Repository cloned"
    else
        # Fallback: download as zip if git not available
        print_warning "Git not found. Installing git..."
        sudo apt update -qq
        sudo apt install -y git
        git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
        print_status "Repository cloned"
    fi
fi

cd "$INSTALL_DIR"

#######################################
# Setup conda environment
#######################################
print_info "Setting up Python environment..."

if [ ! -d "$INSTALL_DIR/.conda" ]; then
    # Check if conda/mamba available
    if command -v mamba &> /dev/null; then
        print_info "Using mamba to create environment..."
        mamba create -y -p "$INSTALL_DIR/.conda" python=3.11
    elif command -v conda &> /dev/null; then
        print_info "Using conda to create environment..."
        conda create -y -p "$INSTALL_DIR/.conda" python=3.11
    else
        # Install micromamba
        print_info "Installing micromamba..."
        cd /tmp
        curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba
        sudo mv bin/micromamba /usr/local/bin/
        rm -rf bin
        
        cd "$INSTALL_DIR"
        micromamba create -y -p "$INSTALL_DIR/.conda" python=3.11
    fi
    print_status "Python environment created"
else
    print_status "Python environment already exists"
fi

# Install Python dependencies
print_info "Installing Python dependencies..."
"$INSTALL_DIR/.conda/bin/pip" install -q -r "$INSTALL_DIR/requirements.txt"
print_status "Dependencies installed"

#######################################
# Run deployment script
#######################################
echo ""
print_info "Running deployment script..."
echo ""

DEPLOY_ARGS="-d $DOMAIN -u $USERNAME -p $TERMINAL_PORT -P $INSTALL_DIR/.conda/bin/python"

if [ -n "$BASE_PATH" ]; then
    DEPLOY_ARGS="$DEPLOY_ARGS -b $BASE_PATH"
fi

if [ -n "$NGINX_MODE" ]; then
    DEPLOY_ARGS="$DEPLOY_ARGS --$NGINX_MODE"
fi

if [ "$SKIP_SSL" = true ]; then
    DEPLOY_ARGS="$DEPLOY_ARGS -s"
fi

if [ "$SKIP_VSCODE" = true ]; then
    DEPLOY_ARGS="$DEPLOY_ARGS -c"
fi

bash "$INSTALL_DIR/deploy.sh" $DEPLOY_ARGS

#######################################
# Done
#######################################
echo ""
echo "========================================"
echo -e "${GREEN}  ✨ Installation Complete!${NC}"
echo "========================================"
echo ""
echo "Your remote development environment is now running at:"
if [ "$SKIP_SSL" = true ]; then
    echo -e "  ${BLUE}http://$DOMAIN${NC}"
else
    echo -e "  ${BLUE}https://$DOMAIN${NC}"
fi
echo ""
echo "Installed to: $INSTALL_DIR"
echo ""
echo "Useful commands:"
echo "  View logs:      sudo journalctl -u rdock -f"
echo "  Restart:        sudo systemctl restart rdock"
echo "  Update:         cd $INSTALL_DIR && git pull && sudo systemctl restart rdock"
echo "  Uninstall:      curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/install.sh | bash -s -- --uninstall"
echo ""
