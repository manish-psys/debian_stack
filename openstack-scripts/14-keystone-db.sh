#!/bin/bash
###############################################################################
# 14-keystone-db.sh
# Create Keystone database and user (Idempotent - safe to re-run)
#
# This script:
# - Uses the centralized openstack-env.sh configuration
# - Creates Keystone database and user non-interactively
# - Uses the helper function for consistent database creation
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 14: Keystone Database Setup ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"
echo ""

# ============================================================================
# Create Keystone database and user using helper function
# ============================================================================
echo "[1/2] Creating Keystone database and user..."

# Use the helper function from openstack-env.sh
# This is idempotent and non-interactive (uses unix_socket auth for root)
create_service_database "keystone" "keystone" "${KEYSTONE_DB_PASS}"

# ============================================================================
# Verify database creation
# ============================================================================
echo "[2/2] Verifying database setup..."

ERRORS=0

# Check database exists
if sudo mysql -e "USE keystone;" &>/dev/null; then
    echo "  ✓ Database 'keystone' exists"
else
    echo "  ✗ Database 'keystone' not found!"
    ERRORS=$((ERRORS + 1))
fi

# Check user can connect
if mysql -u keystone -p"${KEYSTONE_DB_PASS}" -h localhost -e "SELECT 1;" &>/dev/null 2>&1; then
    echo "  ✓ User 'keystone' can connect from localhost"
else
    echo "  ✗ User 'keystone' cannot connect!"
    ERRORS=$((ERRORS + 1))
fi

# Verify grants
GRANTS=$(sudo mysql -e "SHOW GRANTS FOR 'keystone'@'localhost';" 2>/dev/null | grep -c "keystone" || echo "0")
if [ "$GRANTS" -gt 0 ]; then
    echo "  ✓ User 'keystone' has privileges on 'keystone' database"
else
    echo "  ✗ User 'keystone' missing privileges!"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=========================================="
    echo "=== ✓ Keystone database setup complete ==="
    echo "=========================================="
    echo ""
    echo "Database Configuration:"
    echo "  Database: keystone"
    echo "  User: keystone"
    echo "  Password: ${KEYSTONE_DB_PASS}"
    echo "  Connection: mysql+pymysql://keystone:${KEYSTONE_DB_PASS}@${CONTROLLER_IP}/keystone"
    echo ""
    echo "Next: Run 15-keystone-install.sh"
    echo "      (or 15-keystone-cleanup.sh first if re-installing)"
else
    echo "=== Database setup completed with $ERRORS error(s) ==="
    exit 1
fi
