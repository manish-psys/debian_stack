#!/bin/bash
###############################################################################
# 29-cinder-db-cleanup.sh
# Remove Cinder database and Keystone entities
# WARNING: This will delete all Cinder data!
###############################################################################

set -u

echo "=== Cleanup: Cinder Database and Keystone Entities ==="
echo ""
echo "WARNING: This will delete:"
echo "  - Cinder database and all volume metadata"
echo "  - Cinder Keystone user"
echo "  - Cinder service and endpoints"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Source admin credentials
if [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
fi

echo ""
echo "[1/3] Removing Keystone endpoints and service..."

# Delete endpoints
for ENDPOINT_ID in $(openstack endpoint list --service cinderv3 -f value -c ID 2>/dev/null); do
    echo "  Deleting endpoint $ENDPOINT_ID..."
    openstack endpoint delete "$ENDPOINT_ID" 2>/dev/null || true
done
echo "  ✓ Endpoints deleted"

# Delete service
if openstack service show cinderv3 &>/dev/null; then
    openstack service delete cinderv3
    echo "  ✓ Service 'cinderv3' deleted"
else
    echo "  ✓ Service 'cinderv3' not found (already deleted)"
fi

echo ""
echo "[2/3] Removing Keystone user..."
if openstack user show cinder &>/dev/null; then
    openstack user delete cinder
    echo "  ✓ User 'cinder' deleted"
else
    echo "  ✓ User 'cinder' not found (already deleted)"
fi

echo ""
echo "[3/3] Removing database..."
sudo mysql -u root <<EOF 2>/dev/null || true
DROP DATABASE IF EXISTS cinder;
DROP USER IF EXISTS 'cinder'@'localhost';
DROP USER IF EXISTS 'cinder'@'%';
FLUSH PRIVILEGES;
EOF
echo "  ✓ Database 'cinder' and user deleted"

echo ""
echo "=== Cinder DB Cleanup Complete ==="
echo ""
echo "Verify with:"
echo "  openstack service list"
echo "  openstack user list"
echo "  sudo mysql -u root -e \"SHOW DATABASES;\""
