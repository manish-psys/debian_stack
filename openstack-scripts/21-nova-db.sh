#!/bin/bash
###############################################################################
# 21-nova-db.sh
# Create Nova databases and Keystone entities
# Idempotent - safe to run multiple times
#
# Nova requires 3 databases:
# - nova_api: API database (cell mappings, instance mappings)
# - nova: Main compute database (instances, flavors, etc.)
# - nova_cell0: Special cell for instances that failed to schedule
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

echo "=== Step 21: Nova Database and Keystone Setup ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo "Using Region: ${REGION_NAME}"

# ============================================================================
# PART 0: Check prerequisites
# ============================================================================
echo ""
echo "[0/4] Checking prerequisites..."

# Check MariaDB is running
if ! systemctl is-active --quiet mariadb; then
    echo "  ✗ ERROR: MariaDB is not running!"
    exit 1
fi
echo "  ✓ MariaDB is running"

# Check admin-openrc exists
if [ ! -f ~/admin-openrc ]; then
    echo "  ✗ ERROR: ~/admin-openrc not found. Run Keystone scripts first!"
    exit 1
fi

# Source OpenStack credentials
source ~/admin-openrc

# Verify openstack CLI is available
if ! /usr/bin/openstack --version &>/dev/null; then
    echo "  ✗ ERROR: openstack command not found!"
    exit 1
fi
echo "  ✓ OpenStack CLI available"

# Test Keystone authentication
if ! /usr/bin/openstack token issue &>/dev/null; then
    echo "  ✗ ERROR: Cannot authenticate with Keystone!"
    exit 1
fi
echo "  ✓ Keystone authentication working"

# Check Placement is ready (Nova depends on Placement)
if ! /usr/bin/openstack service show placement &>/dev/null; then
    echo "  ✗ ERROR: Placement service not found. Run scripts 19-20 first!"
    exit 1
fi
echo "  ✓ Placement service exists"

# Check 'service' project exists
if ! /usr/bin/openstack project show service &>/dev/null; then
    echo "  ✗ ERROR: 'service' project not found. Run Glance scripts first!"
    exit 1
fi
echo "  ✓ Service project exists"

# ============================================================================
# PART 1: Create Nova databases
# ============================================================================
echo ""
echo "[1/4] Creating Nova databases..."

# Create nova_api database
if sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='nova_api'" 2>/dev/null | /usr/bin/grep -q nova_api; then
    echo "  ✓ Database 'nova_api' already exists"
else
    sudo mysql -e "CREATE DATABASE nova_api CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    echo "  ✓ Database 'nova_api' created"
fi

# Create nova database
if sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='nova'" 2>/dev/null | /usr/bin/grep -q nova; then
    echo "  ✓ Database 'nova' already exists"
else
    sudo mysql -e "CREATE DATABASE nova CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    echo "  ✓ Database 'nova' created"
fi

# Create nova_cell0 database
if sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='nova_cell0'" 2>/dev/null | /usr/bin/grep -q nova_cell0; then
    echo "  ✓ Database 'nova_cell0' already exists"
else
    sudo mysql -e "CREATE DATABASE nova_cell0 CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    echo "  ✓ Database 'nova_cell0' created"
fi

# ============================================================================
# PART 2: Create/update database user with grants
# ============================================================================
echo ""
echo "[2/4] Configuring database user..."

# Create or update nova user with all grants
sudo mysql <<EOF
-- Create user if not exists, update password if exists
CREATE USER IF NOT EXISTS 'nova'@'localhost' IDENTIFIED BY '${NOVA_DB_PASS}';
CREATE USER IF NOT EXISTS 'nova'@'%' IDENTIFIED BY '${NOVA_DB_PASS}';

-- Update password (in case user existed with different password)
ALTER USER 'nova'@'localhost' IDENTIFIED BY '${NOVA_DB_PASS}';
ALTER USER 'nova'@'%' IDENTIFIED BY '${NOVA_DB_PASS}';

-- Grant privileges on all Nova databases
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%';

FLUSH PRIVILEGES;
EOF

echo "  ✓ Database user 'nova' configured with grants"

# Verify database access
if mysql -u nova -p"${NOVA_DB_PASS}" -e "SELECT 1" &>/dev/null; then
    echo "  ✓ Database user 'nova' can authenticate"
else
    echo "  ✗ ERROR: Database user authentication failed!"
    exit 1
fi

# ============================================================================
# PART 3: Create Keystone user and role assignment
# ============================================================================
echo ""
echo "[3/4] Creating Keystone user..."

# Ensure credentials are loaded
source ~/admin-openrc

# Create nova user if not exists
if /usr/bin/openstack user show nova &>/dev/null; then
    echo "  ✓ User 'nova' already exists"
    # Update password to ensure it matches
    /usr/bin/openstack user set --password "${NOVA_PASS}" nova
    echo "  ✓ User 'nova' password updated"
else
    /usr/bin/openstack user create --domain default --password "${NOVA_PASS}" nova
    echo "  ✓ User 'nova' created"
