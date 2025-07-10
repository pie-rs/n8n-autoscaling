# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See @README.md for project overview

# architecture docmentation
- @~/docs/architecture.md

# project specifications
- @~/docs/project.spec.md

# Individual Preferences
- @~/.claude/CLAUDE.md



## Project Overview

This is a Docker-based autoscaling solution for n8n workflow automation platform that dynamically scales worker containers based on Redis queue length without requiring Kubernetes or other complex orchestration platforms.

## Key Commands

### Initial Setup
```bash
# Run the interactive setup wizard
./n8n-setup.sh

# The wizard will:
# 1. Create .env file from .env.example
# 2. Ask for environment (dev/test/production)
# 3. Generate secure random secrets (optional)
# 4. Detect and configure timezone
# 5. Configure external network (optional)
# 6. Set up rclone cloud storage integration with directory validation (optional)
# 7. Configure Cloudflare Tunnel with token validation (optional)
# 8. Configure Tailscale IP for PostgreSQL binding (optional)
# 9. Configure n8n and webhook URLs
# 10. Configure autoscaling parameters (optional)
# 11. Detect container runtime (Docker/Podman)
# 12. Create data directories with absolute paths
# 13. Create database and test the setup
# 14. Mark setup as completed

# Run n8n-setup.sh again to:
# - Configure systemd services
# - Re-run setup wizard
# - Reset environment (clean start)
./n8n-setup.sh
```

### Development Commands
```bash
# View logs for specific service
docker compose logs -f [service-name]  # e.g., autoscaler, n8n-worker, redis-monitor

# Check autoscaler status
docker compose logs -f n8n-autoscaler

# Monitor Redis queue length
docker compose exec redis redis-cli LLEN bull:jobs:wait

# Scale workers manually (for testing)
docker compose up -d --scale n8n-worker=3

# Restart specific service
docker compose restart [service-name]

# Stop all services
docker compose down
```

### Systemd Service Management
```bash
# Generate systemd service files
./generate-systemd.sh

# User service commands (if installed as user)
systemctl --user enable n8n-autoscaling.service
systemctl --user start n8n-autoscaling.service
systemctl --user status n8n-autoscaling.service
systemctl --user stop n8n-autoscaling.service
journalctl --user -u n8n-autoscaling -f

# System service commands (if installed as root)
sudo systemctl enable n8n-autoscaling.service
sudo systemctl start n8n-autoscaling.service
sudo systemctl status n8n-autoscaling.service
sudo systemctl stop n8n-autoscaling.service
journalctl -u n8n-autoscaling -f
```

### Debugging Commands
```bash
# Check Redis connection
docker compose exec redis redis-cli ping

# Monitor queue in real-time
docker compose logs -f redis-monitor

# Check worker health
docker compose ps

# Inspect autoscaler decisions
docker compose logs n8n-autoscaler | grep -E "(Scaling|Current|Queue)"
```

## Architecture

### Service Components
- **n8n**: Main instance handling UI and job orchestration (port 5678, proxied via Traefik on 8082)
- **n8n-webhook**: Dedicated webhook handler (proxied via Traefik on 8083)
- **n8n-worker**: Scalable worker instances (1-5 replicas)
- **n8n-autoscaler**: Python service that monitors Redis queue and scales workers
- **redis**: Queue management using BullMQ
- **postgres**: Data persistence (PostgreSQL 17)
- **traefik**: Reverse proxy for routing
- **cloudflared**: Cloudflare tunnel for secure external access
- **redis-monitor**: Queue monitoring for debugging

### Scaling Logic (autoscaler/autoscaler.py)
The autoscaler monitors `bull:jobs:wait` queue length every 30 seconds and:
- Scales UP when queue > 5 jobs AND current workers < max (5)
- Scales DOWN when queue < 2 jobs AND current workers > min (1)
- Enforces 3-minute cooldown between scaling actions
- Uses Docker Compose CLI to adjust replica count

