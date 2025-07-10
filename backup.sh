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
ENVIRONMENT=${ENVIRONMENT:-dev}
POSTGRES_DB=${POSTGRES_DB:-n8n_${ENVIRONMENT}}
POSTGRES_USER=${POSTGRES_USER:-n8n_${ENVIRONMENT}_user}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-}
POSTGRES_ADMIN_USER=${POSTGRES_ADMIN_USER:-postgres}
POSTGRES_ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD:-}
REDIS_PASSWORD=${REDIS_PASSWORD:-}
RCLONE_BACKUP_MOUNT=${RCLONE_BACKUP_MOUNT:-}

# Create backup directories
mkdir -p "$BACKUPS_DIR"/{postgres,redis,n8n}

# Get current timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Encryption function using N8N_ENCRYPTION_KEY
encrypt_backup() {
    local input_file="$1"
    local output_file="${input_file}.enc"
    
    if [ -n "${N8N_ENCRYPTION_KEY:-}" ] && [ ${#N8N_ENCRYPTION_KEY} -ge 16 ]; then
        echo "    🔒 Encrypting backup..."
        
        # Use openssl with AES-256-CBC encryption and the N8N_ENCRYPTION_KEY
        if openssl enc -aes-256-cbc -salt -in "$input_file" -out "$output_file" -k "$N8N_ENCRYPTION_KEY" 2>/dev/null; then
            rm "$input_file"  # Remove unencrypted file
            echo "$output_file"
        else
            echo -e "${YELLOW}⚠️  Encryption failed, keeping unencrypted backup${NC}" >&2
            echo "$input_file"
        fi
    else
        echo -e "${YELLOW}⚠️  N8N_ENCRYPTION_KEY not set or too short (min 16 chars), storing unencrypted backup${NC}" >&2
        echo "$input_file"
    fi
}

echo -e "${GREEN}🔄 Starting backup process for n8n-autoscaling${NC}"
echo "================================================"

# Function to backup PostgreSQL (full backup)
backup_postgres_full() {
    echo -e "${YELLOW}📋 Creating PostgreSQL full backup...${NC}"
    
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
        # Encrypt the backup
        BACKUP_FILE=$(encrypt_backup "$BACKUP_FILE")
        echo -e "    ✅ Full backup completed: $(du -h "$BACKUP_FILE" | cut -f1)"
        
        # Create a marker file for incremental backups
        echo "$TIMESTAMP" > "$BACKUPS_DIR/postgres/.last_full_backup"
    else
        echo -e "${RED}    ❌ Full backup failed${NC}"
        return 1
    fi
}

# Function to backup PostgreSQL (incremental backup using WAL)
backup_postgres_incremental() {
    echo -e "${YELLOW}📋 Creating PostgreSQL incremental backup...${NC}"
    
    # Check if postgres container is running
    if ! docker compose ps postgres | grep -q "Up"; then
        echo -e "${RED}❌ PostgreSQL container is not running${NC}"
        return 1
    fi
    
    # Check if we have a base backup
    if [ ! -f "$BACKUPS_DIR/postgres/.last_full_backup" ]; then
        echo -e "${YELLOW}⚠️  No full backup found, creating full backup instead...${NC}"
        backup_postgres_full
        return $?
    fi
    
    # Create WAL backup directory
    mkdir -p "$BACKUPS_DIR/postgres/wal"
    
    # Force a WAL segment switch and backup current WAL files
    echo "  • Creating incremental backup: postgres_incremental_${TIMESTAMP}.tar.gz"
    
    # Get current WAL file location
    CURRENT_WAL=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT pg_walfile_name(pg_current_wal_lsn());" | tr -d ' \n\r')
    
    # Force WAL switch to ensure current transactions are in a complete WAL file
    docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_switch_wal();" > /dev/null
    
    # Copy WAL files from the container
    BACKUP_FILE="$BACKUPS_DIR/postgres/postgres_incremental_${TIMESTAMP}.tar.gz"
    docker compose exec postgres tar -czf - -C /var/lib/postgresql/data/pg_wal . 2>/dev/null | cat > "$BACKUP_FILE"
    
    if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
        # Encrypt the backup
        BACKUP_FILE=$(encrypt_backup "$BACKUP_FILE")
        echo -e "    ✅ Incremental backup completed: $(du -h "$BACKUP_FILE" | cut -f1)"
        echo "    📝 WAL file: $CURRENT_WAL"
    else
        echo -e "${RED}    ❌ Incremental backup failed${NC}"
        return 1
    fi
}

# Function to backup PostgreSQL (smart backup - full or incremental based on time)
backup_postgres() {
    local FORCE_FULL="${1:-false}"
    
    # Force full backup if requested
    if [ "$FORCE_FULL" = "true" ]; then
        backup_postgres_full
        return $?
    fi
    
    # Check when last full backup was made
    if [ -f "$BACKUPS_DIR/postgres/.last_full_backup" ]; then
        LAST_FULL=$(cat "$BACKUPS_DIR/postgres/.last_full_backup")
        # Convert timestamp to epoch (cross-platform)
        YEAR=${LAST_FULL:0:4}
        MONTH=${LAST_FULL:4:2}
        DAY=${LAST_FULL:6:2}
        HOUR=${LAST_FULL:9:2}
        MIN=${LAST_FULL:11:2}
        SEC=${LAST_FULL:13:2}
        
        # Try macOS date format first, then GNU date format
        LAST_FULL_EPOCH=$(date -j -f "%Y%m%d%H%M%S" "${YEAR}${MONTH}${DAY}${HOUR}${MIN}${SEC}" +%s 2>/dev/null || \
                          date -d "${YEAR}-${MONTH}-${DAY} ${HOUR}:${MIN}:${SEC}" +%s 2>/dev/null || \
                          echo "0")
        CURRENT_EPOCH=$(date +%s)
        HOURS_SINCE_FULL=$(( (CURRENT_EPOCH - LAST_FULL_EPOCH) / 3600 ))
        
        # Create full backup every 12 hours, incremental otherwise
        if [ "$HOURS_SINCE_FULL" -ge 12 ]; then
            echo "  💡 Last full backup was $HOURS_SINCE_FULL hours ago, creating new full backup"
            backup_postgres_full
        else
            echo "  💡 Last full backup was $HOURS_SINCE_FULL hours ago, creating incremental backup"
            backup_postgres_incremental
        fi
    else
        echo "  💡 No previous backup found, creating first full backup"
        backup_postgres_full
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
        # Encrypt the backup
        BACKUP_FILE=$(encrypt_backup "$BACKUP_FILE")
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
        # Encrypt the backup
        BACKUP_FILE=$(encrypt_backup "$BACKUP_FILE")
        echo -e "    ✅ n8n data backup completed: $(du -h "$BACKUP_FILE" | cut -f1)"
    else
        echo -e "${RED}    ❌ n8n data backup failed${NC}"
        return 1
    fi
}

# Function to sync to rclone cloud storage and cleanup
sync_to_rclone() {
    if [ -z "$RCLONE_BACKUP_MOUNT" ]; then
        return 0  # Skip if not configured
    fi
    
    echo -e "${YELLOW}📋 Syncing backups to rclone cloud storage...${NC}"
    
    # Check if rclone backup mount exists
    if [ ! -d "$RCLONE_BACKUP_MOUNT" ]; then
        echo -e "${RED}❌ Rclone cloud storage backup mount not found: $RCLONE_BACKUP_MOUNT${NC}"
        return 1
    fi
    
    # Create rclone backup structure
    mkdir -p "$RCLONE_BACKUP_MOUNT"/{postgres,redis,n8n}
    
    # Sync each backup type
    for backup_type in postgres redis n8n; do
        if [ -d "$BACKUPS_DIR/$backup_type" ]; then
            echo "  • Syncing $backup_type backups..."
            
            # Copy new files to rclone cloud storage
            cp "$BACKUPS_DIR/$backup_type"/* "$RCLONE_BACKUP_MOUNT/$backup_type/" 2>/dev/null || true
            
            echo -e "    ✅ $backup_type backups synced"
        fi
    done
    
    # Clean up old backups from rclone cloud storage (>7 days)
    echo "  • Cleaning up old cloud storage backups (>7 days)..."
    find "$RCLONE_BACKUP_MOUNT" -name "*.gz" -type f -mtime +7 -delete 2>/dev/null || true
    
    # Remove local backups after successful sync
    echo "  • Removing local backups after sync..."
    rm -rf "$BACKUPS_DIR"/{postgres,redis,n8n}/*
    
    echo -e "  ✅ Rclone cloud storage sync completed and local backups cleared"
}

# Function to cleanup old local backups (only if not using rclone cloud storage)
cleanup_local_backups() {
    if [ -n "$RCLONE_BACKUP_MOUNT" ]; then
        return 0  # Skip local cleanup if using rclone cloud storage
    fi
    
    echo -e "${YELLOW}🧹 Cleaning up old local backups (>7 days)...${NC}"
    
    # Remove files older than 7 days (both encrypted and unencrypted)
    find "$BACKUPS_DIR" -name "*.gz" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.gz.enc" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.sql.gz" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.sql.gz.enc" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.rdb.gz" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.rdb.gz.enc" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.tar.gz" -type f -mtime +7 -delete 2>/dev/null || true
    find "$BACKUPS_DIR" -name "*.tar.gz.enc" -type f -mtime +7 -delete 2>/dev/null || true
    
    echo "  ✅ Old local backups cleaned up"
}

# Function to show backup summary
show_backup_summary() {
    echo -e "${YELLOW}💾 Backup summary:${NC}"
    
    if [ -n "$RCLONE_BACKUP_MOUNT" ] && [ -d "$RCLONE_BACKUP_MOUNT" ]; then
        RCLONE_SIZE=$(du -sh "$RCLONE_BACKUP_MOUNT" 2>/dev/null | cut -f1)
        RCLONE_COUNT=$(find "$RCLONE_BACKUP_MOUNT" \( -name "*.gz" -o -name "*.gz.enc" \) -type f | wc -l)
        echo "  • Rclone cloud storage backup size: $RCLONE_SIZE"
        echo "  • Rclone cloud storage backup files: $RCLONE_COUNT"
        echo "  • Rclone cloud storage path: $RCLONE_BACKUP_MOUNT"
    elif [ -d "$BACKUPS_DIR" ]; then
        BACKUP_SIZE=$(du -sh "$BACKUPS_DIR" 2>/dev/null | cut -f1)
        BACKUP_COUNT=$(find "$BACKUPS_DIR" \( -name "*.gz" -o -name "*.gz.enc" \) -type f | wc -l)
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
    
    # Sync to rclone cloud storage if configured, otherwise cleanup local backups
    if [ -n "$RCLONE_BACKUP_MOUNT" ]; then
        if ! sync_to_rclone; then
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
    echo "Recommended cron schedule:"
    echo "  # Smart backups (full every 12h, incremental hourly)"
    echo "  0 * * * * $SCRIPT_DIR/backup.sh >/dev/null 2>&1"
    echo ""
    echo "  # Alternative: Separate full and incremental schedules"
    echo "  # 0 0,12 * * * $SCRIPT_DIR/backup.sh postgres-full >/dev/null 2>&1    # Full backup twice daily"
    echo "  # 0 1-11,13-23 * * * $SCRIPT_DIR/backup.sh postgres-incremental >/dev/null 2>&1  # Incremental hourly"
    echo "  # 30 * * * * $SCRIPT_DIR/backup.sh redis >/dev/null 2>&1               # Redis hourly"
    echo "  # 45 * * * * $SCRIPT_DIR/backup.sh n8n >/dev/null 2>&1                 # n8n data hourly"
    echo ""
    if [ -n "$RCLONE_BACKUP_MOUNT" ]; then
        echo "Rclone cloud storage sync is automatically included when RCLONE_BACKUP_MOUNT is set"
    else
        echo "To enable rclone cloud storage sync, set RCLONE_BACKUP_MOUNT in .env"
    fi
}

# Handle command line arguments
case "${1:-}" in
    postgres)
        echo -e "${GREEN}🔄 Running PostgreSQL backup only${NC}"
        backup_postgres
        ;;
    postgres-full)
        echo -e "${GREEN}🔄 Running PostgreSQL full backup only${NC}"
        backup_postgres_full
        ;;
    postgres-incremental)
        echo -e "${GREEN}🔄 Running PostgreSQL incremental backup only${NC}"
        backup_postgres_incremental
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
        echo "  postgres              Smart PostgreSQL backup (full every 12h, incremental otherwise)"
        echo "  postgres-full         Force full PostgreSQL backup"
        echo "  postgres-incremental  Force incremental PostgreSQL backup"
        echo "  redis                 Backup Redis data only"
        echo "  n8n                   Backup n8n data only"
        echo "  (no args)             Backup all services"
        echo ""
        echo "PostgreSQL Backup Strategy:"
        echo "  - Full backups: Complete database dump (larger, standalone)"
        echo "  - Incremental backups: WAL files since last full backup (smaller, faster)"
        echo "  - Smart backup: Automatically chooses full (every 12h) or incremental"
        echo ""
        echo "🔒 Security Features:"
        echo "  - All backups automatically encrypted with AES-256-CBC"
        echo "  - Uses N8N_ENCRYPTION_KEY for encryption (must be 16+ characters)"
        echo "  - Encrypted files have .enc extension (e.g., backup.sql.gz.enc)"
        echo ""
        echo "Recommended cron schedule:"
        echo "  0 * * * * $SCRIPT_DIR/backup.sh                    # Hourly smart backups"
        echo "  0 0,12 * * * $SCRIPT_DIR/backup.sh postgres-full   # Force full backup twice daily"
        echo ""
        echo "Backups are stored in $BACKUPS_DIR with automatic cleanup after 7 days."
        exit 0
        ;;
    *)
        main
        ;;
esac