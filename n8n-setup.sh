#!/bin/bash
# Simplified n8n-autoscaling setup script - core functionality only

set -e

# Colors using tput for compatibility
if command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0)
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
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
            # Try both docker and podman
            docker compose down -v 2>/dev/null || true
            podman compose down 2>/dev/null || true
            
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
            
            # Prune container resources
            echo -n "Do you want to prune container networks and volumes? [y/N]: "
            read -r prune_response
            case "$prune_response" in
                [Yy]|[Yy][Ee][Ss])
                    echo "${BLUE}Pruning container resources...${NC}"
                    # Try both docker and podman
                    docker network prune -f 2>/dev/null || true
                    docker volume prune -f 2>/dev/null || true
                    podman network prune -f 2>/dev/null || true
                    podman volume prune -f 2>/dev/null || true
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

# Function to detect existing deployment architecture
detect_deployment_architecture() {
    local current_arch=""
    local traefik_enabled=false
    local cloudflare_enabled=false
    local rclone_enabled=false
    
    # Read enable flags from .env
    if [ -f .env ]; then
        local enable_cf=$(grep "^ENABLE_CLOUDFLARE_TUNNEL=" .env 2>/dev/null | cut -d'=' -f2 || echo "false")
        local enable_traefik=$(grep "^ENABLE_TRAEFIK=" .env 2>/dev/null | cut -d'=' -f2 || echo "false")
        local enable_rclone=$(grep "^ENABLE_RCLONE_MOUNT=" .env 2>/dev/null | cut -d'=' -f2 || echo "false")
        
        # Set architecture based on enable flags
        if [ "$enable_cf" = "true" ]; then
            cloudflare_enabled=true
            current_arch="cloudflare"
        elif [ "$enable_traefik" = "true" ]; then
            traefik_enabled=true
            current_arch="traefik"
        fi
        
        if [ "$enable_rclone" = "true" ]; then
            rclone_enabled=true
        fi
    fi
    
    echo "$current_arch,$traefik_enabled,$cloudflare_enabled,$rclone_enabled"
}

# Function to handle architecture migration
handle_migration() {
    local arch_info=$(detect_deployment_architecture)
    local current_arch=$(echo "$arch_info" | cut -d',' -f1)
    local traefik_enabled=$(echo "$arch_info" | cut -d',' -f2)
    local cloudflare_enabled=$(echo "$arch_info" | cut -d',' -f3)
    local rclone_enabled=$(echo "$arch_info" | cut -d',' -f4)
    
    local migration_needed=false
    local migration_type=""
    
    # Detect current configuration - both can be enabled
    if [ "$traefik_enabled" = "true" ] && [ "$cloudflare_enabled" = "true" ]; then
        migration_needed=true
        migration_type="both_enabled"
    elif [ "$traefik_enabled" = "true" ]; then
        migration_type="using_traefik"
    elif [ "$cloudflare_enabled" = "true" ]; then
        migration_type="using_cloudflare"
    else
        migration_type="none_enabled"
    fi
    
    if [ "$migration_needed" = "true" ]; then
        echo ""
        echo "${YELLOW}🔄 Migration Required${NC}"
        echo "-------------------"
        
        case "$migration_type" in
            both_enabled)
                echo "${BLUE}ℹ️  Detected: Both Traefik and Cloudflare tunnel are enabled${NC}"
                echo "   Running both simultaneously can cause conflicts and is not recommended."
                echo ""
                echo "   ${YELLOW}Choose one option:${NC}"
                echo "   1. Keep Cloudflare tunnels only (recommended - better security)"
                echo "   2. Keep Traefik only (local control)"
                echo "   3. Continue with both (not recommended)"
                echo ""
                echo -n "Enter your choice [1-3]: "
                read -r choice
                case "$choice" in
                    1)
                        echo "${BLUE}ℹ️  Disabling Traefik, keeping Cloudflare tunnels${NC}"
                        sed -i.bak "s/^ENABLE_TRAEFIK=.*/ENABLE_TRAEFIK=false/" .env
                        migrate_to_cloudflare
                        ;;
                    2)
                        echo "${BLUE}ℹ️  Disabling Cloudflare, keeping Traefik${NC}"
                        sed -i.bak "s/^ENABLE_CLOUDFLARE_TUNNEL=.*/ENABLE_CLOUDFLARE_TUNNEL=false/" .env
                        migrate_to_traefik
                        ;;
                    3|*)
                        echo "${YELLOW}⚠️  Continuing with both enabled - monitor for conflicts${NC}"
                        ;;
                esac
                ;;
            traefik_to_cloudflare)
                echo "${BLUE}ℹ️  Detected: Traefik currently running + Cloudflare tunnel configured${NC}"
                echo "   This suggests you're migrating from Traefik to Cloudflare tunnels."
                echo ""
                echo "   ${GREEN}Benefits of migration:${NC}"
                echo "   • Better security (zero open ports)"
                echo "   • Built-in DDoS protection"
                echo "   • Automatic HTTPS certificates"
                echo "   • No need for port forwarding"
                echo ""
                echo "   ${YELLOW}Migration will:${NC}"
                echo "   • Stop Traefik container (no longer needed)"
                echo "   • Switch to direct cloudflared tunnel"
                echo "   • Remove unused Traefik resources"
                echo ""
                echo -n "Do you want to migrate to Cloudflare tunnels now? [Y/n]: "
                read -r migrate_response
                if [ -z "$migrate_response" ] || [[ "$migrate_response" =~ ^[Yy] ]]; then
                    migrate_to_cloudflare
                else
                    echo "${BLUE}ℹ️  Continuing with current Traefik setup${NC}"
                fi
                ;;
            cloudflare_to_traefik)
                echo "${BLUE}ℹ️  Detected: Cloudflare tunnel configured but no Traefik running${NC}"
                echo "   You can migrate from Cloudflare tunnels back to Traefik reverse proxy."
                echo ""
                echo "   ${GREEN}Benefits of Traefik:${NC}"
                echo "   • Local SSL certificate management"
                echo "   • Full control over routing"
                echo "   • Works without external dependencies"
                echo "   • Built-in dashboard and monitoring"
                echo ""
                echo "   ${YELLOW}Migration will:${NC}"
                echo "   • Start Traefik reverse proxy"
                echo "   • Disable Cloudflare tunnel mode"
                echo "   • Expose ports 8082, 8083 for access"
                echo "   • Remove cloudflared dependency"
                echo ""
                echo -n "Do you want to migrate to Traefik reverse proxy? [y/N]: "
                read -r migrate_response
                if [[ "$migrate_response" =~ ^[Yy] ]]; then
                    migrate_to_traefik
                else
                    echo "${BLUE}ℹ️  Continuing with current Cloudflare tunnel setup${NC}"
                fi
                ;;
        esac
    elif [ "$migration_type" != "" ]; then
        echo ""
        echo "${BLUE}ℹ️  Current Architecture: $(echo "$migration_type" | sed 's/_/ /g' | sed 's/using //')${NC}"
        if [ "$rclone_enabled" = "true" ]; then
            echo "${BLUE}ℹ️  Rclone cloud storage: Enabled${NC}"
        fi
    fi
}