### Key Configuration
Critical environment variables in `.env`:
- `MIN_REPLICAS` / `MAX_REPLICAS`: Worker scaling limits (1-5)
- `SCALE_UP_QUEUE_THRESHOLD` / `SCALE_DOWN_QUEUE_THRESHOLD`: Queue thresholds (5/2)
- `N8N_CONCURRENCY_PRODUCTION_LIMIT`: Tasks per worker (default: 10)
- `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`: Shutdown timeout (300s)
- `CLOUDFLARE_TUNNEL_TOKEN`: Required for external access

### Network Configuration
- Internal network: `n8n-network` (for service communication)
- External network: `n8n-external` (optional - for integration with other containers)
- Traefik endpoints: `:8082` (UI), `:8083` (webhooks)

## Important Notes

1. **Puppeteer/Chromium**: Built into n8n image via custom Dockerfile for web scraping
2. **Webhook URLs**: Use Cloudflare subdomain, not localhost (e.g., `https://webhook.domain.com/webhook/...`)
3. **Graceful Shutdown**: Set timeouts > longest workflow execution time
4. **Queue Monitoring**: Check both `bull:jobs:wait` and `bull:jobs:waiting` (BullMQ v4+)
5. **Scaling Cooldown**: Prevents thrashing with 3-minute default between actions
6. **Tailscale Support**: PostgreSQL can bind to Tailscale IP for secure access
7. **Rclone Cloud Storage Integration**: Optional mounting via override file
8. **Data Organization**: Environment variable-driven data directory structure

## Testing Autoscaling
```bash
# 1. Monitor autoscaler logs
docker compose logs -f n8n-autoscaler

# 2. Create load (run multiple workflows)
# 3. Watch scaling decisions in logs
# 4. Verify worker count
docker compose ps | grep n8n-worker
```

## Rclone Cloud Storage Integration

The system supports optional rclone cloud storage mounting for data storage:

### Enable Rclone Cloud Storage
```bash
# 1. Edit .env and uncomment the rclone variables:
# RCLONE_DATA_MOUNT=/user/webapps/mounts/rclone-data
# RCLONE_BACKUP_MOUNT=/user/webapps/mounts/rclone-backups

# 2. Create directories and start with rclone support
./n8n-setup.sh
docker compose -f docker-compose.yml -f docker-compose.rclone.yml up -d
```

### Disable Rclone Cloud Storage
```bash
# Use standard compose file (default)
docker compose up -d
```

**Note**: Only `n8n` and `n8n-worker` services get rclone cloud storage access. The `n8n-webhook` service does not need it.

## Common Issues

1. **Workers not scaling**: Check Redis connection and queue name format
2. **Webhooks not working**: Ensure using Cloudflare URL, not localhost
3. **Scaling too aggressive**: Adjust thresholds and cooldown in .env
4. **Container permissions**: n8n services run as root:root by design
5. **Rclone cloud storage not mounting**: Ensure directories exist and RCLONE variables are uncommented in .env

## Production Requirements (from project.spec.md)

### Pending Production Enhancements

1. **Extend Official n8n Images**: Refactor to use official n8n Docker images as base
2. **Multi-Architecture Support**: Add ARM64/AMD64 compatibility with automatic detection
3. **Podman Compatibility**: Support both root and rootless Podman (with auto-detection)
4. **Data Organization**: 
   - Logs: `./Logs`
   - Data: `./Data/Postgres`, `./Data/Redis`, etc.
   - Backups: `./backups`
5. **Rclone Cloud Storage Integration**: Mount at `/user/webapps/mounts/rclone-data` for n8n containers
6. **Systemd Integration**: Script to generate systemd service files
7. **Log Rotation**: Daily rotation, compression, 7-day retention
8. **Backup Strategy**:
   - PostgreSQL: Full backup every 12 hours, incremental hourly
   - Redis: Hourly snapshots
   - n8n data: Hourly backups
   - Auto-move to `/user/webapps/mounts/rclone-backups`
   - 7-day retention policy

