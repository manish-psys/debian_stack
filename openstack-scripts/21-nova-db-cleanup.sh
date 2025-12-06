#!/bin/bash
###############################################################################
# 21-nova-db-cleanup.sh
# Remove Nova database and Keystone entities for clean re-testing
# Run this before re-running 21-nova-db.sh
###############################################################################

echo "=== Nova Database Cleanup (Script 21 only) ==="
echo ""
echo "This will remove:"
echo "  - Nova databases (nova_api, nova, nova_cell0)"
echo "  - Database user 'nova'"
echo "  - Keystone 'nova' user"
echo "  - Keystone 'nova' (compute) service"
echo "  - Keystone compute endpoints"
echo ""
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "[1/4] Removing Keystone endpoints and service..."
source ~/admin-openrc 2>/dev/null || true

# Delete endpoints first (they reference the service)
for ENDPOINT_ID in $(openstack endpoint list --service nova -f value -c ID 2>/dev/null); do
    openstack endpoint delete "$ENDPOINT_ID" 2>/dev/null || true
    echo "  ✓ Deleted endpoint $ENDPOINT_ID"
done

# Delete service
if openstack service show nova &>/dev/null; then
    openstack service delete nova
    echo "  ✓ Deleted 'nova' service"
else
    echo "  ✓ Service 'nova' not found (OK)"
fi

echo "[2/4] Removing Keystone user..."
if openstack user show nova &>/dev/null; then
    openstack user delete nova
    echo "  ✓ Deleted 'nova' user"
else
    echo "  ✓ User 'nova' not found (OK)"
fi

echo "[3/4] Removing databases..."
for DB in nova_api nova nova_cell0; do
    if sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB}'" 2>/dev/null | grep -q "${DB}"; then
        sudo mysql -e "DROP DATABASE ${DB};"
        echo "  ✓ Dropped database '${DB}'"
    else
        echo "  ✓ Database '${DB}' not found (OK)"
    fi
done

echo "[4/4] Removing database user..."
if sudo mysql -e "SELECT User FROM mysql.user WHERE User='nova'" 2>/dev/null | grep -q nova; then
    sudo mysql -e "DROP USER 'nova'@'localhost'; DROP USER 'nova'@'%';" 2>/dev/null || true
    sudo mysql -e "FLUSH PRIVILEGES;"
    echo "  ✓ Dropped database user 'nova'"
else
    echo "  ✓ Database user 'nova' not found (OK)"
fi

echo ""
echo "[Verification]"

CLEAN=true

# Check databases removed
for DB in nova_api nova nova_cell0; do
    if sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB}'" 2>/dev/null | grep -q "${DB}"; then
        echo "  ✗ WARNING: Database '${DB}' still exists"
        CLEAN=false
    else
        echo "  ✓ Database '${DB}' removed"
    fi
done

# Check user removed
if sudo mysql -e "SELECT User FROM mysql.user WHERE User='nova'" 2>/dev/null | grep -q nova; then
    echo "  ✗ WARNING: Database user 'nova' still exists"
    CLEAN=false
else
    echo "  ✓ Database user 'nova' removed"
fi

# Check Keystone user removed
source ~/admin-openrc 2>/dev/null || true
if openstack user show nova &>/dev/null 2>&1; then
    echo "  ✗ WARNING: Keystone user 'nova' still exists"
    CLEAN=false
else
    echo "  ✓ Keystone user 'nova' removed"
fi

# Check service removed
if openstack service show nova &>/dev/null 2>&1; then
    echo "  ✗ WARNING: Service 'nova' still exists"
    CLEAN=false
else
    echo "  ✓ Service 'nova' removed"
fi

echo ""
if [ "$CLEAN" = true ]; then
    echo "=== Cleanup complete ==="
    echo ""
    echo "You can now re-run: ./21-nova-db.sh"
else
    echo "=== Cleanup completed with warnings ==="
    echo "Check warnings above before re-running."
fi
