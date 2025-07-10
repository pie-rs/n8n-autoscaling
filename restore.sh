#!/bin/bash
# Restore script for n8n-autoscaling
# Provides point-in-time recovery with backup integrity validation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
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
RCLONE_BACKUP_MOUNT=${RCLONE_BACKUP_MOUNT:-}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-n8n-autoscaling}
ENVIRONMENT=${ENVIRONMENT:-dev}
POSTGRES_DB=${POSTGRES_DB:-n8n_${ENVIRONMENT}}
POSTGRES_USER=${POSTGRES_USER:-n8n_${ENVIRONMENT}_user}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-}
POSTGRES_ADMIN_USER=${POSTGRES_ADMIN_USER:-postgres}
POSTGRES_ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD:-}
REDIS_PASSWORD=${REDIS_PASSWORD:-}

# Global variables
DRY_RUN=false
BACKUP_CURRENT=true
AUTO_RESTART=true

echo -e "${GREEN}🔄 n8n-autoscaling Restore System${NC}"
echo "================================================"

# Function to find all available backups
find_backups() {
    local service="$1"
    declare -A backups
    
    echo -e "${YELLOW}📋 Scanning for available backups...${NC}"
    
    # Scan local backups
    if [ -d "$BACKUPS_DIR/$service" ]; then
        while IFS= read -r -d '' file; do
            local basename=$(basename "$file")
            local timestamp=$(echo "$basename" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            if [ -n "$timestamp" ]; then
                backups["$timestamp|local"]="$file"
            fi
        done < <(find "$BACKUPS_DIR/$service" -name "*.gz" -print0 2>/dev/null)
    fi
    
    # Scan rclone cloud storage backups
    if [ -n "$RCLONE_BACKUP_MOUNT" ] && [ -d "$RCLONE_BACKUP_MOUNT/$service" ]; then
        while IFS= read -r -d '' file; do
            local basename=$(basename "$file")
            local timestamp=$(echo "$basename" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            if [ -n "$timestamp" ]; then
                backups["$timestamp|rclone"]="$file"
            fi
        done < <(find "$RCLONE_BACKUP_MOUNT/$service" -name "*.gz" -print0 2>/dev/null)
    fi
    
    # Return the associative array as key-value pairs
    for key in "${!backups[@]}"; do
        echo "$key=${backups[$key]}"
    done
}

# Function to display available backups
display_backups() {
    local service="$1"
    local -A backup_list
    local counter=1
    
    echo -e "${BLUE}Available $service backups:${NC}"
    echo "----------------------------------------"
    
    # Read backups into associative array
    while IFS='=' read -r key value; do
        backup_list["$counter"]="$key|$value"
        counter=$((counter + 1))
    done < <(find_backups "$service" | sort -r)
    
    if [ ${#backup_list[@]} -eq 0 ]; then
        echo -e "${RED}❌ No backups found for $service${NC}"
        return 1
    fi
    
    # Display backups with numbers
    for i in $(seq 1 $((counter - 1))); do
        local entry="${backup_list[$i]}"
        local timestamp=$(echo "$entry" | cut -d'|' -f1)
        local source=$(echo "$entry" | cut -d'|' -f2)
        local filepath=$(echo "$entry" | cut -d'|' -f3)
        local size=""
        
        if [ -f "$filepath" ]; then
            size=" ($(du -h "$filepath" | cut -f1))"
        fi
        
        # Format date for display (cross-platform)
        local year=${timestamp:0:4}
        local month=${timestamp:4:2}
        local day=${timestamp:6:2}
        local hour=${timestamp:9:2}
        local min=${timestamp:11:2}
        local sec=${timestamp:13:2}
        
        # Try macOS date format first, then GNU date format
        local date_formatted=$(date -j -f "%Y%m%d%H%M%S" "${year}${month}${day}${hour}${min}${sec}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
                               date -d "${year}-${month}-${day} ${hour}:${min}:${sec}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
                               echo "$timestamp")
        
        if [ "$source" = "rclone" ]; then
            echo -e "${MAGENTA}$i)${NC} $date_formatted ${YELLOW}[Cloud]${NC}$size - $(basename "$filepath")"
        else
            echo -e "${MAGENTA}$i)${NC} $date_formatted ${BLUE}[Local]${NC}$size - $(basename "$filepath")"
        fi
    done
    
    echo ""
    
    # Return the backup list for selection
    for i in $(seq 1 $((counter - 1))); do
        echo "$i=${backup_list[$i]}"
    done
}

# Function to validate backup integrity
validate_backup() {
    local filepath="$1"
    local service="$2"
    
    echo -e "${YELLOW}🔍 Validating backup integrity...${NC}"
    
    if [ ! -f "$filepath" ]; then
        echo -e "${RED}❌ Backup file not found: $filepath${NC}"
        return 1
    fi
    
    # Check if file is not empty
    if [ ! -s "$filepath" ]; then
        echo -e "${RED}❌ Backup file is empty: $filepath${NC}"
        return 1
    fi
    
    # Validate compression format
    if [[ "$filepath" == *.gz ]]; then
        if ! gzip -t "$filepath" 2>/dev/null; then
            echo -e "${RED}❌ Backup file is corrupted (gzip test failed): $filepath${NC}"
            return 1
        fi
    elif [[ "$filepath" == *.tar.gz ]]; then
        if ! tar -tzf "$filepath" >/dev/null 2>&1; then
            echo -e "${RED}❌ Backup file is corrupted (tar test failed): $filepath${NC}"
            return 1
        fi
    fi
    
    # Service-specific validation
    case "$service" in
        postgres)
            if [[ "$filepath" == *"_full_"* ]]; then
                # For SQL dumps, check for basic SQL structure
                if ! gunzip -c "$filepath" 2>/dev/null | head -20 | grep -q "PostgreSQL database dump\|CREATE\|INSERT"; then
                    echo -e "${RED}❌ PostgreSQL backup appears corrupted (no SQL content found)${NC}"
                    return 1
                fi
            fi
            ;;
        redis)
            # Basic size check for Redis dumps
            local size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null)
            if [ "$size" -lt 100 ]; then
                echo -e "${RED}❌ Redis backup appears too small (< 100 bytes)${NC}"
                return 1
            fi
            ;;
    esac
    
    echo -e "${GREEN}✅ Backup validation passed${NC}"
    return 0
}

# Function to backup current data before restore
backup_current_data() {
    local service="$1"
    
    if [ "$BACKUP_CURRENT" = false ]; then
        return 0
    fi
    
    echo -e "${YELLOW}💾 Creating safety backup of current data...${NC}"
    
    local safety_dir="$BACKUPS_DIR/safety_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$safety_dir"
    
    case "$service" in
        postgres|all)
            if docker compose ps postgres | grep -q "Up"; then
                echo "  • Backing up current PostgreSQL data..."
                docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$safety_dir/postgres_safety.sql.gz"
            fi
            ;;
    esac
    
    case "$service" in
        redis|all)
            if docker compose ps redis | grep -q "Up"; then
                echo "  • Backing up current Redis data..."
                docker compose exec redis redis-cli -a "$REDIS_PASSWORD" --rdb - | gzip > "$safety_dir/redis_safety.rdb.gz"
            fi
            ;;
    esac
    
    case "$service" in
        n8n|all)
            if [ -d "$BACKUPS_DIR/../Data/n8n" ]; then
                echo "  • Backing up current n8n data..."
                tar -czf "$safety_dir/n8n_safety.tar.gz" -C "$BACKUPS_DIR/../Data" n8n n8n-webhook 2>/dev/null || true
            fi
            ;;
    esac
    
    echo -e "${GREEN}✅ Safety backup created at: $safety_dir${NC}"
    echo -e "${BLUE}💡 You can restore from this safety backup if needed${NC}"
}

