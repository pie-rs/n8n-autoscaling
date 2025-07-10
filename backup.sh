#!/bin/bash
# Backup script for n8n-autoscaling
# Handles PostgreSQL, Redis, and n8n data backups with compression and rotation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load environment variables
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
fi

# Set default values
BACKUPS_DIR=${BACKUPS_DIR:-./backups}
DATA_DIR=${DATA_DIR:-./Data}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-n8n-autoscaling}
POSTGRES_DB=${POSTGRES_DB:-n8n}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-}
REDIS_PASSWORD=${REDIS_PASSWORD:-}
GDRIVE_BACKUP_MOUNT=${GDRIVE_BACKUP_MOUNT:-}

# Create backup directories
mkdir -p "$BACKUPS_DIR"/{postgres,redis,n8n}

# Get current timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo -e "${GREEN}🔄 Starting backup process for n8n-autoscaling${NC}"
echo "================================================"

# Function to backup PostgreSQL
backup_postgres() {
    echo -e "${YELLOW}📋 Backing up PostgreSQL database...${NC}"
    
    # Check if postgres container is running
    if ! docker compose ps postgres | grep -q "Up"; then
        echo -e "${RED}❌ PostgreSQL container is not running${NC}"
        return 1
    fi
    
    # Full backup
    BACKUP_FILE="$BACKUPS_DIR/postgres/postgres_full_${TIMESTAMP}.sql.gz"
    
    echo "  • Creating full backup: $(basename "$BACKUP_FILE")"
    docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$BACKUP_FILE"
    
    if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
        echo -e "    ✅ Full backup completed: $(du -h "$BACKUP_FILE" | cut -f1)"
    else
        echo -e "${RED}    ❌ Full backup failed${NC}"
        return 1
    fi
}

# Function to backup Redis
backup_redis() {
    echo -e "${YELLOW}📋 Backing up Redis data...${NC}"
    
    # Check if redis container is running
    if ! docker compose ps redis | grep -q "Up"; then
        echo -e "${RED}❌ Redis container is not running${NC}"
        return 1
    fi
    
    # Create Redis backup using BGSAVE
    echo "  • Triggering Redis background save..."
    docker compose exec redis redis-cli -a "$REDIS_PASSWORD" BGSAVE
    
    # Wait for background save to complete
    while [ "$(docker compose exec redis redis-cli -a "$REDIS_PASSWORD" LASTSAVE)" = "$(docker compose exec redis redis-cli -a "$REDIS_PASSWORD" LASTSAVE)" ]; do
        sleep 1
    done
    
    # Copy and compress the dump file
    BACKUP_FILE="$BACKUPS_DIR/redis/redis_${TIMESTAMP}.rdb.gz"
    
    echo "  • Creating compressed backup: $(basename "$BACKUP_FILE")"
    docker compose exec redis cat /data/dump.rdb | gzip > "$BACKUP_FILE"
    
    if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
        echo -e "    ✅ Redis backup completed: $(du -h "$BACKUP_FILE" | cut -f1)"
    else
        echo -e "${RED}    ❌ Redis backup failed${NC}"
        return 1
    fi
}

# Function to backup n8n data
backup_n8n() {
    echo -e "${YELLOW}📋 Backing up n8n data...${NC}"
    
    # Check if n8n data directories exist
    if [ ! -d "$DATA_DIR/n8n" ] && [ ! -d "$DATA_DIR/n8n-webhook" ]; then
        echo -e "${RED}❌ n8n data directories not found: $DATA_DIR/n8n or $DATA_DIR/n8n-webhook${NC}"
        return 1
    fi
    
    BACKUP_FILE="$BACKUPS_DIR/n8n/n8n_data_${TIMESTAMP}.tar.gz"
    
    echo "  • Creating compressed archive: $(basename "$BACKUP_FILE")"
    # Include both n8n and n8n-webhook directories
    tar -czf "$BACKUP_FILE" -C "$DATA_DIR" $(ls -d n8n n8n-webhook 2>/dev/null | tr '\n' ' ')
    
    if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
        echo -e "    ✅ n8n data backup completed: $(du -h "$BACKUP_FILE" | cut -f1)"
    else
        echo -e "${RED}    ❌ n8n data backup failed${NC}"
        return 1
    fi
}

