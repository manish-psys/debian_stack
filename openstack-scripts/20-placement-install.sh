#!/bin/bash
###############################################################################
# 20-placement-install.sh
# Install and configure Placement service
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

echo "=== Step 20: Placement Installation ==="
echo "Using Region: ${REGION_NAME}"
echo "Using Controller: ${CONTROLLER_IP}"

# ============================================================================
# PART 0: Check prerequisites
# ============================================================================
echo "[0/6] Checking prerequisites..."

if ! command -v crudini &> /dev/null; then
    sudo apt install -y crudini
fi
echo "  ✓ crudini available"

# Check database is ready
if sudo mysql -e "SELECT 1 FROM mysql.user WHERE User='placement'" 2>/dev/null | grep -q 1; then
    echo "  ✓ Placement database user exists"
else
    echo "  ✗ ERROR: Placement database not ready. Run 19-placement-db.sh first!"
    exit 1
fi

# Check Keystone service exists
source ~/admin-openrc
if openstack service show placement &>/dev/null; then
    echo "  ✓ Placement service registered in Keystone"
else
    echo "  ✗ ERROR: Placement service not in Keystone. Run 19-placement-db.sh first!"
    exit 1
fi

# ============================================================================
# PART 1: Pre-seed dbconfig-common
# ============================================================================
echo "[1/6] Configuring dbconfig-common..."

sudo mkdir -p /etc/dbconfig-common
cat <<EOF | sudo tee /etc/dbconfig-common/placement-api.conf > /dev/null
dbc_install='false'
dbc_upgrade='false'
dbc_remove=''
dbc_dbtype='mysql'
dbc_dbuser='placement'
dbc_dbpass='${PLACEMENT_DB_PASS}'
dbc_dbserver='localhost'
dbc_dbname='placement'
EOF

echo "placement-api placement/dbconfig-install boolean false" | sudo debconf-set-selections

echo "  ✓ dbconfig-common configured"

# ============================================================================
# PART 2: Install Placement package
# ============================================================================
echo "[2/6] Installing Placement..."

export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get -t bullseye-wallaby-backports install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    placement-api

echo "  ✓ Placement packages installed"

# ============================================================================
# PART 3: Configure Placement
# ============================================================================
echo "[3/6] Configuring Placement..."

# Backup original config (only if not already backed up)
if [ -f /etc/placement/placement.conf ] && [ ! -f /etc/placement/placement.conf.orig ]; then
    sudo cp /etc/placement/placement.conf /etc/placement/placement.conf.orig
    echo "  ✓ Original config backed up"
fi

# Database connection
sudo crudini --set /etc/placement/placement.conf placement_database connection \
    "mysql+pymysql://placement:${PLACEMENT_DB_PASS}@localhost/placement"

# API auth strategy
sudo crudini --set /etc/placement/placement.conf api auth_strategy "keystone"

# Keystone authentication - using helper function from openstack-env.sh
configure_keystone_authtoken /etc/placement/placement.conf placement "$PLACEMENT_PASS"

# Verify config was written
if sudo grep -q "^connection = mysql" /etc/placement/placement.conf; then
    echo "  ✓ Database connection configured"
else
    echo "  ✗ ERROR: Database connection not set!"
    exit 1
fi

echo "  ✓ Placement configured"

# ============================================================================
# PART 4: Sync database
# ============================================================================
echo "[4/6] Syncing Placement database..."

# db sync is idempotent - safe to run multiple times
if sudo -u placement placement-manage db sync 2>&1; then
    echo "  ✓ Database synced"
else
    echo "  ✗ ERROR: Database sync failed!"
    echo "  Check database connection and credentials"
    exit 1
fi

# ============================================================================
# PART 5: Restart Apache
# ============================================================================
echo "[5/6] Restarting Apache..."

sudo systemctl restart apache2
sudo systemctl enable apache2

echo "  ✓ Apache restarted"

# ============================================================================
# PART 6: Wait and verify service is ready
# ============================================================================
echo "[6/6] Waiting for Placement service to be ready..."

# Wait for Apache to fully start and Placement to respond
MAX_RETRIES=10
RETRY_INTERVAL=2
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if sudo ss -tlnp | grep -q ':8778'; then
        # Port is listening, now check if API responds
        if curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8778/" 2>/dev/null | grep -q "200\|300\|401"; then
            echo "  ✓ Placement service is ready"
            break
        fi
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for Placement... (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep $RETRY_INTERVAL
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "  ⚠ WARNING: Placement may not be fully ready yet"
fi

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "Verifying Placement installation..."

ERRORS=0

# Check Apache is running
if systemctl is-active --quiet apache2; then
    echo "  ✓ Apache is running"
else
    echo "  ✗ Apache is NOT running!"
    ERRORS=$((ERRORS + 1))
fi

# Check Placement port is listening (via Apache)
if sudo ss -tlnp | grep -q ':8778'; then
    echo "  ✓ Placement is listening on port 8778"
else
    echo "  ✗ Placement is NOT listening on port 8778!"
    ERRORS=$((ERRORS + 1))
fi

# Check package is properly installed
if dpkg -l placement-api 2>/dev/null | grep -q "^ii"; then
    echo "  ✓ Placement package is properly installed"
else
    echo "  ✗ Placement package has issues!"
    ERRORS=$((ERRORS + 1))
fi

# Verify region configuration
CONFIGURED_REGION=$(sudo crudini --get /etc/placement/placement.conf keystone_authtoken region_name 2>/dev/null || echo "NOT SET")
if [ "$CONFIGURED_REGION" = "$REGION_NAME" ]; then
    echo "  ✓ Region correctly set to: $CONFIGURED_REGION"
else
    echo "  ✗ Region mismatch! Expected: $REGION_NAME, Got: $CONFIGURED_REGION"
    ERRORS=$((ERRORS + 1))
fi

# Test Placement API
source ~/admin-openrc
if openstack --os-placement-api-version 1.2 resource class list &>/dev/null; then
    echo "  ✓ Placement API responding"
    echo ""
    echo "Sample resource classes:"
    openstack --os-placement-api-version 1.2 resource class list --sort-column name | head -10
else
    echo "  ✗ Placement API not responding!"
    echo "  Check logs: sudo tail -50 /var/log/apache2/placement-api_error.log"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=== Placement installed successfully ==="
else
    echo "=== Placement installation completed with $ERRORS error(s) ==="
    echo "Check Apache logs: sudo tail -50 /var/log/apache2/error.log"
fi

echo ""
echo "Next: Run 21-nova-db.sh"
