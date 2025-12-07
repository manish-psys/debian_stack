#!/bin/bash
###############################################################################
# 26-neutron-cleanup.sh
# Remove Neutron packages and configuration
# Run this before re-running 26-neutron-install.sh
#
# NOTE: This does NOT remove:
# - Neutron database (managed by Script 24)
# - Keystone user/service/endpoints (managed by Script 24)
# - OVS bridge (managed by Script 25)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
fi

echo "=== Neutron Installation Cleanup (Script 26) ==="
echo ""
echo "This will remove:"
echo "  - Neutron packages"
echo "  - /etc/neutron/ directory"
echo "  - Neutron database TABLES (not the database itself)"
echo ""
echo "This will NOT remove:"
echo "  - Keystone 'neutron' user (Script 24)"
echo "  - Network service/endpoints (Script 24)"
echo "  - MySQL 'neutron' database (Script 24)"
echo "  - OVS bridge (Script 25)"
echo ""
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "[1/4] Stopping Neutron services..."
for SERVICE in neutron-server neutron-openvswitch-agent neutron-dhcp-agent neutron-metadata-agent neutron-l3-agent neutron-linuxbridge-agent; do
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        sudo systemctl stop "$SERVICE"
        sudo systemctl disable "$SERVICE" 2>/dev/null || true
        echo "  ✓ Stopped $SERVICE"
    fi
done
echo "  ✓ All Neutron services stopped"

echo ""
echo "[2/4] Removing Neutron packages..."
NEUTRON_PACKAGES="neutron-server neutron-plugin-ml2 neutron-openvswitch-agent neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent neutron-l3-agent neutron-common python3-neutron"
if dpkg -l neutron-server 2>/dev/null | grep -q "^ii"; then
    sudo apt-get remove --purge -y $NEUTRON_PACKAGES 2>/dev/null || true
    sudo apt-get autoremove -y 2>/dev/null || true
    echo "  ✓ Neutron packages removed"
else
    echo "  ✓ Neutron packages not installed"
fi

echo ""
echo "[3/4] Removing configuration files..."
if [ -d /etc/neutron ]; then
    sudo rm -rf /etc/neutron
    echo "  ✓ /etc/neutron removed"
else
    echo "  ✓ /etc/neutron not present"
fi

# Remove dbconfig-common config
if [ -f /etc/dbconfig-common/neutron-server.conf ]; then
    sudo rm -f /etc/dbconfig-common/neutron-server.conf
    echo "  ✓ dbconfig-common/neutron-server.conf removed"
fi

# Remove log directory
if [ -d /var/log/neutron ]; then
    sudo rm -rf /var/log/neutron
    echo "  ✓ /var/log/neutron removed"
fi

# Remove lib directory
if [ -d /var/lib/neutron ]; then
    sudo rm -rf /var/lib/neutron
    echo "  ✓ /var/lib/neutron removed"
fi

echo ""
echo "[4/4] Clearing database tables..."
if command -v mysql &>/dev/null; then
    # Get all tables and drop them
    TABLES=$(mysql -u neutron -p"${NEUTRON_DB_PASS}" -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='neutron'" 2>/dev/null || true)
    if [ -n "$TABLES" ]; then
        mysql -u neutron -p"${NEUTRON_DB_PASS}" -e "SET FOREIGN_KEY_CHECKS=0" neutron 2>/dev/null || true
        for TABLE in $TABLES; do
            mysql -u neutron -p"${NEUTRON_DB_PASS}" -e "DROP TABLE IF EXISTS \`$TABLE\`" neutron 2>/dev/null || true
        done
        mysql -u neutron -p"${NEUTRON_DB_PASS}" -e "SET FOREIGN_KEY_CHECKS=1" neutron 2>/dev/null || true
        echo "  ✓ Database tables dropped"
    else
        echo "  ✓ Database already empty"
    fi
fi

echo ""
echo "[5/5] Verifying cleanup..."
if ! dpkg -l neutron-server 2>/dev/null | grep -q "^ii"; then
    echo "  ✓ Neutron packages removed"
else
    echo "  ✗ Some Neutron packages still installed"
fi

if [ ! -d /etc/neutron ]; then
    echo "  ✓ /etc/neutron removed"
else
    echo "  ✗ /etc/neutron still exists"
fi

if ! sudo ss -tlnp | grep -q ":9696"; then
    echo "  ✓ Port 9696 is free"
else
    echo "  ✗ Port 9696 still in use"
fi

echo ""
echo "=== Cleanup complete ==="
echo "You can now re-run: ./26-neutron-install.sh"