# Function to sync to Google Drive and cleanup
sync_to_gdrive() {
    if [ -z "$GDRIVE_BACKUP_MOUNT" ]; then
        return 0  # Skip if not configured
    fi
    
    echo -e "${YELLOW}📋 Syncing backups to Google Drive...${NC}"
    
    # Check if Google Drive backup mount exists
    if [ ! -d "$GDRIVE_BACKUP_MOUNT" ]; then
        echo -e "${RED}❌ Google Drive backup mount not found: $GDRIVE_BACKUP_MOUNT${NC}"
        return 1
    fi
    
    # Create Google Drive backup structure
    mkdir -p "$GDRIVE_BACKUP_MOUNT"/{postgres,redis,n8n}
    
    # Sync each backup type
    for backup_type in postgres redis n8n; do
        if [ -d "$BACKUPS_DIR/$backup_type" ]; then
            echo "  • Syncing $backup_type backups..."
            
            # Copy new files to Google Drive
            cp "$BACKUPS_DIR/$backup_type"/* "$GDRIVE_BACKUP_MOUNT/$backup_type/" 2>/dev/null || true
            
            echo -e "    ✅ $backup_type backups synced"
        fi
    done
    
    # Clean up old backups from Google Drive (>7 days)
    echo "  • Cleaning up old Google Drive backups (>7 days)..."
    find "$GDRIVE_BACKUP_MOUNT" -name "*.gz" -type f -mtime +7 -delete 2>/dev/null || true
    
    # Remove local backups after successful sync
    echo "  • Removing local backups after sync..."
    rm -rf "$BACKUPS_DIR"/{postgres,redis,n8n}/*
    
    echo -e "  ✅ Google Drive sync completed and local backups cleared"
}

# Function to cleanup old local backups (only if not using Google Drive)
cleanup_local_backups() {
    if [ -n "$GDRIVE_BACKUP_MOUNT" ]; then
        return 0  # Skip local cleanup if using Google Drive
    fi
    
    echo -e "${YELLOW}🧹 Cleaning up old local backups (>7 days)...${NC}"
    
    # Remove files older than 7 days
    find "$BACKUPS_DIR" -name "*.gz" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.sql.gz" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.rdb.gz" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.tar.gz" -type f -mtime +7 -delete 2>/dev/null || true
    
    echo "  ✅ Old local backups cleaned up"
}

# Function to show backup summary
show_backup_summary() {
    echo -e "${YELLOW}💾 Backup summary:${NC}"
    
    if [ -n "$GDRIVE_BACKUP_MOUNT" ] && [ -d "$GDRIVE_BACKUP_MOUNT" ]; then
        GDRIVE_SIZE=$(du -sh "$GDRIVE_BACKUP_MOUNT" 2>/dev/null | cut -f1)
        GDRIVE_COUNT=$(find "$GDRIVE_BACKUP_MOUNT" -name "*.gz" -type f | wc -l)
        echo "  • Google Drive backup size: $GDRIVE_SIZE"
        echo "  • Google Drive backup files: $GDRIVE_COUNT"
        echo "  • Google Drive path: $GDRIVE_BACKUP_MOUNT"
    elif [ -d "$BACKUPS_DIR" ]; then
        BACKUP_SIZE=$(du -sh "$BACKUPS_DIR" 2>/dev/null | cut -f1)
        BACKUP_COUNT=$(find "$BACKUPS_DIR" -name "*.gz" -type f | wc -l)
        echo "  • Local backup size: $BACKUP_SIZE"
        echo "  • Local backup files: $BACKUP_COUNT"
        echo "  • Local backup directory: $BACKUPS_DIR"
    fi
}

# Main execution
main() {
    local success=true
    
    # Run backups
    if ! backup_postgres; then
        success=false
    fi
    
    if ! backup_redis; then
        success=false
    fi
    
    if ! backup_n8n; then
        success=false
    fi
    
    # Sync to Google Drive if configured, otherwise cleanup local backups
    if [ -n "$GDRIVE_BACKUP_MOUNT" ]; then
        if ! sync_to_gdrive; then
            success=false
        fi
    else
        cleanup_local_backups
    fi
    
    # Show summary
    show_backup_summary
    
    echo ""
    if [ "$success" = true ]; then
        echo -e "${GREEN}✅ All backups completed successfully!${NC}"
    else
        echo -e "${RED}❌ Some backups failed. Check the output above.${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${YELLOW}📋 To set up automatic backups:${NC}"
    echo ""
    echo "1. Add to crontab for hourly backups:"
    echo "   0 * * * * $SCRIPT_DIR/backup.sh >/dev/null 2>&1"
    echo ""
    echo "2. Add to crontab for twice-daily PostgreSQL full backups:"
    echo "   0 0,12 * * * $SCRIPT_DIR/backup.sh postgres >/dev/null 2>&1"
    echo ""
    if [ -n "$GDRIVE_BACKUP_MOUNT" ]; then
        echo "3. Google Drive sync is automatically included when GDRIVE_BACKUP_MOUNT is set"
    else
        echo "3. To enable Google Drive sync, set GDRIVE_BACKUP_MOUNT in .env"
    fi
}

# Handle command line arguments
case "${1:-}" in
    postgres)
        echo -e "${GREEN}🔄 Running PostgreSQL backup only${NC}"
        backup_postgres
        ;;
    redis)
        echo -e "${GREEN}🔄 Running Redis backup only${NC}"
        backup_redis
        ;;
    n8n)
        echo -e "${GREEN}🔄 Running n8n data backup only${NC}"
        backup_n8n
        ;;
    --help|-h)
        echo "Usage: $0 [SERVICE]"
        echo ""
        echo "Services:"
        echo "  postgres    Backup PostgreSQL database only"
        echo "  redis       Backup Redis data only"
        echo "  n8n         Backup n8n data only"
        echo "  (no args)   Backup all services"
        echo ""
        echo "This script creates compressed backups of all n8n-autoscaling data."
        echo "Backups are stored in $BACKUPS_DIR with automatic cleanup after 7 days."
        exit 0
        ;;
    *)
        main
        ;;
esac