### Completed Production Enhancements ✅

1. **✅ Extended Official n8n Images**: Now uses `n8nio/n8n:latest` as base image
2. **✅ Multi-Architecture Support**: Added ARM64/AMD64 compatibility with automatic detection
3. **✅ Updated Base Images**: 
   - **n8n**: Uses official n8n image with Alpine-based Chromium/Puppeteer
   - **Autoscaler**: Uses Python 3.12-slim with multi-arch Docker Compose detection
   - **Monitor**: Uses Python 3.12-slim with non-root security
4. **✅ Improved Security**: Non-root users where possible, removed deprecated npm flags
5. **✅ Optimized Dependencies**: Removed duplicate packages already in n8n base image

### Current Build Status

- **Dockerfile**: Extends official n8n image with optimized Puppeteer/Chromium setup
- **Autoscaler**: Python 3.12 with architecture-aware Docker Compose installation
- **Monitor**: Python 3.12 with dedicated non-root user
- **All services**: Multi-architecture ready via standard `docker compose build`

### Completed Production Enhancements ✅ (Updated)

6. **✅ Data Organization**: Configurable data locations via environment variables
   - `./Data/Postgres`, `./Data/Redis`, `./Data/n8n`, etc.
   - `./Logs` for application logs
   - `./backups` for backup storage
7. **✅ Rclone Cloud Storage Integration**: Optional mount system
   - Conditional mounting only when configured
   - Override file `docker-compose.rclone.yml` for optional integration
   - Only n8n and n8n-worker services get rclone cloud storage access (not webhook)
8. **✅ Logging Configuration**: Structured logging with rotation limits
   - Configurable log driver, max size, and file count
   - Applied to all services uniformly
9. **✅ Podman Compatibility**: Full support for both Docker and Podman
   - Automatic runtime detection
   - Environment variable override option
   - Works with both root and rootless Podman
10. **✅ External Network**: Optional configuration via environment variable
    - Renamed from `shark` to `n8n-external`
    - Disabled by default for simpler setup
    - Easy to enable when needed

### Completed Production Enhancements ✅ (Latest)

11. **✅ Systemd Integration**: Complete systemd service generator
    - Automatic Docker/Podman detection
    - User vs system service installation
    - Podman auto-update integration with labels
    - Lingering setup for rootless Podman
    - Rclone cloud storage integration prompt
    - No update timers (simplified approach)

12. **✅ Automatic Updates**: Different strategies by runtime
    - **Docker**: Watchtower integration documented in README
    - **Podman**: Built-in auto-update via systemd timer and container labels
    - Podman auto-update configured automatically via `./generate-systemd.sh`

### Completed Production Enhancements ✅ (Latest)

13. **✅ Logging Configuration**: Built-in Docker/Podman log rotation
    - Uses json-file driver with automatic rotation (10MB/3 files)
    - No additional log rotation needed - handled by container runtime
    - Comprehensive logging documentation in README
    - Systemd service logs via journalctl

14. **✅ Redis 8 Upgrade**: Upgraded to Redis 8 with mandatory password
    - Updated to redis:8-alpine image
    - Added mandatory password authentication via REDIS_PASSWORD
    - Updated healthcheck to use password authentication
    - Updated all Redis CLI commands in documentation
    - Added password configuration to autoscaler environment

15. **✅ Backup System**: Comprehensive backup strategy with rclone cloud storage integration
    - PostgreSQL: Smart backup system (full every 12h, incremental hourly)
    - Redis: Database snapshots using BGSAVE (compressed)
    - n8n Data: Complete data directories including webhook data (compressed)
    - Automatic rclone cloud storage sync with local cleanup when configured
    - 7-day retention policy (on rclone cloud storage when enabled, locally otherwise)
    - Single script handles all backup types with individual service options
    - Cron-ready with suggested hourly and twice-daily schedules

