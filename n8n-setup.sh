#!/bin/bash
# Simplified n8n-autoscaling setup script - core functionality only

set -e

# Colors using tput for compatibility
if command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    NC=$(tput sgr0)
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

echo "${CYAN}🚀 n8n-autoscaling Setup Wizard${NC}"
echo "================================"
echo ""

# Function to reset environment
reset_environment() {
    echo "${YELLOW}⚠️  WARNING: This will delete all data and configuration!${NC}"
    echo ""
    echo "What would you like to reset?"
    echo "1. Everything (recommended for clean start)"
    echo "2. Just data directories (keep .env file)"
    echo "3. Just .env file (keep data)"
    echo "4. Cancel"
    echo ""
    echo -n "Enter your choice [1-4]: "
    read -r reset_choice
    
    case "$reset_choice" in
        1)
            echo "${YELLOW}🔄 Resetting everything...${NC}"
            
            # Stop all containers
            echo "${BLUE}Stopping all containers...${NC}"
            docker compose down -v 2>/dev/null || true
            
            # Remove data directories
            echo "${BLUE}Removing data directories...${NC}"
            rm -rf Data/Postgres/pgdata 2>/dev/null || true
            rm -rf Data/Redis/* 2>/dev/null || true
            rm -rf Data/n8n/* 2>/dev/null || true
            rm -rf Data/n8n-webhook/* 2>/dev/null || true
            rm -rf Data/Traefik/* 2>/dev/null || true
            
            # Remove .env file
            echo "${BLUE}Removing .env file...${NC}"
            rm -f .env .env.bak
            
            # Prune Docker resources
            echo -n "Do you want to prune Docker networks and volumes? [y/N]: "
            read -r prune_response
            case "$prune_response" in
                [Yy]|[Yy][Ee][Ss])
                    docker network prune -f
                    docker volume prune -f
                    ;;
            esac
            
            echo "${GREEN}✅ Environment reset complete${NC}"
            echo ""
            echo -n "Do you want to run the setup wizard now? [Y/n]: "
            read -r setup_response
            if [ -z "$setup_response" ] || [[ "$setup_response" =~ ^[Yy] ]]; then
                echo ""
                # Continue with setup
                return 0
            else
                exit 0
            fi
            ;;
        2)
            echo "${YELLOW}🔄 Resetting data directories...${NC}"
            
            # Stop containers first
            echo "${BLUE}Stopping all containers...${NC}"
            docker compose down 2>/dev/null || true
            
            # Remove data directories
            echo "${BLUE}Removing data directories...${NC}"
            rm -rf Data/Postgres/pgdata 2>/dev/null || true
            rm -rf Data/Redis/* 2>/dev/null || true
            rm -rf Data/n8n/* 2>/dev/null || true
            rm -rf Data/n8n-webhook/* 2>/dev/null || true
            rm -rf Data/Traefik/* 2>/dev/null || true
            
            echo "${GREEN}✅ Data directories reset complete${NC}"
            exit 0
            ;;
        3)
            echo "${YELLOW}🔄 Removing .env file...${NC}"
            rm -f .env .env.bak
            echo "${GREEN}✅ .env file removed${NC}"
            echo "${YELLOW}⚠️  Note: Existing data won't work with new passwords!${NC}"
            echo ""
            # Continue with setup
            return 0
            ;;
        4|*)
            echo "${BLUE}Cancelled${NC}"
            exit 0
            ;;
    esac
}

# Check if any data directories exist (even without .env)
DATA_EXISTS=false
if [ -d "Data/Postgres/pgdata" ] || [ -d "Data/Redis" ] || [ -d "Data/n8n" ] || [ -f .env ]; then
    DATA_EXISTS=true
fi

# Show main menu based on current state
if [ "$DATA_EXISTS" = "true" ]; then
    if [ -f .env ]; then
        SETUP_COMPLETE_FLAG=$(grep "^SETUP_COMPLETED=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
        if [ "$SETUP_COMPLETE_FLAG" = "true" ]; then
            echo "${GREEN}✅ Setup has been completed previously.${NC}"
        else
            echo "${YELLOW}⚠️  Found partial setup (.env exists but setup not completed)${NC}"
        fi
    else
        echo "${YELLOW}⚠️  Found existing data directories but no .env file${NC}"
    fi
    
    echo ""
    echo "What would you like to do?"
    echo "1. Run full setup wizard"
    echo "2. Reset environment (clean start)"
    if [ "$SETUP_COMPLETE_FLAG" = "true" ]; then
        echo "3. Set up systemd services"
        echo "4. Exit"
    else
        echo "3. Exit"
    fi
    echo ""
    
    if [ "$SETUP_COMPLETE_FLAG" = "true" ]; then
        echo -n "Enter your choice [1-4]: "
    else
        echo -n "Enter your choice [1-3]: "
    fi
    read -r choice_response
    
    case "$choice_response" in
        1)
            echo "${BLUE}🔄 Running setup wizard...${NC}"
            echo ""
            # Continue with full setup
            ;;
        2)
            reset_environment
            ;;
        3)
            if [ "$SETUP_COMPLETE_FLAG" = "true" ]; then
                echo "${BLUE}🔧 Setting up systemd services...${NC}"
                ./generate-systemd.sh
                exit 0
            else
                exit 0
            fi
            ;;
        4|*)
            exit 0
            ;;
    esac
fi

# Function to detect timezone
detect_timezone() {
    if [ -f /etc/timezone ]; then
        cat /etc/timezone
    elif [ -L /etc/localtime ]; then
        readlink /etc/localtime | sed 's|/usr/share/zoneinfo/||'
    elif command -v timedatectl &> /dev/null; then
        timedatectl show --property=Timezone --value
    else
        echo "UTC"
    fi
}

# Step 1: Environment file creation
echo "${BLUE}📋 Environment Configuration${NC}"
echo "----------------------------"

if [ -f .env ]; then
    echo "${YELLOW}⚠️  .env file already exists.${NC}"
    echo -n "Do you want to overwrite it? [y/N]: "
    read -r overwrite_response
    case "$overwrite_response" in
        [Yy]|[Yy][Ee][Ss])
            rm -f .env
            echo "${GREEN}✅ Existing .env file removed.${NC}"
            ;;
        *)
            echo "${BLUE}ℹ️  Using existing .env file. Some settings may not be updated.${NC}"
            ;;
    esac
fi

if [ ! -f .env ]; then
    echo -n "Create .env file from .env.example? [Y/n]: "
    read -r create_response
    if [ -z "$create_response" ]; then
        create_response="y"
    fi
    
    case "$create_response" in
        [Yy]|[Yy][Ee][Ss])
            cp .env.example .env
            echo "${GREEN}✅ Created .env file from .env.example${NC}"
            ;;
        *)
            echo "${RED}❌ Cannot proceed without .env file.${NC}"
            exit 1
            ;;
    esac
fi

# Step 2: Environment selection with validation
echo ""
echo "${BLUE}🏗️  Environment Setup${NC}"
echo "--------------------"

while true; do
    echo -n "Enter environment (dev/test/production) [dev]: "
    read -r ENVIRONMENT_INPUT
    if [ -z "$ENVIRONMENT_INPUT" ]; then
        ENVIRONMENT="dev"
        break
    else
        case "$ENVIRONMENT_INPUT" in
            dev|test|production)
                ENVIRONMENT="$ENVIRONMENT_INPUT"
                break
                ;;
            *)
                echo "${RED}❌ Invalid environment. Please enter 'dev', 'test', or 'production'${NC}"
                ;;
        esac
    fi
done
echo "${GREEN}✅ Environment set to: $ENVIRONMENT${NC}"

# Update environment in .env
sed -i.bak "s/^ENVIRONMENT=.*/ENVIRONMENT=$ENVIRONMENT/" .env

