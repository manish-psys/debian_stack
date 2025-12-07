#!/bin/bash
###############################################################################
# 24-neutron-db.sh
# Create Neutron database and Keystone entities
# Idempotent - safe to run multiple times
#
# This script creates:
# - MySQL database: neutron
# - MySQL user: neutron
# - Keystone user: neutron
# - Keystone service: network
# - Keystone endpoints: public, internal, admin
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

echo "=== Step 24: Neutron Database and Keystone Setup ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo "Using Region: ${REGION_NAME}"

# ============================================================================
# PART 1: Check prerequisites
# ============================================================================
echo ""
echo "[1/5] Checking prerequisites..."

# Check MariaDB is running
if ! systemctl is-active --quiet mariadb; then
    echo "  ✗ ERROR: MariaDB is not running!"
    exit 1
fi
echo "  ✓ MariaDB is running"

# Check Keystone is accessible
if [ ! -f ~/admin-openrc ]; then
    echo "  ✗ ERROR: ~/admin-openrc not found!"
    exit 1
fi
source ~/admin-openrc

if ! openstack token issue &>/dev/null; then
    echo "  ✗ ERROR: Cannot authenticate with Keystone!"
    exit 1
fi
echo "  ✓ Keystone authentication working"

# Check Nova is installed (Neutron integrates with Nova)
if ! openstack service show nova &>/dev/null; then
    echo "  ✗ ERROR: Nova service not found. Run Nova scripts first!"
    exit 1
fi
echo "  ✓ Nova service exists"

# ============================================================================
# PART 2: Create Neutron database
# ============================================================================
echo ""
echo "[2/5] Creating Neutron database..."

# Check if database exists
DB_EXISTS=$(sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='neutron'" 2>/dev/null | grep -c "neutron" || echo "0")

if [ "$DB_EXISTS" -eq 0 ]; then
    sudo mysql <<EOF
CREATE DATABASE neutron;
EOF
    echo "  ✓ Database 'neutron' created"
else
    echo "  ✓ Database 'neutron' already exists"
fi

# Create or update user (idempotent)
sudo mysql <<EOF
CREATE USER IF NOT EXISTS 'neutron'@'localhost' IDENTIFIED BY '${NEUTRON_DB_PASS}';
CREATE USER IF NOT EXISTS 'neutron'@'%' IDENTIFIED BY '${NEUTRON_DB_PASS}';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%';
ALTER USER 'neutron'@'localhost' IDENTIFIED BY '${NEUTRON_DB_PASS}';
ALTER USER 'neutron'@'%' IDENTIFIED BY '${NEUTRON_DB_PASS}';
FLUSH PRIVILEGES;
EOF
echo "  ✓ Database user 'neutron' configured"

# ============================================================================
# PART 3: Create Keystone user
# ============================================================================
echo ""
echo "[3/5] Creating Keystone user..."

if openstack user show neutron &>/dev/null; then
    echo "  ✓ Keystone user 'neutron' already exists"
    # Update password to ensure it matches
    openstack user set --password "${NEUTRON_PASS}" neutron
    echo "  ✓ Keystone user 'neutron' password updated"
else
    openstack user create --domain default --password "${NEUTRON_PASS}" neutron
    echo "  ✓ Keystone user 'neutron' created"
fi

# Add admin role (idempotent - won't fail if already exists)
openstack role add --project service --user neutron admin 2>/dev/null || true
echo "  ✓ Admin role assigned to 'neutron' user"

# ============================================================================
# PART 4: Create Keystone service and endpoints
# ============================================================================
echo ""
echo "[4/5] Creating Keystone service and endpoints..."

# Create service if not exists
if openstack service show network &>/dev/null; then
    echo "  ✓ Network service already exists"
else
    openstack service create --name neutron --description "OpenStack Networking" network
    echo "  ✓ Network service created"
fi

# Create endpoints (delete and recreate to ensure correct URLs)
for INTERFACE in public internal admin; do
    EXISTING=$(openstack endpoint list --service network --interface ${INTERFACE} --region ${REGION_NAME} -f value -c ID 2>/dev/null || true)
    if [ -n "$EXISTING" ]; then
        echo "  ✓ Network ${INTERFACE} endpoint already exists"
    else
        openstack endpoint create --region ${REGION_NAME} network ${INTERFACE} "http://${CONTROLLER_IP}:9696"
        echo "  ✓ Network ${INTERFACE} endpoint created"
    fi
done

# ============================================================================
# PART 5: Verification
# ============================================================================
echo ""
echo "[5/5] Verifying setup..."

ERRORS=0

# Verify database
if sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='neutron'" 2>/dev/null | grep -q "neutron"; then
    echo "  ✓ Database 'neutron' exists"
else
    echo "  ✗ Database 'neutron' NOT found!"
    ERRORS=$((ERRORS + 1))
fi

# Verify database user can connect
if mysql -u neutron -p"${NEUTRON_DB_PASS}" -e "SELECT 1" neutron &>/dev/null; then
    echo "  ✓ Database user 'neutron' can connect"
else
    echo "  ✗ Database user 'neutron' cannot connect!"
    ERRORS=$((ERRORS + 1))
fi

# Verify Keystone user
if openstack user show neutron &>/dev/null; then
    echo "  ✓ Keystone user 'neutron' exists"
else
    echo "  ✗ Keystone user 'neutron' NOT found!"
    ERRORS=$((ERRORS + 1))
fi

# Verify service
if openstack service show network &>/dev/null; then
    echo "  ✓ Network service registered"
else
    echo "  ✗ Network service NOT found!"
    ERRORS=$((ERRORS + 1))
fi

# Verify endpoints
ENDPOINT_COUNT=$(openstack endpoint list --service network -f value -c ID 2>/dev/null | wc -l)
if [ "$ENDPOINT_COUNT" -ge 3 ]; then
    echo "  ✓ Network endpoints configured (${ENDPOINT_COUNT} endpoints)"
else
    echo "  ✗ Network endpoints incomplete (only ${ENDPOINT_COUNT} found)!"
    ERRORS=$((ERRORS + 1))
fi

# Show summary
echo ""
echo "Neutron Endpoints:"
openstack endpoint list --service network -f table

# Final summary
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Neutron database setup complete ==="
    echo "=========================================="
    echo ""
    echo "Database: neutron"
    echo "DB User:  neutron"
    echo "DB Pass:  ${NEUTRON_DB_PASS}"
    echo ""
    echo "Keystone User: neutron"
    echo "Keystone Pass: ${NEUTRON_PASS}"
    echo ""
    echo "Service:  network (neutron)"
    echo "API Port: 9696"
    echo ""
    echo "Next: Run 25-neutron-install.sh"
else
    echo "=== Setup completed with $ERRORS error(s) ==="
    echo "=========================================="
    echo "Please check the errors above."
    exit 1
fi
