#!/bin/bash
###############################################################################
# 19-placement-db.sh
# Create Placement database and Keystone entities
# Idempotent - safe to run multiple times
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Source shared environment
# =============================================================================
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found in ${SCRIPT_DIR}"
    echo "Please ensure openstack-env.sh is in the same directory as this script."
    exit 1
fi

echo "=== Step 19: Placement Database and Keystone Setup ==="

# ============================================================================
# PART 1: Create Placement database
# ============================================================================
echo "[1/3] Creating Placement database..."

sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS placement;
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost' IDENTIFIED BY '${PLACEMENT_DB_PASS}';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%' IDENTIFIED BY '${PLACEMENT_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "  ✓ Placement database created"

# ============================================================================
# PART 2: Load OpenStack credentials
# ============================================================================
echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc
echo "  ✓ Credentials loaded"

# ============================================================================
# PART 3: Create Placement Keystone entities
# ============================================================================
echo "[3/3] Creating Placement Keystone entities..."

# Create placement user (if not exists)
if openstack user show placement &>/dev/null; then
    echo "  ✓ Placement user already exists"
else
    openstack user create --domain default --password "${PLACEMENT_PASS}" placement
    echo "  ✓ Placement user created"
fi

# Add admin role to placement user in service project
openstack role add --project service --user placement admin 2>/dev/null || true
echo "  ✓ Admin role assigned to placement user"

# Create placement service (if not exists)
if openstack service show placement &>/dev/null; then
    echo "  ✓ Placement service already exists"
else
    openstack service create --name placement --description "Placement API" placement
    echo "  ✓ Placement service created"
fi

# Create endpoints (check if exists first)
EXISTING_ENDPOINTS=$(openstack endpoint list --service placement -f value -c Interface 2>/dev/null || true)

if echo "$EXISTING_ENDPOINTS" | grep -q "public"; then
    echo "  ✓ Public endpoint already exists"
else
    openstack endpoint create --region "${REGION_NAME}" placement public "http://${CONTROLLER_IP}:8778"
    echo "  ✓ Public endpoint created"
fi

if echo "$EXISTING_ENDPOINTS" | grep -q "internal"; then
    echo "  ✓ Internal endpoint already exists"
else
    openstack endpoint create --region "${REGION_NAME}" placement internal "http://${CONTROLLER_IP}:8778"
    echo "  ✓ Internal endpoint created"
fi

if echo "$EXISTING_ENDPOINTS" | grep -q "admin"; then
    echo "  ✓ Admin endpoint already exists"
else
    openstack endpoint create --region "${REGION_NAME}" placement admin "http://${CONTROLLER_IP}:8778"
    echo "  ✓ Admin endpoint created"
fi

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "Verifying setup..."

# Check database
if sudo mysql -e "SELECT 1 FROM mysql.user WHERE User='placement'" | grep -q 1; then
    echo "  ✓ Placement database user exists"
else
    echo "  ✗ Placement database user missing!"
fi

# Check Keystone entities
openstack user show placement -f value -c name &>/dev/null && echo "  ✓ Placement user verified"
openstack service show placement -f value -c name &>/dev/null && echo "  ✓ Placement service verified"

ENDPOINT_COUNT=$(openstack endpoint list --service placement -f value | wc -l)
echo "  ✓ Placement endpoints: ${ENDPOINT_COUNT}/3"

echo ""
echo "=== Placement database and Keystone entities created ==="
echo ""
echo "Credentials:"
echo "  DB User: placement"
echo "  DB Password: ${PLACEMENT_DB_PASS}"
echo "  Keystone User: placement"
echo "  Keystone Password: ${PLACEMENT_PASS}"
echo ""
echo "Next: Run 20-placement-install.sh"
