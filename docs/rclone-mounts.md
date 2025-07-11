# Rclone Cloud Storage Integration Guide

This guide provides comprehensive instructions for setting up rclone cloud storage mounts with n8n-autoscaling, including provider-specific examples and best practices for Docker and Podman users.

## Table of Contents
- [Overview](#overview)
- [Security Recommendations](#security-recommendations)
- [Installation](#installation)
- [Provider Configuration](#provider-configuration)
- [Mount Examples](#mount-examples)
- [Container Runtime Considerations](#container-runtime-considerations)
- [Troubleshooting](#troubleshooting)
- [Performance Tuning](#performance-tuning)

## Overview

Rclone enables n8n to access cloud storage from 70+ providers including:
- Google Drive, OneDrive, Dropbox
- AWS S3, Azure Blob, Google Cloud Storage
- SFTP, FTP, WebDAV servers
- Many more cloud and protocol backends

The n8n-autoscaling system uses rclone mounts for:
- **Data Storage**: Media files, documents, and assets that n8n workflows process
- **Backup Storage**: Automated backups with cloud redundancy and retention policies

## Security Recommendations

### 🔒 Use Rootless Containers (Strongly Recommended)

**Why Rootless?**
- Better security isolation
- No root privileges required
- FUSE mounts work seamlessly with your user permissions
- Simplified permission management

**Container Runtime Security Ranking:**
1. **🟢 Rootless Podman** - Best security, built-in rootless support
2. **🟡 Rootless Docker** - Good security with rootless mode
3. **🔴 Rootful Podman** - Avoid if possible
4. **🔴 Rootful Docker** - Least secure, avoid for production

## Installation

### Install Rclone

**Latest Version (Recommended):**
```bash
curl https://rclone.org/install.sh | sudo bash
```

**Package Managers:**
```bash
# Ubuntu/Debian
sudo apt install rclone

# RHEL/Fedora/CentOS
sudo dnf install rclone

# macOS
brew install rclone

# Arch Linux
sudo pacman -S rclone
```

### Configure Your Backend

```bash
# Start interactive configuration
rclone config

# Follow prompts to:
# 1. Create new remote (n)
# 2. Name it (e.g., 'mydrive', 'backups')
# 3. Select provider
# 4. Complete provider-specific auth

# Test configuration
rclone ls myremote:
```

## Provider Configuration

### Popular Provider Guides

- **Google Drive**: [https://rclone.org/drive/](https://rclone.org/drive/)
- **OneDrive**: [https://rclone.org/onedrive/](https://rclone.org/onedrive/)
- **Dropbox**: [https://rclone.org/dropbox/](https://rclone.org/dropbox/)
- **AWS S3**: [https://rclone.org/s3/](https://rclone.org/s3/)
- **Backblaze B2**: [https://rclone.org/b2/](https://rclone.org/b2/)
- **Google Cloud Storage**: [https://rclone.org/googlecloudstorage/](https://rclone.org/googlecloudstorage/)
- **All Providers**: [https://rclone.org/overview/](https://rclone.org/overview/)

## Mount Examples

### Basic Mount Structure

```bash
# Create mount points
mkdir -p ~/mounts/rclone-data ~/mounts/rclone-backups

# Basic mount command
rclone mount remote:path /local/mount/path [flags]
```

### Example 1: Google Drive for Media Files

**Use Case**: Large media files, video editing, documents

```bash
# Optimized for media streaming and editing
rclone mount gdrive:n8n-data ~/mounts/rclone-data \
  --vfs-cache-mode full \
  --vfs-cache-max-size 20G \
  --vfs-cache-max-age 2h \
  --vfs-read-ahead 512M \
  --vfs-read-chunk-size 128M \
  --vfs-read-chunk-size-limit 2G \
  --buffer-size 512M \
  --dir-cache-time 1h \
  --vfs-fast-fingerprint \
  --transfers 8 \
  --umask 002 \
  --daemon
```

### Example 2: S3-Compatible Storage for Backups

**Use Case**: Backup storage with compression support

```bash
# Optimized for backup writes
rclone mount s3:n8n-backups ~/mounts/rclone-backups \
  --vfs-cache-mode writes \
  --vfs-cache-max-size 5G \
  --vfs-cache-max-age 1h \
  --vfs-write-back 5m \
  --buffer-size 64M \
  --transfers 4 \
  --s3-chunk-size 64M \
  --umask 002 \
  --daemon
```

### Example 3: OneDrive for Documents

**Use Case**: Office documents, small files

```bash
# Optimized for small file access
rclone mount onedrive:Documents ~/mounts/rclone-data \
  --vfs-cache-mode full \
  --vfs-cache-max-size 10G \
  --vfs-cache-max-age 24h \
  --buffer-size 32M \
  --dir-cache-time 5m \
  --poll-interval 1m \
  --umask 002 \
  --daemon
```

### Example 4: SFTP for Secure Corporate Storage

**Use Case**: Corporate SFTP server integration

```bash
# SFTP mount with specific permissions
rclone mount sftp:data ~/mounts/rclone-data \
  --vfs-cache-mode minimal \
  --sftp-idle-timeout 5m \
  --buffer-size 32M \
  --transfers 2 \
  --umask 002 \
  --daemon
```

## Container Runtime Considerations

### Rootless Podman (Recommended)

**Advantages:**
- Mounts created as your user work seamlessly
- No permission translation needed
- Most secure option

**Mount Command:**
```bash
# Standard mount - containers can access directly
rclone mount remote:path ~/mounts/path \
  --vfs-cache-mode full \
  --umask 002 \
  --daemon
```

**Container Usage:**
```bash
# Containers automatically have access
podman run -v ~/mounts/rclone-data:/data:rw myimage
```

### Rootless Docker

**Setup Requirements:**
```bash
# Enable rootless Docker
dockerd-rootless-setuptool.sh install

# Verify rootless mode
docker context use rootless
```

**Mount Considerations:**
- Similar to rootless Podman
- Ensure Docker daemon runs as your user
- May need to adjust `~/.config/docker/daemon.json`

### Rootful Containers (Not Recommended)

If you must use rootful containers:

**1. Enable FUSE access for other users:**
```bash
# Edit /etc/fuse.conf
sudo sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf
```

**2. Mount with permission flags:**
```bash
rclone mount remote:path /mnt/rclone-data \
  --allow-other \
  --uid 1000 \
  --gid 1000 \
  --umask 002 \
  --daemon
```

**⚠️ Security Warning**: Rootful containers have equivalent root access to your host system.

## Systemd Service for Automatic Mounting

### User Service (Rootless - Recommended)

Create `~/.config/systemd/user/rclone-data.service`:

```ini
[Unit]
Description=Rclone mount for n8n data
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p %h/mounts/rclone-data
ExecStart=/usr/bin/rclone mount gdrive:n8n-data %h/mounts/rclone-data \
  --config %h/.config/rclone/rclone.conf \
  --vfs-cache-mode full \
  --vfs-cache-max-size 20G \
  --vfs-read-ahead 512M \
  --buffer-size 512M \
  --umask 002 \
  --log-level INFO \
  --log-file %h/.local/share/rclone/rclone-data.log
ExecStop=/bin/fusermount -u %h/mounts/rclone-data
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

**Enable and start:**
```bash
# Enable lingering for user services
loginctl enable-linger $USER

# Enable and start service
systemctl --user daemon-reload
systemctl --user enable rclone-data.service
systemctl --user start rclone-data.service

# Check status
systemctl --user status rclone-data.service
```

### System Service (Rootful - Not Recommended)

Only use if absolutely necessary. Create `/etc/systemd/system/rclone-mount.service`:

```ini
[Unit]
Description=Rclone mount
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=rclone
Group=rclone
ExecStartPre=/bin/mkdir -p /mnt/rclone-data
ExecStart=/usr/bin/rclone mount remote:data /mnt/rclone-data \
  --allow-other \
  --uid 1000 \
  --gid 1000 \
  --umask 002
ExecStop=/bin/fusermount -u /mnt/rclone-data
Restart=always

[Install]
WantedBy=multi-user.target
```

## Troubleshooting

### Permission Issues

**Symptom**: Containers can't access mounted files

**For Rootless (Recommended):**
```bash
# Verify mount ownership
ls -la ~/mounts/

# Test container access
podman run --rm -v ~/mounts/rclone-data:/test:rw alpine touch /test/testfile

# Check your UID/GID
id
```

**For Rootful (If Required):**
```bash
# Check FUSE configuration
grep user_allow_other /etc/fuse.conf

# Remount with correct permissions
fusermount -u /mnt/rclone-data
rclone mount remote:data /mnt/rclone-data --allow-other --uid $(id -u) --gid $(id -g)
```

### Mount Not Working

```bash
# Check if already mounted
mount | grep rclone

# Check rclone processes
ps aux | grep rclone

# View logs
journalctl --user -u rclone-data.service -f  # For user service
tail -f ~/.local/share/rclone/rclone.log      # For manual mounts
```

### Performance Issues

**Slow Directory Listings:**
```bash
# Increase dir cache time
--dir-cache-time 1h

# Enable fast fingerprint
--vfs-fast-fingerprint
```

**Slow File Access:**
```bash
# Increase cache and read-ahead
--vfs-cache-mode full
--vfs-read-ahead 1G
--vfs-cache-max-size 50G
```

**High Memory Usage:**
```bash
# Limit cache size
--vfs-cache-max-size 10G
--buffer-size 32M
```

## Performance Tuning

### Cache Modes Explained

- **`off`**: No caching, direct access (slowest, least memory)
- **`minimal`**: Only cache file info (good for browsing)
- **`writes`**: Cache writes before upload (good for backups)
- **`full`**: Cache everything (fastest, most memory)

### Recommended Settings by Use Case

**High-Performance Media Editing:**
```bash
--vfs-cache-mode full
--vfs-cache-max-size 50G
--vfs-read-ahead 1G
--vfs-read-chunk-size 256M
--buffer-size 1G
```

**Backup Operations:**
```bash
--vfs-cache-mode writes
--vfs-write-back 5m
--transfers 4
--checkers 8
```

**Low-Memory Systems:**
```bash
--vfs-cache-mode minimal
--buffer-size 16M
--vfs-cache-max-size 1G
```

## Integration with n8n-autoscaling

After setting up your mounts:

1. **Configure in `.env`:**
   ```bash
   RCLONE_DATA_MOUNT=/home/user/mounts/rclone-data
   RCLONE_BACKUP_MOUNT=/home/user/mounts/rclone-backups
   ```

2. **Start with rclone support:**
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.rclone.yml up -d
   ```

3. **Verify mounts in containers:**
   ```bash
   docker compose exec n8n ls -la /rclone-data
   docker compose exec n8n ls -la /rclone-backups
   ```

## Best Practices

1. **Always use absolute paths** in mount commands and `.env` configuration
2. **Test mounts thoroughly** before starting n8n services
3. **Monitor cache usage** with `df -h ~/.cache/rclone/`
4. **Use systemd services** for automatic mounting on boot
5. **Keep logs** for troubleshooting with `--log-file` flag
6. **Regular cleanup** of cache with `rclone cache clean`
7. **Backup your rclone config** at `~/.config/rclone/rclone.conf`

## Additional Resources

- [Rclone Documentation](https://rclone.org/docs/)
- [Rclone Forum](https://forum.rclone.org/)
- [VFS Cache Documentation](https://rclone.org/commands/rclone_mount/#vfs-file-caching)
- [Performance Tuning Guide](https://rclone.org/commands/rclone_mount/#vfs-performance)