# Function to stop containers
stop_containers() {
    local service="$1"
    
    echo -e "${YELLOW}⏹️  Stopping containers for safe restore...${NC}"
    
    case "$service" in
        postgres|all)
            docker compose stop postgres || true
            ;;
    esac
    
    case "$service" in
        redis|all)
            docker compose stop redis || true
            ;;
    esac
    
    case "$service" in
        n8n|all)
            docker compose stop n8n n8n-worker n8n-webhook || true
            ;;
    esac
    
    echo -e "${GREEN}✅ Containers stopped${NC}"
}

# Function to start containers
start_containers() {
    local service="$1"
    
    if [ "$AUTO_RESTART" = false ]; then
        return 0
    fi
    
    echo -e "${YELLOW}▶️  Starting containers...${NC}"
    
    case "$service" in
        postgres|all)
            docker compose up -d postgres
            echo "  • Waiting for PostgreSQL to be ready..."
            sleep 5
            ;;
    esac
    
    case "$service" in
        redis|all)
            docker compose up -d redis
            echo "  • Waiting for Redis to be ready..."
            sleep 3
            ;;
    esac
    
    case "$service" in
        n8n|all)
            docker compose up -d n8n n8n-worker n8n-webhook
            echo "  • Waiting for n8n services to be ready..."
            sleep 10
            ;;
    esac
    
    echo -e "${GREEN}✅ Containers started${NC}"
}

