#!/bin/bash

# Sublyne Auto Installation Script
# This script automatically installs Sublyne tunnel management system

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Determine if we need sudo or not
if [[ $EUID -eq 0 ]]; then
    SUDO_CMD=""
    print_warning "Running as root user"
else
    SUDO_CMD="sudo"
    print_status "Running as regular user with sudo"
fi

print_status "Starting Sublyne installation..."

# Update system packages
print_status "Updating system packages..."
$SUDO_CMD apt update && $SUDO_CMD apt upgrade -y

# Install required system dependencies
print_status "Installing system dependencies..."
$SUDO_CMD DEBIAN_FRONTEND=noninteractive apt install -y \
    python3 \
    python3-pip \
    python3-venv \
    git \
    curl \
    wget \
    unzip \
    iptables \
    iptables-persistent \
    netfilter-persistent \
    systemd \
    cron

# Pre-configure iptables-persistent to avoid interactive prompts
print_status "Configuring iptables-persistent..."
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | $SUDO_CMD debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | $SUDO_CMD debconf-set-selections

# Install Gost (corrected download link and extraction)
print_status "Installing Gost..."
GOST_VERSION="2.11.5"
GOST_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-amd64-${GOST_VERSION}.gz"
GOST_DIR="/opt/gost"

$SUDO_CMD mkdir -p $GOST_DIR
cd /tmp
wget $GOST_URL -O gost-linux-amd64.gz

# Extract the .gz file (not tar.gz)
gunzip gost-linux-amd64.gz
$SUDO_CMD mv gost-linux-amd64 $GOST_DIR/gost
$SUDO_CMD chmod +x $GOST_DIR/gost

# Add Gost to PATH
echo "export PATH=\$PATH:$GOST_DIR" | $SUDO_CMD tee /etc/profile.d/gost.sh
$SUDO_CMD chmod +x /etc/profile.d/gost.sh

# Create sublyne user (only if not running as root)
if [[ $EUID -ne 0 ]]; then
    print_status "Creating sublyne user..."
    if ! id "sublyne" &>/dev/null; then
        $SUDO_CMD useradd -r -s /bin/bash -d /opt/sublyne -m sublyne
        print_success "User 'sublyne' created successfully"
    else
        print_warning "User 'sublyne' already exists"
    fi
    SUBLYNE_USER="sublyne"
    SUBLYNE_GROUP="sublyne"
else
    print_status "Using root user for installation"
    SUBLYNE_USER="root"
    SUBLYNE_GROUP="root"
fi

# Download and extract Sublyne project
print_status "Downloading Sublyne project..."
PROJECT_DIR="/opt/sublyne"
$SUDO_CMD mkdir -p $PROJECT_DIR
cd /tmp