# Function to perform Traefik to Cloudflare migration
migrate_to_cloudflare() {
    echo ""
    echo "${YELLOW}🔄 Migrating to Cloudflare tunnels...${NC}"
    
    # Detect container runtime
    local runtime=""
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        runtime="docker"
    elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
        runtime="podman"
    else
        echo "${RED}❌ No compatible container runtime found${NC}"
        return 1
    fi
    
    # Stop all services gracefully
    echo "${BLUE}1. Stopping existing services...${NC}"
    if [ "$runtime" = "docker" ]; then
        docker compose down
    else
        podman compose down
    fi
    
    # Clean up Traefik resources
    echo "${BLUE}2. Cleaning up Traefik resources...${NC}"
    
    # Remove Traefik container if it exists
    if [ "$runtime" = "docker" ]; then
        docker rm -f n8n-autoscaling_traefik_1 2>/dev/null || true
        docker rm -f n8n-autoscaling-traefik-1 2>/dev/null || true
    else
        podman rm -f n8n-autoscaling_traefik_1 2>/dev/null || true
        podman rm -f n8n-autoscaling-traefik-1 2>/dev/null || true
    fi
    
    # Optionally remove Traefik volume
    echo -n "Remove Traefik data volume (certificates will be lost)? [y/N]: "
    read -r remove_volume_response
    case "$remove_volume_response" in
        [Yy]|[Yy][Ee][Ss])
            if [ "$runtime" = "docker" ]; then
                docker volume rm n8n-autoscaling_traefik_data 2>/dev/null || true
            else
                podman volume rm n8n-autoscaling_traefik_data 2>/dev/null || true
            fi
            echo "${GREEN}✅ Traefik volume removed${NC}"
            ;;
        *)
            echo "${BLUE}ℹ️  Traefik volume preserved${NC}"
            ;;
    esac
    
    # Clean up unused networks and resources
    echo "${BLUE}3. Cleaning up unused resources...${NC}"
    if [ "$runtime" = "docker" ]; then
        docker network prune -f >/dev/null 2>&1 || true
        docker system prune -f >/dev/null 2>&1 || true
    else
        podman network prune -f >/dev/null 2>&1 || true
        podman system prune -f >/dev/null 2>&1 || true
    fi
    
    # Start with new architecture
    echo "${BLUE}4. Starting with Cloudflare tunnel architecture...${NC}"
    
    # Build compose file list
    local compose_files="-f docker-compose.yml"
    
    # Check for rclone
    local rclone_data=$(grep "^RCLONE_DATA_MOUNT=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
    if [ -n "$rclone_data" ]; then
        compose_files="$compose_files -f docker-compose.rclone.yml"
        echo "${BLUE}ℹ️  Including rclone cloud storage support${NC}"
    fi
    
    # Add Cloudflare override
    compose_files="$compose_files -f docker-compose.cloudflare.yml"
    
    echo "${BLUE}ℹ️  Starting with: $compose_files${NC}"
    if [ "$runtime" = "docker" ]; then
        docker compose $compose_files up -d
    else
        podman compose $compose_files up -d
    fi
    
    echo ""
    echo "${GREEN}✅ Migration to Cloudflare tunnels completed!${NC}"
    echo ""
    echo "${BLUE}📋 New Architecture:${NC}"
    echo "   • Cloudflare tunnel handles all external traffic"
    echo "   • No open ports on your server"
    echo "   • Built-in DDoS protection and HTTPS"
    echo "   • Traefik disabled (no longer needed)"
    echo ""
    echo "${YELLOW}⚠️  Important:${NC}"
    echo "   • Configure ingress rules in Cloudflare Zero Trust dashboard"
    echo "   • Test your n8n and webhook URLs"
    echo "   • Update any firewall rules (you can close ports 8082, 8083)"
    echo ""
}

# Function to perform Cloudflare to Traefik migration
migrate_to_traefik() {
    echo ""
    echo "${YELLOW}🔄 Migrating to Traefik reverse proxy...${NC}"
    
    # Detect container runtime
    local runtime=""
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        runtime="docker"
    elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
        runtime="podman"
    else
        echo "${RED}❌ No compatible container runtime found${NC}"
        return 1
    fi
    
    # Stop all services gracefully
    echo "${BLUE}1. Stopping existing services...${NC}"
    if [ "$runtime" = "docker" ]; then
        docker compose down
    else
        podman compose down
    fi
    
    # Clean up Cloudflare resources
    echo "${BLUE}2. Cleaning up Cloudflare resources...${NC}"
    
    # Remove cloudflared container if it exists
    if [ "$runtime" = "docker" ]; then
        docker rm -f n8n-autoscaling_cloudflared_1 2>/dev/null || true
        docker rm -f n8n-autoscaling-cloudflared-1 2>/dev/null || true
    else
        podman rm -f n8n-autoscaling_cloudflared_1 2>/dev/null || true
        podman rm -f n8n-autoscaling-cloudflared-1 2>/dev/null || true
    fi
    
    # Optionally disable Cloudflare tunnel token
    echo -n "Remove Cloudflare tunnel token from .env? [y/N]: "
    read -r remove_token_response
    case "$remove_token_response" in
        [Yy]|[Yy][Ee][Ss])
            sed -i.bak 's/^CLOUDFLARE_TUNNEL_TOKEN=.*/#CLOUDFLARE_TUNNEL_TOKEN=your_tunnel_token_here/' .env
            echo "${GREEN}✅ Cloudflare tunnel token disabled${NC}"
            ;;
        *)
            echo "${BLUE}ℹ️  Cloudflare tunnel token preserved (can re-enable later)${NC}"
            ;;
    esac
    
    # Clean up unused networks and resources
    echo "${BLUE}3. Cleaning up unused resources...${NC}"
    if [ "$runtime" = "docker" ]; then
        docker network prune -f >/dev/null 2>&1 || true
        docker system prune -f >/dev/null 2>&1 || true
    else
        podman network prune -f >/dev/null 2>&1 || true
        podman system prune -f >/dev/null 2>&1 || true
    fi
    
    # Start with new architecture
    echo "${BLUE}4. Starting with Traefik reverse proxy architecture...${NC}"
    
    # Build compose file list (exclude cloudflare override)
    local compose_files="-f docker-compose.yml"
    
    # Check for rclone
    local rclone_data=$(grep "^RCLONE_DATA_MOUNT=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
    if [ -n "$rclone_data" ]; then
        compose_files="$compose_files -f docker-compose.rclone.yml"
        echo "${BLUE}ℹ️  Including rclone cloud storage support${NC}"
    fi
    
    # Note: We explicitly do NOT add docker-compose.cloudflare.yml
    
    echo "${BLUE}ℹ️  Starting with: $compose_files${NC}"
    if [ "$runtime" = "docker" ]; then
        docker compose $compose_files up -d
    else
        podman compose $compose_files up -d
    fi
    
    echo ""
    echo "${GREEN}✅ Migration to Traefik reverse proxy completed!${NC}"
    echo ""
    echo "${BLUE}📋 New Architecture:${NC}"
    echo "   • Traefik reverse proxy handles routing"
    echo "   • n8n UI available on port 8082"
    echo "   • n8n webhooks available on port 8083"
    echo "   • Local SSL certificate management"
    echo "   • Cloudflare tunnel disabled"
    echo ""
    echo "${YELLOW}⚠️  Important:${NC}"
    echo "   • Configure your firewall to allow ports 8082, 8083"
    echo "   • Set up port forwarding if behind NAT"
    echo "   • Consider setting up Let's Encrypt for SSL certificates"
    echo "   • Update DNS records to point to your server IP"
    echo "   • Test your n8n and webhook URLs"
    echo ""
    echo "${BLUE}📋 Next Steps:${NC}"
    echo "   • Access n8n UI: http://your-server-ip:8082"
    echo "   • Access webhooks: http://your-server-ip:8083"
    echo "   • Traefik dashboard: http://your-server-ip:8080 (if enabled)"
    echo ""
}

# Show main menu based on current state
if [ "$DATA_EXISTS" = "true" ]; then
    if [ -f .env ]; then
        SETUP_COMPLETE_FLAG=$(grep "^SETUP_COMPLETED=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
        if [ "$SETUP_COMPLETE_FLAG" = "true" ]; then
            echo "${GREEN}✅ Setup has been completed previously.${NC}"
            
            # Check for migration opportunities
            handle_migration
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
        echo "3. Change architecture (Traefik ↔ Cloudflare)"
        echo "4. Set up systemd services"
        echo "5. Exit"
    else
        echo "3. Exit"
    fi
    echo ""
    
    if [ "$SETUP_COMPLETE_FLAG" = "true" ]; then
        echo -n "Enter your choice [1-5]: "
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
                echo "${BLUE}🔄 Architecture Migration${NC}"
                echo "---------------------"
                echo ""
                
                # Detect current architecture
                local arch_info=$(detect_deployment_architecture)
                local current_arch=$(echo "$arch_info" | cut -d',' -f1)
                local cloudflare_configured=$(echo "$arch_info" | cut -d',' -f3)
                
                if [ "$current_arch" = "cloudflare" ] || [ "$cloudflare_configured" = "true" ]; then
                    echo "${BLUE}Current: Cloudflare tunnels${NC}"
                    echo "Available: Migrate to Traefik reverse proxy"
                    echo ""
                    echo -n "Migrate to Traefik? [y/N]: "
                    read -r migrate_choice
                    if [[ "$migrate_choice" =~ ^[Yy] ]]; then
                        migrate_to_traefik
                    fi
                else
                    echo "${BLUE}Current: Traefik reverse proxy${NC}"
                    echo "Available: Migrate to Cloudflare tunnels"
                    echo ""
                    echo -n "Do you have a Cloudflare tunnel token? [y/N]: "
                    read -r has_token
                    if [[ "$has_token" =~ ^[Yy] ]]; then
                        echo -n "Enter your Cloudflare tunnel token: "
                        read -r cf_token
                        if [ -n "$cf_token" ]; then
                            # Update .env with new token
                            sed -i.bak "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=$cf_token|" .env
                            echo "${GREEN}✅ Cloudflare token configured${NC}"
                            migrate_to_cloudflare
                        fi
                    else
                        echo "${YELLOW}ℹ️  You need a Cloudflare tunnel token to migrate${NC}"
                        echo "   Create one at: https://dash.cloudflare.com → Zero Trust → Access → Tunnels"
                    fi
                fi
                exit 0
            else
                exit 0
            fi
            ;;
        4)
            if [ "$SETUP_COMPLETE_FLAG" = "true" ]; then
                echo "${BLUE}🔧 Setting up systemd services...${NC}"
                ./generate-systemd.sh
                exit 0
            else
                exit 0
            fi
            ;;
        5|*)
            exit 0
            ;;
    esac