# Step 3: Secret generation
echo ""
echo "${BLUE}🔐 Secret Generation${NC}"
echo "-------------------"

echo -n "Do you want to generate secure random secrets? [Y/n]: "
read -r secrets_response
if [ -z "$secrets_response" ]; then
    secrets_response="y"
fi

case "$secrets_response" in
    [Yy]|[Yy][Ee][Ss])
        echo -n "Enter a salt (any characters) for secret generation [press Enter for random]: "
        read -r SALT
        if [ -z "$SALT" ]; then
            SALT=$(openssl rand -hex 16)
            echo "${BLUE}ℹ️  Using random salt: $SALT${NC}"
        fi
        
        echo "${YELLOW}🔄 Generating secrets...${NC}"
        
        # Simple secret generation without complex function
        REDIS_PASSWORD=$(echo -n "${SALT}redis$(date +%s)" | sha256sum | cut -c1-32)
        POSTGRES_PASSWORD=$(echo -n "${SALT}postgres$(date +%s)" | sha256sum | cut -c1-32)
        POSTGRES_ADMIN_PASSWORD=$(echo -n "${SALT}admin$(date +%s)" | sha256sum | cut -c1-32)
        N8N_ENCRYPTION_KEY=$(echo -n "${SALT}encrypt$(date +%s)" | sha256sum | cut -c1-64)
        N8N_JWT_SECRET=$(echo -n "${SALT}jwt$(date +%s)" | sha256sum | cut -c1-64)
        N8N_RUNNERS_AUTH_TOKEN=$(echo -n "${SALT}token$(date +%s)" | sha256sum | cut -c1-32)
        
        # Update .env with generated secrets
        sed -i.bak "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=$REDIS_PASSWORD/" .env
        sed -i.bak "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$POSTGRES_PASSWORD/" .env
        sed -i.bak "s/^POSTGRES_ADMIN_PASSWORD=.*/POSTGRES_ADMIN_PASSWORD=$POSTGRES_ADMIN_PASSWORD/" .env
        sed -i.bak "s/^N8N_ENCRYPTION_KEY=.*/N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY/" .env
        sed -i.bak "s/^N8N_USER_MANAGEMENT_JWT_SECRET=.*/N8N_USER_MANAGEMENT_JWT_SECRET=$N8N_JWT_SECRET/" .env
        sed -i.bak "s/^N8N_RUNNERS_AUTH_TOKEN=.*/N8N_RUNNERS_AUTH_TOKEN=$N8N_RUNNERS_AUTH_TOKEN/" .env
        
        echo "${GREEN}✅ Secrets generated and updated in .env${NC}"
        ;;
    *)
        echo "${YELLOW}⚠️  You'll need to manually update passwords in .env${NC}"
        ;;
