#!/bin/bash

# Sublyne Auto Installation Script
# Usage: curl -sSL https://raw.githubusercontent.com/PatrickStatus/Sublyne/main/install.sh | sudo bash

set -e  # Exit on any error

echo "=== Sublyne Auto Installation Script ==="
echo "Starting installation..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root (use sudo)"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Set non-interactive mode for apt
export DEBIAN_FRONTEND=noninteractive

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
else
    print_error "Cannot detect OS"
    exit 1
fi

print_status "Detected OS: $OS $VER"

# Update system packages
print_status "Updating system packages..."
if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
    apt update && apt upgrade -y
    PACKAGE_MANAGER="apt"
elif [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Red Hat"* ]] || [[ "$OS" == *"Rocky"* ]]; then
    yum update -y
    PACKAGE_MANAGER="yum"
else
    print_error "Unsupported OS: $OS"
    exit 1
fi

# Pre-configure iptables-persistent to avoid interactive prompts
if [ "$PACKAGE_MANAGER" = "apt" ]; then
    print_status "Pre-configuring iptables-persistent..."
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
fi

# Install required system packages
print_status "Installing system dependencies..."
if [ "$PACKAGE_MANAGER" = "apt" ]; then
    apt install -y python3 python3-pip python3-venv unzip curl wget iptables-persistent net-tools
elif [ "$PACKAGE_MANAGER" = "yum" ]; then
    yum install -y python3 python3-pip unzip curl wget iptables-services net-tools
    systemctl enable iptables
fi

# Install gost (for tunneling)
print_status "Installing gost..."
GOST_VERSION="2.11.5"
wget -O /tmp/gost.tar.gz "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-amd64-${GOST_VERSION}.gz"
tar -xzf /tmp/gost.tar.gz -C /tmp/
mv "/tmp/gost-linux-amd64-${GOST_VERSION}/gost" /usr/local/bin/
chmod +x /usr/local/bin/gost
rm -rf /tmp/gost*
print_status "Gost installed successfully"

# Create sublyne user
print_status "Creating sublyne user..."
if ! id "sublyne" &>/dev/null; then
    useradd -m -s /bin/bash sublyne
    print_status "User 'sublyne' created"
else
    print_warning "User 'sublyne' already exists"
fi

# Create application directory
print_status "Setting up application directory..."
APP_DIR="/opt/sublyne"
mkdir -p $APP_DIR
chown sublyne:sublyne $APP_DIR

# Download and extract project from GitHub
print_status "Downloading project from GitHub..."
cd /tmp
wget -O sublyne.zip "https://github.com/PatrickStatus/Sublyne/raw/main/sublyne.zip"
if [ ! -f "sublyne.zip" ]; then
    print_error "Failed to download sublyne.zip from GitHub"
    exit 1
fi

print_status "Extracting project files..."
unzip -o sublyne.zip -d $APP_DIR
chown -R sublyne:sublyne $APP_DIR
rm -f /tmp/sublyne.zip

# Setup Python virtual environment
print_status "Setting up Python virtual environment..."
su - sublyne -c "cd $APP_DIR && python3 -m venv venv"
su - sublyne -c "cd $APP_DIR && source venv/bin/activate && pip install --upgrade pip"

# Check if requirements.txt exists
if [ -f "$APP_DIR/requirements.txt" ]; then
    su - sublyne -c "cd $APP_DIR && source venv/bin/activate && pip install -r requirements.txt"
else
    print_warning "requirements.txt not found, installing basic dependencies"
    su - sublyne -c "cd $APP_DIR && source venv/bin/activate && pip install fastapi uvicorn sqlalchemy psutil"
fi

# Create database directory
print_status "Setting up database..."
mkdir -p $APP_DIR/database
chown sublyne:sublyne $APP_DIR/database

# Create systemd service
print_status "Creating systemd service..."
cat > /etc/systemd/system/sublyne.service << EOF
[Unit]
Description=Sublyne Tunnel Management API
After=network.target

[Service]
Type=simple
User=sublyne
Group=sublyne
WorkingDirectory=$APP_DIR/backend
Environment=PATH=$APP_DIR/venv/bin
ExecStart=$APP_DIR/venv/bin/python main.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Enable IP forwarding
print_status "Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
sysctl -p

# Setup firewall rules
print_status "Setting up firewall rules..."
# Clear existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Set default policies
iptables -P INPUT DROP
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH (port 22)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Allow API port (8000)
iptables -A INPUT -p tcp --dport 8000 -j ACCEPT

# Allow ping
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# Save iptables rules without prompts
print_status "Saving iptables rules..."
if [ "$PACKAGE_MANAGER" = "apt" ]; then
    # Create directories if they don't exist
    mkdir -p /etc/iptables
    # Save rules directly
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    print_status "Iptables rules saved to /etc/iptables/"
elif [ "$PACKAGE_MANAGER" = "yum" ]; then
    service iptables save
fi

# Create startup script for iptables restoration (if exists)
if [ -f "$APP_DIR/backend/startup.sh" ]; then
    print_status "Setting up startup script..."
    cp $APP_DIR/backend/startup.sh /etc/init.d/sublyne-startup
    chmod +x /etc/init.d/sublyne-startup
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        update-rc.d sublyne-startup defaults
    elif [ "$PACKAGE_MANAGER" = "yum" ]; then
        chkconfig --add sublyne-startup
        chkconfig sublyne-startup on
    fi
fi

# Start and enable service
print_status "Starting Sublyne service..."
systemctl daemon-reload
systemctl enable sublyne
systemctl start sublyne

# Wait for service to start
print_status "Waiting for service to start..."
sleep 10

# Check service status
if systemctl is-active --quiet sublyne; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${GREEN}✅ Sublyne service is running successfully!${NC}"
    echo -e "${GREEN}🌐 API is available at: http://${SERVER_IP}:8000${NC}"
    echo -e "${GREEN}📚 API Documentation: http://${SERVER_IP}:8000/docs${NC}"
    echo -e "${GREEN}🔧 Redoc Documentation: http://${SERVER_IP}:8000/redoc${NC}"
else
    echo -e "${RED}❌ Sublyne service failed to start${NC}"
    echo -e "${YELLOW}Check logs with: journalctl -u sublyne -f${NC}"
    echo -e "${YELLOW}Service status: systemctl status sublyne${NC}"
    exit 1
fi

echo ""
echo "=== Installation completed successfully! ==="
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  Start service:   systemctl start sublyne"
echo "  Stop service:    systemctl stop sublyne"
echo "  Restart service: systemctl restart sublyne"
echo "  View logs:       journalctl -u sublyne -f"
echo "  Service status:  systemctl status sublyne"
echo ""
echo -e "${YELLOW}Default admin credentials:${NC}"
echo "  Username: admin"
echo "  Password: admin123"
echo ""
echo -e "${GREEN}🎉 Sublyne is ready to use!${NC}"