fi

# Function to detect timezone
detect_timezone() {
    # Detect from system (don't return .env value - that's not detection!)
    if [ -f /etc/timezone ]; then
        cat /etc/timezone
    elif [ -L /etc/localtime ]; then
        # Handle both Linux and macOS paths
        readlink /etc/localtime | sed 's|/usr/share/zoneinfo/||' | sed 's|/var/db/timezone/zoneinfo/||'
    elif command -v timedatectl &> /dev/null; then
        timedatectl show --property=Timezone --value
    elif [ "$(uname)" = "Darwin" ]; then
        # macOS timezone detection
        if command -v systemsetup >/dev/null 2>&1; then
            systemsetup -gettimezone 2>/dev/null | awk '{print $2}'
        else
            # Fall back to localtime parsing on macOS
            if [ -L /etc/localtime ]; then
                readlink /etc/localtime | sed 's|/var/db/timezone/zoneinfo/||'
            else
                echo "UTC"
            fi
        fi
    else
        echo "UTC"
    fi
}

# Function to read existing value from .env
get_existing_value() {
    local key="$1"
    local default="$2"
    if [ -f .env ]; then
        local value=$(grep "^$key=" .env 2>/dev/null | cut -d'=' -f2- | sed 's/#.*//' | xargs || echo "$default")
        # Return default if empty after comment removal
        if [ -n "$value" ]; then
            echo "$value"
        else
            echo "$default"
        fi
    else
        echo "$default"
    fi
}

# Function to ask user to keep existing value or configure new one
ask_keep_or_configure() {
    local description="$1"          # e.g., "Cloudflare tunnel token"
    local env_key="$2"              # e.g., "CLOUDFLARE_TUNNEL_TOKEN"
    local existing_value="$3"       # Current value from .env
    local default_prompt="$4"       # Default for new setup (Y/n or y/N)
    local extra_text="$5"           # Optional extra instructions (like doc links)
    local validation_func="$6"      # Optional validation function name
    
    # Check if we have a valid existing value
    if [ -n "$existing_value" ] && [ "$existing_value" != "your_tunnel_token_here" ] && [ "$existing_value" != "changeme" ]; then
        echo "${BLUE}ℹ️  $description currently configured: ${YELLOW}$existing_value${NC}"
        
        # Simple Y/n validation with retry
        while true; do
            echo -n "Keep current $description configuration? [Y/n]: "
            read -r keep_response
            case "$keep_response" in
                [Yy]|[Yy][Ee][Ss]|"")
                    echo "${GREEN}✅ $description configuration kept${NC}"
                    return 0
                    ;;
                [Nn]|[Nn][Oo])
                    # User wants to change - break and continue to input section
                    break
                    ;;
                *)
                    echo "${RED}❌ Please enter 'y' for yes or 'n' for no${NC}"
                    ;;
            esac
        done
        
        # User said no - get new value
        # Show extra instructions if provided
        if [ -n "$extra_text" ]; then
            echo "$extra_text"
        fi
        get_validated_input "$description" "$env_key" "$validation_func"
        return $?
    else
        # No existing value - ask if they want to configure
        local should_configure=false
        
        # Simple Y/n validation with retry  
        while true; do
            echo -n "Do you want to configure $description? $default_prompt: "
            read -r configure_response
            case "$configure_response" in
                [Yy]|[Yy][Ee][Ss])
                    should_configure=true
                    break
                    ;;
                [Nn]|[Nn][Oo])
                    should_configure=false
                    break
                    ;;
                "")
                    # Empty response - use default
                    if [[ "$default_prompt" == *"[Y/n]"* ]]; then
                        should_configure=true  # Default to Yes
                    else
                        should_configure=false # Default to No
                    fi
                    break
                    ;;
                *)
                    echo "${RED}❌ Please enter 'y' for yes or 'n' for no${NC}"
                    ;;
            esac
        done
        
        if [ "$should_configure" = "true" ]; then
            # Show extra instructions if provided
            if [ -n "$extra_text" ]; then
                echo "$extra_text"
            fi
            # Get new value with validation
            get_validated_input "$description" "$env_key" "$validation_func"
            return $?
        else
            echo "${BLUE}ℹ️  $description not configured${NC}"
            return 1
        fi
    fi
}

# Function to get and validate user input
get_validated_input() {
    local description="$1"
    local env_key="$2"
    local validation_func="$3"
    
    while true; do
        echo -n "Please provide $description: "
        read -r new_value
        
        # If no validation function provided, accept any non-empty value
        if [ -z "$validation_func" ]; then
            if [ -n "$new_value" ]; then
                sed -i.bak "s/^$env_key=.*/$env_key=$new_value/" .env
                echo "${GREEN}✅ $description configured${NC}"
                return 0
            else
                echo "${RED}❌ Value cannot be empty${NC}"
            fi
        else
            # Call validation function with error handling
            if command -v "$validation_func" >/dev/null 2>&1; then
                if "$validation_func" "$new_value" 2>/dev/null; then
                    # Escape special characters in sed replacement
                    local safe_value=$(printf '%s\n' "$new_value" | sed 's/[[\.*^$()+?{|]/\\&/g')
                    sed -i.bak "s/^$env_key=.*/$env_key=$safe_value/" .env
                    echo "${GREEN}✅ $description configured${NC}"
                    return 0
                fi
                # Validation function should print its own error message
            else
                echo "${RED}❌ Validation function '$validation_func' not found. Accepting any non-empty value.${NC}"
                if [ -n "$new_value" ]; then
                    local safe_value=$(printf '%s\n' "$new_value" | sed 's/[[\.*^$()+?{|]/\\&/g')
                    sed -i.bak "s/^$env_key=.*/$env_key=$safe_value/" .env
                    echo "${GREEN}✅ $description configured${NC}"
                    return 0
                else
                    echo "${RED}❌ Value cannot be empty${NC}"
                fi
            fi
        fi
    done
}

