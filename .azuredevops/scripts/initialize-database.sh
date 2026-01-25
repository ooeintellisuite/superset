#!/bin/bash
set -euo pipefail

echo "=== Superset Database Initialization ==="
echo "This script handles both brownfield (migration) and greenfield (fresh) deployments"
echo ""

# Configuration
OLD_DB_CONTAINER="superset_db"
NEW_DB_CONTAINER="oee-postgres"
NEW_DB_NAME="superset_meta"
BACKUP_DIR="/tmp/superset-backup"

# ===================================================================
# Step 1: Ensure superset_meta database exists (all scenarios)
# ===================================================================
echo "Step 1: Ensuring $NEW_DB_NAME database exists in $NEW_DB_CONTAINER..."

DB_EXISTS=$(docker exec "$NEW_DB_CONTAINER" psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$NEW_DB_NAME'" 2>/dev/null || echo "")

if [ "$DB_EXISTS" = "1" ]; then
    echo "✓ Database $NEW_DB_NAME already exists"
else
    echo "Creating database $NEW_DB_NAME..."
    docker exec "$NEW_DB_CONTAINER" psql -U postgres -c "CREATE DATABASE $NEW_DB_NAME;"
    echo "✓ Database $NEW_DB_NAME created"
fi

echo ""

# ===================================================================
# Step 2: Check if this is brownfield (old database exists) or greenfield
# ===================================================================
echo "Step 2: Checking for existing superset_db container..."

if docker ps --format '{{.Names}}' | grep -q "^${OLD_DB_CONTAINER}$"; then
    echo "⚠ Brownfield deployment detected: $OLD_DB_CONTAINER container exists"
    echo "Starting data migration..."
    echo ""

    # ===================================================================
    # BROWNSFIELD: Migrate existing data
    # ===================================================================

    echo "Step 3a: Stopping Superset services to prevent connections..."
    docker compose -f .azuredevops/docker-compose-deploy.yml --project-name azuredevops stop superset_app superset_init 2>/dev/null || echo "Services not running"
    echo "✓ Superset services stopped"

    echo ""
    echo "Step 4a: Creating backup directory..."
    mkdir -p "$BACKUP_DIR"
    echo "✓ Backup directory created"

    echo ""
    echo "Step 5a: Dumping data from $OLD_DB_CONTAINER..."
    docker exec "$OLD_DB_CONTAINER" pg_dump -U superset superset > "$BACKUP_DIR/migration_dump.sql"
    echo "✓ Data dumped from $OLD_DB_CONTAINER"

    echo ""
    echo "Step 6a: Restoring data to $NEW_DB_CONTAINER:$NEW_DB_NAME..."
    docker exec -i "$NEW_DB_CONTAINER" psql -U postgres -d "$NEW_DB_NAME" < "$BACKUP_DIR/migration_dump.sql"
    echo "✓ Data restored to $NEW_DB_NAME"

    echo ""
    echo "Step 7a: Verifying migration..."
    TABLE_COUNT=$(docker exec "$NEW_DB_CONTAINER" psql -U postgres -d "$NEW_DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';")
    TABLE_COUNT=$(echo "$TABLE_COUNT" | xargs)
    echo "✓ Migration complete - $TABLE_COUNT tables migrated"

    echo ""
    echo "⚠ NOTE: Old $OLD_DB_CONTAINER container will be removed during deployment"

else
    # ===================================================================
    # GREENFIELD: Fresh deployment, no migration needed
    # ===================================================================

    echo "✓ Greenfield deployment detected: no existing database to migrate"
    echo ""
    echo "Step 3b: Skipping data migration (fresh environment)"
    echo "Database $NEW_DB_NAME is ready for Superset initialization"
    echo ""
    echo "✓ Superset will create its tables on first startup"
fi

echo ""
echo "=== Database Initialization Complete ==="
echo "Next: Deployment will start Superset services"
