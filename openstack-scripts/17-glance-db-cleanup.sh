#!/bin/bash
###############################################################################
# 17-glance-db-cleanup.sh
# Clean up Glance database and Keystone entities
# Run this ONLY if script 17 failed and you need to start fresh
#
# This script:
# - Removes Glance endpoints from Keystone
# - Removes Glance service from Keystone
# - Removes Glance user from Keystone
# - Drops Glance database and database user
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 17: Glance Database and Keystone Cleanup ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"
echo ""
echo "WARNING: This will remove:"
echo "  - Glance endpoints (public, internal, admin)"
echo "  - Glance service"
echo "  - Glance Keystone user"
echo "  - Glance database and database user"
echo ""
read -p "Continue? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

# ============================================================================
# PART 1: Load OpenStack credentials
# ============================================================================
echo "[1/4] Loading OpenStack credentials..."
if [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
    echo "  ✓ Credentials loaded"
else
    echo "  ✗ ERROR: admin-openrc not found!"
    echo "  Cannot clean up Keystone entities without credentials"
    exit 1
fi

# ============================================================================
# PART 2: Remove Glance endpoints
# ============================================================================
echo "[2/4] Removing Glance endpoints..."

ENDPOINT_COUNT=$(/usr/bin/openstack endpoint list --service glance -f value -c ID 2>/dev/null | wc -l)
if [ "$ENDPOINT_COUNT" -gt 0 ]; then
    /usr/bin/openstack endpoint list --service glance -f value -c ID | while read ENDPOINT_ID; do
        /usr/bin/openstack endpoint delete "$ENDPOINT_ID" 2>/dev/null || true
    done
    echo "  ✓ Removed $ENDPOINT_COUNT Glance endpoint(s)"
else
    echo "  ✓ No Glance endpoints to remove"
fi

# ============================================================================
# PART 3: Remove Glance service and user
# ============================================================================
echo "[3/4] Removing Glance service and user..."

# Remove service
if /usr/bin/openstack service show glance &>/dev/null; then
    /usr/bin/openstack service delete glance
    echo "  ✓ Glance service removed"
else
    echo "  ✓ Glance service already removed"
fi

# Remove user
if /usr/bin/openstack user show glance &>/dev/null; then
    /usr/bin/openstack user delete glance
    echo "  ✓ Glance user removed"
else
    echo "  ✓ Glance user already removed"
fi

# ============================================================================
# PART 4: Drop Glance database and users
# ============================================================================
echo "[4/4] Dropping Glance database and users..."

sudo mysql <<EOF
DROP DATABASE IF EXISTS glance;
DROP USER IF EXISTS 'glance'@'localhost';
DROP USER IF EXISTS 'glance'@'%';
FLUSH PRIVILEGES;
EOF

echo "  ✓ Glance database and users dropped"

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "Verifying cleanup..."

ERRORS=0

# Check service removed
if /usr/bin/openstack service show glance &>/dev/null; then
    echo "  ✗ Glance service still exists!"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ Glance service removed"
fi

# Check user removed
if /usr/bin/openstack user show glance &>/dev/null; then
    echo "  ✗ Glance user still exists!"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ Glance user removed"
fi

# Check endpoints removed
REMAINING_ENDPOINTS=$(/usr/bin/openstack endpoint list --service glance -f value -c ID 2>/dev/null | wc -l)
if [ "$REMAINING_ENDPOINTS" -gt 0 ]; then
    echo "  ✗ $REMAINING_ENDPOINTS Glance endpoint(s) still exist!"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ All Glance endpoints removed"
fi

# Check database dropped
if sudo mysql -e "USE glance;" &>/dev/null; then
    echo "  ✗ Glance database still exists!"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ Glance database dropped"
fi

# Check database user removed
DB_USER_COUNT=$(sudo mysql -e "SELECT COUNT(*) FROM mysql.user WHERE User='glance';" -N 2>/dev/null || echo "0")
if [ "$DB_USER_COUNT" != "0" ]; then
    echo "  ✗ Glance database user(s) still exist!"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ Glance database users removed"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=========================================="
    echo "=== ✓ Cleanup completed successfully ==="
    echo "=========================================="
    echo ""
    echo "You can now re-run: ./17-glance-db.sh"
else
    echo "=========================================="
    echo "=== ⚠ Cleanup completed with $ERRORS error(s) ==="
    echo "=========================================="
    echo ""
    echo "Some items may still exist. Review errors above."
    exit 1
fi