# Validation functions
validate_cloudflare_token() {
    local token="$1"
    if [ -n "$token" ] && [ ${#token} -gt 20 ]; then
        return 0
    else
        echo "${RED}❌ Invalid token. Please enter a valid Cloudflare tunnel token${NC}"
        return 1
    fi
}

validate_ip_address() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        echo "${RED}❌ Invalid IP format. Please use format: 192.168.1.100${NC}"
        return 1
    fi
}

validate_scaling_number() {
    local number="$1"
    if [[ $number =~ ^[0-9]+$ ]] && [ "$number" -ge 1 ]; then
        return 0
    else
        echo "${RED}❌ Please enter a valid number (1 or greater)${NC}"
        return 1
    fi
}

validate_url() {
    local url="$1"
    
    # Check if URL is empty
    if [ -z "$url" ]; then
        echo "${RED}❌ URL cannot be empty${NC}"
        return 1
    fi
    
    # Basic domain validation - should be in format: domain.com or subdomain.domain.com
    # Allow alphanumeric characters, hyphens, and dots
    # Must have at least one dot and valid TLD pattern
    if [[ "$url" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        # Additional checks for common invalid patterns
        if [[ "$url" =~ \.\. ]] || [[ "$url" =~ ^- ]] || [[ "$url" =~ -$ ]] || [[ "$url" =~ ^\. ]] || [[ "$url" =~ \.$  ]]; then
            echo "${RED}❌ Invalid domain format. Use format like: example.com or subdomain.example.com${NC}"
            return 1
        fi
        return 0
    else
        echo "${RED}❌ Invalid domain format. Use format like: example.com or subdomain.example.com${NC}"
        echo "${BLUE}ℹ️  Examples: n8n.mydomain.com, webhook.example.org, mysite.io${NC}"
        echo "${BLUE}ℹ️  Do not include 'https://' - just the domain name${NC}"
        return 1
    fi
}

validate_timezone() {
    local tz="$1"
    if [ -z "$tz" ]; then
        echo "${RED}❌ Timezone cannot be empty${NC}"
        return 1
    fi
    
    # Strict timezone validation - check against known valid patterns
    # Allow UTC and standard timezone formats (Continent/City or Continent/Region/City)
    if [ "$tz" = "UTC" ] || [ "$tz" = "GMT" ]; then
        return 0
    elif [[ "$tz" =~ ^(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)/[A-Za-z_]+(/[A-Za-z_]+)?$ ]]; then
        return 0
    elif [[ "$tz" =~ ^(Brazil|Canada|Chile|Mexico|US)/[A-Za-z_]+$ ]]; then
        return 0
    else
        echo "${RED}❌ Invalid timezone format. Use format like 'UTC', 'America/New_York', 'Europe/London'${NC}"
        echo "${BLUE}ℹ️  Examples: UTC, America/New_York, Europe/London, Asia/Dubai, Australia/Sydney${NC}"
        echo "${BLUE}ℹ️  Valid continents: Africa, America, Antarctica, Arctic, Asia, Atlantic, Australia, Europe, Indian, Pacific${NC}"
        return 1
    fi
}

# Function to configure external network in docker-compose.yml
configure_external_network() {
    local enable="$1"  # true to enable, false to disable
    local network_name="$2"  # network name (only needed when enabling)
    
    if [ "$enable" = "true" ]; then
        echo "${YELLOW}🔧 Enabling external network in docker-compose.yml...${NC}"
        
        # Uncomment the external network definition
        sed -i.bak 's|^  #n8n-external:|  n8n-external:|' docker-compose.yml
        sed -i.bak 's|^  #  external: true|    external: true|' docker-compose.yml
        sed -i.bak 's|^  #  name: ${EXTERNAL_NETWORK_NAME:-n8n-external}|    name: ${EXTERNAL_NETWORK_NAME:-n8n-external}|' docker-compose.yml
        
        # Uncomment external network connections for all services
        sed -i.bak 's|^    #- n8n-external|    - n8n-external|g' docker-compose.yml
        
        echo "${GREEN}✅ External network enabled in docker-compose.yml${NC}"
    else
        echo "${YELLOW}🔧 Disabling external network in docker-compose.yml...${NC}"
        
        # Comment out the external network definition
        sed -i.bak 's|^  n8n-external:|  #n8n-external:|' docker-compose.yml
        sed -i.bak 's|^    external: true|  #  external: true|' docker-compose.yml
        sed -i.bak 's|^    name: ${EXTERNAL_NETWORK_NAME:-n8n-external}|  #  name: ${EXTERNAL_NETWORK_NAME:-n8n-external}|' docker-compose.yml
        
        # Comment out external network connections for all services
        sed -i.bak 's|^    - n8n-external|    #- n8n-external|g' docker-compose.yml
        
        echo "${GREEN}✅ External network disabled in docker-compose.yml${NC}"
    fi
}

# Function to get default from .env.example (handles both commented and uncommented)
get_default_from_example() {
    local key="$1"
    local fallback="$2"
    local result=""
    
    if [ -f .env.example ]; then
        # Try uncommented first
        result=$(grep "^$key=" .env.example 2>/dev/null | cut -d'=' -f2- | head -1)
        
        # If empty, try commented
        if [ -z "$result" ]; then
            result=$(grep "^#$key=" .env.example 2>/dev/null | cut -d'=' -f2- | head -1)
        fi
        
        # If still empty, use fallback
        if [ -z "$result" ]; then
            result="$fallback"
        fi
    else
        result="$fallback"
    fi
    
    echo "$result"
}

# Function to validate directory with options to fix typo, create, or skip
validate_directory() {
    local description="$1"
    local default_path="$2"
    local skip_action="$3"  # What to do if user chooses to skip
    
    while true; do
        echo -n "Enter $description [$default_path]: "
        read -r dir_path
        if [ -z "$dir_path" ]; then
            dir_path="$default_path"
        fi
        
        if [ -d "$dir_path" ]; then
            echo "${GREEN}✅ Directory exists: $dir_path${NC}"
            echo "$dir_path"
            return 0
        else
            echo "${RED}❌ Directory does not exist: $dir_path${NC}"
            echo "What would you like to do?"
            echo "1. Re-enter path (fix typo)"
            echo "2. Create the directory"
            echo "3. $skip_action"
            echo -n "Enter your choice [1-3]: "
            read -r dir_choice
            case "$dir_choice" in
                1)
                    # Continue the loop to re-prompt for path
                    continue
                    ;;
                2)
                    if mkdir -p "$dir_path" 2>/dev/null; then
                        echo "${GREEN}✅ Created directory: $dir_path${NC}"
                        echo "$dir_path"
                        return 0
                    else
                        echo "${RED}❌ Failed to create directory. Please check permissions.${NC}"
                        continue
                    fi
                    ;;
                3|*)
                    echo "${YELLOW}⚠️  $skip_action${NC}"
                    return 1  # Return failure to indicate skip
                    ;;
            esac
        fi
    done
}

# Step 1: Environment file creation
echo "${BLUE}📋 Environment Configuration${NC}"
echo "----------------------------"

# Check if we should preserve existing configuration
PRESERVE_EXISTING_CONFIG=false

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
            echo "${BLUE}ℹ️  Using existing .env file. Will preserve existing configuration.${NC}"
            PRESERVE_EXISTING_CONFIG=true
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

if [ "$PRESERVE_EXISTING_CONFIG" = "true" ]; then
    # Read existing environment from .env
    EXISTING_ENVIRONMENT=$(grep "^ENVIRONMENT=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
    if [ -n "$EXISTING_ENVIRONMENT" ]; then
        echo "${BLUE}ℹ️  Found existing environment: $EXISTING_ENVIRONMENT${NC}"
        echo -n "Keep existing environment ($EXISTING_ENVIRONMENT)? [Y/n]: "
        read -r keep_env_response
        if [ -z "$keep_env_response" ] || [[ "$keep_env_response" =~ ^[Yy] ]]; then
            ENVIRONMENT="$EXISTING_ENVIRONMENT"
            echo "${GREEN}✅ Using existing environment: $ENVIRONMENT${NC}"
        else
            # Ask for new environment
            while true; do
                echo -n "Enter new environment (dev/test/production): "
                read -r ENVIRONMENT_INPUT
                case "$ENVIRONMENT_INPUT" in
                    dev|test|production)
                        ENVIRONMENT="$ENVIRONMENT_INPUT"
                        break
                        ;;
                    *)
                        echo "${RED}❌ Invalid environment. Please enter 'dev', 'test', or 'production'${NC}"
                        ;;
                esac
            done
            sed -i.bak "s/^ENVIRONMENT=.*/ENVIRONMENT=$ENVIRONMENT/" .env
            echo "${GREEN}✅ Environment updated to: $ENVIRONMENT${NC}"
        fi
    else
        echo "${YELLOW}⚠️  No environment found in existing .env${NC}"
        ENVIRONMENT="dev"
        sed -i.bak "s/^ENVIRONMENT=.*/ENVIRONMENT=$ENVIRONMENT/" .env
        echo "${GREEN}✅ Environment set to default: $ENVIRONMENT${NC}"
    fi
else
    # New .env file - ask for environment
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
fi

# Step 3: Secret generation
echo ""
echo "${BLUE}🔐 Secret Generation${NC}"
echo "-------------------"

