#!/bin/bash

# Sublyne Installation Script
# This script installs all required dependencies for Sublyne project

set -e

echo "[INFO] Starting Sublyne installation..."

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        echo "[INFO] Running as root user"
        SUDO_CMD=""
    else
        echo "[INFO] Running as regular user, will use sudo for system operations"
        SUDO_CMD="sudo"
    fi
}

# Function to install system dependencies
install_system_deps() {
    echo "[INFO] Installing system dependencies..."
    
    # Set non-interactive mode for apt
    export DEBIAN_FRONTEND=noninteractive
    
    # Update package list
    $SUDO_CMD apt-get update -y
    
    # Install required packages
    $SUDO_CMD apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        iptables \
        iptables-persistent \
        wget \
        curl \
        unzip \
        net-tools \
        iproute2
    
    echo "[INFO] System dependencies installed successfully"
}

# Function to setup iptables-persistent
setup_iptables() {
    echo "[INFO] Setting up iptables-persistent..."
    
    # Pre-configure iptables-persistent to avoid interactive prompts
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | $SUDO_CMD debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | $SUDO_CMD debconf-set-selections
    
    # Save current iptables rules
    $SUDO_CMD iptables-save > /tmp/rules.v4
    $SUDO_CMD ip6tables-save > /tmp/rules.v6
    $SUDO_CMD mv /tmp/rules.v4 /etc/iptables/rules.v4
    $SUDO_CMD mv /tmp/rules.v6 /etc/iptables/rules.v6
    
    echo "[INFO] iptables-persistent configured successfully"
}

# Function to install Gost
install_gost() {
    echo "[INFO] Installing Gost..."
    
    # Download Gost
    GOST_VERSION="2.11.5"
    GOST_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-amd64-${GOST_VERSION}.gz"
    
    cd /tmp
    wget -O gost-linux-amd64.gz "$GOST_URL"
    
    # Extract Gost
    gunzip gost-linux-amd64.gz
    
    # Install Gost
    $SUDO_CMD mv gost-linux-amd64 /usr/local/bin/gost
    $SUDO_CMD chmod +x /usr/local/bin/gost
    
    echo "[INFO] Gost installed successfully"
}

# Function to setup Python environment
setup_python_env() {
    echo "[INFO] Setting up Python environment..."
    
    # Create virtual environment if it doesn't exist
    if [ ! -d "venv" ]; then
        python3 -m venv venv
    fi
    
    # Activate virtual environment and install requirements
    source venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt
    
    echo "[INFO] Python environment setup completed"
}

# Function to create sublyne user
create_sublyne_user() {
    if [[ $EUID -ne 0 ]]; then
        echo "[INFO] Creating sublyne user..."
        
        if ! id "sublyne" &>/dev/null; then
            $SUDO_CMD useradd -m -s /bin/bash sublyne
            echo "[INFO] User 'sublyne' created successfully"
        else
            echo "[INFO] User 'sublyne' already exists"
        fi
        
        # Set ownership of project files
        $SUDO_CMD chown -R sublyne:sublyne /opt/sublyne 2>/dev/null || true
    fi
}

# Function to setup project directory
setup_project_dir() {
    echo "[INFO] Setting up project directory..."
    
    PROJECT_DIR="/opt/sublyne"
    
    # Create project directory
    $SUDO_CMD mkdir -p "$PROJECT_DIR"
    
    # Copy project files
    $SUDO_CMD cp -r . "$PROJECT_DIR/"
    
    # Set proper permissions
    if [[ $EUID -eq 0 ]]; then
        chown -R root:root "$PROJECT_DIR"
    else
        $SUDO_CMD chown -R sublyne:sublyne "$PROJECT_DIR"
    fi
    
    echo "[INFO] Project directory setup completed"
}

# Function to setup systemd service
setup_systemd_service() {
    echo "[INFO] Setting up systemd service..."
    
    cat > /tmp/sublyne.service << EOF
[Unit]
Description=Sublyne Tunnel Management Service
After=network.target

[Service]
Type=simple
User=sublyne
WorkingDirectory=/opt/sublyne/backend
ExecStart=/opt/sublyne/venv/bin/python main.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    $SUDO_CMD mv /tmp/sublyne.service /etc/systemd/system/
    $SUDO_CMD systemctl daemon-reload
    $SUDO_CMD systemctl enable sublyne
    
    echo "[INFO] Systemd service setup completed"
}

# Main installation function
main() {
    echo "[INFO] Starting Sublyne installation process..."
    
    check_root
    install_system_deps
    setup_iptables
    install_gost
    create_sublyne_user
    setup_project_dir
    
    # Change to project directory for Python setup
    cd /opt/sublyne
    setup_python_env
    setup_systemd_service
    
    echo "[SUCCESS] Sublyne installation completed successfully!"
    echo "[INFO] You can start the service with: sudo systemctl start sublyne"
    echo "[INFO] Check service status with: sudo systemctl status sublyne"
}

# Run main function
main "$@"
