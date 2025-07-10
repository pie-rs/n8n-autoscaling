# Use official n8n image as base
# Multi-architecture support via Docker buildx
FROM n8nio/n8n:latest

# Switch to root for package installation
USER root

# Install Chromium and its dependencies for Puppeteer
# The n8n base image uses Alpine Linux
# Note: ca-certificates already included in n8n base image
RUN apk add --no-cache \
    chromium \
    chromium-chromedriver \
    ffmpeg \
    freetype \
    freetype-dev \
    harfbuzz \
    nss \
    ttf-freefont \
    && rm -rf /var/cache/apk/*

# Install Puppeteer without downloading Chromium (we'll use system Chromium)
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

RUN npm install -g puppeteer

# Create entrypoint scripts for worker and webhook modes
RUN printf '#!/bin/sh\nexec n8n worker\n' > /worker && \
    printf '#!/bin/sh\nexec n8n webhook\n' > /webhook && \
    chmod +x /worker /webhook

# Switch back to node user (as per official n8n image)
USER node

# Keep the official image's entrypoint and command
# The base image already exposes port 5678 and has proper entrypoint