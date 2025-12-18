#!/bin/bash
###############################################################################
# 26-neutron-cleanup.sh
# Remove Neutron packages and configuration (for re-testing installation)
# Use this ONLY for testing purposes - to verify script 26 works correctly
#
# This script:
# - Stops Neutron services
# - Purges Neutron packages
# - Removes Neutron configuration files
# - Clears Neutron database tables (but keeps database and user)
# - Does NOT touch OVS/OVN (those should remain from script 25)
#
# NOTE: This does NOT remove:
# - Neutron database (managed by Script 24)
# - Keystone user/service/endpoints (managed by Script 24)
# - OVS bridge (managed by Script 25)
# - OVN services (managed by Script 25)
#
# After running this, you can re-run 26-neutron-install.sh to test the fix
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

echo "=== Neutron Cleanup (for re-testing script 26) ==="
echo ""
echo "This will remove:"
echo "  - Neutron packages (server, ml2, ovn-metadata-agent)"
echo "  - /etc/neutron/ directory"
echo "  - Neutron database TABLES (not the database itself)"
echo ""
echo "This will NOT remove:"
echo "  - Keystone 'neutron' user (Script 24)"
echo "  - Network service/endpoints (Script 24)"
echo "  - MySQL 'neutron' database (Script 24)"
echo "  - OVS/OVN installation (Script 25)"
echo ""
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

PROVIDER_BRIDGE="${PROVIDER_BRIDGE_NAME:-br-provider}"

# =============================================================================
# PART 1: Ensure provider bridge connectivity BEFORE doing anything
# =============================================================================
echo ""
echo "[1/5] Ensuring provider bridge connectivity..."

# CRITICAL: Add NORMAL flow rule before we do anything that might disrupt network
# This prevents network loss during cleanup operations
if sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE} 2>/dev/null; then
    sudo ovs-vsctl remove bridge ${PROVIDER_BRIDGE} fail_mode secure 2>/dev/null || true
    sudo ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL" 2>/dev/null || true
    echo "  ✓ Provider bridge protected"
else
    echo "  ⚠ Provider bridge ${PROVIDER_BRIDGE} not found (skipping protection)"
fi

# =============================================================================
# PART 2: Stop Neutron services
# =============================================================================
echo ""
echo "[2/5] Stopping Neutron services..."

# OVN-based services (current architecture)
NEUTRON_SERVICES=(
    "neutron-server"
    "neutron-api"
    "neutron-rpc-server"
    "neutron-ovn-metadata-agent"
)

# Legacy services (in case they were installed from older script versions)
LEGACY_SERVICES=(
    "neutron-openvswitch-agent"
    "neutron-dhcp-agent"
    "neutron-metadata-agent"
    "neutron-l3-agent"
    "neutron-linuxbridge-agent"
)

for SERVICE in "${NEUTRON_SERVICES[@]}" "${LEGACY_SERVICES[@]}"; do
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        sudo systemctl stop "$SERVICE"
        sudo systemctl disable "$SERVICE" 2>/dev/null || true
        echo "  ✓ Stopped $SERVICE"
    fi
done
echo "  ✓ Services stopped"

# Re-ensure connectivity after stopping services
if sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE} 2>/dev/null; then
    sudo ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL" 2>/dev/null || true
fi

# =============================================================================
# PART 3: Purge Neutron packages
# =============================================================================
echo ""
echo "[3/5] Removing Neutron packages..."

export DEBIAN_FRONTEND=noninteractive

# OVN-based packages (current architecture)
NEUTRON_PACKAGES=(
    "neutron-server"
    "neutron-plugin-ml2"
    "neutron-ovn-metadata-agent"
    "neutron-common"
)

# Legacy packages (in case they were installed from older script versions)
LEGACY_PACKAGES=(
    "neutron-openvswitch-agent"
    "neutron-linuxbridge-agent"
    "neutron-dhcp-agent"
    "neutron-metadata-agent"
    "neutron-l3-agent"
    "python3-neutron"
)

for PKG in "${NEUTRON_PACKAGES[@]}" "${LEGACY_PACKAGES[@]}"; do
    if dpkg -l "$PKG" 2>/dev/null | /usr/bin/grep -q "^ii"; then
        sudo apt-get remove --purge -y "$PKG" 2>/dev/null || true
        echo "  ✓ Purged $PKG"
    fi
done

# Autoremove orphaned dependencies
sudo apt-get autoremove -y 2>/dev/null || true

echo "  ✓ Packages purged"

# Re-ensure connectivity after package removal
if sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE} 2>/dev/null; then
    sudo ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL" 2>/dev/null || true
fi

# =============================================================================
# PART 4: Remove configuration and data files
# =============================================================================
echo ""
echo "[4/5] Removing configuration files..."