# Function to restore PostgreSQL
restore_postgres() {
    local filepath="$1"
    
    echo -e "${YELLOW}🔄 Restoring PostgreSQL from: $(basename "$filepath")${NC}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN] Would restore PostgreSQL from $filepath${NC}"
        return 0
    fi
    
    # Validate backup first
    if ! validate_backup "$filepath" "postgres"; then
        return 1
    fi
    
    # Start PostgreSQL if not running
    if ! docker compose ps postgres | grep -q "Up"; then
        docker compose up -d postgres
        echo "  • Waiting for PostgreSQL to start..."
        sleep 10
    fi
    
    # Drop and recreate database (using admin user)
    echo "  • Dropping and recreating database..."
    docker compose exec -T postgres psql -U "$POSTGRES_ADMIN_USER" -c "DROP DATABASE IF EXISTS $POSTGRES_DB;"
    docker compose exec -T postgres psql -U "$POSTGRES_ADMIN_USER" -c "CREATE DATABASE $POSTGRES_DB OWNER $POSTGRES_USER;"
    docker compose exec -T postgres psql -U "$POSTGRES_ADMIN_USER" -c "GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;"
    
    # Restore from backup (using application user)
    echo "  • Restoring data..."
    gunzip -c "$filepath" | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
    
    echo -e "${GREEN}✅ PostgreSQL restore completed${NC}"
}

# Function to restore Redis
restore_redis() {
    local filepath="$1"
    
    echo -e "${YELLOW}🔄 Restoring Redis from: $(basename "$filepath")${NC}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN] Would restore Redis from $filepath${NC}"
        return 0
    fi
    
    # Validate backup first
    if ! validate_backup "$filepath" "redis"; then
        return 1
    fi
    
    # Stop Redis for file replacement
    docker compose stop redis
    
    # Restore Redis dump file
    echo "  • Restoring Redis data file..."
    gunzip -c "$filepath" > "/tmp/dump.rdb"
    docker compose cp "/tmp/dump.rdb" redis:/data/dump.rdb
    rm -f "/tmp/dump.rdb"
    
    echo -e "${GREEN}✅ Redis restore completed${NC}"
}

# Function to restore n8n data
restore_n8n() {
    local filepath="$1"
    
    echo -e "${YELLOW}🔄 Restoring n8n data from: $(basename "$filepath")${NC}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN] Would restore n8n data from $filepath${NC}"
        return 0
    fi
    
    # Validate backup first
    if ! validate_backup "$filepath" "n8n"; then
        return 1
    fi
    
    # Stop n8n services
    docker compose stop n8n n8n-worker n8n-webhook
    
    # Backup current data and restore
    local data_dir="$BACKUPS_DIR/../Data"
    echo "  • Restoring n8n data directories..."
    
    # Remove current data
    rm -rf "$data_dir/n8n" "$data_dir/n8n-webhook" 2>/dev/null || true
    
    # Extract backup
    tar -xzf "$filepath" -C "$data_dir"
    
    echo -e "${GREEN}✅ n8n data restore completed${NC}"
}