esac

# Step 4: Timezone configuration
echo ""
echo "${BLUE}🌍 Timezone Configuration${NC}"
echo "-------------------------"

DETECTED_TZ=$(detect_timezone)
echo "${BLUE}ℹ️  Detected timezone: $DETECTED_TZ${NC}"

echo -n "Use detected timezone? [Y/n]: "
read -r tz_response
if [ -z "$tz_response" ]; then
    tz_response="y"
fi

case "$tz_response" in
    [Yy]|[Yy][Ee][Ss])
        TIMEZONE="$DETECTED_TZ"
        ;;
    *)
        echo -n "Enter timezone (e.g., America/New_York, Europe/London) [$DETECTED_TZ]: "
        read -r TIMEZONE_INPUT
        if [ -z "$TIMEZONE_INPUT" ]; then
            TIMEZONE="$DETECTED_TZ"
        else
            TIMEZONE="$TIMEZONE_INPUT"
        fi
        ;;
esac

# Update timezone in .env
sed -i.bak "s|^GENERIC_TIMEZONE=.*|GENERIC_TIMEZONE=$TIMEZONE|" .env
echo "${GREEN}✅ Timezone set to: $TIMEZONE${NC}"
echo "${BLUE}ℹ️  PostgreSQL will use UTC internally (recommended for production)${NC}"

# Step 5: URL Configuration
echo ""
echo "${BLUE}🌐 URL Configuration${NC}"
echo "-------------------"

echo -n "Enter n8n main URL (without https://, e.g., n8n.yourdomain.com): "
read -r N8N_HOST
while [ -z "$N8N_HOST" ]; do
    echo "${RED}❌ N8N URL is required${NC}"
    echo -n "Enter n8n main URL (without https://): "
    read -r N8N_HOST
done

echo -n "Enter webhook URL (without https://, e.g., webhook.yourdomain.com): "
read -r N8N_WEBHOOK_HOST
while [ -z "$N8N_WEBHOOK_HOST" ]; do
    echo "${RED}❌ Webhook URL is required${NC}"
    echo -n "Enter webhook URL (without https://): "
    read -r N8N_WEBHOOK_HOST
done

# Build the full URLs (add https:// where needed)
N8N_MAIN_URL="https://$N8N_HOST"
N8N_WEBHOOK_URL="https://$N8N_WEBHOOK_HOST"

# Update URLs in .env
sed -i.bak "s|^N8N_HOST=.*|N8N_HOST=$N8N_HOST|" .env
sed -i.bak "s|^N8N_WEBHOOK=.*|N8N_WEBHOOK=$N8N_WEBHOOK_HOST|" .env
sed -i.bak "s|^N8N_WEBHOOK_URL=.*|N8N_WEBHOOK_URL=$N8N_WEBHOOK_URL|" .env
sed -i.bak "s|^WEBHOOK_URL=.*|WEBHOOK_URL=$N8N_WEBHOOK_URL|" .env
sed -i.bak "s|^N8N_EDITOR_BASE_URL=.*|N8N_EDITOR_BASE_URL=$N8N_MAIN_URL|" .env

echo "${GREEN}✅ URLs configured:${NC}"
echo "   N8N_HOST: $N8N_HOST"
echo "   N8N_WEBHOOK: $N8N_WEBHOOK_HOST" 
echo "   N8N_WEBHOOK_URL: $N8N_WEBHOOK_URL"
echo "   WEBHOOK_URL: $N8N_WEBHOOK_URL"
echo "   N8N_EDITOR_BASE_URL: $N8N_MAIN_URL"

# Step 6: External Network Configuration
echo ""
echo "${BLUE}🌐 External Network Configuration${NC}"
echo "---------------------------------"

