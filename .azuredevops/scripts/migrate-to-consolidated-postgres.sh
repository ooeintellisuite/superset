#!/bin/bash
set -euo pipefail

echo "=== PostgreSQL Consolidation Migration Script ==="
echo "This script migrates Superset metadata from superset_db to oee-postgres"
echo ""

# Configuration
OLD_DB_CONTAINER="superset_db"
NEW_DB_CONTAINER="oee-postgres"
NEW_DB_NAME="superset_meta"
BACKUP_DIR="/tmp/superset-backup"

echo "Step 1: Stopping Superset services to prevent connections..."
docker compose -f .azuredevops/docker-compose-deploy.yml --project-name azuredevops stop superset_app superset_init
echo "✓ Superset services stopped"

echo ""
echo "Step 2: Creating dedicated database in oee-postgres..."

# Check if database already exists
DB_EXISTS=$(docker exec "$NEW_DB_CONTAINER" psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$NEW_DB_NAME'" 2>/dev/null || echo "")

if [ "$DB_EXISTS" = "1" ]; then
    echo "⚠ Database $NEW_DB_NAME already exists - dropping and recreating..."
    docker exec "$NEW_DB_CONTAINER" psql -U postgres -c "DROP DATABASE $NEW_DB_NAME;"
fi

docker exec "$NEW_DB_CONTAINER" psql -U postgres -c "CREATE DATABASE $NEW_DB_NAME;"
echo "✓ Database $NEW_DB_NAME created"

echo ""
echo "Creating backup directory..."
mkdir -p "$BACKUP_DIR"
echo "✓ Backup directory created"

echo ""
echo "Step 3: Dumping data from superset_db..."
docker exec "$OLD_DB_CONTAINER" pg_dump -U superset superset > "$BACKUP_DIR"/migration_dump.sql
echo "✓ Data dumped from superset_db"

echo ""
echo "Step 4: Restoring data to oee-postgres:$NEW_DB_NAME..."
docker exec -i "$NEW_DB_CONTAINER" psql -U postgres -d "$NEW_DB_NAME" < "$BACKUP_DIR"/migration_dump.sql
echo "✓ Data restored to $NEW_DB_NAME"

echo ""
echo "Step 5: Verifying migration..."
TABLE_COUNT=$(docker exec "$NEW_DB_CONTAINER" psql -U postgres -d "$NEW_DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';")
echo "✓ Migration complete - $TABLE_COUNT tables migrated"

echo ""
echo "=== Migration Complete ==="
echo "Next step: Update docker-compose configuration and restart services"
