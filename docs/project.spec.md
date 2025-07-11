# Productionize this code

## review this document and the codebase and make suggestions if you think this is not complete.

## refactor to extend the official n8n docker images while keeping the distinct service containers:

 - n8n
 - n8n-worker
 - n8n-webhook

## ensure other containers are using latest stable secure base image

## define default data locations for all containers

 ./Logs
 ./Data
 ./Data/Postgres (etc for different apps)

## add a mount to n8n containers for rclone cloud storage

  - we will use rclone as a datastore add a r/w mount
    /user/webapps/mounts/rclone-data

## Refactor to ensure everything is arm64/amd64 compatible / automatically detects at build

 - this includes puppeteer and its dependencies the autocaler and monitor queue containers

## Ensure that the system will work with root and rootless podman

 - by default autodetect but add an environment variable to enable choice

## add a script to create systemd files 

 - alow user to choose root or user based (use docker/podman detection/env to use correct type)

## add log rotation

  - id like logs for these containers rotated and compressed daily
  - keep only 7 days of rotated logs

## add backups compressed into  ./backups

 - backup postgres fully every 12 hours. incrementals every hour.

 - I'd like to backup redis hourly (unless you have a better suggestion)

 - backup n8n data folder hourly

 - detail a cron to
   - move completed backups to /user/webapps/mounts/rclone-backups
   - delete backups older than 7 days from /user/webapps/mounts/rclone-backups

## upgrade to redis 8

  - make the redis password compulsorary

## extra performance variables with defaults for each app in the .env.example under advanced APPNAME
  - add extra sensible tuning options for each app with defaults but # the start of the line