echo -n "Do you want to enable external network for connecting to other containers? [y/N]: "
read -r external_network_response
case "$external_network_response" in
    [Yy]|[Yy][Ee][Ss])
        echo -n "Enter external network name [n8n-external]: "
        read -r EXTERNAL_NETWORK_NAME
        if [ -z "$EXTERNAL_NETWORK_NAME" ]; then
            EXTERNAL_NETWORK_NAME="n8n-external"
        fi
        
        # Uncomment and update external network settings
        sed -i.bak "s|^#EXTERNAL_NETWORK_NAME=.*|EXTERNAL_NETWORK_NAME=$EXTERNAL_NETWORK_NAME|" .env
        
        echo "${GREEN}✅ External network enabled: $EXTERNAL_NETWORK_NAME${NC}"
        echo "${BLUE}ℹ️  You'll need to uncomment network sections in docker-compose.yml${NC}"
        ;;
    *)
        echo "${BLUE}ℹ️  External network disabled${NC}"
        ;;
esac

# Step 7: Rclone Mount Integration
echo ""
echo "${BLUE}☁️  Rclone Mount Integration${NC}"
echo "----------------------------"
echo "${BLUE}ℹ️  Rclone supports many cloud storage backends (Google Drive, OneDrive, S3, etc.)${NC}"

echo -n "Do you want to enable rclone mount integration? [y/N]: "
read -r rclone_response
case "$rclone_response" in
    [Yy]|[Yy][Ee][Ss])
        echo "${YELLOW}⚠️  Make sure you have rclone installed and configured first!${NC}"
        echo "${BLUE}ℹ️  See documentation for rclone setup instructions${NC}"
        echo ""
        
        while true; do
            echo -n "Enter rclone data mount path [/mnt/rclone-data]: "
            read -r RCLONE_DATA_MOUNT
            if [ -z "$RCLONE_DATA_MOUNT" ]; then
                RCLONE_DATA_MOUNT="/mnt/rclone-data"
            fi
            
            if [ -d "$RCLONE_DATA_MOUNT" ]; then
                echo "${GREEN}✅ Data mount directory exists${NC}"
                break
            else
                echo "${RED}❌ Directory does not exist: $RCLONE_DATA_MOUNT${NC}"
                echo -n "Do you want to create it? [y/N]: "
                read -r create_dir_response
                case "$create_dir_response" in
                    [Yy]|[Yy][Ee][Ss])
                        mkdir -p "$RCLONE_DATA_MOUNT" && echo "${GREEN}✅ Created directory${NC}" && break
                        ;;
                    *)
                        echo "${YELLOW}⚠️  Skipping rclone integration${NC}"
                        RCLONE_ENABLED=false
                        break 2  # Break out of both loops
                        ;;
                esac
            fi
        done
        
        # Only continue with backup mount if data mount was successful
        if [ "$RCLONE_ENABLED" != "false" ]; then
        while true; do
            echo -n "Enter rclone backup mount path [/mnt/rclone-backups]: "
            read -r RCLONE_BACKUP_MOUNT
            if [ -z "$RCLONE_BACKUP_MOUNT" ]; then
                RCLONE_BACKUP_MOUNT="/mnt/rclone-backups"
            fi
            
            if [ -d "$RCLONE_BACKUP_MOUNT" ]; then
                echo "${GREEN}✅ Backup mount directory exists${NC}"
                break
            else
                echo "${RED}❌ Directory does not exist: $RCLONE_BACKUP_MOUNT${NC}"
                echo -n "Do you want to create it? [y/N]: "
                read -r create_backup_dir_response
                case "$create_backup_dir_response" in
                    [Yy]|[Yy][Ee][Ss])
                        mkdir -p "$RCLONE_BACKUP_MOUNT" && echo "${GREEN}✅ Created directory${NC}" && break
                        ;;
                    *)
                        echo "${YELLOW}⚠️  Skipping rclone integration${NC}"
                        RCLONE_ENABLED=false
                        break 2  # Break out of both loops
                        ;;
                esac
            fi
        done
        
        # Only configure rclone if both mounts were successful
        if [ "$RCLONE_ENABLED" != "false" ]; then
            RCLONE_ENABLED=true
            
            # Uncomment and update rclone settings
            sed -i.bak "s|^#RCLONE_DATA_MOUNT=.*|RCLONE_DATA_MOUNT=$RCLONE_DATA_MOUNT|" .env
            sed -i.bak "s|^#RCLONE_BACKUP_MOUNT=.*|RCLONE_BACKUP_MOUNT=$RCLONE_BACKUP_MOUNT|" .env
            
            echo "${GREEN}✅ Rclone integration enabled${NC}"
            echo "${BLUE}ℹ️  Make sure to mount your rclone remote before starting services${NC}"
        fi
        fi
        ;;
    *)
        echo "${BLUE}ℹ️  Rclone integration disabled${NC}"
        RCLONE_ENABLED=false
        ;;
esac

# Step 8: Cloudflare Tunnel Configuration
echo ""
echo "${BLUE}☁️  Cloudflare Tunnel Configuration${NC}"
echo "----------------------------------"

