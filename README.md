# 🚢 rdock

Persistent dev station for remote development. One command to deploy a complete development environment with persistent terminal and VS Code in your browser. No need to consistently relogin to your SSH every single time 

<p align="center">
  <img src="https://img.shields.io/badge/Python-3.11+-blue.svg" alt="Python 3.11+">
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License">
</p>

## ✨ Features

- **🔒 Secure**: HTTPS with Let's Encrypt SSL + password authentication
- **💾 Persistent**: Sessions survive browser restarts using tmux
- **🎨 Modern UI**: Clean, dark interface with tabbed terminals
- **📁 VS Code**: Built-in VS Code web editor (optional)
- **🚀 One Command**: Install and deploy in seconds
- **🔄 Auto-restart**: systemd service ensures 24/7 uptime
- **🌍 Cross-browser**: State synced server-side

## 📦 Quick Install

**One-line installation:**

```bash
curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/install.sh | bash -s -- \
  -d rdock.yourdomain.com \
  -u admin
```

Replace:
- `rdock.yourdomain.com` with your domain
- `admin` with your desired username

You'll be prompted to create a password during installation.

## 📋 Requirements

- **OS**: Ubuntu 20.04+ or Debian 10+ (with sudo access)
- **DNS**: Domain pointing to your server's IP
- **Ports**: 80 (HTTP) and 443 (HTTPS) open

## 🎯 Usage

After installation, access your environment at:
- `https://your-domain.com` (rdock terminal)
- `https://your-domain.com/code/` (VS Code, if enabled)

### Keyboard Shortcuts

- `Cmd/Ctrl+T` - New terminal tab
- `Cmd/Ctrl+W` - Close current tab (overrides browser close)
- `Ctrl+Tab` - Next tab
- `Ctrl+Shift+Tab` - Previous tab
- `Ctrl+Shift+E` - Open VS Code tab

### Managing the Service

```bash
# View logs
sudo journalctl -u rdock -f

# Restart service
sudo systemctl restart rdock

# Check status
sudo systemctl status rdock

# Update to latest version
cd ~/.rdock && git pull && sudo systemctl restart rdock
```

## 💻 VS Code Only (Standalone)

Want just VS Code in your browser without the full rdock terminal? Use the lightweight installer:

**One-liner (interactive - asks you everything):**

```bash
curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/install-vscode.sh | bash
```

**One-liner with flags (no prompts):**

```bash
curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/install-vscode.sh | bash -s -- \
  -d myserver.example.com \
  -p 8893 \
  -u admin
```

This installs the official VS Code CLI, sets up nginx to reverse-proxy at `https://DOMAIN/code/`, configures SSL, and runs it as a systemd service. If an nginx config already exists for the domain, it appends the `/code/` location block.

| Flag | Description | Default |
|------|-------------|---------|
| `-d` | Domain name | _(prompted)_ |
| `-p` | Local port | `8893` |
| `-u` | Username for basic auth | _(none)_ |
| `--no-auth` | Skip basic auth | |
| `-s` | Skip SSL/certbot | |

## ⚙️ Advanced Options

### Skip SSL (use existing certificate)

```bash
curl -fsSL <url>/install.sh | bash -s -- -d domain.com -u admin -s
```

### Skip VS Code

```bash
curl -fsSL <url>/install.sh | bash -s -- -d domain.com -u admin -c
```

### Custom port

```bash
curl -fsSL <url>/install.sh | bash -s -- -d domain.com -u admin -p 9000
```

### Manual Installation

```bash
# Clone repository
git clone https://github.com/younghyopark/rdock.git ~/.rdock
cd ~/.rdock

# Create Python environment
conda create -p .conda python=3.11
.conda/bin/pip install -r requirements.txt

# Run deployment
bash deploy.sh -d your-domain.com -u admin
```

## 🔐 Security

- **Authentication**: HTTP Basic Auth via nginx (bcrypt hashed passwords)
- **Encryption**: TLS 1.2+ with Let's Encrypt certificates
- **Sessions**: 30-day secure cookies (httponly)
- **Isolation**: Runs as non-root user with minimal permissions

### Add Additional Users

```bash
sudo htpasswd /etc/nginx/.htpasswd newuser
```

## 🗑️ Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/install.sh | bash -s -- --uninstall
```

Or manually:

```bash
sudo systemctl stop rdock vscode-web
sudo systemctl disable rdock vscode-web
sudo rm /etc/systemd/system/rdock.service
sudo rm /etc/systemd/system/vscode-web.service
rm -rf ~/.rdock
```

## 🛠️ Troubleshooting

### Service not responding

```bash
# Check service status
sudo systemctl status rdock

# View detailed logs
sudo journalctl -u rdock -n 50

# Restart service
sudo systemctl restart rdock
```

### SSL certificate issues

```bash
# Test certificate renewal
sudo certbot renew --dry-run

# Force renewal
sudo certbot renew --force-renewal
```

### Port already in use

```bash
# Check what's using the port
sudo lsof -i :8890

# Change port during installation
curl -fsSL <url>/install.sh | bash -s -- -d domain.com -u admin -p 9000
```

## 🏗️ Architecture

```
┌─────────────┐
│   Browser   │
└──────┬──────┘
       │ HTTPS (443)
       ▼
┌─────────────┐
│    nginx    │ ◄─── SSL/TLS termination, Basic Auth
└──────┬──────┘
       │ HTTP (8890)
       ▼
┌─────────────┐
│  server.py  │ ◄─── Python/aiohttp WebSocket server
└──────┬──────┘
       │
       ▼
┌─────────────┐
│    tmux     │ ◄─── Persistent terminal sessions
└─────────────┘
```

## 📝 Configuration Files

- **Install location**: `~/.rdock/`
- **Server state**: `~/.rdock_state.json`
- **nginx config**: `/etc/nginx/sites-available/YOUR_DOMAIN`
- **Auth file**: `/etc/nginx/.htpasswd`
- **systemd service**: `/etc/systemd/system/rdock.service`

## 🤝 Contributing

Contributions welcome! Please feel free to submit a Pull Request.

## 📄 License

MIT License - see LICENSE file for details

## 🙏 Acknowledgments

Inspired by [oh-my-tmux](https://github.com/gpakosz/.tmux) for the one-line install approach.

## 💡 Tips

- Use tmux features like split panes within the web terminal
- Create named tmux sessions for different projects
- Recent VS Code workspaces are remembered server-side
- Sessions persist across browser restarts and even server reboots

---

**Made with ❤️ for remote developers**