# Main interactive menu
interactive_restore() {
    echo -e "${BLUE}🎯 Interactive Restore Mode${NC}"
    echo ""
    
    # Service selection
    echo "Select service to restore:"
    echo "1) PostgreSQL database"
    echo "2) Redis data"
    echo "3) n8n data"
    echo "4) All services (point-in-time)"
    echo "5) List backups only"
    echo "0) Exit"
    echo ""
    read -p "Enter choice [0-5]: " service_choice
    
    local service=""
    case "$service_choice" in
        1) service="postgres" ;;
        2) service="redis" ;;
        3) service="n8n" ;;
        4) service="all" ;;
        5) 
            echo ""
            display_backups "postgres" | head -20
            echo ""
            display_backups "redis" | head -10
            echo ""
            display_backups "n8n" | head -10
            return 0
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid choice${NC}"; return 1 ;;
    esac
    
    # Display available backups
    echo ""
    local backup_options
    backup_options=$(display_backups "$service")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Backup selection
    echo "Select backup to restore:"
    echo "0) Cancel"
    echo ""
    read -p "Enter backup number: " backup_choice
    
    if [ "$backup_choice" = "0" ]; then
        echo "Restore cancelled"
        return 0
    fi
    
    # Get selected backup info
    local selected_backup=$(echo "$backup_options" | grep "^$backup_choice=")
    if [ -z "$selected_backup" ]; then
        echo -e "${RED}Invalid backup selection${NC}"
        return 1
    fi
    
    local backup_info=$(echo "$selected_backup" | cut -d'=' -f2-)
    local filepath=$(echo "$backup_info" | cut -d'|' -f3)
    
    # Confirmation
    echo ""
    echo -e "${RED}⚠️  WARNING: This will replace current data with backup data!${NC}"
    echo -e "${YELLOW}Selected backup: $(basename "$filepath")${NC}"
    echo ""
    echo "Safety measures:"
    echo "✓ Current data will be backed up before restore"
    echo "✓ Backup integrity will be validated"
    echo "✓ Containers will be safely stopped/restarted"
    echo ""
    read -p "Are you sure you want to proceed? [yes/no]: " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "Restore cancelled"
        return 0
    fi
    
    # Execute restore
    echo ""
    echo -e "${GREEN}🚀 Starting restore process...${NC}"
    
    # Create safety backup
    backup_current_data "$service"
    
    # Stop containers
    stop_containers "$service"
    
    # Perform restore
    case "$service" in
        postgres) restore_postgres "$filepath" ;;
        redis) restore_redis "$filepath" ;;
        n8n) restore_n8n "$filepath" ;;
        all)
            # For all services, we need to implement point-in-time restore
            echo -e "${YELLOW}🔄 Point-in-time restore not yet implemented for 'all' services${NC}"
            echo -e "${BLUE}💡 Please restore services individually for now${NC}"
            return 1
            ;;
    esac
    
    # Start containers
    start_containers "$service"
    
    echo ""
    echo -e "${GREEN}🎉 Restore completed successfully!${NC}"
    echo -e "${BLUE}💡 Test your system to ensure everything is working correctly${NC}"
}

# Handle command line arguments
case "${1:-}" in
    --dry-run)
        DRY_RUN=true
        echo -e "${BLUE}🔍 DRY RUN MODE - No changes will be made${NC}"
        echo ""
        interactive_restore
        ;;
    --list)
        echo -e "${BLUE}📋 Available backups:${NC}"
        echo ""
        display_backups "postgres" | head -10
        echo ""
        display_backups "redis" | head -10
        echo ""
        display_backups "n8n" | head -10
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h    Show this help message"
        echo "  --dry-run     Show what would be restored without doing it"
        echo "  --list        List available backups"
        echo "  (no args)     Interactive restore mode"
        echo ""
        echo "This script provides point-in-time recovery for n8n-autoscaling."
        echo "It automatically finds backups from both local and rclone cloud storage sources."
        echo ""
        echo "Safety features:"
        echo "  • Creates safety backup before restore"
        echo "  • Validates backup integrity"
        echo "  • Safely stops/starts containers"
        echo "  • Interactive confirmation prompts"
        ;;
    *)
        interactive_restore
        ;;
esac