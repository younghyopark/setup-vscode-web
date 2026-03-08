# Quick Reference

## Installation

### One-line install (recommended)
```bash
curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/install.sh | bash -s -- -d rdock.example.com -u admin
```

### Manual install
```bash
git clone https://github.com/younghyopark/rdock.git ~/.rdock
cd ~/.rdock
conda create -p .conda python=3.11
.conda/bin/pip install -r requirements.txt
bash deploy.sh -d rdock.example.com -u admin
```

## Management Commands

### Service Control
```bash
# Start
sudo systemctl start rdock

# Stop
sudo systemctl stop rdock

# Restart
sudo systemctl restart rdock

# Status
sudo systemctl status rdock

# Enable auto-start on boot
sudo systemctl enable rdock

# Disable auto-start
sudo systemctl disable rdock
```

### Logs
```bash
# Follow live logs
sudo journalctl -u rdock -f

# Last 50 lines
sudo journalctl -u rdock -n 50

# Logs since boot
sudo journalctl -u rdock -b
```

### User Management
```bash
# Add user
sudo htpasswd /etc/nginx/.htpasswd newuser

# Change password
sudo htpasswd /etc/nginx/.htpasswd existinguser

# Remove user
sudo htpasswd -D /etc/nginx/.htpasswd username

# List users
sudo cat /etc/nginx/.htpasswd | cut -d: -f1
```

### Updates
```bash
# Update to latest version
cd ~/.rdock
git pull
sudo systemctl restart rdock
```

### SSL/Certificates
```bash
# Renew certificates (automatic, but can force)
sudo certbot renew

# Test renewal
sudo certbot renew --dry-run

# Check certificate expiry
sudo certbot certificates
```

### Nginx
```bash
# Test config
sudo nginx -t

# Reload config
sudo systemctl reload nginx

# Restart nginx
sudo systemctl restart nginx

# View nginx logs
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/access.log
```

## Troubleshooting

### Server won't start
```bash
# Check logs
sudo journalctl -u rdock -n 100

# Check if port is in use
sudo lsof -i :8890

# Test Python directly
cd ~/.rdock
.conda/bin/python server.py
```

### Can't access via domain
```bash
# Check nginx
sudo systemctl status nginx
sudo nginx -t

# Check DNS
dig +short yourdomain.com

# Check firewall
sudo ufw status
```

### SSL issues
```bash
# Check certificate
sudo certbot certificates

# Renew manually
sudo certbot renew --force-renewal

# Check nginx SSL config
sudo cat /etc/nginx/sites-available/yourdomain.com | grep ssl
```

### Authentication not working
```bash
# Verify htpasswd file
sudo cat /etc/nginx/.htpasswd

# Test credentials
htpasswd -vb /etc/nginx/.htpasswd username password
```

## Development

### Local testing (no nginx/SSL)
```bash
cd ~/.rdock
./test.sh
# Visit http://localhost:8890
```

### Run with custom port
```bash
cd ~/.rdock
.conda/bin/python server.py
# Edit server.py to change port from 8890
```

## File Locations

- **Installation**: `~/.rdock/`
- **Server script**: `~/.rdock/server.py`
- **State file**: `~/.rdock_state.json`
- **Systemd service**: `/etc/systemd/system/rdock.service`
- **Nginx config**: `/etc/nginx/sites-available/YOUR_DOMAIN`
- **Auth file**: `/etc/nginx/.htpasswd`
- **SSL certificates**: `/etc/letsencrypt/live/YOUR_DOMAIN/`

## Uninstall

```bash
# Using install script
curl -fsSL https://raw.githubusercontent.com/younghyopark/rdock/main/install.sh | bash -s -- --uninstall

# Manual
sudo systemctl stop rdock vscode-web
sudo systemctl disable rdock vscode-web
sudo rm /etc/systemd/system/rdock.service /etc/systemd/system/vscode-web.service
sudo rm /etc/nginx/sites-enabled/YOUR_DOMAIN
sudo rm /etc/nginx/sites-available/YOUR_DOMAIN
sudo rm /etc/nginx/.htpasswd
rm -rf ~/.rdock ~/.rdock_state.json
```

## Configuration

### Change port
Edit `/etc/systemd/system/rdock.service`, modify nginx proxy_pass, then:
```bash
sudo systemctl daemon-reload
sudo systemctl restart rdock
sudo systemctl reload nginx
```

### Add custom domain
```bash
# Copy existing config
sudo cp /etc/nginx/sites-available/old-domain.com /etc/nginx/sites-available/new-domain.com
# Edit server_name in new config
sudo nano /etc/nginx/sites-available/new-domain.com
# Enable site
sudo ln -s /etc/nginx/sites-available/new-domain.com /etc/nginx/sites-enabled/
# Get SSL cert
sudo certbot --nginx -d new-domain.com
```
