#!/bin/bash
# Setup script for n8n-autoscaling data directories

set -e

echo "Setting up n8n-autoscaling data directories..."

# Simple runtime detection for network creation only
CONTAINER_RUNTIME=""
if [ -n "$CONTAINER_RUNTIME_OVERRIDE" ]; then
    CONTAINER_RUNTIME="$CONTAINER_RUNTIME_OVERRIDE"
elif command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
fi

# Load environment variables from .env if it exists
if [ -f .env ]; then
    source .env
    echo "✅ Loaded environment variables from .env"
else
    echo "⚠️  No .env file found, using defaults from .env.example"
    echo "   Please copy .env.example to .env and configure your settings"
fi

# Use environment variables with fallback to defaults
DATA_DIR=${DATA_DIR:-./Data}
LOGS_DIR=${LOGS_DIR:-./Logs}
BACKUPS_DIR=${BACKUPS_DIR:-./backups}

# Create local data directories
echo "Creating data directories..."
mkdir -p "${DATA_DIR}/Postgres"
mkdir -p "${DATA_DIR}/Redis"
mkdir -p "${DATA_DIR}/n8n"
mkdir -p "${DATA_DIR}/n8n-webhook"
mkdir -p "${DATA_DIR}/Traefik"
mkdir -p "${LOGS_DIR}"
mkdir -p "${BACKUPS_DIR}"


# Set appropriate permissions
echo "Setting directory permissions..."
chmod -R 755 "${DATA_DIR}" 2>/dev/null || true
chmod -R 755 "${LOGS_DIR}" 2>/dev/null || true
chmod -R 755 "${BACKUPS_DIR}" 2>/dev/null || true

echo ""
echo "✅ Directory setup completed!"
echo ""
echo "Directory structure created:"
echo "  ${DATA_DIR}/Postgres    - PostgreSQL data"
echo "  ${DATA_DIR}/Redis       - Redis data"
echo "  ${DATA_DIR}/n8n         - n8n main data"
echo "  ${DATA_DIR}/n8n-webhook - n8n webhook data"
echo "  ${DATA_DIR}/Traefik     - Traefik data"
echo "  ${LOGS_DIR}             - Application logs"
echo "  ${BACKUPS_DIR}          - Backup files"
echo ""
# Create external network if configured
if [ -n "$EXTERNAL_NETWORK_NAME" ]; then
    if [ -n "$CONTAINER_RUNTIME" ]; then
        echo "Creating external network '${EXTERNAL_NETWORK_NAME}'..."
        if [ "$CONTAINER_RUNTIME" = "docker" ]; then
            docker network inspect "${EXTERNAL_NETWORK_NAME}" >/dev/null 2>&1 || docker network create "${EXTERNAL_NETWORK_NAME}"
            echo "✅ Created/verified Docker network '${EXTERNAL_NETWORK_NAME}'"
        elif [ "$CONTAINER_RUNTIME" = "podman" ]; then
            podman network inspect "${EXTERNAL_NETWORK_NAME}" >/dev/null 2>&1 || podman network create "${EXTERNAL_NETWORK_NAME}"
            echo "✅ Created/verified Podman network '${EXTERNAL_NETWORK_NAME}'"
        fi
    else
        echo "⚠️  No container runtime detected. Create network manually:"
        echo "   Docker: docker network create ${EXTERNAL_NETWORK_NAME}"
        echo "   Podman: podman network create ${EXTERNAL_NETWORK_NAME}"
    fi
fi

echo ""
echo "✅ Setup completed successfully!"

echo ""
echo "Next steps:"
echo "1. Ensure .env file is configured (copy from .env.example)"
echo "2. Start services:"
echo "   Docker: docker compose up -d"
echo "   Podman: podman compose up -d (or podman-compose up -d)"
echo "3. For Google Drive support (optional): add -f docker-compose.gdrive.yml"