# Remove Neutron config directory
if [ -d /etc/neutron ]; then
    sudo rm -rf /etc/neutron
    echo "  ✓ Removed /etc/neutron"
else
    echo "  ✓ /etc/neutron not present"
fi

# Remove dbconfig-common config
if [ -f /etc/dbconfig-common/neutron-server.conf ]; then
    sudo rm -f /etc/dbconfig-common/neutron-server.conf
    echo "  ✓ Removed dbconfig-common config"
fi

# Remove log directory
if [ -d /var/log/neutron ]; then
    sudo rm -rf /var/log/neutron
    echo "  ✓ Removed /var/log/neutron"
fi

# Remove lib/state directory
if [ -d /var/lib/neutron ]; then
    sudo rm -rf /var/lib/neutron
    echo "  ✓ Removed /var/lib/neutron"
fi

echo "  ✓ Configuration files removed"

# =============================================================================
# PART 5: Clear Neutron database tables and verify
# =============================================================================
echo ""
echo "[5/5] Clearing database tables and verifying..."

if command -v mysql &>/dev/null; then
    # Get list of tables and drop them all
    TABLES=$(mysql -u neutron -p"${NEUTRON_DB_PASS}" -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='neutron'" 2>/dev/null || echo "")

    if [ -n "$TABLES" ]; then
        # Disable foreign key checks, drop all tables, re-enable
        mysql -u neutron -p"${NEUTRON_DB_PASS}" neutron -e "SET FOREIGN_KEY_CHECKS = 0;" 2>/dev/null || true

        for TABLE in $TABLES; do
            mysql -u neutron -p"${NEUTRON_DB_PASS}" neutron -e "DROP TABLE IF EXISTS \`$TABLE\`;" 2>/dev/null || true
        done

        mysql -u neutron -p"${NEUTRON_DB_PASS}" neutron -e "SET FOREIGN_KEY_CHECKS = 1;" 2>/dev/null || true
        echo "  ✓ All Neutron tables dropped"
    else
        echo "  ✓ No tables to drop (database already empty)"
    fi

    # Verify database is empty
    TABLE_COUNT=$(mysql -u neutron -p"${NEUTRON_DB_PASS}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='neutron'" 2>/dev/null || echo "0")
    echo "  Tables remaining: ${TABLE_COUNT}"
fi

# Verify packages are removed
echo ""
echo "Verification:"
if ! dpkg -l neutron-server 2>/dev/null | /usr/bin/grep -q "^ii"; then
    echo "  ✓ Neutron packages removed"
else
    echo "  ✗ Some Neutron packages still installed"
fi

if [ ! -d /etc/neutron ]; then
    echo "  ✓ /etc/neutron removed"
else
    echo "  ✗ /etc/neutron still exists"
fi

if ! sudo ss -tlnp | /usr/bin/grep -q ":9696"; then
    echo "  ✓ Port 9696 is free"
else
    echo "  ✗ Port 9696 still in use"
fi

# Verify OVS/OVN still running (should be untouched)
if systemctl is-active --quiet openvswitch-switch; then
    echo "  ✓ OVS still running"
else
    echo "  ⚠ OVS not running (may need to restart)"
fi

if systemctl is-active --quiet ovn-central; then
    echo "  ✓ OVN central still running"
else
    echo "  ⚠ OVN central not running (may need to restart)"
fi

# Final connectivity check
echo ""
echo "Final connectivity check..."
if sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE} 2>/dev/null; then
    sudo ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL" 2>/dev/null || true
fi

GATEWAY=$(ip route | /usr/bin/grep "^default" | awk '{print $3}' | head -1)
if [ -n "$GATEWAY" ]; then
    if ping -c 2 -W 2 $GATEWAY &>/dev/null; then
        echo "  ✓ Network connectivity OK (gateway $GATEWAY reachable)"
    else
        echo "  ⚠ Gateway $GATEWAY not reachable - check provider bridge!"
    fi
else
    echo "  ⚠ No default gateway found"
fi

echo ""
echo "=========================================="
echo "=== Neutron Cleanup Complete ==="
echo "=========================================="
echo ""
echo "Removed:"
echo "  - Neutron packages (server, ml2, metadata-agent)"
echo "  - Configuration files (/etc/neutron)"
echo "  - Database tables (database and user kept)"
echo ""
echo "Kept intact:"
echo "  - OVS/OVN installation (from script 25)"
echo "  - Provider bridge ${PROVIDER_BRIDGE}"
echo "  - Neutron database and user (from script 24)"
echo "  - Keystone user and service endpoints"
echo ""
echo "You can now re-run: ./26-neutron-install.sh"
echo ""
