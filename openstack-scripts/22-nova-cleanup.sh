#!/bin/bash
###############################################################################
# 22-nova-cleanup.sh
# Remove Nova installation for clean re-testing
# Run this before re-running 22-nova-install.sh
#
# NOTE: This does NOT touch Script 21 items (databases, Keystone user/service)
#       Only cleans up what Script 22 installs
###############################################################################

echo "=== Nova Installation Cleanup (Script 22 only) ==="
echo ""
echo "This will remove:"
echo "  - Nova packages (nova-api, nova-conductor, nova-scheduler, etc.)"
echo "  - /etc/nova/ directory"
echo "  - Nova database TABLES (not the databases themselves)"
echo "  - dbconfig-common configuration"
echo ""
echo "This will NOT remove (managed by Script 21):"
echo "  - Keystone 'nova' user"
echo "  - Keystone 'nova' service"
echo "  - Keystone endpoints"
echo "  - MySQL databases (nova_api, nova, nova_cell0)"
echo "  - MySQL 'nova' user"
echo ""
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "[1/5] Stopping Nova services..."
for SERVICE in nova-api nova-conductor nova-scheduler nova-novncproxy nova-compute; do
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        sudo systemctl stop "$SERVICE"
        sudo systemctl disable "$SERVICE" 2>/dev/null || true
        echo "  ✓ Stopped $SERVICE"
    fi
done
echo "  ✓ All Nova services stopped"

echo "[2/5] Removing Nova packages..."
NOVA_PACKAGES="nova-api nova-conductor nova-scheduler nova-novncproxy nova-compute nova-common python3-nova"
if dpkg -l nova-api 2>/dev/null | grep -q "^ii"; then
    sudo apt-get remove --purge -y $NOVA_PACKAGES 2>/dev/null || true
    sudo apt-get autoremove -y 2>/dev/null || true
    echo "  ✓ Nova packages removed"
else
    echo "  ✓ Nova packages not installed"
fi

echo "[3/5] Removing configuration files..."
if [ -d /etc/nova ]; then
    sudo rm -rf /etc/nova
    echo "  ✓ /etc/nova removed"
else
    echo "  ✓ /etc/nova not present"
fi

# Remove dbconfig-common configs
for CONF in nova-api.conf nova-common.conf; do
    if [ -f /etc/dbconfig-common/$CONF ]; then
        sudo rm -f /etc/dbconfig-common/$CONF
        echo "  ✓ dbconfig-common/$CONF removed"
    fi
done

# Remove log directory
if [ -d /var/log/nova ]; then
    sudo rm -rf /var/log/nova
    echo "  ✓ /var/log/nova removed"
fi

# Remove lib directory
if [ -d /var/lib/nova ]; then
    sudo rm -rf /var/lib/nova
    echo "  ✓ /var/lib/nova removed"
fi

echo "[4/5] Clearing database tables..."
# Drop all tables but keep the databases (Script 21 created them)

for DB in nova_api nova nova_cell0; do
    if sudo mysql -e "USE ${DB}" 2>/dev/null; then
        TABLE_COUNT=$(sudo mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB}';" 2>/dev/null || echo "0")
        if [ "$TABLE_COUNT" -gt 0 ]; then
            # Drop ALL tables in a SINGLE session with FK checks disabled
            sudo mysql ${DB} <<'EOF'
SET FOREIGN_KEY_CHECKS=0;
SET @tables = NULL;
SELECT GROUP_CONCAT('`', table_name, '`') INTO @tables
  FROM information_schema.tables
  WHERE table_schema = DATABASE();
SET @tables = IFNULL(CONCAT('DROP TABLE IF EXISTS ', @tables), 'SELECT 1');
PREPARE stmt FROM @tables;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
SET FOREIGN_KEY_CHECKS=1;
EOF
            echo "  ✓ Tables dropped from '${DB}'"
        else
            echo "  ✓ No tables in '${DB}'"
        fi
    else
        echo "  ✓ Database '${DB}' not accessible (OK)"
    fi
done

echo "[5/5] Verifying cleanup..."

CLEAN=true

# Check packages removed
if dpkg -l nova-api 2>/dev/null | grep -q "^ii"; then
    echo "  ✗ WARNING: nova-api package still installed"
    CLEAN=false
else
    echo "  ✓ Nova packages removed"
fi

# Check config removed
if [ -d /etc/nova ]; then
    echo "  ✗ WARNING: /etc/nova still exists"
    CLEAN=false
else
    echo "  ✓ /etc/nova removed"
fi

# Check ports are free
for PORT in 8774 6080; do
    if sudo ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
        echo "  ✗ WARNING: Port ${PORT} still in use"
        CLEAN=false
    else
        echo "  ✓ Port ${PORT} is free"
    fi
done

# Check database tables cleared
for DB in nova_api nova nova_cell0; do
    TABLE_COUNT=$(sudo mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB}';" 2>/dev/null || echo "0")
    if [ "$TABLE_COUNT" -gt 0 ]; then
        echo "  ✗ WARNING: ${TABLE_COUNT} tables still exist in '${DB}'"
        CLEAN=false
    else
        echo "  ✓ Database '${DB}' is empty (ready for sync)"
    fi
done

echo ""
if [ "$CLEAN" = true ]; then
    echo "=== Cleanup complete ==="
    echo ""
    echo "You can now re-run: ./22-nova-install.sh"
else
    echo "=== Cleanup completed with warnings ==="
    echo "Check warnings above before re-running installation."
fi
