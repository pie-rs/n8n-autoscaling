# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Docker-based autoscaling solution for n8n workflow automation platform that dynamically scales worker containers based on Redis queue length without requiring Kubernetes or other complex orchestration platforms.

## Key Commands

### Initial Setup
```bash
# Copy environment configuration
cp .env.example .env
# Then edit .env with your values

# Create data directories (and optional external network if configured)
./setup.sh

# Start all services
docker compose up -d

# Optional: Enable external network for connecting to other containers
# 1. Uncomment EXTERNAL_NETWORK_NAME=n8n-external in .env
# 2. Uncomment the network sections in docker-compose.yml
# 3. Re-run ./setup.sh to create the network
# 4. Restart services: docker compose up -d

# Optional: Enable Google Drive integration
# 1. Uncomment GDRIVE_DATA_MOUNT in .env
# 2. Ensure mount point exists and is accessible
# 3. Start with Google Drive support:
docker compose -f docker-compose.yml -f docker-compose.gdrive.yml up -d
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
7. **Google Drive Integration**: Optional mounting via override file
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

## Google Drive Integration

The system supports optional Google Drive mounting for data storage:

### Enable Google Drive
```bash
# 1. Edit .env and uncomment the Google Drive variables:
# GDRIVE_DATA_MOUNT=/user/webapps/mounts/gdrive-data
# GDRIVE_BACKUP_MOUNT=/user/webapps/mounts/gdrive-backups

# 2. Create directories and start with Google Drive support
./setup.sh
docker compose -f docker-compose.yml -f docker-compose.gdrive.yml up -d
```

### Disable Google Drive
```bash
# Use standard compose file (default)
docker compose up -d
```

**Note**: Only `n8n` and `n8n-worker` services get Google Drive access. The `n8n-webhook` service does not need it.

## Common Issues

1. **Workers not scaling**: Check Redis connection and queue name format
2. **Webhooks not working**: Ensure using Cloudflare URL, not localhost
3. **Scaling too aggressive**: Adjust thresholds and cooldown in .env
4. **Container permissions**: n8n services run as root:root by design
5. **Google Drive not mounting**: Ensure directories exist and GDRIVE variables are uncommented in .env

## Production Requirements (from project.spec.md)

### Pending Production Enhancements

1. **Extend Official n8n Images**: Refactor to use official n8n Docker images as base
2. **Multi-Architecture Support**: Add ARM64/AMD64 compatibility with automatic detection
3. **Podman Compatibility**: Support both root and rootless Podman (with auto-detection)
4. **Data Organization**: 
   - Logs: `./Logs`
   - Data: `./Data/Postgres`, `./Data/Redis`, etc.
   - Backups: `./backups`
5. **Google Drive Integration**: Mount at `/user/webapps/mounts/gdrive-data` for n8n containers
6. **Systemd Integration**: Script to generate systemd service files
7. **Log Rotation**: Daily rotation, compression, 7-day retention
8. **Backup Strategy**:
   - PostgreSQL: Full backup every 12 hours, incremental hourly
   - Redis: Hourly snapshots
   - n8n data: Hourly backups
   - Auto-move to `/user/webapps/mounts/gdrive-backups`
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
7. **✅ Google Drive Integration**: Optional mount system
   - Conditional mounting only when configured
   - Override file `docker-compose.gdrive.yml` for optional integration
   - Only n8n and n8n-worker services get Google Drive access (not webhook)
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

### Remaining Production Tasks

1. **Systemd Integration**: Script to generate systemd service files
2. **Log Rotation**: Daily rotation, compression, 7-day retention
3. **Backup Strategy**: Automated backups with retention policies
4. **Redis 8 Upgrade**: Upgrade to Redis 8 with mandatory password
5. **Performance Tuning**: Add extra performance variables for each app