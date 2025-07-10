# Use latest stable Python 3.12 slim image for better security and performance
FROM python:3.12-slim AS builder

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    docker.io \
    jq \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set the working directory in the container
WORKDIR /app

# Install Docker Compose v2 with multi-architecture support
# Detect architecture and download appropriate binary
RUN ARCH=$(dpkg --print-architecture) && \
    case ${ARCH} in \
        amd64) COMPOSE_ARCH='x86_64' ;; \
        arm64) COMPOSE_ARCH='aarch64' ;; \
        armhf) COMPOSE_ARCH='armv7' ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    mkdir -p ~/.docker/cli-plugins/ && \
    curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}" -o ~/.docker/cli-plugins/docker-compose && \
    chmod +x ~/.docker/cli-plugins/docker-compose

# Copy requirements first to leverage Docker cache
COPY autoscaler/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Final stage - use same Python version for consistency
FROM python:3.12-slim
WORKDIR /app

# Copy from builder
COPY --from=builder /usr/bin/docker /usr/bin/docker
COPY --from=builder /root/.docker/cli-plugins/ /usr/local/lib/docker/cli-plugins/
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages

# Ensure docker compose plugin is in PATH
ENV PATH="/usr/local/lib/docker/cli-plugins:${PATH}"

# Copy application files
COPY autoscaler/autoscaler.py .
COPY docker-compose.yml .
COPY Dockerfile .

# Run as non-root user for security (create a dedicated user)
RUN useradd -m -u 1000 autoscaler && \
    chown -R autoscaler:autoscaler /app

# Note: Docker socket will need to be accessible by this user
# This is handled by volume mount permissions

# Specify the command to run on container start
CMD ["python", "-u", "autoscaler.py"]