fi

# Assign admin role to nova user in service project
if /usr/bin/openstack role assignment list --user nova --project service --role admin -f value | /usr/bin/grep -q admin; then
    echo "  ✓ Admin role already assigned to 'nova' user"
else
    /usr/bin/openstack role add --project service --user nova admin
    echo "  ✓ Admin role assigned to 'nova' user"
fi

# Verify user
if /usr/bin/openstack user show nova -f value -c name | /usr/bin/grep -q nova; then
    echo "  ✓ User 'nova' verified in Keystone"
else
    echo "  ✗ ERROR: User verification failed!"
    exit 1
fi

# ============================================================================
# PART 4: Create compute service and endpoints
# ============================================================================
echo ""
echo "[4/4] Creating compute service and endpoints..."

# Ensure credentials are loaded
source ~/admin-openrc

# Nova API endpoint URL (includes /v2.1 path)
NOVA_ENDPOINT="http://${CONTROLLER_IP}:8774/v2.1"

# Create compute service if not exists
if /usr/bin/openstack service show nova &>/dev/null; then
    echo "  ✓ Service 'nova' already exists"
else
    /usr/bin/openstack service create --name nova --description "OpenStack Compute" compute
    echo "  ✓ Service 'nova' created"
fi

# Get existing endpoints for nova service
EXISTING_ENDPOINTS=$(/usr/bin/openstack endpoint list --service nova -f value -c Interface 2>/dev/null || true)

# Create public endpoint if not exists
if echo "$EXISTING_ENDPOINTS" | /usr/bin/grep -q "public"; then
    echo "  ✓ Public endpoint already exists"
else
    /usr/bin/openstack endpoint create --region "${REGION_NAME}" compute public "${NOVA_ENDPOINT}"
    echo "  ✓ Public endpoint created"
fi

# Create internal endpoint if not exists
if echo "$EXISTING_ENDPOINTS" | /usr/bin/grep -q "internal"; then
    echo "  ✓ Internal endpoint already exists"
else
    /usr/bin/openstack endpoint create --region "${REGION_NAME}" compute internal "${NOVA_ENDPOINT}"
    echo "  ✓ Internal endpoint created"
fi

# Create admin endpoint if not exists
if echo "$EXISTING_ENDPOINTS" | /usr/bin/grep -q "admin"; then
    echo "  ✓ Admin endpoint already exists"
else
    /usr/bin/openstack endpoint create --region "${REGION_NAME}" compute admin "${NOVA_ENDPOINT}"
    echo "  ✓ Admin endpoint created"
fi

# ============================================================================
# Verification Summary
# ============================================================================
echo ""
echo "=========================================="
echo "Verifying Nova database and Keystone setup..."
echo "=========================================="
echo ""

ERRORS=0

# Check databases exist
for DB in nova_api nova nova_cell0; do
    if sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB}'" 2>/dev/null | /usr/bin/grep -q "${DB}"; then
        echo "  ✓ Database '${DB}' exists"
    else
        echo "  ✗ Database '${DB}' missing!"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check database user
if sudo mysql -e "SELECT User FROM mysql.user WHERE User='nova'" 2>/dev/null | /usr/bin/grep -q nova; then
    echo "  ✓ Database user 'nova' exists"
else
    echo "  ✗ Database user 'nova' missing!"
    ERRORS=$((ERRORS + 1))
fi

# Check Keystone user
if /usr/bin/openstack user show nova &>/dev/null; then
    echo "  ✓ Keystone user 'nova' exists"
else
    echo "  ✗ Keystone user 'nova' missing!"
    ERRORS=$((ERRORS + 1))
fi

# Check service
if /usr/bin/openstack service show nova &>/dev/null; then
    echo "  ✓ Compute service 'nova' exists"
else
    echo "  ✗ Compute service 'nova' missing!"
    ERRORS=$((ERRORS + 1))
fi

# Check endpoints
ENDPOINT_COUNT=$(/usr/bin/openstack endpoint list --service nova -f value 2>/dev/null | wc -l)
if [ "$ENDPOINT_COUNT" -ge 3 ]; then
    echo "  ✓ Endpoints configured: ${ENDPOINT_COUNT}/3"
else
    echo "  ✗ Missing endpoints! Found: ${ENDPOINT_COUNT}/3"
    ERRORS=$((ERRORS + 1))
fi

# Show endpoints
echo ""
echo "Nova Endpoints:"
/usr/bin/openstack endpoint list --service nova -f table

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=========================================="
    echo "=== Nova database setup complete ==="
    echo "=========================================="
    echo ""
    echo "Databases: nova_api, nova, nova_cell0"
    echo "DB User: nova"
    echo "DB Password: ${NOVA_DB_PASS}"
    echo "Keystone User: nova"
    echo "Keystone Password: ${NOVA_PASS}"
    echo ""
    echo "Next: Run 22-nova-install.sh"
else
    echo "=========================================="
    echo "=== Setup completed with $ERRORS error(s) ==="
    echo "=========================================="
    exit 1
fi
