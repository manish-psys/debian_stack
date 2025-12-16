#!/bin/bash
###############################################################################
# 20-placement-install.sh
# Install and configure Placement service
# Idempotent - safe to run multiple times
#
# For Debian 13 (Trixie) with native OpenStack packages
# Placement version: placement-api (OpenStack 2024.1 Caracal)
#
# Key notes:
# - Debian placement-api uses uwsgi (not Apache mod_wsgi)
# - Stop service before config, sync DB, then restart
# - Verify database tables exist after sync
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 20: Placement Installation ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"
echo ""

# ============================================================================
# PART 0: Check prerequisites
# ============================================================================
echo "[0/7] Checking prerequisites..."

# Check crudini using absolute path (avoid PATH issues in different contexts)
if [ ! -x /usr/bin/crudini ]; then
    sudo apt-get install -y crudini
fi
echo "  ✓ crudini available"

# Check database is ready
if sudo mysql -e "SELECT 1 FROM mysql.user WHERE User='placement'" 2>/dev/null | /usr/bin/grep -q 1; then
    echo "  ✓ Placement database user exists"
else
    echo "  ✗ ERROR: Placement database not ready. Run 19-placement-db.sh first!"
    exit 1
fi

# Check Keystone service exists
source ~/admin-openrc
if /usr/bin/openstack service show placement &>/dev/null; then
    echo "  ✓ Placement service registered in Keystone"
else
    echo "  ✗ ERROR: Placement service not in Keystone. Run 19-placement-db.sh first!"
    exit 1
fi

# ============================================================================
# PART 1: Pre-seed dbconfig-common
# ============================================================================
echo "[1/7] Configuring dbconfig-common..."

sudo mkdir -p /etc/dbconfig-common
cat <<EOF | sudo tee /etc/dbconfig-common/placement-api.conf > /dev/null
dbc_install='false'
dbc_upgrade='false'
dbc_remove=''
dbc_dbtype='mysql'
dbc_dbuser='placement'
dbc_dbpass='${PLACEMENT_DB_PASS}'
dbc_dbserver='${CONTROLLER_IP}'
dbc_dbname='placement'
EOF

echo "placement-api placement/dbconfig-install boolean false" | sudo debconf-set-selections

echo "  ✓ dbconfig-common configured"

# ============================================================================
# PART 2: Install Placement package
# ============================================================================
echo "[2/7] Installing Placement..."

export DEBIAN_FRONTEND=noninteractive

# Debian Trixie has Placement in main repositories - no backports needed
# Package: placement-api (OpenStack 2024.1 Caracal)
sudo -E apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    placement-api

echo "  ✓ Placement packages installed"

# Display installed version
PLACEMENT_VERSION=$(dpkg -l placement-api | grep "^ii" | awk '{print $3}')
echo "  Installed version: placement-api ${PLACEMENT_VERSION}"

# ============================================================================
# PART 3: Stop placement-api service before configuration
# ============================================================================
echo "[3/7] Stopping placement-api service for configuration..."

# Debian's placement-api uses uwsgi via systemd, NOT Apache
# The package may auto-start with incomplete config, so we stop it first
if systemctl is-active --quiet placement-api; then
    sudo systemctl stop placement-api
    echo "  ✓ placement-api service stopped"
else
    echo "  ✓ placement-api service not running (OK)"
fi

# ============================================================================
# PART 4: Configure Placement
# ============================================================================
echo "[4/7] Configuring Placement..."

# Backup original config (only if not already backed up)
if [ -f /etc/placement/placement.conf ] && [ ! -f /etc/placement/placement.conf.orig ]; then
    sudo cp /etc/placement/placement.conf /etc/placement/placement.conf.orig
    echo "  ✓ Original config backed up"
fi

# Database connection - NOTE: section is 'placement_database' for Placement
# Use CONTROLLER_IP for consistency
sudo crudini --set /etc/placement/placement.conf placement_database connection \
    "mysql+pymysql://placement:${PLACEMENT_DB_PASS}@${CONTROLLER_IP}/placement"

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

if sudo grep -q "^region_name = ${REGION_NAME}" /etc/placement/placement.conf; then
    echo "  ✓ Region configured: ${REGION_NAME}"
else
    echo "  ✗ ERROR: Region not set correctly!"
    exit 1
fi

echo "  ✓ Placement configured"

# ============================================================================
# PART 5: Sync database (MUST happen before service starts)
# ============================================================================
echo "[5/7] Syncing Placement database..."

