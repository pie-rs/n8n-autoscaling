#!/bin/bash
# Generate systemd service files for n8n-autoscaling

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔧 Systemd Service Generator for n8n-autoscaling${NC}"
echo "================================================"

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load environment variables
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Ask about rclone cloud storage support
RCLONE_ENABLED="no"
echo ""
read -p "Enable rclone cloud storage support? (y/N): " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
    RCLONE_ENABLED="yes"
    echo -e "${GREEN}✅ Rclone cloud storage support will be enabled${NC}"
    echo -e "${YELLOW}⚠️  Make sure your rclone mounts are active before starting the service${NC}"
else
    echo -e "${YELLOW}⚠️  Rclone cloud storage support disabled${NC}"
fi

# Detect container runtime
CONTAINER_RUNTIME=""
COMPOSE_CMD=""

if [ -n "$CONTAINER_RUNTIME_OVERRIDE" ]; then
    CONTAINER_RUNTIME="$CONTAINER_RUNTIME_OVERRIDE"
elif command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
    if command -v podman-compose &> /dev/null; then
        COMPOSE_CMD="podman-compose"
    else
        COMPOSE_CMD="podman compose"
    fi
elif command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
    COMPOSE_CMD="docker compose"
else
    echo -e "${RED}❌ Error: Neither Docker nor Podman found${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Detected runtime: ${CONTAINER_RUNTIME}${NC}"
echo -e "${GREEN}✅ Using compose command: ${COMPOSE_CMD}${NC}"

# Determine if running as root or user
if [ "$EUID" -eq 0 ]; then
    SYSTEMD_DIR="/etc/systemd/system"
    SERVICE_TYPE="system"
    echo -e "${YELLOW}Running as root - will create system service${NC}"
else
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    SERVICE_TYPE="user"
    mkdir -p "$SYSTEMD_DIR"
    echo -e "${YELLOW}Running as user - will create user service${NC}"
fi

# Service name
SERVICE_NAME="n8n-autoscaling"

# Build compose command with optional rclone and Podman autoupdate
COMPOSE_FILES="-f docker-compose.yml"