echo -n "Do you want to configure Cloudflare Tunnel? [y/N]: "
read -r cloudflare_response
case "$cloudflare_response" in
    [Yy]|[Yy][Ee][Ss])
        echo "${BLUE}ℹ️  You can get your tunnel token from: https://dash.cloudflare.com/ → Zero Trust → Access → Tunnels${NC}"
        while true; do
            echo -n "Enter your Cloudflare tunnel token: "
            read -r CLOUDFLARE_TOKEN
            if [ -n "$CLOUDFLARE_TOKEN" ] && [ ${#CLOUDFLARE_TOKEN} -gt 20 ]; then
                break
            else
                echo "${RED}❌ Invalid token. Please enter a valid Cloudflare tunnel token${NC}"
            fi
        done
        
        # Update Cloudflare token
        sed -i.bak "s/^CLOUDFLARE_TUNNEL_TOKEN=.*/CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TOKEN/" .env
        
        echo "${GREEN}✅ Cloudflare tunnel configured${NC}"
        ;;
    *)
        echo "${BLUE}ℹ️  Cloudflare tunnel not configured${NC}"
        echo "${YELLOW}⚠️  You'll need to set CLOUDFLARE_TUNNEL_TOKEN manually in .env${NC}"
        ;;
esac

# Step 9: Tailscale Configuration
echo ""
echo "${BLUE}🔗 Tailscale Configuration${NC}"
echo "-------------------------"

echo -n "Do you want to configure Tailscale IP for PostgreSQL binding? [y/N]: "
read -r tailscale_response
case "$tailscale_response" in
    [Yy]|[Yy][Ee][Ss])
        echo "${BLUE}ℹ️  This binds PostgreSQL to your Tailscale IP for secure remote access${NC}"
        echo "${BLUE}ℹ️  Find your Tailscale IP with: tailscale ip -4${NC}"
        
        while true; do
            echo -n "Enter your Tailscale IP (e.g., 100.64.1.2): "
            read -r TAILSCALE_IP
            # Basic IP validation
            if [[ $TAILSCALE_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                break
            else
                echo "${RED}❌ Invalid IP format. Please use format: 192.168.1.100${NC}"
            fi
        done
        
        # Update Tailscale IP
        sed -i.bak "s/^TAILSCALE_IP=.*/TAILSCALE_IP=$TAILSCALE_IP/" .env
        
        echo "${GREEN}✅ Tailscale IP configured: $TAILSCALE_IP${NC}"
        echo "${BLUE}ℹ️  PostgreSQL will bind to: $TAILSCALE_IP:5432${NC}"
        ;;
    *)
        echo "${BLUE}ℹ️  Tailscale not configured - PostgreSQL will bind to all interfaces${NC}"
        ;;
esac

# Step 10: Autoscaling Configuration
echo ""
echo "${BLUE}⚖️  Autoscaling Configuration${NC}"
echo "----------------------------"

echo "${BLUE}ℹ️  Current defaults: MIN=1, MAX=5, Scale Up at >5 jobs, Scale Down at <1 job${NC}"
echo -n "Do you want to customize autoscaling parameters? [y/N]: "
read -r autoscaling_response
case "$autoscaling_response" in
    [Yy]|[Yy][Ee][Ss])
        echo -n "Minimum worker replicas (always running) [1]: "
        read -r MIN_REPLICAS
        if [ -z "$MIN_REPLICAS" ]; then
            MIN_REPLICAS="1"
        fi
        
        echo -n "Maximum worker replicas (scale limit) [5]: "
        read -r MAX_REPLICAS
        if [ -z "$MAX_REPLICAS" ]; then
            MAX_REPLICAS="5"
        fi
        
        echo -n "Scale up when queue length exceeds [5]: "
        read -r SCALE_UP_THRESHOLD
        if [ -z "$SCALE_UP_THRESHOLD" ]; then
            SCALE_UP_THRESHOLD="5"
        fi
        
        echo -n "Scale down when queue length drops below [1]: "
        read -r SCALE_DOWN_THRESHOLD
        if [ -z "$SCALE_DOWN_THRESHOLD" ]; then
            SCALE_DOWN_THRESHOLD="1"
        fi
        
        # Update autoscaling settings
        sed -i.bak "s/^MIN_REPLICAS=.*/MIN_REPLICAS=$MIN_REPLICAS/" .env
        sed -i.bak "s/^MAX_REPLICAS=.*/MAX_REPLICAS=$MAX_REPLICAS/" .env
        sed -i.bak "s/^SCALE_UP_QUEUE_THRESHOLD=.*/SCALE_UP_QUEUE_THRESHOLD=$SCALE_UP_THRESHOLD/" .env
        sed -i.bak "s/^SCALE_DOWN_QUEUE_THRESHOLD=.*/SCALE_DOWN_QUEUE_THRESHOLD=$SCALE_DOWN_THRESHOLD/" .env
        
        echo "${GREEN}✅ Autoscaling configured: $MIN_REPLICAS-$MAX_REPLICAS workers, up at >$SCALE_UP_THRESHOLD, down at <$SCALE_DOWN_THRESHOLD${NC}"
        ;;
    *)
        echo "${BLUE}ℹ️  Using default autoscaling settings (1-5 workers)${NC}"
        ;;
