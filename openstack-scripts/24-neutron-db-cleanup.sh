#!/bin/bash
###############################################################################
# 24-neutron-db-cleanup.sh
# Remove Neutron database and Keystone entities
# Use this to cleanly re-run 24-neutron-db.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared environment
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
fi

echo "=== Neutron Database Cleanup (Script 24) ==="
echo ""
echo "This will remove:"
echo "  - Keystone 'neutron' user"
echo "  - Keystone 'network' service and endpoints"
echo "  - MySQL 'neutron' database"
echo "  - MySQL 'neutron' user"
echo ""
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "[1/3] Removing Keystone entities..."
source ~/admin-openrc 2>/dev/null || true

# Remove endpoints
for ENDPOINT_ID in $(openstack endpoint list --service network -f value -c ID 2>/dev/null); do
    openstack endpoint delete "$ENDPOINT_ID" 2>/dev/null || true
    echo "  ✓ Endpoint $ENDPOINT_ID deleted"
done

# Remove service
if openstack service show network &>/dev/null; then
    openstack service delete network 2>/dev/null || true
    echo "  ✓ Network service deleted"
else
    echo "  ✓ Network service not present"
fi

# Remove user
if openstack user show neutron &>/dev/null; then
    openstack user delete neutron 2>/dev/null || true
    echo "  ✓ Keystone user 'neutron' deleted"
else
    echo "  ✓ Keystone user 'neutron' not present"
fi

echo ""
echo "[2/3] Removing MySQL database and user..."
sudo mysql <<EOF 2>/dev/null || true
DROP DATABASE IF EXISTS neutron;
DROP USER IF EXISTS 'neutron'@'localhost';
DROP USER IF EXISTS 'neutron'@'%';
FLUSH PRIVILEGES;
EOF
echo "  ✓ Database 'neutron' dropped"
echo "  ✓ Database user 'neutron' dropped"

echo ""
echo "[3/3] Verifying cleanup..."

# Verify database removed
if ! sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='neutron'" 2>/dev/null | grep -q "neutron"; then
    echo "  ✓ Database 'neutron' removed"
else
    echo "  ✗ Database 'neutron' still exists!"
fi

# Verify user removed
if ! openstack user show neutron &>/dev/null 2>&1; then
    echo "  ✓ Keystone user 'neutron' removed"
else
    echo "  ✗ Keystone user 'neutron' still exists!"
fi

# Verify service removed
if ! openstack service show network &>/dev/null 2>&1; then
    echo "  ✓ Network service removed"
else
    echo "  ✗ Network service still exists!"
fi

echo ""
echo "=== Cleanup complete ==="
echo "You can now re-run: ./24-neutron-db.sh"
