#!/bin/bash
# PostgreSQL initialization script for n8n-autoscaling
# Creates environment-specific database and user

set -e

# Load environment variables
if [ -f /app/.env ]; then
    # shellcheck disable=SC1091
    source /app/.env
fi

# Set defaults
ENVIRONMENT=${ENVIRONMENT:-dev}
POSTGRES_ADMIN_USER=${POSTGRES_ADMIN_USER:-postgres}
POSTGRES_ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD:-}
N8N_DB_NAME="n8n_${ENVIRONMENT}"
N8N_DB_USER="n8n_${ENVIRONMENT}_user"
N8N_DB_PASSWORD=${POSTGRES_PASSWORD:-}

echo "Initializing PostgreSQL for environment: $ENVIRONMENT"
echo "Database: $N8N_DB_NAME"
echo "User: $N8N_DB_USER"

# Wait for PostgreSQL to be ready
until PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql -h postgres -U "$POSTGRES_ADMIN_USER" -c '\q' 2>/dev/null; do
    echo "Waiting for PostgreSQL to be ready..."
    sleep 2
done

echo "PostgreSQL is ready. Creating database and user..."

# Create the n8n user if it doesn't exist
PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql -h postgres -U "$POSTGRES_ADMIN_USER" -tc "SELECT 1 FROM pg_user WHERE usename = '$N8N_DB_USER'" | grep -q 1 || \
PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql -h postgres -U "$POSTGRES_ADMIN_USER" -c "CREATE USER $N8N_DB_USER WITH PASSWORD '$N8N_DB_PASSWORD';"

# Create the n8n database if it doesn't exist
PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql -h postgres -U "$POSTGRES_ADMIN_USER" -tc "SELECT 1 FROM pg_database WHERE datname = '$N8N_DB_NAME'" | grep -q 1 || \
PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql -h postgres -U "$POSTGRES_ADMIN_USER" -c "CREATE DATABASE $N8N_DB_NAME OWNER $N8N_DB_USER;"

# Grant necessary permissions
PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql -h postgres -U "$POSTGRES_ADMIN_USER" -c "GRANT ALL PRIVILEGES ON DATABASE $N8N_DB_NAME TO $N8N_DB_USER;"

echo "Database initialization completed successfully!"
echo "Database: $N8N_DB_NAME"
echo "User: $N8N_DB_USER"
echo "Connection string: postgresql://$N8N_DB_USER:***@postgres:5432/$N8N_DB_NAME"