#!/bin/bash
###############################################################################
# 29-cinder-db.sh
# Create Cinder database and Keystone entities for Block Storage service
# Idempotent - safe to run multiple times
#
# Prerequisites:
#   - MariaDB running (script 13)
#   - Keystone configured (script 15-16)
#   - admin-openrc available
#
# This script creates:
#   - MySQL database 'cinder'
#   - MySQL user 'cinder'
#   - Keystone user 'cinder'
#   - Keystone service 'cinderv3' (volumev3)
#   - Keystone endpoints (public, internal, admin)
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
    exit 1
fi

echo "=== Step 29: Cinder Database and Keystone Setup ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo "Using Region: ${REGION_NAME}"
echo ""

# =============================================================================
# PART 1: Check Prerequisites
# =============================================================================
echo "[1/5] Checking prerequisites..."

# Check if MariaDB is running
if ! systemctl is-active --quiet mariadb; then
    echo "  ✗ ERROR: MariaDB is not running!"
    exit 1
fi
echo "  ✓ MariaDB is running"

# Check if Keystone is available
if [ ! -f ~/admin-openrc ]; then
    echo "  ✗ ERROR: admin-openrc not found!"
    echo "  Run Keystone setup scripts first."
    exit 1
fi
echo "  ✓ admin-openrc exists"

# Source admin credentials
source ~/admin-openrc

# Test Keystone connectivity
if ! /usr/bin/openstack token issue &>/dev/null; then
    echo "  ✗ ERROR: Cannot connect to Keystone!"
    exit 1
fi
echo "  ✓ Keystone is accessible"

# Check RabbitMQ
if ! systemctl is-active --quiet rabbitmq-server; then
    echo "  ✗ ERROR: RabbitMQ is not running!"
    exit 1
fi
echo "  ✓ RabbitMQ is running"

# =============================================================================
# PART 2: Create Cinder Database
# =============================================================================
echo ""
echo "[2/5] Creating Cinder database..."

# Use helper function from openstack-env.sh
create_service_database "cinder" "cinder" "${CINDER_DB_PASS}"

# Test database connection
echo "  Testing database connection..."
if mysql -u cinder -p"${CINDER_DB_PASS}" -e "SELECT 1;" cinder &>/dev/null; then
    echo "  ✓ Database connection successful"
else
    echo "  ✗ ERROR: Cannot connect to database as 'cinder' user!"
    exit 1
fi

# =============================================================================
# PART 3: Create Keystone User
# =============================================================================
echo ""
echo "[3/5] Creating Keystone user 'cinder'..."

# Check if user already exists
if /usr/bin/openstack user show cinder &>/dev/null; then
    echo "  ✓ User 'cinder' already exists"
else
    echo "  Creating user 'cinder'..."
    /usr/bin/openstack user create --domain default --password "${CINDER_PASS}" cinder
    echo "  ✓ User 'cinder' created"
fi

# Add admin role to cinder user
echo "  Adding 'admin' role to 'cinder' user..."
/usr/bin/openstack role add --project service --user cinder admin 2>/dev/null || true
echo "  ✓ Role 'admin' assigned to user 'cinder'"

# =============================================================================
# PART 4: Create Cinder Service and Endpoints
# =============================================================================
echo ""
echo "[4/5] Creating Cinder service and endpoints..."

# Cinder v3 API (volumev3) - this is the current standard
# Note: Cinder v2 is deprecated, we only create v3

# Check if service exists
if /usr/bin/openstack service show cinderv3 &>/dev/null; then
    echo "  ✓ Service 'cinderv3' already exists"
else
    echo "  Creating service 'cinderv3'..."
    /usr/bin/openstack service create --name cinderv3 \
        --description "OpenStack Block Storage v3" volumev3
    echo "  ✓ Service 'cinderv3' created"
fi

# Create endpoints
# Cinder v3 uses /v3/%(project_id)s path
CINDER_URL="http://${CONTROLLER_IP}:8776/v3/%(project_id)s"

EXISTING_ENDPOINTS=$(/usr/bin/openstack endpoint list --service cinderv3 -f value -c Interface 2>/dev/null || true)

for INTERFACE in public internal admin; do
    if echo "$EXISTING_ENDPOINTS" | /usr/bin/grep -q "^${INTERFACE}$"; then
        echo "  ✓ ${INTERFACE} endpoint already exists"
    else
        echo "  Creating ${INTERFACE} endpoint..."
        /usr/bin/openstack endpoint create --region "${REGION_NAME}" \
            volumev3 ${INTERFACE} "${CINDER_URL}"
        echo "  ✓ ${INTERFACE} endpoint created"
    fi
done

# =============================================================================
# PART 5: Verification
# =============================================================================
echo ""
echo "[5/5] Verifying Cinder setup..."

ERRORS=0

# Verify database
echo ""
echo "Database verification:"
TABLES=$(mysql -u cinder -p"${CINDER_DB_PASS}" -N -e "SHOW TABLES;" cinder 2>/dev/null | wc -l)
echo "  Tables in 'cinder' database: ${TABLES} (will be populated after db sync)"

# Verify Keystone user
echo ""
echo "Keystone user:"
/usr/bin/openstack user show cinder -f table -c name -c domain_id -c enabled 2>/dev/null || { echo "  ✗ User not found"; ERRORS=$((ERRORS+1)); }

# Verify service
echo ""
echo "Cinder service:"
/usr/bin/openstack service show cinderv3 -f table -c name -c type -c enabled 2>/dev/null || { echo "  ✗ Service not found"; ERRORS=$((ERRORS+1)); }

# Verify endpoints
echo ""
echo "Cinder endpoints:"
ENDPOINT_COUNT=$(/usr/bin/openstack endpoint list --service cinderv3 -f value 2>/dev/null | wc -l)
if [ "$ENDPOINT_COUNT" -ge 3 ]; then
    /usr/bin/openstack endpoint list --service cinderv3 -f table -c "Service Name" -c "Service Type" -c Interface -c URL
    echo "  ✓ All 3 endpoints registered"
else
    echo "  ✗ Expected 3 endpoints, found ${ENDPOINT_COUNT}"
    ERRORS=$((ERRORS+1))
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Cinder DB Setup Completed Successfully ==="
else
    echo "=== Cinder DB Setup Completed with $ERRORS Error(s) ==="
fi
echo "=========================================="
echo ""
echo "Configuration summary:"
echo "  Database: cinder"
echo "  DB User: cinder"
echo "  Keystone User: cinder"
echo "  Service: cinderv3 (volumev3)"
echo "  API Port: 8776"
echo ""
echo "Next: Run 30-cinder-install.sh"