if [ "$RCLONE_ENABLED" = "yes" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.rclone.yml"
fi

# Add Podman autoupdate override if using Podman and autoupdate is enabled
if [ "$CONTAINER_RUNTIME" = "podman" ] && [ "${PODMAN_AUTOUPDATE:-registry}" != "no" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.podman-autoupdate.yml"
fi

# Create the service file
cat > "${SERVICE_NAME}.service" << EOF
[Unit]
Description=n8n Autoscaling Stack
Documentation=${DOCS_README}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=${SCRIPT_DIR}
Environment="PATH=/usr/local/bin:/usr/bin:/bin"

# Pre-start: ensure directories exist
ExecStartPre=/bin/bash -c 'mkdir -p ${DATA_DIR}/{Postgres,Redis,n8n,n8n-webhook,Traefik} ${BACKUPS_DIR}'

# Start the stack
ExecStart=/usr/bin/env ${COMPOSE_CMD} ${COMPOSE_FILES} up -d --remove-orphans

# Stop the stack
ExecStop=/usr/bin/env ${COMPOSE_CMD} ${COMPOSE_FILES} down

# Restart policy - 'on-failure' is compatible with both Docker and Podman
Restart=on-failure
RestartSec=30
# Limit restart attempts to prevent infinite loops
StartLimitBurst=5
StartLimitIntervalSec=600

# Time to wait for start/stop
TimeoutStartSec=300
TimeoutStopSec=300

# Resource limits (optional - uncomment and adjust as needed)
#LimitNOFILE=65536
#LimitNPROC=4096

# For rootless podman, ensure XDG_RUNTIME_DIR is set
$([ "$SERVICE_TYPE" = "user" ] && echo "Environment=\"XDG_RUNTIME_DIR=/run/user/\$(id -u)\"")

[Install]
WantedBy=$([ "$SERVICE_TYPE" = "user" ] && echo "default.target" || echo "multi-user.target")
EOF

echo -e "${GREEN}✅ Created ${SERVICE_NAME}.service${NC}"


# Ask if user wants to install the files
echo ""
read -p "Would you like to install the systemd service files now? (y/N): " -r
INSTALL_NOW=""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    INSTALL_NOW="yes"
fi

# Installation instructions
echo ""
echo -e "${YELLOW}📋 Installation Instructions:${NC}"
echo ""

if [ "$SERVICE_TYPE" = "user" ]; then
    echo "For USER service installation:"
    echo "1. Copy service files:"
    echo "   cp ${SERVICE_NAME}.service ${SYSTEMD_DIR}/"
    echo ""
    echo "2. Reload systemd:"
    echo "   systemctl --user daemon-reload"
    echo ""
    echo "3. Enable and start the service:"
    echo "   systemctl --user enable ${SERVICE_NAME}.service"
    echo "   systemctl --user start ${SERVICE_NAME}.service"
    echo ""
    echo "4. Check status:"
    echo "   systemctl --user status ${SERVICE_NAME}.service"
    echo ""
    echo "Note: User services require you to be logged in. For persistent services,"
    echo "      enable lingering: sudo loginctl enable-linger $(whoami)"
else
    echo "For SYSTEM service installation:"
    echo "1. Copy service files:"
    echo "   sudo cp ${SERVICE_NAME}.service ${SYSTEMD_DIR}/"
    echo ""
    echo "2. Reload systemd:"
    echo "   sudo systemctl daemon-reload"
    echo ""
    echo "3. Enable and start the service:"
    echo "   sudo systemctl enable ${SERVICE_NAME}.service"
    echo "   sudo systemctl start ${SERVICE_NAME}.service"
    echo ""
    echo "4. Check status:"
    echo "   sudo systemctl status ${SERVICE_NAME}.service"
fi

echo ""
echo -e "${YELLOW}📝 Useful systemd commands:${NC}"
echo "  View logs:    journalctl $([ "$SERVICE_TYPE" = "user" ] && echo "--user") -u ${SERVICE_NAME} -f"
echo "  Restart:      systemctl $([ "$SERVICE_TYPE" = "user" ] && echo "--user") restart ${SERVICE_NAME}"
echo "  Stop:         systemctl $([ "$SERVICE_TYPE" = "user" ] && echo "--user") stop ${SERVICE_NAME}"
# Auto-install if requested
if [ "$INSTALL_NOW" = "yes" ]; then
    echo ""
    echo -e "${YELLOW}Installing systemd service files...${NC}"
    
    if [ "$SERVICE_TYPE" = "user" ]; then
        # User installation
        cp "${SERVICE_NAME}".service "${SYSTEMD_DIR}/" 2>/dev/null
        systemctl --user daemon-reload
        echo -e "${GREEN}✅ Service files installed to ${SYSTEMD_DIR}${NC}"
        echo ""
        echo "To enable and start:"
        echo "  systemctl --user enable ${SERVICE_NAME}.service"
        echo "  systemctl --user start ${SERVICE_NAME}.service"
        
        # Set up Podman auto-update if using Podman
        if [ "$CONTAINER_RUNTIME" = "podman" ]; then
            echo ""
            echo -e "${YELLOW}Setting up Podman auto-update...${NC}"
            
            # Enable lingering for user services
            sudo loginctl enable-linger "$(whoami)" 2>/dev/null || echo "  ⚠️  Could not enable lingering (may already be enabled)"
            
            # Enable podman auto-update timer
            systemctl --user enable podman-auto-update.timer 2>/dev/null || echo "  ⚠️  Could not enable podman-auto-update.timer"
            systemctl --user start podman-auto-update.timer 2>/dev/null || echo "  ⚠️  Could not start podman-auto-update.timer"
            
            echo -e "${GREEN}✅ Podman auto-update configured${NC}"
        fi
    else
        # System installation (requires sudo)
        if sudo cp "${SERVICE_NAME}".service "${SYSTEMD_DIR}/" 2>/dev/null; then
            sudo systemctl daemon-reload
            echo -e "${GREEN}✅ Service files installed to ${SYSTEMD_DIR}${NC}"
            echo ""
            echo "To enable and start:"
            echo "  sudo systemctl enable ${SERVICE_NAME}.service"
            echo "  sudo systemctl start ${SERVICE_NAME}.service"
        else
            echo -e "${RED}❌ Failed to install system service files (need sudo)${NC}"
        fi
    fi
else
    echo ""
    echo -e "${GREEN}✅ Systemd service files generated successfully!${NC}"
fi

# Add Podman-specific notes
if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo ""
    echo -e "${YELLOW}📌 Podman-specific notes:${NC}"
    echo "  • Restart policy 'on-failure' is fully supported"
    echo "  • For rootless mode, ensure your user has lingering enabled:"
    echo "    sudo loginctl enable-linger $(whoami)"
    echo "  • Podman handles cgroups and namespaces automatically"
    echo "  • Auto-update configured via podman-auto-update.timer"
    echo "  • Containers need 'io.containers.autoupdate=registry' label to auto-update"
fi