esac

# Step 11: Container Runtime Detection
echo ""
echo "${BLUE}🐳 Container Runtime Configuration${NC}"
echo "---------------------------------"

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
else
    CONTAINER_RUNTIME="none"
fi

echo "${BLUE}ℹ️  Detected container runtime: $CONTAINER_RUNTIME${NC}"

if [ "$CONTAINER_RUNTIME" = "none" ]; then
    echo "${RED}❌ No container runtime detected. Please install Docker or Podman.${NC}"
    exit 1
fi

echo -n "Use detected container runtime ($CONTAINER_RUNTIME)? [Y/n]: "
read -r runtime_response
if [ -z "$runtime_response" ]; then
    runtime_response="y"
fi

case "$runtime_response" in
    [Yy]|[Yy][Ee][Ss])
        echo "${GREEN}✅ Using $CONTAINER_RUNTIME${NC}"
        ;;
    *)
        while true; do
            echo -n "Enter container runtime (docker/podman) [$CONTAINER_RUNTIME]: "
            read -r CONTAINER_RUNTIME_INPUT
            if [ -z "$CONTAINER_RUNTIME_INPUT" ]; then
                break
            elif [ "$CONTAINER_RUNTIME_INPUT" = "docker" ] || [ "$CONTAINER_RUNTIME_INPUT" = "podman" ]; then
                CONTAINER_RUNTIME="$CONTAINER_RUNTIME_INPUT"
                break
            else
                echo "${RED}❌ Invalid runtime. Please enter 'docker' or 'podman'${NC}"
            fi
        done
        ;;
esac

# Step 12: Create data directories
echo ""
echo "${BLUE}📁 Creating Data Directories${NC}"
echo "----------------------------"

# Load current .env to get directory paths
source .env

echo "${YELLOW}🔄 Creating data directories...${NC}"
mkdir -p "${DATA_DIR}/Postgres"
mkdir -p "${DATA_DIR}/Redis"
mkdir -p "${DATA_DIR}/n8n"
mkdir -p "${DATA_DIR}/n8n-webhook"
mkdir -p "${DATA_DIR}/Traefik"
mkdir -p "${BACKUPS_DIR}"

# Set permissions
chmod -R 755 "${DATA_DIR}" 2>/dev/null || true
chmod -R 755 "${BACKUPS_DIR}" 2>/dev/null || true