16. **✅ Restore System**: Interactive point-in-time recovery with safety features
    - Multi-source backup discovery (local and rclone cloud storage)
    - Interactive menu for service and backup selection
    - Automatic safety backup before restore
    - Backup integrity validation (compression, SQL structure, size checks)
    - Smart container management (stop/start sequences)
    - Dry-run mode for testing restore operations
    - Point-in-time recovery with timestamp display
    - Support for PostgreSQL, Redis, and n8n data restoration

### Completed Production Enhancements ✅ (Latest)

17. **✅ Performance Tuning**: Comprehensive performance variables for all applications
    - **n8n**: Concurrency, memory limits, execution data pruning, Node.js optimizations
    - **PostgreSQL**: Memory allocation, query performance, parallel processing settings
    - **Redis**: Memory limits, eviction policies, persistence configuration
    - **Autoscaler**: Resource limits, connection pooling, timeout configurations
    - **Monitor**: Resource limits and operational settings
    - All variables commented out by default with sensible defaults
    - Comprehensive documentation in README for each performance category

18. **✅ PostgreSQL Security**: Environment-based database and user configuration
    - **Separate Admin and Application Users**: PostgreSQL admin user (`postgres`) for database operations, dedicated application user for n8n
    - **Environment-Based Naming**: Database and user names based on ENVIRONMENT variable (dev/test/production)
    - **Database Naming**: `n8n_${ENVIRONMENT}` (e.g., `n8n_dev`, `n8n_test`, `n8n_production`)
    - **User Naming**: `n8n_${ENVIRONMENT}_user` (e.g., `n8n_dev_user`, `n8n_test_user`, `n8n_production_user`)
    - **Automatic Database/User Creation**: `init-postgres.sh` script creates database and user on first run
    - **Updated Backup/Restore**: Scripts handle both admin and application user contexts appropriately

19. **✅ Interactive Setup Wizard**: Comprehensive setup.sh wizard for zero-configuration deployment
    - **Environment File Creation**: Creates .env from .env.example with user confirmation
    - **Environment Selection**: Prompts for dev/test/production environment
    - **Secure Secret Generation**: Generates cryptographically secure passwords, encryption keys, and tokens using user-provided salt
    - **Timezone Detection**: Automatically detects system timezone with option to override
    - **External Network Configuration**: Optional external network setup for container integration
    - **Rclone Cloud Storage Integration**: Optional rclone cloud storage mount configuration with directory validation and creation
    - **Cloudflare Tunnel Configuration**: Optional Cloudflare tunnel token setup with validation
    - **Tailscale Integration**: Optional Tailscale IP configuration for secure PostgreSQL binding
    - **URL Configuration**: Validates and configures n8n main and webhook URLs
    - **Autoscaling Configuration**: Optional customization of worker scaling parameters (min/max replicas, thresholds)
    - **Container Runtime Detection**: Automatically detects Docker/Podman with manual override option
    - **Database Creation**: Creates environment-specific database and user with existence checks
    - **Setup Testing**: Starts services and runs health checks (Redis, PostgreSQL, container status)
    - **Systemd Integration**: On second run, offers to set up systemd services
    - **Setup Completion Tracking**: Uses flag in .env to track completion status

## 🎉 Production Requirements Complete

All production requirements from `docs/project.spec.md` have been successfully implemented:

✅ **Refactored to extend official n8n Docker images**
✅ **Multi-architecture support (ARM64/AMD64) with automatic detection** 
✅ **Root and rootless Podman compatibility with auto-detection**
✅ **Systemd service file generation script**
✅ **Log rotation handled by Docker/Podman built-in system**
✅ **Comprehensive backup system with rclone cloud storage integration**
✅ **Redis 8 upgrade with mandatory password authentication**
✅ **Performance tuning variables for all applications**
✅ **PostgreSQL security with environment-based database and user configuration**
✅ **Interactive setup wizard for zero-configuration deployment**

The n8n-autoscaling system is now production-ready with enterprise-grade features.