if [ "$PRESERVE_EXISTING_CONFIG" = "true" ]; then
    # Check if secrets already exist and are secure
    EXISTING_REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
    EXISTING_POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
    EXISTING_N8N_ENCRYPTION_KEY=$(grep "^N8N_ENCRYPTION_KEY=" .env 2>/dev/null | cut -d'=' -f2 || echo "")
    
    # Check if existing secrets are secure (not defaults)
    INSECURE_DEFAULTS="YOURPASSWORD YOURKEY changeme password 123456 redis_password postgres_password"
    SECRETS_SECURE=true
    
    for default in $INSECURE_DEFAULTS; do
        if [ "$EXISTING_REDIS_PASSWORD" = "$default" ] || [ "$EXISTING_POSTGRES_PASSWORD" = "$default" ] || [ "$EXISTING_N8N_ENCRYPTION_KEY" = "$default" ]; then
            SECRETS_SECURE=false
            break
        fi
    done
    
    if [ -n "$EXISTING_REDIS_PASSWORD" ] && [ -n "$EXISTING_POSTGRES_PASSWORD" ] && [ -n "$EXISTING_N8N_ENCRYPTION_KEY" ] && [ "$SECRETS_SECURE" = "true" ]; then
        echo "${GREEN}✅ Found existing secure passwords${NC}"
        echo -n "Keep existing passwords? [Y/n]: "
        read -r keep_secrets_response
        if [ -z "$keep_secrets_response" ] || [[ "$keep_secrets_response" =~ ^[Yy] ]]; then
            echo "${BLUE}ℹ️  Using existing secure passwords${NC}"
            # Skip secret generation
            SKIP_SECRET_GENERATION=true
        else
            echo "${YELLOW}⚠️  Will generate new passwords${NC}"
            SKIP_SECRET_GENERATION=false
        fi
    else
        echo "${YELLOW}⚠️  Existing passwords appear insecure or incomplete${NC}"
        echo "${BLUE}ℹ️  Will generate new secure passwords${NC}"
        SKIP_SECRET_GENERATION=false
    fi
else
    SKIP_SECRET_GENERATION=false
fi

if [ "$SKIP_SECRET_GENERATION" != "true" ]; then
    while true; do
        echo -n "Do you want to generate secure random secrets? [Y/n]: "
        read -r secrets_response
        case "$secrets_response" in
            [Yy]|[Yy][Ee][Ss]|"")
                secrets_response="y"
                break
                ;;
            [Nn]|[Nn][Oo])
                secrets_response="n"
                break
                ;;
            *)
                echo "${RED}❌ Please enter 'y' for yes or 'n' for no${NC}"
                ;;
        esac
    done
else
    secrets_response="n"
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
        
        # Security validation: Reject dangerous default passwords
        INSECURE_DEFAULTS="YOURPASSWORD YOURKEY your_tunnel_token_here changeme password 123456"
        for default in $INSECURE_DEFAULTS; do
            if [ "$SALT" = "$default" ] || [ -z "$SALT" ]; then
                echo "${RED}❌ Security Error: Cannot use default or empty salt value${NC}"
                echo "${YELLOW}⚠️  For security, please provide a unique salt value${NC}"
                exit 1
            fi
        done
        
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

# Get current timezone from .env and detect system timezone
CURRENT_TZ=$(get_existing_value "GENERIC_TIMEZONE" "UTC")
DETECTED_TZ=$(detect_timezone)

# Clean up detected timezone (remove weird macOS paths)
if [[ "$DETECTED_TZ" == *"/var/db/timezone/zoneinfo/"* ]]; then
    DETECTED_TZ=$(echo "$DETECTED_TZ" | sed 's|/var/db/timezone/zoneinfo/||')
fi

echo "${BLUE}ℹ️  Current timezone in .env: $CURRENT_TZ${NC}"
echo "${BLUE}ℹ️  System detected timezone: $DETECTED_TZ${NC}"

while true; do
    echo -n "Enter timezone [$DETECTED_TZ]: "
    read -r TIMEZONE_INPUT
    if [ -z "$TIMEZONE_INPUT" ]; then
        TIMEZONE="$DETECTED_TZ"
        break
    elif validate_timezone "$TIMEZONE_INPUT"; then
        TIMEZONE="$TIMEZONE_INPUT"
        break
    fi
    # Validation failed, loop continues
done

# Update timezone in .env
sed -i.bak "s|^GENERIC_TIMEZONE=.*|GENERIC_TIMEZONE=$TIMEZONE|" .env
echo "${GREEN}✅ Timezone set to: $TIMEZONE${NC}"
echo "${BLUE}ℹ️  PostgreSQL will use UTC internally (recommended for production)${NC}"

# Step 5: URL Configuration
echo ""
echo "${BLUE}🌐 URL Configuration${NC}"
echo "-------------------"

# Read current URLs from .env
CURRENT_N8N_HOST=$(get_existing_value "N8N_HOST" "")
CURRENT_N8N_WEBHOOK=$(get_existing_value "N8N_WEBHOOK" "")

# Configure URLs using the reusable function
ask_keep_or_configure "n8n main URL (without https://)" "N8N_HOST" "$CURRENT_N8N_HOST" "[y/N]" "" "validate_url"
ask_keep_or_configure "webhook URL (without https://)" "N8N_WEBHOOK" "$CURRENT_N8N_WEBHOOK" "[y/N]" "" "validate_url"

# Read the final values for URL building
N8N_HOST=$(get_existing_value "N8N_HOST" "")
N8N_WEBHOOK_HOST=$(get_existing_value "N8N_WEBHOOK" "")

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

# Check current external network status
CURRENT_EXTERNAL_NETWORK=$(get_existing_value "EXTERNAL_NETWORK_NAME" "")
CURRENT_DEFAULT="n8n-external"

if [ -n "$CURRENT_EXTERNAL_NETWORK" ]; then
    echo "${BLUE}ℹ️  External network currently enabled: $CURRENT_EXTERNAL_NETWORK${NC}"
    
    # Simple Y/n validation with retry
    while true; do
        echo -n "Keep external network enabled? [Y/n]: "
        read -r keep_response
        case "$keep_response" in
            [Yy]|[Yy][Ee][Ss]|"")
                echo "${GREEN}✅ External network kept: $CURRENT_EXTERNAL_NETWORK${NC}"
                EXTERNAL_NETWORK_NAME="$CURRENT_EXTERNAL_NETWORK"
                break
                ;;
            [Nn]|[Nn][Oo])
                # Comment out the external network setting and disable in docker-compose
                sed -i.bak "s|^EXTERNAL_NETWORK_NAME=.*|#EXTERNAL_NETWORK_NAME=$CURRENT_DEFAULT|" .env
                configure_external_network "false"
                echo "${BLUE}ℹ️  External network disabled${NC}"
                EXTERNAL_NETWORK_NAME=""
                break
                ;;
            *)
                echo "${RED}❌ Please enter 'y' for yes or 'n' for no${NC}"
                ;;
        esac
    done
else
    # Simple Y/n validation with retry
    while true; do
        echo -n "Do you want to enable external network for connecting to other containers? [y/N]: "
        read -r external_network_response
        case "$external_network_response" in
            [Yy]|[Yy][Ee][Ss])
                echo -n "Enter external network name [$CURRENT_DEFAULT]: "
                read -r EXTERNAL_NETWORK_NAME
                if [ -z "$EXTERNAL_NETWORK_NAME" ]; then
                    EXTERNAL_NETWORK_NAME="$CURRENT_DEFAULT"
                fi
                
                # Uncomment and update external network settings in .env
                sed -i.bak "s|^#EXTERNAL_NETWORK_NAME=.*|EXTERNAL_NETWORK_NAME=$EXTERNAL_NETWORK_NAME|" .env
                
                # Enable external network in docker-compose.yml
                configure_external_network "true" "$EXTERNAL_NETWORK_NAME"
                
                echo "${GREEN}✅ External network enabled: $EXTERNAL_NETWORK_NAME${NC}"
                break
                ;;
            [Nn]|[Nn][Oo]|"")
                echo "${BLUE}ℹ️  External network disabled${NC}"
                EXTERNAL_NETWORK_NAME=""
                break
                ;;
            *)
                echo "${RED}❌ Please enter 'y' for yes or 'n' for no${NC}"
                ;;
        esac
    done
