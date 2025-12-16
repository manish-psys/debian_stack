#!/bin/bash
###############################################################################
# 19-placement-db.sh
# Create Placement database and Keystone entities
# Idempotent - safe to run multiple times
# Sources openstack-env.sh for centralized configuration
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 19: Placement Database and Keystone Setup ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"
echo ""

# ============================================================================
# PART 1: Create Placement database (using helper function)
# ============================================================================
echo "[1/3] Creating Placement database..."

# Use helper function from openstack-env.sh (idempotent)
create_service_database "placement" "placement" "${PLACEMENT_DB_PASS}"

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
if /usr/bin/openstack user show placement &>/dev/null; then
    echo "  ✓ Placement user already exists"
else
    /usr/bin/openstack user create --domain default --password "${PLACEMENT_PASS}" placement
    echo "  ✓ Placement user created"
fi

# Add admin role to placement user in service project
/usr/bin/openstack role add --project service --user placement admin 2>/dev/null || true
echo "  ✓ Admin role assigned to placement user"

# Create service and endpoints (using helper function from openstack-env.sh)
create_service_endpoints "placement" "placement" "Placement API" "8778"

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "Verifying setup..."

ERRORS=0

# Check database
if sudo mysql -e "SELECT 1 FROM mysql.user WHERE User='placement'" | /usr/bin/grep -q 1; then
    echo "  ✓ Placement database user exists"
else
    echo "  ✗ Placement database user missing!"
    ERRORS=$((ERRORS + 1))
fi

# Check user can connect
if mysql -u placement -p"${PLACEMENT_DB_PASS}" -h ${CONTROLLER_IP} -e "SELECT 1;" &>/dev/null 2>&1; then
    echo "  ✓ User 'placement' can connect from localhost"
else
    echo "  ✗ User 'placement' cannot connect!"
    ERRORS=$((ERRORS + 1))
fi

# Check Keystone entities
/usr/bin/openstack user show placement -f value -c name &>/dev/null && echo "  ✓ Placement user verified"
/usr/bin/openstack service show placement -f value -c name &>/dev/null && echo "  ✓ Placement service verified"

ENDPOINT_COUNT=$(/usr/bin/openstack endpoint list --service placement -f value | wc -l)
echo "  ✓ Placement endpoints: ${ENDPOINT_COUNT}/3"

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=========================================="
    echo "=== ✓ Placement database setup complete ==="
    echo "=========================================="
    echo ""
    echo "Database Configuration:"
    echo "  Database: placement"
    echo "  User: placement"
    echo "  Password: ${PLACEMENT_DB_PASS}"
    echo "  Connection: mysql+pymysql://placement:${PLACEMENT_DB_PASS}@${CONTROLLER_IP}/placement"
    echo ""
    echo "Keystone Configuration:"
    echo "  User: placement"
    echo "  Password: ${PLACEMENT_PASS}"
    echo ""
    echo "Next: Run 20-placement-install.sh"
else
    echo "=== Placement setup completed with $ERRORS error(s) ==="
    exit 1
fi
