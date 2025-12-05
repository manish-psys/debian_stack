#!/bin/bash
###############################################################################
# 17-glance-db.sh
# Create Glance database and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
GLANCE_DB_PASS="glancepass123"    # Simple password (avoid special chars)
GLANCE_PASS="glancepass123"       # Keystone user password
IP_ADDRESS="192.168.2.9"

echo "=== Step 17: Glance Database and Keystone Setup ==="

# ============================================================================
# PART 1: Create Glance database
# ============================================================================
echo "[1/4] Creating Glance database..."

# Use sudo to access mysql as root (no password prompt needed)
sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '${GLANCE_DB_PASS}';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '${GLANCE_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "  ✓ Glance database created"

# ============================================================================
# PART 2: Load OpenStack credentials
# ============================================================================
echo "[2/4] Loading OpenStack credentials..."
source ~/admin-openrc
echo "  ✓ Credentials loaded"

# ============================================================================
# PART 3: Create service project (if not exists)
# ============================================================================
echo "[3/4] Creating service project..."

if openstack project show service &>/dev/null; then
    echo "  ✓ Service project already exists"
else
    openstack project create --domain default --description "Service Project" service
    echo "  ✓ Service project created"
fi

# ============================================================================
# PART 4: Create Glance Keystone entities
# ============================================================================
echo "[4/4] Creating Glance Keystone entities..."

# Create glance user (if not exists)
if openstack user show glance &>/dev/null; then
    echo "  ✓ Glance user already exists"
else
    openstack user create --domain default --password "${GLANCE_PASS}" glance
    echo "  ✓ Glance user created"
fi

# Add admin role to glance user in service project
openstack role add --project service --user glance admin 2>/dev/null || true
echo "  ✓ Admin role assigned to glance user"

# Create glance service (if not exists)
if openstack service show glance &>/dev/null; then
    echo "  ✓ Glance service already exists"
else
    openstack service create --name glance --description "OpenStack Image" image
    echo "  ✓ Glance service created"
fi

# Create endpoints (check if exists first)
EXISTING_ENDPOINTS=$(openstack endpoint list --service glance -f value -c Interface 2>/dev/null || true)

if echo "$EXISTING_ENDPOINTS" | grep -q "public"; then
    echo "  ✓ Public endpoint already exists"
else
    openstack endpoint create --region RegionOne image public "http://${IP_ADDRESS}:9292"
    echo "  ✓ Public endpoint created"
fi

if echo "$EXISTING_ENDPOINTS" | grep -q "internal"; then
    echo "  ✓ Internal endpoint already exists"
else
    openstack endpoint create --region RegionOne image internal "http://${IP_ADDRESS}:9292"
    echo "  ✓ Internal endpoint created"
fi

if echo "$EXISTING_ENDPOINTS" | grep -q "admin"; then
    echo "  ✓ Admin endpoint already exists"
else
    openstack endpoint create --region RegionOne image admin "http://${IP_ADDRESS}:9292"
    echo "  ✓ Admin endpoint created"
fi

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "Verifying setup..."

# Check database
if sudo mysql -e "SELECT 1 FROM mysql.user WHERE User='glance'" | grep -q 1; then
    echo "  ✓ Glance database user exists"
else
    echo "  ✗ Glance database user missing!"
fi

# Check Keystone entities
openstack user show glance -f value -c name &>/dev/null && echo "  ✓ Glance user verified"
openstack service show glance -f value -c name &>/dev/null && echo "  ✓ Glance service verified"

ENDPOINT_COUNT=$(openstack endpoint list --service glance -f value | wc -l)
echo "  ✓ Glance endpoints: ${ENDPOINT_COUNT}/3"

echo ""
echo "=== Glance database and Keystone entities created ==="
echo ""
echo "Credentials:"
echo "  DB User: glance"
echo "  DB Password: ${GLANCE_DB_PASS}"
echo "  Keystone User: glance"
echo "  Keystone Password: ${GLANCE_PASS}"
echo ""
echo "IMPORTANT: Save these passwords securely!"
echo "Next: Run 18-glance-install.sh"