fi

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
        
        # Initialize rclone enabled flag
        RCLONE_ENABLED=true
        
        DEFAULT_DATA_MOUNT=$(get_default_from_example "RCLONE_DATA_MOUNT" "/mnt/rclone-data")
        
        # Validate data mount directory - avoid command substitution for interactive prompts
        echo -n "Enter rclone data mount path [$DEFAULT_DATA_MOUNT]: "
        read -r RCLONE_DATA_MOUNT
        if [ -z "$RCLONE_DATA_MOUNT" ]; then
            RCLONE_DATA_MOUNT="$DEFAULT_DATA_MOUNT"
        fi
        
        if [ -d "$RCLONE_DATA_MOUNT" ]; then
            echo "${GREEN}✅ Data mount configured: $RCLONE_DATA_MOUNT${NC}"
        else
            echo "${RED}❌ Directory does not exist: $RCLONE_DATA_MOUNT${NC}"
            echo "What would you like to do?"
            echo "1. Re-enter path"
            echo "2. Create the directory"
            echo "3. Skip rclone integration"
            echo -n "Enter your choice [1-3]: "
            read -r choice
            case "$choice" in
                1)
                    echo -n "Enter rclone data mount path: "
                    read -r RCLONE_DATA_MOUNT
                    if [ ! -d "$RCLONE_DATA_MOUNT" ]; then
                        echo "${RED}❌ Directory still doesn't exist, skipping rclone${NC}"
                        RCLONE_ENABLED=false
                    else
                        echo "${GREEN}✅ Data mount configured: $RCLONE_DATA_MOUNT${NC}"
                    fi
                    ;;
                2)
                    if mkdir -p "$RCLONE_DATA_MOUNT" 2>/dev/null; then
                        echo "${GREEN}✅ Created and configured data mount: $RCLONE_DATA_MOUNT${NC}"
                    else
                        echo "${RED}❌ Failed to create directory, skipping rclone${NC}"
                        RCLONE_ENABLED=false
                    fi
                    ;;
                3|*)
                    echo "${YELLOW}⚠️  Skipping rclone integration${NC}"
                    RCLONE_ENABLED=false
                    ;;
            esac
        fi
        
        # Only continue with backup mount if data mount was successful
        if [ "$RCLONE_ENABLED" = "true" ]; then
            DEFAULT_BACKUP_MOUNT=$(get_default_from_example "RCLONE_BACKUP_MOUNT" "/mnt/rclone-backups")
            
            echo -n "Enter rclone backup mount path [$DEFAULT_BACKUP_MOUNT]: "
            read -r RCLONE_BACKUP_MOUNT
            if [ -z "$RCLONE_BACKUP_MOUNT" ]; then
                RCLONE_BACKUP_MOUNT="$DEFAULT_BACKUP_MOUNT"
            fi
            
            if [ -d "$RCLONE_BACKUP_MOUNT" ]; then
                echo "${GREEN}✅ Backup mount configured: $RCLONE_BACKUP_MOUNT${NC}"
            else
                echo "${RED}❌ Directory does not exist: $RCLONE_BACKUP_MOUNT${NC}"
                echo "What would you like to do?"
                echo "1. Re-enter path"
                echo "2. Create the directory"
                echo "3. Skip rclone integration"
                echo -n "Enter your choice [1-3]: "
                read -r choice
                case "$choice" in
                    1)
                        echo -n "Enter rclone backup mount path: "
                        read -r RCLONE_BACKUP_MOUNT
                        if [ ! -d "$RCLONE_BACKUP_MOUNT" ]; then
                            echo "${RED}❌ Directory still doesn't exist, skipping rclone${NC}"
                            RCLONE_ENABLED=false
                        else
                            echo "${GREEN}✅ Backup mount configured: $RCLONE_BACKUP_MOUNT${NC}"
                        fi
                        ;;
                    2)
                        if mkdir -p "$RCLONE_BACKUP_MOUNT" 2>/dev/null; then
                            echo "${GREEN}✅ Created and configured backup mount: $RCLONE_BACKUP_MOUNT${NC}"
                        else
                            echo "${RED}❌ Failed to create directory, skipping rclone${NC}"
                            RCLONE_ENABLED=false
                        fi
                        ;;
                    3|*)
                        echo "${YELLOW}⚠️  Skipping rclone integration${NC}"
                        RCLONE_ENABLED=false
                        ;;
                esac
            fi
        fi
        
        # Only configure rclone if both mounts were successful
        if [ "$RCLONE_ENABLED" = "true" ]; then
            # Update rclone settings
            sed -i.bak "s|^RCLONE_DATA_MOUNT=.*|RCLONE_DATA_MOUNT=$RCLONE_DATA_MOUNT|" .env
            sed -i.bak "s|^RCLONE_BACKUP_MOUNT=.*|RCLONE_BACKUP_MOUNT=$RCLONE_BACKUP_MOUNT|" .env
            
            echo "${GREEN}✅ Rclone integration enabled${NC}"
            echo "${BLUE}ℹ️  Make sure to mount your rclone remote before starting services${NC}"
        else
            echo "${YELLOW}⚠️  Rclone integration skipped${NC}"
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

# Configure Cloudflare tunnel using the reusable function
CURRENT_CF_TOKEN=$(get_existing_value "CLOUDFLARE_TUNNEL_TOKEN" "")
SETUP_GUIDE_URL=$(get_existing_value "DOCS_SETUP_GUIDE" "https://www.reddit.com/r/n8n/comments/1l9mi6k/major_update_to_n8nautoscaling_build_step_by_step/")

CF_EXTRA_TEXT="${BLUE}ℹ️  For detailed Cloudflare tunnel setup instructions, visit:${NC}
${CYAN}   $SETUP_GUIDE_URL${NC}

${BLUE}ℹ️  You can also get your tunnel token from: https://dash.cloudflare.com/ → Zero Trust → Access → Tunnels${NC}"

# Configure Cloudflare tunnel and handle the result
if ask_keep_or_configure "Cloudflare tunnel" "CLOUDFLARE_TUNNEL_TOKEN" "$CURRENT_CF_TOKEN" "[Y/n]" "$CF_EXTRA_TEXT" "validate_cloudflare_token"; then
    # Cloudflare tunnel configured successfully
    echo "${GREEN}✅ Cloudflare tunnel will be used for external access${NC}"
    sed -i.bak "s/^ENABLE_CLOUDFLARE_TUNNEL=.*/ENABLE_CLOUDFLARE_TUNNEL=true/" .env
    sed -i.bak "s/^ENABLE_TRAEFIK=.*/ENABLE_TRAEFIK=false/" .env
    echo "${BLUE}ℹ️  Traefik disabled (Cloudflare tunnel handles external access)${NC}"
else
    # Cloudflare tunnel declined or failed - use Traefik instead
    echo "${YELLOW}⚠️  Cloudflare tunnel not configured${NC}"
    echo "${BLUE}ℹ️  Enabling Traefik reverse proxy for external access${NC}"
    sed -i.bak "s/^ENABLE_CLOUDFLARE_TUNNEL=.*/ENABLE_CLOUDFLARE_TUNNEL=false/" .env
    sed -i.bak "s/^ENABLE_TRAEFIK=.*/ENABLE_TRAEFIK=true/" .env
    echo "${GREEN}✅ Traefik reverse proxy will be used${NC}"
    echo "${YELLOW}⚠️  Remember to configure firewall rules for ports 8082 and 8083${NC}"
fi

# Step 9: Tailscale Configuration
echo ""
echo "${BLUE}🔗 Tailscale Configuration${NC}"
echo "-------------------------"

# Configure Tailscale IP using the reusable function
CURRENT_TAILSCALE_IP=$(get_existing_value "TAILSCALE_IP" "")

TS_EXTRA_TEXT="${BLUE}ℹ️  This binds PostgreSQL to your Tailscale IP for secure remote access${NC}
${BLUE}ℹ️  Find your Tailscale IP with: tailscale ip -4${NC}"

if ask_keep_or_configure "Tailscale IP" "TAILSCALE_IP" "$CURRENT_TAILSCALE_IP" "[y/N]" "$TS_EXTRA_TEXT" "validate_ip_address"; then
    TAILSCALE_IP=$(get_existing_value "TAILSCALE_IP" "")
    echo "${BLUE}ℹ️  PostgreSQL will bind to: $TAILSCALE_IP:5432${NC}"
else
    echo "${BLUE}ℹ️  Tailscale not configured - PostgreSQL will bind to all interfaces${NC}"
fi

# Step 10: Autoscaling Configuration
echo ""
echo "${BLUE}⚖️  Autoscaling Configuration${NC}"
echo "----------------------------"

