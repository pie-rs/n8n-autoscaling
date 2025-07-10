#!/bin/bash
# Setup script for n8n-autoscaling data directories

set -e

echo "Setting up n8n-autoscaling data directories..."

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
GDRIVE_DATA_MOUNT=${GDRIVE_DATA_MOUNT:-/user/webapps/mounts/gdrive-data}
GDRIVE_BACKUP_MOUNT=${GDRIVE_BACKUP_MOUNT:-/user/webapps/mounts/gdrive-backups}

# Create local data directories
echo "Creating data directories..."
mkdir -p "${DATA_DIR}/Postgres"
mkdir -p "${DATA_DIR}/Redis"
mkdir -p "${DATA_DIR}/n8n"
mkdir -p "${DATA_DIR}/n8n-webhook"
mkdir -p "${DATA_DIR}/Traefik"
mkdir -p "${LOGS_DIR}"
mkdir -p "${BACKUPS_DIR}"

# Create Google Drive mount directories only if variables are set and not empty
if [ -n "$GDRIVE_DATA_MOUNT" ] && [ "$GDRIVE_DATA_MOUNT" != "#GDRIVE_DATA_MOUNT=/user/webapps/mounts/gdrive-data" ]; then
    if [ ! -d "${GDRIVE_DATA_MOUNT}" ]; then
        echo "Creating Google Drive data mount directory: ${GDRIVE_DATA_MOUNT}"
        if sudo mkdir -p "${GDRIVE_DATA_MOUNT}" 2>/dev/null; then
            echo "✅ Created: ${GDRIVE_DATA_MOUNT}"
        else
            echo "⚠️  Could not create ${GDRIVE_DATA_MOUNT} - you may need to create it manually with appropriate permissions"
        fi
    else
        echo "✅ Google Drive data mount exists: ${GDRIVE_DATA_MOUNT}"
    fi
fi

if [ -n "$GDRIVE_BACKUP_MOUNT" ] && [ "$GDRIVE_BACKUP_MOUNT" != "#GDRIVE_BACKUP_MOUNT=/user/webapps/mounts/gdrive-backups" ]; then
    if [ ! -d "${GDRIVE_BACKUP_MOUNT}" ]; then
        echo "Creating Google Drive backup mount directory: ${GDRIVE_BACKUP_MOUNT}"
        if sudo mkdir -p "${GDRIVE_BACKUP_MOUNT}" 2>/dev/null; then
            echo "✅ Created: ${GDRIVE_BACKUP_MOUNT}"
        else
            echo "⚠️  Could not create ${GDRIVE_BACKUP_MOUNT} - you may need to create it manually with appropriate permissions"
        fi
    else
        echo "✅ Google Drive backup mount exists: ${GDRIVE_BACKUP_MOUNT}"
    fi
fi

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
echo "Google Drive mounts:"
echo "  ${GDRIVE_DATA_MOUNT}    - n8n data store"
echo "  ${GDRIVE_BACKUP_MOUNT}  - backup storage"
echo ""
echo "Next steps:"
echo "1. Ensure .env file is configured (copy from .env.example)"
echo "2. Create external network: docker network create shark"
echo "3. Start services: docker compose up -d"