# Download the latest release or main branch
wget https://github.com/PatrickStatus/Sublyne/archive/refs/heads/main.zip -O sublyne.zip
$SUDO_CMD unzip -o sublyne.zip -d /tmp/
$SUDO_CMD cp -r /tmp/Sublyne-main/* $PROJECT_DIR/
$SUDO_CMD chown -R $SUBLYNE_USER:$SUBLYNE_GROUP $PROJECT_DIR

# Setup Python virtual environment
print_status "Setting up Python virtual environment..."
if [[ $EUID -eq 0 ]]; then
    python3 -m venv $PROJECT_DIR/venv
    $PROJECT_DIR/venv/bin/pip install --upgrade pip
else
    $SUDO_CMD -u sublyne python3 -m venv $PROJECT_DIR/venv
    $SUDO_CMD -u sublyne $PROJECT_DIR/venv/bin/pip install --upgrade pip
fi

# Install Python dependencies
print_status "Installing Python dependencies..."
if [ -f "$PROJECT_DIR/requirements.txt" ]; then
    if [[ $EUID -eq 0 ]]; then
        $PROJECT_DIR/venv/bin/pip install -r $PROJECT_DIR/requirements.txt
    else
        $SUDO_CMD -u sublyne $PROJECT_DIR/venv/bin/pip install -r $PROJECT_DIR/requirements.txt
    fi
else
    print_warning "requirements.txt not found, installing basic dependencies..."
    if [[ $EUID -eq 0 ]]; then
        $PROJECT_DIR/venv/bin/pip install fastapi uvicorn sqlalchemy psutil
    else
        $SUDO_CMD -u sublyne $PROJECT_DIR/venv/bin/pip install fastapi uvicorn sqlalchemy psutil
    fi
fi

# Create database directory
$SUDO_CMD mkdir -p $PROJECT_DIR/database
$SUDO_CMD chown -R $SUBLYNE_USER:$SUBLYNE_GROUP $PROJECT_DIR/database

# Initialize database
print_status "Initializing database..."
cd $PROJECT_DIR/backend
if [[ $EUID -eq 0 ]]; then
    $PROJECT_DIR/venv/bin/python -c "from app.db.init_db import init_database; init_database()"
else
    $SUDO_CMD -u sublyne $PROJECT_DIR/venv/bin/python -c "from app.db.init_db import init_database; init_database()"
fi

# Create systemd service
print_status "Creating systemd service..."
$SUDO_CMD tee /etc/systemd/system/sublyne.service > /dev/null <<EOF
[Unit]
Description=Sublyne Tunnel Management System
After=network.target

[Service]
Type=simple
User=$SUBLYNE_USER
Group=$SUBLYNE_GROUP
WorkingDirectory=$PROJECT_DIR/backend
Environment=PATH=$PROJECT_DIR/venv/bin:/opt/gost
ExecStart=$PROJECT_DIR/venv/bin/python main.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Setup firewall rules
print_status "Configuring firewall rules..."
# Allow SSH (port 22)
$SUDO_CMD iptables -A INPUT -p tcp --dport 22 -j ACCEPT
# Allow Sublyne API (port 8000)
$SUDO_CMD iptables -A INPUT -p tcp --dport 8000 -j ACCEPT
# Allow established connections
$SUDO_CMD iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow loopback
$SUDO_CMD iptables -A INPUT -i lo -j ACCEPT
# Drop other incoming connections
$SUDO_CMD iptables -A INPUT -j DROP

# Save iptables rules
$SUDO_CMD iptables-save | $SUDO_CMD tee /etc/iptables/rules.v4 > /dev/null
$SUDO_CMD ip6tables-save | $SUDO_CMD tee /etc/iptables/rules.v6 > /dev/null

# Enable and start services
print_status "Enabling and starting services..."
$SUDO_CMD systemctl daemon-reload
$SUDO_CMD systemctl enable sublyne
$SUDO_CMD systemctl enable netfilter-persistent
$SUDO_CMD systemctl start netfilter-persistent
$SUDO_CMD systemctl start sublyne

# Create startup script for traffic rules restoration
print_status "Creating startup script..."
$SUDO_CMD tee $PROJECT_DIR/restore_traffic.py > /dev/null <<'EOF'
#!/usr/bin/env python3
import subprocess
import sqlite3
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def restore_traffic_rules():
    try:
        conn = sqlite3.connect('/opt/sublyne/database/sublyne.db')
        cursor = conn.cursor()
        
        cursor.execute("SELECT interface_salt FROM tunnels WHERE status = 'active'")
        active_tunnels = cursor.fetchall()
        
        for tunnel in active_tunnels:
            interface = tunnel[0]
            # Restore traffic monitoring rules
            subprocess.run([
                'iptables', '-A', 'FORWARD', '-i', interface, '-j', 'ACCEPT'
            ], check=True)
            subprocess.run([
                'iptables', '-A', 'FORWARD', '-o', interface, '-j', 'ACCEPT'
            ], check=True)
            
        conn.close()
        logger.info(f"Restored traffic rules for {len(active_tunnels)} tunnels")
        
    except Exception as e:
        logger.error(f"Error restoring traffic rules: {e}")

if __name__ == "__main__":
    restore_traffic_rules()
EOF

$SUDO_CMD chmod +x $PROJECT_DIR/restore_traffic.py
$SUDO_CMD chown $SUBLYNE_USER:$SUBLYNE_GROUP $PROJECT_DIR/restore_traffic.py

# Add to crontab for startup
if [[ $EUID -eq 0 ]]; then
    (crontab -l 2>/dev/null; echo "@reboot $PROJECT_DIR/venv/bin/python $PROJECT_DIR/restore_traffic.py") | crontab -
else
    ($SUDO_CMD crontab -u sublyne -l 2>/dev/null; echo "@reboot $PROJECT_DIR/venv/bin/python $PROJECT_DIR/restore_traffic.py") | $SUDO_CMD crontab -u sublyne -
fi

# Final status check
print_status "Checking service status..."
sleep 5
if $SUDO_CMD systemctl is-active --quiet sublyne; then
    print_success "Sublyne service is running successfully!"
else
    print_error "Sublyne service failed to start. Check logs with: $SUDO_CMD journalctl -u sublyne -f"
fi

# Display final information
print_success "\n=== Sublyne Installation Completed ==="
print_status "Service Status: $($SUDO_CMD systemctl is-active sublyne)"
print_status "API Endpoint: http://$(hostname -I | awk '{print $1}'):8000"
print_status "API Documentation: http://$(hostname -I | awk '{print $1}'):8000/docs"
print_status "\nUseful Commands:"
print_status "  - Check service status: $SUDO_CMD systemctl status sublyne"
print_status "  - View logs: $SUDO_CMD journalctl -u sublyne -f"
print_status "  - Restart service: $SUDO_CMD systemctl restart sublyne"
print_status "  - Stop service: $SUDO_CMD systemctl stop sublyne"
print_status "\nDefault API credentials:"
print_status "  - Username: admin"
print_status "  - Password: admin"

print_success "Installation completed successfully!"
