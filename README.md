# setup-vscode-web

Simple, secure VS Code Web setup helper. One command to get VS Code running in your browser with HTTPS and password authentication.

## Quick Start

Just run this — it will ask you everything interactively:

```bash
curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/setup-vscode-web.sh | bash
```

Works over SSH too. You'll be prompted for domain, username, port, and password.

Or pass flags to skip the prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/setup-vscode-web.sh | bash -s -- \
  -d dev.example.com \
  -u admin
```

## What It Does

1. Installs the official [VS Code CLI](https://code.visualstudio.com/docs/remote/tunnels)
2. Sets up nginx as a reverse proxy
3. Configures HTTPS with Let's Encrypt (auto-renewal)
4. Adds password authentication (HTTP Basic Auth, bcrypt)
5. Adds security headers (HSTS, X-Frame-Options, etc.)
6. Creates a systemd service for auto-start on boot

## Requirements

- **OS**: Ubuntu 20.04+ or Debian 10+ (with sudo access)
- **DNS**: Domain pointing to your server's IP
- **Ports**: 80 and 443 open

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `-d, --domain` | Domain name | _(prompted)_ |
| `-u, --username` | Username for auth (required) | _(prompted)_ |
| `-p, --port` | Local port for VS Code | `8893` |
| `-b, --base-path` | URL path prefix | `/code` |
| `-s, --skip-ssl` | Skip SSL (not recommended) | |
| `--uninstall` | Remove VS Code Web service | |

## Security

All security measures are enabled by default:

- **HTTPS enforced** — HTTP automatically redirects to HTTPS (via certbot)
- **HSTS** — browsers remember to always use HTTPS (`max-age=31536000`)
- **Password auth required** — HTTP Basic Auth with bcrypt-hashed passwords
- **Security headers** — `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`
- **Localhost binding** — VS Code only listens on `127.0.0.1`, never exposed directly
- **Non-root** — runs as your regular user via systemd

### Add / Remove Users

```bash
# Add a user
sudo htpasswd /etc/nginx/.htpasswd newuser

# Remove a user
sudo htpasswd -D /etc/nginx/.htpasswd olduser
```

## Managing the Service

```bash
# View logs
sudo journalctl -u vscode-web -f

# Restart
sudo systemctl restart vscode-web

# Check status
sudo systemctl status vscode-web

# Renew SSL certificate
sudo certbot renew
```

## Architecture

```
Browser (HTTPS/443)
    |
nginx (SSL termination + Basic Auth + Security Headers)
    |
code-cli serve-web (127.0.0.1:8893)
    |
VS Code Web UI
```

## Configuration Files

| File | Purpose |
|------|---------|
| `/etc/nginx/sites-available/DOMAIN` | nginx config |
| `/etc/nginx/.htpasswd` | User credentials (bcrypt) |
| `/etc/letsencrypt/live/DOMAIN/` | SSL certificates |
| `/etc/systemd/system/vscode-web.service` | systemd unit |

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/setup-vscode-web.sh | bash -s -- --uninstall
```

## Legacy

The `legacy/` folder contains the original rdock project — a full remote development environment with a web-based terminal (xterm.js + tmux persistence) and integrated VS Code. See `legacy/REFERENCE.md` for details.

## License

MIT
