#!/bin/bash

# Simple Sublyne Installation Script
set -e  # Exit on any error

echo "=== Sublyne Installation Script ==="
echo "Starting installation..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Update system
echo "[1/8] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y python3 python3-pip python3-venv git wget curl iptables-persistent > /dev/null 2>&1

# Install Gost
echo "[2/8] Installing Gost..."
wget -q -O /tmp/gost.tar.gz https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.tar.gz
tar -xzf /tmp/gost.tar.gz -C /tmp/
mv /tmp/gost-linux-amd64-2.11.5/gost /usr/local/bin/
chmod +x /usr/local/bin/gost
rm -rf /tmp/gost*

# Create user
echo "[3/8] Creating sublyne user..."
if ! id "sublyne" &>/dev/null; then
    useradd -r -s /bin/bash -d /opt/sublyne sublyne
fi

# Download project
echo "[4/8] Downloading Sublyne project..."
rm -rf /tmp/sublyne-download
mkdir -p /tmp/sublyne-download
cd /tmp/sublyne-download
git clone -q https://github.com/PatrickStatus/Sublyne.git .

# Setup project directory
echo "[5/8] Setting up project files..."
rm -rf /opt/sublyne
mkdir -p /opt/sublyne
cp -r * /opt/sublyne/
chown -R sublyne:sublyne /opt/sublyne

# Setup Python environment
echo "[6/8] Setting up Python environment..."
cd /opt/sublyne
sudo -u sublyne python3 -m venv venv
sudo -u sublyne ./venv/bin/pip install -q --upgrade pip
sudo -u sublyne ./venv/bin/pip install -q -r requirements.txt

# Initialize database
echo "[7/8] Initializing database..."
cd /opt/sublyne/backend
sudo -u sublyne ../venv/bin/python -c "from app.db.init_db import init_database; init_database()" 2>/dev/null || echo "Database already exists"

# Create and start service
echo "[8/8] Creating system service..."
chmod +x /opt/sublyne/backend/startup.sh 2>/dev/null || true

cat > /etc/systemd/system/sublyne.service << 'EOF'
[Unit]
Description=Sublyne Tunnel Service
After=network.target

[Service]
Type=simple
User=sublyne
Group=sublyne
WorkingDirectory=/opt/sublyne/backend
Environment=PATH=/opt/sublyne/venv/bin
ExecStart=/opt/sublyne/venv/bin/python main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sublyne
systemctl start sublyne

# Cleanup
rm -rf /tmp/sublyne-download

# Check status
sleep 3
if systemctl is-active --quiet sublyne; then
    echo "✅ Installation completed successfully!"
    echo "📍 Sublyne is running on: http://localhost:8000"
    echo "📊 Check status: systemctl status sublyne"
    echo "📋 View logs: journalctl -u sublyne -f"
else
    echo "❌ Service failed to start. Check logs: journalctl -u sublyne"
    exit 1
fi
