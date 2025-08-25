#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
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

# Update system packages
print_info "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# Install system dependencies
print_info "Installing system dependencies..."
apt-get install -y python3 python3-pip python3-venv git curl wget iptables-persistent

# Clone the project from GitHub
print_info "Cloning Sublyne project from GitHub..."
cd /tmp
if [ -d "Sublyne" ]; then
    rm -rf Sublyne
fi

git clone https://github.com/PatrickStatus/Sublyne.git
if [ ! -d "Sublyne" ]; then
    print_error "Failed to clone Sublyne repository"
    exit 1
fi

cd Sublyne
print_success "Successfully cloned Sublyne project"
print_info "Project contents:"
ls -la

# Check if requirements.txt exists
if [ ! -f "requirements.txt" ]; then
    print_error "requirements.txt not found in cloned repository"
    print_info "Contents of cloned directory:"
    ls -la
    exit 1
fi

print_success "Found requirements.txt in cloned repository"

# Download and install Gost
print_info "Installing Gost..."
wget -O /tmp/gost.tar.gz https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.tar.gz
tar -xzf /tmp/gost.tar.gz -C /tmp/
mv /tmp/gost-linux-amd64-2.11.5/gost /usr/local/bin/
chmod +x /usr/local/bin/gost
rm -rf /tmp/gost*

# Create sublyne user if it doesn't exist
if ! id "sublyne" &>/dev/null; then
    print_info "Creating sublyne user..."
    useradd -r -s /bin/bash -d /opt/sublyne sublyne
fi

# Create project directory and copy files
print_info "Setting up project directory..."
mkdir -p /opt/sublyne
cp -r /tmp/Sublyne/* /opt/sublyne/
chown -R sublyne:sublyne /opt/sublyne

# Setup Python virtual environment
print_info "Setting up Python virtual environment..."
cd /opt/sublyne
sudo -u sublyne python3 -m venv venv
sudo -u sublyne /opt/sublyne/venv/bin/pip install --upgrade pip

# Install Python dependencies
print_info "Installing Python dependencies..."
if [ -f "/opt/sublyne/requirements.txt" ]; then
    sudo -u sublyne /opt/sublyne/venv/bin/pip install -r /opt/sublyne/requirements.txt
    print_success "Python dependencies installed successfully"
else
    print_error "requirements.txt not found in /opt/sublyne"
    exit 1
fi

# Initialize database
print_info "Initializing database..."
cd /opt/sublyne/backend
sudo -u sublyne /opt/sublyne/venv/bin/python -c "from app.db.init_db import init_database; init_database()"
print_success "Database initialized successfully"

# Make startup script executable
if [ -f "/opt/sublyne/backend/startup.sh" ]; then
    chmod +x /opt/sublyne/backend/startup.sh
    print_success "Made startup.sh executable"
fi

# Create systemd service
print_info "Creating systemd service..."
cat > /etc/systemd/system/sublyne.service << EOF
[Unit]
Description=Sublyne Tunnel Management Service
After=network.target

[Service]
Type=simple
User=sublyne
Group=sublyne
WorkingDirectory=/opt/sublyne/backend
Environment=PATH=/opt/sublyne/venv/bin
ExecStart=/opt/sublyne/venv/bin/python main.py
ExecStartPre=/opt/sublyne/backend/startup.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
print_info "Enabling and starting Sublyne service..."
systemctl daemon-reload
systemctl enable sublyne
systemctl start sublyne

# Check service status
print_info "Checking service status..."
sleep 5
if systemctl is-active --quiet sublyne; then
    print_success "Sublyne service is running successfully!"
    print_info "Service status:"
    systemctl status sublyne --no-pager
else
    print_error "Sublyne service failed to start"
    print_info "Service logs:"
    journalctl -u sublyne --no-pager -n 20
    exit 1
fi

# Cleanup
print_info "Cleaning up temporary files..."
rm -rf /tmp/Sublyne

print_success "Installation completed successfully!"
print_info "Sublyne is now running on http://localhost:8000"
print_info "You can check the service status with: systemctl status sublyne"
print_info "View logs with: journalctl -u sublyne -f"
print_info "Access the web interface at: http://your-server-ip:8000"
