#!/bin/bash
###############################################################################
# 20-placement-cleanup.sh
# Remove Placement installation for clean re-testing
# Run this before re-running 20-placement-install.sh
#
# NOTE: This does NOT touch Script 19 items (Keystone user/service/endpoints)
#       Only cleans up what Script 20 installs
###############################################################################

echo "=== Placement Cleanup (Script 20 only) ==="
echo ""
echo "This will remove:"
echo "  - placement-api package"
echo "  - /etc/placement/ directory"
echo "  - Placement database TABLES (not the database itself)"
echo "  - dbconfig-common configuration"
echo ""
echo "This will NOT remove (managed by Script 19):"
echo "  - Keystone 'placement' user"
echo "  - Keystone 'placement' service"
echo "  - Keystone endpoints"
echo "  - MySQL 'placement' database and user"
echo ""
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "[1/5] Stopping placement-api service..."
if systemctl is-active --quiet placement-api 2>/dev/null; then
    sudo systemctl stop placement-api
    sudo systemctl disable placement-api 2>/dev/null || true
    echo "  ✓ placement-api stopped"
else
    echo "  ✓ placement-api not running"
fi

echo "[2/5] Removing placement packages..."
if dpkg -l placement-api 2>/dev/null | grep -q "^ii"; then
    sudo apt-get remove --purge -y placement-api placement-common python3-placement 2>/dev/null || true
    sudo apt-get autoremove -y 2>/dev/null || true
    echo "  ✓ Packages removed"
else
    echo "  ✓ Packages not installed"
fi

echo "[3/5] Removing configuration files..."
if [ -d /etc/placement ]; then
    sudo rm -rf /etc/placement
    echo "  ✓ /etc/placement removed"
else
    echo "  ✓ /etc/placement not present"
fi

# Remove dbconfig-common config
if [ -f /etc/dbconfig-common/placement-api.conf ]; then
    sudo rm -f /etc/dbconfig-common/placement-api.conf
    echo "  ✓ dbconfig-common config removed"
fi

# Remove log directory
if [ -d /var/log/placement ]; then
    sudo rm -rf /var/log/placement
    echo "  ✓ /var/log/placement removed"
fi

# Remove lib directory
if [ -d /var/lib/placement ]; then
    sudo rm -rf /var/lib/placement
    echo "  ✓ /var/lib/placement removed"
fi

echo "[4/5] Clearing placement database tables..."
# Drop all tables but keep the database (Script 19 created the DB)
if sudo mysql -e "USE placement" 2>/dev/null; then
    # Check if there are tables to drop
    TABLE_COUNT=$(sudo mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='placement';" 2>/dev/null || echo "0")
    if [ "$TABLE_COUNT" -gt 0 ]; then
        # Drop ALL tables in a SINGLE session with FK checks disabled
        # This avoids the issue where each mysql -e runs in separate session
        sudo mysql placement <<'EOF'
SET FOREIGN_KEY_CHECKS=0;
DROP TABLE IF EXISTS alembic_version;
DROP TABLE IF EXISTS allocations;
DROP TABLE IF EXISTS consumers;
DROP TABLE IF EXISTS inventories;
DROP TABLE IF EXISTS placement_aggregates;
DROP TABLE IF EXISTS projects;
DROP TABLE IF EXISTS resource_classes;
DROP TABLE IF EXISTS resource_provider_aggregates;
DROP TABLE IF EXISTS resource_provider_traits;
DROP TABLE IF EXISTS resource_providers;
DROP TABLE IF EXISTS traits;
DROP TABLE IF EXISTS users;
SET FOREIGN_KEY_CHECKS=1;
EOF
        echo "  ✓ All tables dropped from placement database"
    else
        echo "  ✓ No tables to drop"
    fi
else
    echo "  ✓ placement database not accessible (OK if Script 19 not run)"
fi

echo "[5/5] Verifying cleanup..."

CLEAN=true

if dpkg -l placement-api 2>/dev/null | grep -q "^ii"; then
    echo "  ✗ WARNING: placement-api package still installed"
    CLEAN=false
else
    echo "  ✓ placement-api package removed"
fi

if [ -d /etc/placement ]; then
    echo "  ✗ WARNING: /etc/placement still exists"
    CLEAN=false
else
    echo "  ✓ /etc/placement removed"
fi

if sudo ss -tlnp 2>/dev/null | grep -q ':8778'; then
    echo "  ✗ WARNING: Something still listening on port 8778"
    CLEAN=false
else
    echo "  ✓ Port 8778 is free"
fi

TABLE_COUNT=$(sudo mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='placement';" 2>/dev/null || echo "0")
if [ "$TABLE_COUNT" -gt 0 ]; then
    echo "  ✗ WARNING: $TABLE_COUNT tables still exist in placement database"
    CLEAN=false
else
    echo "  ✓ placement database is empty (ready for db sync)"
fi

echo ""
if [ "$CLEAN" = true ]; then
    echo "=== Cleanup complete ==="
    echo ""
    echo "You can now re-run: ./20-placement-install.sh"
else
    echo "=== Cleanup completed with warnings ==="
    echo "Check warnings above before re-running installation."
fi
