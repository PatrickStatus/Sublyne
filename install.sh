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
apt-get install -y python3 python3-pip python3-venv git wget curl iptables-persistent unzip > /dev/null 2>&1
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

# Download Sublyne project from GitHub
echo "[3/8] Downloading Sublyne project from GitHub..."
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
ZIP_FILE="$SCRIPT_DIR/sublyne.zip"

# Download the zip file if it doesn't exist
if [ ! -f "$ZIP_FILE" ]; then
    echo "Downloading sublyne.zip from GitHub..."
    if command -v wget >/dev/null 2>&1; then
        wget -O "$ZIP_FILE" "https://github.com/PatrickStatus/Sublyne/raw/main/sublyne.zip"
    elif command -v curl >/dev/null 2>&1; then
        curl -L -o "$ZIP_FILE" "https://github.com/PatrickStatus/Sublyne/raw/main/sublyne.zip"
    else
        echo "❌ Neither wget nor curl is available. Please install one of them."
        exit 1
    fi
    
    if [ ! -f "$ZIP_FILE" ]; then
        echo "❌ Failed to download sublyne.zip"
        exit 1
    fi
    echo "✅ sublyne.zip downloaded successfully"
else
    echo "✅ sublyne.zip already exists, skipping download"
fi

# Extract project from local zip file
echo "[4/8] Extracting Sublyne project from local zip..."
rm -rf /tmp/sublyne-extract
mkdir -p /tmp/sublyne-extract

echo "Extracting $ZIP_FILE to /tmp/sublyne-extract..."
if unzip -q "$ZIP_FILE" -d /tmp/sublyne-extract; then
    echo "✅ Project extracted successfully"
else
    echo "❌ Failed to extract sublyne.zip"
    exit 1
fi

# Setup project directory
echo "[5/8] Setting up project files..."
rm -rf /opt/sublyne
mkdir -p /opt/sublyne

# Copy all extracted files with absolute paths
cp -a /tmp/sublyne-extract/* /opt/sublyne/ 2>/dev/null || cp -a /tmp/sublyne-extract/.* /opt/sublyne/ 2>/dev/null || true
chown -R sublyne:sublyne /opt/sublyne
echo "✅ Project files copied"

# Verify project structure
echo "Verifying project structure..."
if [ ! -d "/opt/sublyne/backend" ]; then
    echo "❌ Backend directory not found"
    echo "Available directories in /opt/sublyne:"
    ls -la /opt/sublyne/
    exit 1
fi

if [ ! -f "/opt/sublyne/requirements.txt" ]; then
    echo "❌ requirements.txt not found"
    echo "Available files in /opt/sublyne:"
    ls -la /opt/sublyne/
    exit 1
fi

echo "✅ Project structure verified"

# Setup Python environment
echo "[6/8] Setting up Python environment..."
# Use absolute paths, no cd
sudo -u sublyne python3 -m venv /opt/sublyne/venv
sudo -u sublyne /opt/sublyne/venv/bin/pip install -q --upgrade pip
sudo -u sublyne /opt/sublyne/venv/bin/pip install -q -r /opt/sublyne/requirements.txt
echo "✅ Python environment ready"

# Initialize database
echo "[7/8] Initializing database..."
# Use absolute paths for database initialization
sudo -u sublyne /opt/sublyne/venv/bin/python -c "import sys; sys.path.append('/opt/sublyne/backend'); from app.db.init_db import init_database; init_database()" 2>/dev/null || echo "Database already exists"
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
rm -rf /tmp/sublyne-extract

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
