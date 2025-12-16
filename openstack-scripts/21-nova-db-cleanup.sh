#!/bin/bash
###############################################################################
# 21-nova-db-cleanup.sh
# Remove Nova database and Keystone entities for clean re-testing
# Run this before re-running 21-nova-db.sh
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

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

# Source credentials if available
if [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
fi

# Delete endpoints first (they reference the service)
if /usr/bin/openstack --version &>/dev/null && [ -n "$OS_AUTH_URL" ]; then
    for ENDPOINT_ID in $(/usr/bin/openstack endpoint list --service nova -f value -c ID 2>/dev/null); do
        /usr/bin/openstack endpoint delete "$ENDPOINT_ID" 2>/dev/null || true
        echo "  ✓ Deleted endpoint $ENDPOINT_ID"
    done

    # Delete service
    if /usr/bin/openstack service show nova &>/dev/null; then
        /usr/bin/openstack service delete nova
        echo "  ✓ Deleted 'nova' service"
    else
        echo "  ✓ Service 'nova' not found (OK)"
    fi
else
    echo "  ⚠ OpenStack CLI not available, skipping Keystone cleanup"
fi

echo "[2/4] Removing Keystone user..."
if /usr/bin/openstack --version &>/dev/null && [ -n "$OS_AUTH_URL" ]; then
    if /usr/bin/openstack user show nova &>/dev/null; then
        /usr/bin/openstack user delete nova
        echo "  ✓ Deleted 'nova' user"
    else
        echo "  ✓ User 'nova' not found (OK)"
    fi
else
    echo "  ⚠ OpenStack CLI not available, skipping user cleanup"
fi

echo "[3/4] Removing databases..."
for DB in nova_api nova nova_cell0; do
    if sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB}'" 2>/dev/null | /usr/bin/grep -q "${DB}"; then
        sudo mysql -e "DROP DATABASE ${DB};"
        echo "  ✓ Dropped database '${DB}'"
    else
        echo "  ✓ Database '${DB}' not found (OK)"
    fi
done

echo "[4/4] Removing database user..."
if sudo mysql -e "SELECT User FROM mysql.user WHERE User='nova'" 2>/dev/null | /usr/bin/grep -q nova; then
    sudo mysql -e "DROP USER IF EXISTS 'nova'@'localhost';"
    sudo mysql -e "DROP USER IF EXISTS 'nova'@'%';"
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
    if sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB}'" 2>/dev/null | /usr/bin/grep -q "${DB}"; then
        echo "  ✗ WARNING: Database '${DB}' still exists"
        CLEAN=false
    else
        echo "  ✓ Database '${DB}' removed"
    fi
done

# Check user removed
if sudo mysql -e "SELECT User FROM mysql.user WHERE User='nova'" 2>/dev/null | /usr/bin/grep -q nova; then
    echo "  ✗ WARNING: Database user 'nova' still exists"
    CLEAN=false
else
    echo "  ✓ Database user 'nova' removed"
fi

# Check Keystone items if CLI available
if /usr/bin/openstack --version &>/dev/null && [ -n "$OS_AUTH_URL" ]; then
    # Check Keystone user removed
    if /usr/bin/openstack user show nova &>/dev/null 2>&1; then
        echo "  ✗ WARNING: Keystone user 'nova' still exists"
        CLEAN=false
    else
        echo "  ✓ Keystone user 'nova' removed"
    fi

    # Check service removed
    if /usr/bin/openstack service show nova &>/dev/null 2>&1; then
        echo "  ✗ WARNING: Service 'nova' still exists"
        CLEAN=false
    else
        echo "  ✓ Service 'nova' removed"
    fi
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
