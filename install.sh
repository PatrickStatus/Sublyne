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

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root for security reasons."
   print_status "Please run as a regular user with sudo privileges."
   exit 1
fi

# Check if sudo is available
if ! command -v sudo &> /dev/null; then
    print_error "sudo is required but not installed. Please install sudo first."
    exit 1
fi

print_status "Starting Sublyne installation..."

# Update system packages
print_status "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install required system dependencies
print_status "Installing system dependencies..."
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
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
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections

# Install Gost (corrected download link and extraction)
print_status "Installing Gost..."
GOST_VERSION="2.11.5"
GOST_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-amd64-${GOST_VERSION}.gz"
GOST_DIR="/opt/gost"

sudo mkdir -p $GOST_DIR
cd /tmp
wget $GOST_URL -O gost-linux-amd64.gz

# Extract the .gz file (not tar.gz)
gunzip gost-linux-amd64.gz
sudo mv gost-linux-amd64 $GOST_DIR/gost
sudo chmod +x $GOST_DIR/gost

# Add Gost to PATH
echo "export PATH=\$PATH:$GOST_DIR" | sudo tee /etc/profile.d/gost.sh
sudo chmod +x /etc/profile.d/gost.sh

# Create sublyne user
print_status "Creating sublyne user..."
if ! id "sublyne" &>/dev/null; then
    sudo useradd -r -s /bin/bash -d /opt/sublyne -m sublyne
    print_success "User 'sublyne' created successfully"
else
    print_warning "User 'sublyne' already exists"
fi

# Download and extract Sublyne project
print_status "Downloading Sublyne project..."
PROJECT_DIR="/opt/sublyne"
sudo mkdir -p $PROJECT_DIR
cd /tmp

# Download the latest release or main branch
wget https://github.com/PatrickStatus/Sublyne/archive/refs/heads/main.zip -O sublyne.zip
sudo unzip -o sublyne.zip -d /tmp/
sudo cp -r /tmp/Sublyne-main/* $PROJECT_DIR/
sudo chown -R sublyne:sublyne $PROJECT_DIR

# Setup Python virtual environment
print_status "Setting up Python virtual environment..."
sudo -u sublyne python3 -m venv $PROJECT_DIR/venv
sudo -u sublyne $PROJECT_DIR/venv/bin/pip install --upgrade pip

# Install Python dependencies
print_status "Installing Python dependencies..."
if [ -f "$PROJECT_DIR/requirements.txt" ]; then
    sudo -u sublyne $PROJECT_DIR/venv/bin/pip install -r $PROJECT_DIR/requirements.txt
else
    print_warning "requirements.txt not found, installing basic dependencies..."
    sudo -u sublyne $PROJECT_DIR/venv/bin/pip install fastapi uvicorn sqlalchemy psutil
fi

# Create database directory
sudo mkdir -p $PROJECT_DIR/database
sudo chown -R sublyne:sublyne $PROJECT_DIR/database

# Initialize database
print_status "Initializing database..."
cd $PROJECT_DIR/backend
sudo -u sublyne $PROJECT_DIR/venv/bin/python -c "from app.db.init_db import init_database; init_database()"

# Create systemd service
print_status "Creating systemd service..."
sudo tee /etc/systemd/system/sublyne.service > /dev/null <<EOF
[Unit]
Description=Sublyne Tunnel Management System
After=network.target

[Service]
Type=simple
User=sublyne
Group=sublyne
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
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
# Allow Sublyne API (port 8000)
sudo iptables -A INPUT -p tcp --dport 8000 -j ACCEPT
# Allow established connections
sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow loopback
sudo iptables -A INPUT -i lo -j ACCEPT
# Drop other incoming connections
sudo iptables -A INPUT -j DROP

# Save iptables rules
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null
sudo ip6tables-save | sudo tee /etc/iptables/rules.v6 > /dev/null

# Enable and start services
print_status "Enabling and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable sublyne
sudo systemctl enable netfilter-persistent
sudo systemctl start netfilter-persistent
sudo systemctl start sublyne

# Create startup script for traffic rules restoration
print_status "Creating startup script..."
sudo tee $PROJECT_DIR/restore_traffic.py > /dev/null <<'EOF'
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

sudo chmod +x $PROJECT_DIR/restore_traffic.py
sudo chown sublyne:sublyne $PROJECT_DIR/restore_traffic.py

# Add to crontab for startup
(sudo crontab -u sublyne -l 2>/dev/null; echo "@reboot $PROJECT_DIR/venv/bin/python $PROJECT_DIR/restore_traffic.py") | sudo crontab -u sublyne -

# Final status check
print_status "Checking service status..."
sleep 5
if sudo systemctl is-active --quiet sublyne; then
    print_success "Sublyne service is running successfully!"
else
    print_error "Sublyne service failed to start. Check logs with: sudo journalctl -u sublyne -f"
fi

# Display final information
print_success "\n=== Sublyne Installation Completed ==="
print_status "Service Status: $(sudo systemctl is-active sublyne)"
print_status "API Endpoint: http://$(hostname -I | awk '{print $1}'):8000"
print_status "API Documentation: http://$(hostname -I | awk '{print $1}'):8000/docs"
print_status "\nUseful Commands:"
print_status "  - Check service status: sudo systemctl status sublyne"
print_status "  - View logs: sudo journalctl -u sublyne -f"
print_status "  - Restart service: sudo systemctl restart sublyne"
print_status "  - Stop service: sudo systemctl stop sublyne"
print_status "\nDefault API credentials:"
print_status "  - Username: admin"
print_status "  - Password: admin"

print_success "Installation completed successfully!"