# Read current values from .env
CURRENT_MIN_REPLICAS=$(get_existing_value "MIN_REPLICAS" "")
CURRENT_MAX_REPLICAS=$(get_existing_value "MAX_REPLICAS" "")
CURRENT_SCALE_UP_THRESHOLD=$(get_existing_value "SCALE_UP_QUEUE_THRESHOLD" "")
CURRENT_SCALE_DOWN_THRESHOLD=$(get_existing_value "SCALE_DOWN_QUEUE_THRESHOLD" "")

echo "${BLUE}ℹ️  Current settings: MIN=$CURRENT_MIN_REPLICAS, MAX=$CURRENT_MAX_REPLICAS, Scale Up at >$CURRENT_SCALE_UP_THRESHOLD jobs, Scale Down at <$CURRENT_SCALE_DOWN_THRESHOLD job${NC}"
echo -n "Do you want to customize autoscaling parameters? [y/N]: "
read -r autoscaling_response
case "$autoscaling_response" in
    [Yy]|[Yy][Ee][Ss])
        # Configure each autoscaling parameter using the reusable function
        ask_keep_or_configure "minimum worker replicas (always running)" "MIN_REPLICAS" "$CURRENT_MIN_REPLICAS" "[y/N]" "" "validate_scaling_number"
        ask_keep_or_configure "maximum worker replicas (scale limit)" "MAX_REPLICAS" "$CURRENT_MAX_REPLICAS" "[y/N]" "" "validate_scaling_number"
        ask_keep_or_configure "scale up threshold (queue length)" "SCALE_UP_QUEUE_THRESHOLD" "$CURRENT_SCALE_UP_THRESHOLD" "[y/N]" "" "validate_scaling_number"
        ask_keep_or_configure "scale down threshold (queue length)" "SCALE_DOWN_QUEUE_THRESHOLD" "$CURRENT_SCALE_DOWN_THRESHOLD" "[y/N]" "" "validate_scaling_number"
        
        # Read the final values for display
        FINAL_MIN=$(get_existing_value "MIN_REPLICAS" "")
        FINAL_MAX=$(get_existing_value "MAX_REPLICAS" "")
        FINAL_UP=$(get_existing_value "SCALE_UP_QUEUE_THRESHOLD" "")
        FINAL_DOWN=$(get_existing_value "SCALE_DOWN_QUEUE_THRESHOLD" "")
        
        echo "${GREEN}✅ Autoscaling configured: $FINAL_MIN-$FINAL_MAX workers, up at >$FINAL_UP, down at <$FINAL_DOWN${NC}"
        ;;
    *)
        echo "${BLUE}ℹ️  Using current autoscaling settings ($CURRENT_MIN_REPLICAS-$CURRENT_MAX_REPLICAS workers)${NC}"
        ;;
esac

# Step 11: Container Runtime Detection
echo ""
echo "${BLUE}🐳 Container Runtime Configuration${NC}"
echo "---------------------------------"

# Function to detect if runtime is rootless
detect_rootless_mode() {
    local runtime="$1"
    
    if [ "$runtime" = "podman" ]; then
        # Check if podman is running in rootless mode
        if podman info --format "{{.Host.Security.Rootless}}" 2>/dev/null | grep -q "true"; then
            echo "rootless"
        else
            echo "rootful"
        fi
    elif [ "$runtime" = "docker" ]; then
        # Check if Docker is running in rootless mode
        if docker info 2>/dev/null | grep -q "rootless"; then
            echo "rootless"
        else
            echo "rootful"
        fi
    else
        echo "unknown"
    fi
}

# Function to detect correct compose command
detect_compose_command() {
    local runtime="$1"
    
    if [ "$runtime" = "docker" ]; then
        # For Docker, prefer 'docker compose' (v2) over 'docker-compose' (v1)
        if docker compose version >/dev/null 2>&1; then
            echo "docker compose"
        elif command -v docker-compose >/dev/null 2>&1; then
            echo "docker-compose"
        else
            echo ""
        fi
    elif [ "$runtime" = "podman" ]; then
        # For Podman, prefer podman-compose over podman compose
        if command -v podman-compose >/dev/null 2>&1; then
            echo "podman-compose"
        elif podman compose version >/dev/null 2>&1; then
            echo "podman compose"
        else
            echo ""
        fi
    fi
}

# Detect container runtime and mode
PODMAN_AVAILABLE=false
DOCKER_AVAILABLE=false
PODMAN_MODE=""
DOCKER_MODE=""

if command -v podman &> /dev/null; then
    PODMAN_AVAILABLE=true
    PODMAN_MODE=$(detect_rootless_mode "podman")
fi

if command -v docker &> /dev/null; then
    DOCKER_AVAILABLE=true
    DOCKER_MODE=$(detect_rootless_mode "docker")
fi

# Security ranking (best to worst)
# 1. Rootless Podman (most secure)
# 2. Rootless Docker (secure)  
# 3. Rootful Podman (less secure)
# 4. Rootful Docker (least secure)

if [ "$PODMAN_AVAILABLE" = "true" ] && [ "$PODMAN_MODE" = "rootless" ]; then
    CONTAINER_RUNTIME="podman"
    RUNTIME_MODE="rootless"
    SECURITY_LEVEL="🟢 Maximum"
elif [ "$DOCKER_AVAILABLE" = "true" ] && [ "$DOCKER_MODE" = "rootless" ]; then
    CONTAINER_RUNTIME="docker"
    RUNTIME_MODE="rootless"
    SECURITY_LEVEL="🟡 Good"
elif [ "$PODMAN_AVAILABLE" = "true" ]; then
    CONTAINER_RUNTIME="podman"
    RUNTIME_MODE="rootful"
    SECURITY_LEVEL="🔴 Poor"
elif [ "$DOCKER_AVAILABLE" = "true" ]; then
    CONTAINER_RUNTIME="docker"
    RUNTIME_MODE="rootful"
    SECURITY_LEVEL="🔴 Poor"
else
    echo "${RED}❌ No container runtime detected. Please install Docker or Podman.${NC}"
    echo ""
    echo "${BLUE}📋 Installation options:${NC}"
    echo "   Rootless Podman (most secure): https://podman.io/docs/installation"
    echo "   Rootless Docker: https://docs.docker.com/engine/security/rootless/"
    exit 1
fi

echo "${BLUE}ℹ️  Detected: $CONTAINER_RUNTIME ($RUNTIME_MODE mode)${NC}"
echo "${BLUE}ℹ️  Security level: $SECURITY_LEVEL${NC}"

# Display security warnings and migration guidance
if [ "$RUNTIME_MODE" = "rootful" ]; then
    echo ""
    echo "${RED}⚠️  SECURITY WARNING: Running in rootful mode${NC}"
    echo "${YELLOW}   Docker socket access provides root-level privileges to containers${NC}"
    echo "${YELLOW}   This is equivalent to giving containers full access to your host system${NC}"
    echo ""
    
    if [ "$CONTAINER_RUNTIME" = "docker" ]; then
        echo "${BLUE}🔒 To improve security, consider migrating to rootless Docker:${NC}"
        echo "   1. Stop current Docker daemon:"
        echo "      sudo systemctl stop docker"
        echo ""
        echo "   2. Install and configure rootless Docker:"
        echo "      curl -fsSL https://get.docker.com/rootless | sh"
        echo "      systemctl --user enable docker"
        echo "      systemctl --user start docker"
        echo ""
        echo "   3. Update your shell environment:"
        echo "      echo 'export DOCKER_HOST=unix:///run/user/\$(id -u)/docker.sock' >> ~/.bashrc"
        echo "      source ~/.bashrc"
        echo ""
        echo "${BLUE}🔒 Or consider migrating to rootless Podman (even more secure):${NC}"
        echo "   1. Install Podman:"
        echo "      sudo apt install podman  # Ubuntu/Debian"
        echo "      brew install podman      # macOS"
        echo ""
        echo "   2. Configure Podman:"
        echo "      podman machine init"
        echo "      podman machine start"
        echo ""
    elif [ "$CONTAINER_RUNTIME" = "podman" ]; then
        echo "${BLUE}🔒 To improve security, migrate to rootless Podman:${NC}"
        echo "   1. Stop current rootful Podman:"
        echo "      sudo systemctl stop podman"
        echo ""
        echo "   2. Configure rootless Podman:"
        echo "      podman machine init"
        echo "      podman machine start"
        echo ""
        echo "   3. Enable user lingering for automatic startup:"
        echo "      sudo loginctl enable-linger \$(whoami)"
        echo ""
    fi
    
    echo "${YELLOW}ℹ️  After migration, re-run this setup script to use the new runtime${NC}"
    echo ""
    echo -n "Continue with current $RUNTIME_MODE $CONTAINER_RUNTIME? [y/N]: "
    read -r continue_response
    case "$continue_response" in
        [Yy]|[Yy][Ee][Ss])
            echo "${YELLOW}⚠️  Proceeding with $RUNTIME_MODE $CONTAINER_RUNTIME (security risk acknowledged)${NC}"
            ;;
        *)
            echo "${BLUE}ℹ️  Setup cancelled. Please configure a more secure container runtime and try again.${NC}"
            exit 0
            ;;
    esac
