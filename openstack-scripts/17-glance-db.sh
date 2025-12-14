#!/bin/bash
###############################################################################
# 17-glance-db.sh
# Create Glance database and Keystone entities
# Sources openstack-env.sh for centralized configuration
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 17: Glance Database and Keystone Setup ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"
echo ""

# ============================================================================
# PART 1: Create Glance database (using helper function)
# ============================================================================
echo "[1/4] Creating Glance database..."

# Use helper function from openstack-env.sh (idempotent)
create_service_database "glance" "glance" "${GLANCE_DB_PASS}"

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

# Create endpoints (using helper function from openstack-env.sh)
create_service_endpoints "glance" "image" "OpenStack Image" "9292"

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
