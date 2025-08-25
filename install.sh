#!/bin/bash

# Simple Sublyne Installation Script with Better Error Handling
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
echo "✅ System packages updated"

# Install Gost with correct format
echo "[2/8] Installing Gost..."
GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
echo "Downloading Gost from: $GOST_URL"

# Try downloading with timeout
if timeout 60 wget -q --show-progress -O /tmp/gost.gz "$GOST_URL"; then
    echo "✅ Gost downloaded successfully"
else
    echo "❌ Failed to download Gost. Trying alternative method..."
    # Try with curl as fallback
    if timeout 60 curl -L -o /tmp/gost.gz "$GOST_URL"; then
        echo "✅ Gost downloaded with curl"
    else
        echo "❌ Failed to download Gost with both wget and curl"
        echo "Please check your internet connection and try again"
        exit 1
    fi
fi

# Extract and install Gost (it's a gzipped binary, not tar.gz)
echo "Extracting and installing Gost..."
if gunzip -c /tmp/gost.gz > /usr/local/bin/gost; then
    chmod +x /usr/local/bin/gost
    rm -f /tmp/gost.gz
    echo "✅ Gost installed successfully"
else
    echo "❌ Failed to extract Gost archive"
    exit 1
fi

# Verify Gost installation
if /usr/local/bin/gost -V > /dev/null 2>&1; then
    echo "✅ Gost verification successful"
else
    echo "❌ Gost installation verification failed"
    exit 1
fi

# Create user
echo "[3/8] Creating sublyne user..."
if ! id "sublyne" &>/dev/null; then
    useradd -r -s /bin/bash -d /opt/sublyne sublyne
    echo "✅ User sublyne created"
else
    echo "✅ User sublyne already exists"
fi

# Download project
echo "[4/8] Downloading Sublyne project..."
rm -rf /tmp/sublyne-download
mkdir -p /tmp/sublyne-download
cd /tmp/sublyne-download

if timeout 120 git clone -q https://github.com/PatrickStatus/Sublyne.git .; then
    echo "✅ Project downloaded successfully"
else
    echo "❌ Failed to clone repository"
    exit 1
fi

# Setup project directory
echo "[5/8] Setting up project files..."
rm -rf /opt/sublyne
mkdir -p /opt/sublyne
cp -r * /opt/sublyne/
chown -R sublyne:sublyne /opt/sublyne
echo "✅ Project files copied"

# Setup Python environment
echo "[6/8] Setting up Python environment..."
cd /opt/sublyne
sudo -u sublyne python3 -m venv venv
sudo -u sublyne ./venv/bin/pip install -q --upgrade pip
sudo -u sublyne ./venv/bin/pip install -q -r requirements.txt
echo "✅ Python environment ready"

# Initialize database
echo "[7/8] Initializing database..."
cd /opt/sublyne/backend
sudo -u sublyne ../venv/bin/python -c "from app.db.init_db import init_database; init_database()" 2>/dev/null || echo "Database already exists"
echo "✅ Database initialized"

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
echo "✅ Service created and started"

# Cleanup
rm -rf /tmp/sublyne-download

# Check status
echo "Checking service status..."
sleep 3
if systemctl is-active --quiet sublyne; then
    echo "✅ Installation completed successfully!"
    echo "📍 Sublyne is running on: http://localhost:8000"
    echo "📊 Check status: systemctl status sublyne"
    echo "📋 View logs: journalctl -u sublyne -f"
else
    echo "❌ Service failed to start. Checking logs..."
    journalctl -u sublyne --no-pager -n 10
    exit 1
fi