# Update .env with absolute paths for Docker volumes
CURRENT_DIR=$(pwd)
# Convert DATA_DIR to absolute path - handle both relative and absolute paths
if [[ "$DATA_DIR" = /* ]]; then
    # Already absolute path
    ABSOLUTE_DATA_DIR="$DATA_DIR"
else
    # Convert relative path to absolute
    ABSOLUTE_DATA_DIR="$CURRENT_DIR/${DATA_DIR#./}"
fi
sed -i.bak "s|^DATA_DIR=.*|DATA_DIR=$ABSOLUTE_DATA_DIR|" .env

# Update BACKUPS_DIR to absolute path
if [[ "$BACKUPS_DIR" != /* ]]; then
    ABSOLUTE_BACKUPS_DIR="$CURRENT_DIR/${BACKUPS_DIR#./}"
    sed -i.bak "s|^BACKUPS_DIR=.*|BACKUPS_DIR=$ABSOLUTE_BACKUPS_DIR|" .env
fi

echo "${GREEN}✅ Data directories created with absolute paths${NC}"

# Create external network if configured
if [ -n "$EXTERNAL_NETWORK_NAME" ]; then
    echo "${YELLOW}🔄 Creating external network...${NC}"
    if [ "$CONTAINER_RUNTIME" = "docker" ]; then
        docker network inspect "${EXTERNAL_NETWORK_NAME}" >/dev/null 2>&1 || docker network create "${EXTERNAL_NETWORK_NAME}"
    elif [ "$CONTAINER_RUNTIME" = "podman" ]; then
        podman network inspect "${EXTERNAL_NETWORK_NAME}" >/dev/null 2>&1 || podman network create "${EXTERNAL_NETWORK_NAME}"
    fi
    echo "${GREEN}✅ External network created/verified${NC}"
fi

# Step 13: Database Creation
echo ""
echo "${BLUE}🗄️  Database Setup${NC}"
echo "-----------------"

echo -n "Do you want to create the database now? [Y/n]: "
read -r db_response
if [ -z "$db_response" ]; then
    db_response="y"
fi

case "$db_response" in
    [Yy]|[Yy][Ee][Ss])
        echo "${YELLOW}🔄 Starting database services...${NC}"
        
        # Build compose file list for database startup
        COMPOSE_FILES="-f docker-compose.yml"
        if [ "$RCLONE_ENABLED" = "true" ]; then
            COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.rclone.yml"
        fi
        if [ -n "$CLOUDFLARE_TOKEN" ] && [ "$CLOUDFLARE_TOKEN" != "your_tunnel_token_here" ]; then
            COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.cloudflare.yml"
        fi
        
        # Start PostgreSQL and Redis
        if [ "$CONTAINER_RUNTIME" = "docker" ]; then
            docker compose $COMPOSE_FILES up -d postgres redis
        else
            podman compose $COMPOSE_FILES up -d postgres redis
        fi
        
        echo "${YELLOW}⏳ Waiting for database to be ready...${NC}"
        sleep 10
        
        # Check if database already exists
        DB_EXISTS=false
        if [ "$CONTAINER_RUNTIME" = "docker" ]; then
            if docker compose exec -T -e PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}" postgres psql -U "${POSTGRES_ADMIN_USER:-postgres}" -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "n8n_${ENVIRONMENT}"; then
                DB_EXISTS=true
            fi
        else
            if podman compose exec -T -e PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}" postgres psql -U "${POSTGRES_ADMIN_USER:-postgres}" -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "n8n_${ENVIRONMENT}"; then
                DB_EXISTS=true
            fi
        fi
        
        if [ "$DB_EXISTS" = "true" ]; then
            echo "${YELLOW}⚠️  Database n8n_${ENVIRONMENT} already exists.${NC}"
            echo -n "Do you want to overwrite it? [y/N]: "
            read -r overwrite_db_response
            case "$overwrite_db_response" in
                [Yy]|[Yy][Ee][Ss])
                    echo "${YELLOW}🔄 Recreating database...${NC}"
                    # Run database initialization
                    if [ "$CONTAINER_RUNTIME" = "docker" ]; then
                        docker compose $COMPOSE_FILES up --force-recreate postgres-init
                    else
                        podman compose $COMPOSE_FILES up --force-recreate postgres-init
                    fi
                    ;;
                *)
                    echo "${BLUE}ℹ️  Using existing database${NC}"
                    ;;
            esac
        else
            echo "${YELLOW}🔄 Creating database...${NC}"
            # Run database initialization
            if [ "$CONTAINER_RUNTIME" = "docker" ]; then
                docker compose $COMPOSE_FILES up postgres-init
            else
                podman compose $COMPOSE_FILES up postgres-init
            fi
        fi
        
        echo "${GREEN}✅ Database setup completed${NC}"
        ;;
    *)
        echo "${BLUE}ℹ️  Database creation skipped. Run '$CONTAINER_RUNTIME compose up -d' to create later${NC}"
        ;;
esac

# Step 14: Test Setup
echo ""
echo "${BLUE}🧪 Test Setup${NC}"
echo "-------------"

echo -n "Do you want to test the setup by starting all services? [Y/n]: "
read -r test_response
if [ -z "$test_response" ]; then
    test_response="y"
fi

case "$test_response" in
    [Yy]|[Yy][Ee][Ss])
        echo "${YELLOW}🔄 Starting all services...${NC}"
        
        # Build compose file list based on enabled features
        COMPOSE_FILES="-f docker-compose.yml"
        
        # Add rclone override if enabled
        if [ "$RCLONE_ENABLED" = "true" ]; then
            COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.rclone.yml"
            echo "${BLUE}ℹ️  Including rclone cloud storage support${NC}"
        fi
        
        # Add Cloudflare override if tunnel token is configured
        if [ -n "$CLOUDFLARE_TOKEN" ] && [ "$CLOUDFLARE_TOKEN" != "your_tunnel_token_here" ]; then
            COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.cloudflare.yml"
            echo "${BLUE}ℹ️  Using Cloudflare tunnels (Traefik disabled for security)${NC}"
        else
            echo "${YELLOW}⚠️  Using Traefik reverse proxy (consider Cloudflare tunnels for better security)${NC}"
        fi
        
        # Start all services
        echo "${BLUE}ℹ️  Starting with: $COMPOSE_FILES${NC}"
        if [ "$CONTAINER_RUNTIME" = "docker" ]; then
            docker compose $COMPOSE_FILES up -d
        else
            podman compose $COMPOSE_FILES up -d
        fi
        
        echo "${YELLOW}⏳ Waiting for services to start...${NC}"
        sleep 30
        
        # Basic health checks
        echo "${YELLOW}🔍 Running basic health checks...${NC}"
        
        # Check if containers are running
        if [ "$CONTAINER_RUNTIME" = "docker" ]; then
            RUNNING_CONTAINERS=$(docker compose $COMPOSE_FILES ps --services --filter "status=running" 2>/dev/null | wc -l | tr -d ' ')
            TOTAL_CONTAINERS=$(docker compose $COMPOSE_FILES ps --services 2>/dev/null | wc -l | tr -d ' ')
        else
            RUNNING_CONTAINERS=$(podman compose $COMPOSE_FILES ps --services --filter "status=running" 2>/dev/null | wc -l | tr -d ' ')
            TOTAL_CONTAINERS=$(podman compose $COMPOSE_FILES ps --services 2>/dev/null | wc -l | tr -d ' ')
        fi
        
        echo "${BLUE}ℹ️  Running containers: $RUNNING_CONTAINERS/$TOTAL_CONTAINERS${NC}"
        
        # Check Redis connectivity
        if [ "$CONTAINER_RUNTIME" = "docker" ]; then
            if docker compose $COMPOSE_FILES exec -T redis redis-cli -a "${REDIS_PASSWORD:-}" ping 2>/dev/null | grep -q "PONG"; then
                echo "${GREEN}✅ Redis is responding${NC}"
            else
                echo "${RED}❌ Redis connection failed${NC}"
            fi
        else
            if podman compose $COMPOSE_FILES exec -T redis redis-cli -a "${REDIS_PASSWORD:-}" ping 2>/dev/null | grep -q "PONG"; then
                echo "${GREEN}✅ Redis is responding${NC}"
            else
                echo "${RED}❌ Redis connection failed${NC}"
            fi
        fi
        
        # Check PostgreSQL connectivity
        if [ "$CONTAINER_RUNTIME" = "docker" ]; then
            if docker compose $COMPOSE_FILES exec -T postgres pg_isready -U "${POSTGRES_ADMIN_USER:-postgres}" 2>/dev/null; then
                echo "${GREEN}✅ PostgreSQL is responding${NC}"
            else
                echo "${RED}❌ PostgreSQL connection failed${NC}"
            fi
        else
            if podman compose $COMPOSE_FILES exec -T postgres pg_isready -U "${POSTGRES_ADMIN_USER:-postgres}" 2>/dev/null; then
                echo "${GREEN}✅ PostgreSQL is responding${NC}"
            else
                echo "${RED}❌ PostgreSQL connection failed${NC}"
            fi
        fi
        
        echo ""
        echo "${BLUE}🌐 Access URLs:${NC}"
        echo "   N8N Main: $N8N_MAIN_URL"
        echo "   N8N Webhook: $N8N_WEBHOOK_URL"
        echo "   Local N8N: http://localhost:5678"
        echo ""
        
        echo -n "Press Enter when you've verified the setup is working: "
        read -r _
        echo "${GREEN}✅ Setup test completed${NC}"
        ;;
    *)
        echo "${BLUE}ℹ️  Setup test skipped${NC}"
        ;;
esac

# Step 15: Mark setup as completed
echo ""
echo "${BLUE}✅ Final Setup${NC}"
echo "--------------"

# Add setup completion flag
echo "" >> .env
echo "# Setup completion flag" >> .env
echo "SETUP_COMPLETED=true" >> .env

# Clean up backup files
rm -f .env.bak

echo ""
echo "${GREEN}🎉 Setup completed successfully!${NC}"
echo ""
echo "${BLUE}📋 Summary:${NC}"
echo "   Environment: $ENVIRONMENT"
echo "   Database: n8n_${ENVIRONMENT}"
echo "   User: n8n_${ENVIRONMENT}_user"
echo "   Timezone: $TIMEZONE (PostgreSQL uses UTC)"
echo "   Container Runtime: $CONTAINER_RUNTIME"
echo "   External Network: $([ -n "$EXTERNAL_NETWORK_NAME" ] && echo "$EXTERNAL_NETWORK_NAME" || echo "Disabled")"
echo "   Rclone Mount: $([ "$RCLONE_ENABLED" = "true" ] && echo "Enabled" || echo "Disabled")"
echo "   Cloudflare Tunnel: $([ -n "$CLOUDFLARE_TOKEN" ] && echo "Configured" || echo "Not configured")"
echo "   Tailscale: $([ -n "$TAILSCALE_IP" ] && echo "$TAILSCALE_IP" || echo "Not configured")"
echo "   Main URL: $N8N_MAIN_URL"
echo "   Webhook URL: $N8N_WEBHOOK_URL"
echo "   Autoscaling: $([ -n "$MIN_REPLICAS" ] && echo "$MIN_REPLICAS-$MAX_REPLICAS workers" || echo "1-5 workers (default)")"
echo ""
echo "${BLUE}📝 Next Steps:${NC}"
if [ -z "$CLOUDFLARE_TOKEN" ]; then
    echo "1. Configure Cloudflare tunnel token manually in .env if not set during setup"
    echo "2. Set up systemd services (optional): ./generate-systemd.sh"
    echo "3. Set up backups (optional): Add to crontab: 0 * * * * $(pwd)/backup.sh"
    echo "4. Access n8n at: $N8N_MAIN_URL"
else
    echo "1. Set up systemd services (optional): ./generate-systemd.sh"
    echo "2. Set up backups (optional): Add to crontab: 0 * * * * $(pwd)/backup.sh"
    echo "3. Access n8n at: $N8N_MAIN_URL"
fi
echo ""
echo "${YELLOW}💡 Run this script again to set up systemd services${NC}"