else
    echo "${GREEN}✅ Running in rootless mode - excellent security posture!${NC}"
fi

echo ""
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

# Detect compose command for the selected runtime
COMPOSE_CMD=$(detect_compose_command "$CONTAINER_RUNTIME")
if [ -z "$COMPOSE_CMD" ]; then
    echo "${RED}❌ No compose tool found for $CONTAINER_RUNTIME${NC}"
    echo ""
    echo "${BLUE}📋 Installation options:${NC}"
    if [ "$CONTAINER_RUNTIME" = "podman" ]; then
        echo "   Install podman-compose: ${CYAN}pip3 install --user podman-compose${NC}"
        echo "   Or install docker-compose: ${CYAN}curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m) -o ~/.local/bin/docker-compose && chmod +x ~/.local/bin/docker-compose${NC}"
    else
        echo "   Install Docker Compose: ${CYAN}https://docs.docker.com/compose/install/${NC}"
    fi
    exit 1
fi

echo "${GREEN}✅ Using compose command: $COMPOSE_CMD${NC}"

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
        
        # Stop any existing containers to avoid port conflicts
        echo "${BLUE}🧹 Stopping any existing containers...${NC}"
        $COMPOSE_CMD $COMPOSE_FILES down --remove-orphans 2>/dev/null || true
        
        # Start PostgreSQL and Redis
        $COMPOSE_CMD $COMPOSE_FILES up -d postgres redis
        
        echo "${YELLOW}⏳ Waiting for database to be ready...${NC}"
        sleep 10
        
        # Check if database already exists
        DB_EXISTS=false
        if $COMPOSE_CMD exec -T -e PGPASSWORD="${POSTGRES_ADMIN_PASSWORD}" postgres psql -U "${POSTGRES_ADMIN_USER:-postgres}" -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "n8n_${ENVIRONMENT}"; then
            DB_EXISTS=true
        fi
        
        if [ "$DB_EXISTS" = "true" ]; then
            echo "${YELLOW}⚠️  Database n8n_${ENVIRONMENT} already exists.${NC}"
            echo -n "Do you want to overwrite it? [y/N]: "
            read -r overwrite_db_response
            case "$overwrite_db_response" in
                [Yy]|[Yy][Ee][Ss])
                    echo "${YELLOW}🔄 Recreating database...${NC}"
                    # Run database initialization
                    $COMPOSE_CMD $COMPOSE_FILES up --force-recreate postgres-init
                    ;;
                *)
                    echo "${BLUE}ℹ️  Using existing database${NC}"
                    ;;
            esac
        else
            echo "${YELLOW}🔄 Creating database...${NC}"
            # Run database initialization
            $COMPOSE_CMD $COMPOSE_FILES up postgres-init
        fi
        
        echo "${GREEN}✅ Database setup completed${NC}"
        ;;
    *)
        echo "${YELLOW}⚠️  Database creation skipped${NC}"
        echo ""
        echo "${RED}❌ Important: You MUST create the database before running n8n${NC}"
        echo ""
        echo "${BLUE}Choose one of these options:${NC}"
        echo ""
        echo "${GREEN}Option 1 (Recommended): Re-run this setup script${NC}"
        echo "   ${CYAN}./n8n-setup.sh${NC}"
        echo "   └─ Choose 'Y' when asked about database creation"
        echo ""
        echo "${GREEN}Option 2: Use the database initialization service${NC}"
        echo "   ${CYAN}$COMPOSE_CMD up -d postgres postgres-init${NC}"
        echo "   └─ Wait for initialization, then: ${CYAN}$COMPOSE_CMD up -d${NC}"
        echo ""
        echo "${GREEN}Option 3: Manual database creation${NC}"
        echo "   1. ${CYAN}$COMPOSE_CMD up -d postgres${NC}"
        echo "   2. ${CYAN}$COMPOSE_CMD exec postgres psql -U postgres -c \"CREATE DATABASE n8n_${ENVIRONMENT};\"${NC}"
        echo "   3. ${CYAN}$COMPOSE_CMD exec postgres psql -U postgres -c \"CREATE USER n8n_${ENVIRONMENT}_user WITH PASSWORD '$(grep "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2)';\"${NC}"
        echo "   4. ${CYAN}$COMPOSE_CMD exec postgres psql -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE n8n_${ENVIRONMENT} TO n8n_${ENVIRONMENT}_user;\"${NC}"
        echo "   5. ${CYAN}$COMPOSE_CMD exec postgres psql -U postgres -c \"ALTER DATABASE n8n_${ENVIRONMENT} OWNER TO n8n_${ENVIRONMENT}_user;\"${NC}"
        echo "   6. ${CYAN}$COMPOSE_CMD up -d${NC}"
        echo ""
        echo "${BLUE}💡 Without proper database setup, n8n services will fail to start${NC}"
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
        $COMPOSE_CMD $COMPOSE_FILES up -d
        
        echo "${YELLOW}⏳ Waiting for services to start...${NC}"
        sleep 30
        
        # Basic health checks
        echo "${YELLOW}🔍 Running basic health checks...${NC}"
        
        # Check if containers are running
        RUNNING_CONTAINERS=$($COMPOSE_CMD $COMPOSE_FILES ps --services --filter "status=running" 2>/dev/null | wc -l | tr -d ' ')
        TOTAL_CONTAINERS=$($COMPOSE_CMD $COMPOSE_FILES ps --services 2>/dev/null | wc -l | tr -d ' ')
        
        echo "${BLUE}ℹ️  Running containers: $RUNNING_CONTAINERS/$TOTAL_CONTAINERS${NC}"
        
        # Check Redis connectivity
        if $COMPOSE_CMD $COMPOSE_FILES exec -T redis redis-cli -a "${REDIS_PASSWORD:-}" ping 2>/dev/null | grep -q "PONG"; then
            echo "${GREEN}✅ Redis is responding${NC}"
        else
            echo "${RED}❌ Redis connection failed${NC}"
        fi
        
        # Check PostgreSQL connectivity
        if $COMPOSE_CMD $COMPOSE_FILES exec -T postgres pg_isready -U "${POSTGRES_ADMIN_USER:-postgres}" 2>/dev/null; then
            echo "${GREEN}✅ PostgreSQL is responding${NC}"
        else
            echo "${RED}❌ PostgreSQL connection failed${NC}"
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
CURRENT_CF_TUNNEL_TOKEN=$(get_existing_value "CLOUDFLARE_TUNNEL_TOKEN" "")
CURRENT_CF_ENABLED=$(get_existing_value "ENABLE_CLOUDFLARE_TUNNEL" "false")
CURRENT_TRAEFIK_ENABLED=$(get_existing_value "ENABLE_TRAEFIK" "false")

echo "   Traefik: $([ "$CURRENT_TRAEFIK_ENABLED" = "true" ] && echo "Enabled" || echo "Disabled")"
echo "   Cloudflare Tunnel: $([ "$CURRENT_CF_ENABLED" = "true" ] && [ -n "$CURRENT_CF_TUNNEL_TOKEN" ] && [ "$CURRENT_CF_TUNNEL_TOKEN" != "your_tunnel_token_here" ] && echo "Enabled" || echo "Disabled")"
echo "   Tailscale: $([ -n "$TAILSCALE_IP" ] && echo "$TAILSCALE_IP" || echo "Not configured")"
echo "   Main URL: $N8N_MAIN_URL"
echo "   Webhook URL: $N8N_WEBHOOK_URL"
CURRENT_MIN=$(get_existing_value "MIN_REPLICAS" "")
CURRENT_MAX=$(get_existing_value "MAX_REPLICAS" "")
echo "   Autoscaling: $([ -n "$MIN_REPLICAS" ] && echo "$MIN_REPLICAS-$MAX_REPLICAS workers" || echo "$CURRENT_MIN-$CURRENT_MAX workers")"
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