# db sync is idempotent - safe to run multiple times
# Run as root since placement user may not have shell access
if sudo placement-manage db sync 2>&1; then
    echo "  ✓ Database sync command completed"
else
    echo "  ✗ ERROR: Database sync failed!"
    echo "  Check database connection and credentials"
    exit 1
fi

# CRITICAL: Verify tables actually exist
TABLE_COUNT=$(sudo mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='placement';" 2>/dev/null || echo "0")
if [ "$TABLE_COUNT" -ge 10 ]; then
    echo "  ✓ Database tables created: ${TABLE_COUNT} tables"
else
    echo "  ✗ ERROR: Database sync did not create tables! Found: ${TABLE_COUNT}"
    echo "  Expected at least 10 tables (traits, resource_classes, allocations, etc.)"
    exit 1
fi

# Verify critical tables exist
for TABLE in traits resource_classes resource_providers allocations; do
    if sudo mysql -N -e "SELECT 1 FROM information_schema.tables WHERE table_schema='placement' AND table_name='${TABLE}';" 2>/dev/null | /usr/bin/grep -q 1; then
        echo "  ✓ Table exists: ${TABLE}"
    else
        echo "  ✗ ERROR: Missing table: ${TABLE}"
        exit 1
    fi
done

# ============================================================================
# PART 6: Start placement-api service
# ============================================================================
echo "[6/7] Starting placement-api service..."

# Debian's placement-api runs via uwsgi (NOT Apache)
sudo systemctl start placement-api
sudo systemctl enable placement-api

echo "  ✓ placement-api service started"

# Wait for service to be ready
MAX_RETRIES=15
RETRY_INTERVAL=2
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if sudo ss -tlnp | grep -q ':8778'; then
        # Port is listening, now check if API responds
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8778/" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" =~ ^(200|300|401)$ ]]; then
            echo "  ✓ Placement API responding (HTTP ${HTTP_CODE})"
            break
        elif [ "$HTTP_CODE" = "500" ]; then
            echo "  ✗ ERROR: Placement returning HTTP 500 - check logs!"
            sudo journalctl -u placement-api -n 20 --no-pager
            exit 1
        fi
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for Placement... (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep $RETRY_INTERVAL
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "  ✗ ERROR: Placement service did not become ready!"
    echo "  Checking logs..."
    sudo journalctl -u placement-api -n 30 --no-pager
    exit 1
fi

# ============================================================================
# PART 7: Verification
# ============================================================================
echo "[7/7] Verifying Placement installation..."
echo ""

ERRORS=0

# Check placement-api service is running (uwsgi-based)
if systemctl is-active --quiet placement-api; then
    echo "  ✓ placement-api service is running"
else
    echo "  ✗ placement-api service is NOT running!"
    ERRORS=$((ERRORS + 1))
fi

# Check Placement port is listening
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

# Test Placement API via OpenStack CLI
source ~/admin-openrc
if /usr/bin/openstack --os-placement-api-version 1.2 resource class list &>/dev/null; then
    echo "  ✓ Placement API responding to OpenStack CLI"

    # Count resource classes
    RC_COUNT=$(/usr/bin/openstack --os-placement-api-version 1.2 resource class list -f value | wc -l)
    echo "  ✓ Resource classes available: ${RC_COUNT}"

    # Show sample
    echo ""
    echo "Sample resource classes:"
    /usr/bin/openstack --os-placement-api-version 1.2 resource class list --sort-column name | head -10
else
    echo "  ✗ Placement API not responding to OpenStack CLI!"
    echo "  Check logs: sudo journalctl -u placement-api -n 50"
    ERRORS=$((ERRORS + 1))
fi

# Final summary
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Placement installed successfully ==="
    echo "=========================================="
    echo ""
    echo "Service: placement-api (uwsgi on port 8778)"
    echo "Config:  /etc/placement/placement.conf"
    echo "Logs:    sudo journalctl -u placement-api -f"
    echo ""
    echo "Quick test commands:"
    echo "  curl http://${CONTROLLER_IP}:8778/"
    echo "  openstack --os-placement-api-version 1.2 resource class list"
    echo "  openstack --os-placement-api-version 1.6 trait list"
else
    echo "=== Placement installation completed with $ERRORS error(s) ==="
    echo "=========================================="
    echo "Check logs: sudo journalctl -u placement-api -n 50"
fi

echo ""
echo "Next: Run 21-nova-db.sh"
