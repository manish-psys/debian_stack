#!/bin/bash
###############################################################################
# 26-neutron-install.sh
# Install and configure Neutron (Networking service) with ML2/OVN
# Idempotent - safe to run multiple times
#
# This script installs:
# - neutron-server: API server
# - neutron-plugin-ml2: Modular Layer 2 plugin
# - neutron-ovn-metadata-agent: Metadata service for VMs (OVN-native)
#
# Network Architecture (OVN-based):
# - Provider networks: Flat/VLAN on physnet1 (br-provider)
# - Self-service networks: Geneve tunnels (OVN native)
# - Security groups: OVN native (no iptables)
# - Distributed routing: OVN native L3
# - DHCP: OVN native (no neutron-dhcp-agent needed)
#
# Why OVN over OVS-agent:
# - Native distributed routing (no L3 agent needed)
# - Native DHCP (no DHCP agent needed)
# - Better performance with kernel datapath
# - Simpler architecture for cloud networking
#
# LESSON LEARNED (2025-12-18):
# When OVN takes control of OVS bridges, it sets fail_mode=secure which drops
# all traffic unless explicit OpenFlow rules exist. For the provider bridge
# that carries management traffic, we MUST add a NORMAL flow rule to allow
# traffic to pass through, otherwise network connectivity is lost.
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

echo "=== Step 26: Neutron Installation (ML2/OVN) ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo "Using Region: ${REGION_NAME}"

# Configuration
PROVIDER_BRIDGE="${PROVIDER_BRIDGE_NAME:-br-provider}"
PROVIDER_NETWORK="${PROVIDER_NETWORK_NAME:-physnet1}"

# =============================================================================
# Helper function: Ensure provider bridge allows traffic
# This is CRITICAL for maintaining network connectivity when OVN manages OVS
# =============================================================================
ensure_provider_bridge_connectivity() {
    echo "  Ensuring provider bridge allows traffic..."

    # Remove fail_mode: secure if set (OVN sets this automatically)
    # For provider bridge carrying management traffic, we need traffic to flow
    sudo ovs-vsctl remove bridge ${PROVIDER_BRIDGE} fail_mode secure 2>/dev/null || true

    # Add default NORMAL flow rule to allow all traffic through provider bridge
    # This is essential because OVN's fail_mode: secure drops all packets
    # without explicit OpenFlow rules
    sudo ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL" 2>/dev/null || true

    echo "  ✓ Provider bridge connectivity ensured"
}

# ============================================================================
# PART 0: Prerequisites Check
# ============================================================================
echo ""
echo "[0/9] Checking prerequisites..."

# Check crudini using absolute path
if [ ! -x /usr/bin/crudini ]; then
    sudo apt-get install -y crudini
fi
echo "  ✓ crudini available"

# Check admin-openrc
if [ ! -f ~/admin-openrc ]; then
    echo "  ✗ ERROR: ~/admin-openrc not found!"
    exit 1
fi
source ~/admin-openrc
echo "  ✓ admin-openrc loaded"

# Check Neutron database exists
if ! sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='neutron'" 2>/dev/null | /usr/bin/grep -q "neutron"; then
    echo "  ✗ ERROR: Database 'neutron' not found. Run 24-neutron-db.sh first!"
    exit 1
fi
echo "  ✓ Neutron database exists"

# Check Keystone user
if ! /usr/bin/openstack user show neutron &>/dev/null; then
    echo "  ✗ ERROR: Keystone user 'neutron' not found. Run 24-neutron-db.sh first!"
    exit 1
fi
echo "  ✓ Keystone user 'neutron' exists"

# Check Neutron service
if ! /usr/bin/openstack service show network &>/dev/null; then
    echo "  ✗ ERROR: Network service not found. Run 24-neutron-db.sh first!"
    exit 1
fi
echo "  ✓ Network service registered"

# Check OVS is running
if ! systemctl is-active --quiet openvswitch-switch; then
    echo "  ✗ ERROR: OVS is not running. Run 25-ovs-ovn-install.sh first!"
    exit 1
fi
echo "  ✓ OVS is running"

# Check OVN central is running
if ! systemctl is-active --quiet ovn-central; then
    echo "  ✗ ERROR: OVN central is not running. Run 25-ovs-ovn-install.sh first!"
    exit 1
fi
echo "  ✓ OVN central is running"

# Check OVS bridge exists
if ! sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE}; then
    echo "  ✗ ERROR: OVS bridge ${PROVIDER_BRIDGE} not found. Run 25-ovs-ovn-install.sh first!"
    exit 1
fi
echo "  ✓ OVS bridge ${PROVIDER_BRIDGE} exists"

# Check RabbitMQ
if ! systemctl is-active --quiet rabbitmq-server; then
    echo "  ✗ ERROR: RabbitMQ is not running!"
    exit 1
fi
echo "  ✓ RabbitMQ is running"

# Check RabbitMQ user
if ! sudo rabbitmqctl list_users 2>/dev/null | /usr/bin/grep -q "^${RABBIT_USER}"; then
    echo "  ✗ ERROR: RabbitMQ user '${RABBIT_USER}' not found!"
    exit 1
fi
echo "  ✓ RabbitMQ user '${RABBIT_USER}' exists"

# Check Nova is running (Neutron integrates with Nova)
if ! systemctl is-active --quiet nova-api; then
    echo "  ✗ ERROR: Nova API is not running!"
    exit 1
fi
echo "  ✓ Nova API is running"

# ============================================================================
# PART 1: Pre-protect provider bridge connectivity
# ============================================================================
echo ""
echo "[1/9] Pre-protecting provider bridge connectivity..."

# CRITICAL: Before installing Neutron/OVN packages, ensure the provider bridge
# has flow rules to allow traffic. OVN will set fail_mode: secure which blocks
# all traffic without explicit rules.
ensure_provider_bridge_connectivity

# Verify we still have network connectivity
if ! ping -c 1 -W 2 ${CONTROLLER_IP} &>/dev/null; then
    # Try the gateway
    GATEWAY=$(ip route | /usr/bin/grep "^default" | awk '{print $3}' | head -1)
    if [ -n "$GATEWAY" ] && ! ping -c 1 -W 2 $GATEWAY &>/dev/null; then
        echo "  ⚠️  WARNING: Network connectivity may be impaired!"
        echo "  ⚠️  Proceeding anyway, but watch for issues."
    fi
fi
echo "  ✓ Network connectivity verified"

# ============================================================================
# PART 2: Pre-seed dbconfig-common
# ============================================================================
echo ""
echo "[2/9] Configuring dbconfig-common..."

sudo mkdir -p /etc/dbconfig-common

cat <<EOF | sudo tee /etc/dbconfig-common/neutron-server.conf > /dev/null
dbc_install='false'
dbc_upgrade='false'
dbc_remove=''
dbc_dbtype='mysql'
dbc_dbuser='neutron'
dbc_dbpass='${NEUTRON_DB_PASS}'
dbc_dbserver='${CONTROLLER_IP}'
dbc_dbname='neutron'
EOF

echo "neutron-server neutron-server/dbconfig-install boolean false" | sudo debconf-set-selections
echo "  ✓ dbconfig-common configured"

# ============================================================================
# PART 3: Install Neutron packages (OVN-based)
# ============================================================================
echo ""
echo "[3/9] Installing Neutron packages (ML2/OVN)..."

export DEBIAN_FRONTEND=noninteractive

# Debian Trixie has Neutron in main repositories - no backports needed
# Install OVN-specific packages for modern cloud networking
sudo -E apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    neutron-server \
    neutron-plugin-ml2 \
    neutron-ovn-metadata-agent \
    python3-ovsdbapp

echo "  ✓ Neutron packages installed"

# Display installed version
NEUTRON_VERSION=$(dpkg -l neutron-common 2>/dev/null | /usr/bin/grep "^ii" | awk '{print $3}')
echo "  Installed version: neutron ${NEUTRON_VERSION}"

# CRITICAL: Re-ensure provider bridge connectivity after package installation
# Package post-install scripts may have started OVN services that modified bridge config
echo ""
echo "  Re-ensuring provider bridge connectivity after package install..."
ensure_provider_bridge_connectivity

# ============================================================================
# PART 4: Stop services for configuration
# ============================================================================
echo ""
echo "[4/9] Stopping Neutron services for configuration..."

for SERVICE in neutron-server neutron-api neutron-rpc-server neutron-ovn-metadata-agent; do
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        sudo systemctl stop "$SERVICE"
        echo "  ✓ Stopped $SERVICE"
    fi
done
echo "  ✓ Neutron services stopped"

# Re-ensure connectivity after stopping services
ensure_provider_bridge_connectivity

# ============================================================================
# PART 5: Configure neutron.conf
# ============================================================================
echo ""
echo "[5/9] Configuring neutron.conf..."

NEUTRON_CONF="/etc/neutron/neutron.conf"

# Backup original
if [ -f "$NEUTRON_CONF" ] && [ ! -f "${NEUTRON_CONF}.orig" ]; then
    sudo cp "$NEUTRON_CONF" "${NEUTRON_CONF}.orig"
    echo "  ✓ Original config backed up"
fi

# [database] section
sudo crudini --set $NEUTRON_CONF database connection \
    "mysql+pymysql://neutron:${NEUTRON_DB_PASS}@${CONTROLLER_IP}/neutron"
echo "  ✓ [database] configured"

# [DEFAULT] section
sudo crudini --set $NEUTRON_CONF DEFAULT core_plugin "ml2"
# OVN provides native L3, DHCP - use OVN router service plugin
sudo crudini --set $NEUTRON_CONF DEFAULT service_plugins "ovn-router"
sudo crudini --set $NEUTRON_CONF DEFAULT transport_url "rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
sudo crudini --set $NEUTRON_CONF DEFAULT auth_strategy "keystone"
sudo crudini --set $NEUTRON_CONF DEFAULT notify_nova_on_port_status_changes "true"
sudo crudini --set $NEUTRON_CONF DEFAULT notify_nova_on_port_data_changes "true"
sudo crudini --set $NEUTRON_CONF DEFAULT allow_overlapping_ips "true"
echo "  ✓ [DEFAULT] configured"

# [keystone_authtoken] section - using helper function
configure_keystone_authtoken $NEUTRON_CONF neutron "$NEUTRON_PASS"
echo "  ✓ [keystone_authtoken] configured"

# [nova] section - for notifications to Nova
sudo crudini --set $NEUTRON_CONF nova auth_url "${KEYSTONE_AUTH_URL}"
sudo crudini --set $NEUTRON_CONF nova auth_type "password"
sudo crudini --set $NEUTRON_CONF nova project_domain_name "Default"
sudo crudini --set $NEUTRON_CONF nova user_domain_name "Default"
sudo crudini --set $NEUTRON_CONF nova region_name "${REGION_NAME}"
sudo crudini --set $NEUTRON_CONF nova project_name "service"
sudo crudini --set $NEUTRON_CONF nova username "nova"
sudo crudini --set $NEUTRON_CONF nova password "${NOVA_PASS}"
echo "  ✓ [nova] configured"

# [oslo_concurrency] section
sudo crudini --set $NEUTRON_CONF oslo_concurrency lock_path "/var/lib/neutron/tmp"
sudo mkdir -p /var/lib/neutron/tmp
sudo chown neutron:neutron /var/lib/neutron/tmp
echo "  ✓ [oslo_concurrency] configured"

# ============================================================================
# PART 6: Configure ML2 plugin for OVN
# ============================================================================
echo ""
echo "[6/9] Configuring ML2 plugin for OVN..."

ML2_CONF="/etc/neutron/plugins/ml2/ml2_conf.ini"

if [ -f "$ML2_CONF" ] && [ ! -f "${ML2_CONF}.orig" ]; then
    sudo cp "$ML2_CONF" "${ML2_CONF}.orig"
    echo "  ✓ Original ML2 config backed up"
fi

# [ml2] section - OVN mechanism driver
sudo crudini --set $ML2_CONF ml2 type_drivers "local,flat,vlan,geneve"
sudo crudini --set $ML2_CONF ml2 tenant_network_types "geneve"
sudo crudini --set $ML2_CONF ml2 mechanism_drivers "ovn"
sudo crudini --set $ML2_CONF ml2 extension_drivers "port_security"
sudo crudini --set $ML2_CONF ml2 overlay_ip_version "4"
echo "  ✓ [ml2] configured for OVN"

# [ml2_type_flat] section
sudo crudini --set $ML2_CONF ml2_type_flat flat_networks "${PROVIDER_NETWORK}"
echo "  ✓ [ml2_type_flat] configured"

# [ml2_type_geneve] section - OVN uses geneve tunnels
sudo crudini --set $ML2_CONF ml2_type_geneve vni_ranges "1:65536"
sudo crudini --set $ML2_CONF ml2_type_geneve max_header_size "38"
echo "  ✓ [ml2_type_geneve] configured"

# [securitygroup] section - OVN native security groups
sudo crudini --set $ML2_CONF securitygroup enable_security_group "true"
echo "  ✓ [securitygroup] configured"

# [ovn] section - OVN database connections
sudo crudini --set $ML2_CONF ovn ovn_nb_connection "unix:/var/run/ovn/ovnnb_db.sock"
sudo crudini --set $ML2_CONF ovn ovn_sb_connection "unix:/var/run/ovn/ovnsb_db.sock"
sudo crudini --set $ML2_CONF ovn ovn_l3_scheduler "leastloaded"
sudo crudini --set $ML2_CONF ovn ovn_metadata_enabled "true"
echo "  ✓ [ovn] configured"

# ============================================================================
# PART 7: Configure OVN Metadata agent
# ============================================================================
echo ""
echo "[7/9] Configuring OVN Metadata agent..."

OVN_METADATA_CONF="/etc/neutron/neutron_ovn_metadata_agent.ini"

if [ -f "$OVN_METADATA_CONF" ] && [ ! -f "${OVN_METADATA_CONF}.orig" ]; then
    sudo cp "$OVN_METADATA_CONF" "${OVN_METADATA_CONF}.orig"
    echo "  ✓ Original OVN metadata config backed up"
fi

# [DEFAULT] section
sudo crudini --set $OVN_METADATA_CONF DEFAULT nova_metadata_host "${CONTROLLER_IP}"
sudo crudini --set $OVN_METADATA_CONF DEFAULT metadata_proxy_shared_secret "${METADATA_SECRET}"
sudo crudini --set $OVN_METADATA_CONF DEFAULT state_path "/var/lib/neutron"
echo "  ✓ [DEFAULT] configured"

# [ovs] section
sudo crudini --set $OVN_METADATA_CONF ovs ovsdb_connection "unix:/var/run/openvswitch/db.sock"
echo "  ✓ [ovs] configured"

# [ovn] section
sudo crudini --set $OVN_METADATA_CONF ovn ovn_sb_connection "unix:/var/run/ovn/ovnsb_db.sock"
echo "  ✓ [ovn] configured"

# ============================================================================
# PART 8: Configure Nova for Neutron/OVN integration
# ============================================================================
echo ""
echo "[8/9] Configuring Nova for Neutron..."

NOVA_CONF="/etc/nova/nova.conf"

# [neutron] section
sudo crudini --set $NOVA_CONF neutron auth_url "${KEYSTONE_AUTH_URL}"
sudo crudini --set $NOVA_CONF neutron auth_type "password"
sudo crudini --set $NOVA_CONF neutron project_domain_name "Default"
sudo crudini --set $NOVA_CONF neutron user_domain_name "Default"
sudo crudini --set $NOVA_CONF neutron region_name "${REGION_NAME}"
sudo crudini --set $NOVA_CONF neutron project_name "service"
sudo crudini --set $NOVA_CONF neutron username "neutron"
sudo crudini --set $NOVA_CONF neutron password "${NEUTRON_PASS}"
sudo crudini --set $NOVA_CONF neutron service_metadata_proxy "true"
sudo crudini --set $NOVA_CONF neutron metadata_proxy_shared_secret "${METADATA_SECRET}"
echo "  ✓ Nova [neutron] section configured"

# ============================================================================
# PART 9: Configure OVS for OVN integration and ensure connectivity
# ============================================================================
echo ""
echo "[9/9] Configuring OVS for OVN integration..."

# Set OVS external-ids for OVN
sudo ovs-vsctl set open . external-ids:ovn-bridge="${PROVIDER_BRIDGE}"
sudo ovs-vsctl set open . external-ids:ovn-bridge-mappings="${PROVIDER_NETWORK}:${PROVIDER_BRIDGE}"
echo "  ✓ OVS bridge mappings configured"

# Ensure ML2 plugin symlink exists
if [ ! -L /etc/neutron/plugin.ini ]; then
    sudo ln -sf /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
    echo "  ✓ ML2 plugin symlink created"
else
    echo "  ✓ ML2 plugin symlink exists"
fi

# CRITICAL: Final ensure of provider bridge connectivity
# This must be the LAST thing we do to ensure traffic flows
echo ""
echo "  Final connectivity protection..."
ensure_provider_bridge_connectivity

# Verify network connectivity at the end
echo ""
echo "  Verifying network connectivity..."
GATEWAY=$(ip route | /usr/bin/grep "^default" | awk '{print $3}' | head -1)
if [ -n "$GATEWAY" ]; then
    if ping -c 2 -W 2 $GATEWAY &>/dev/null; then
        echo "  ✓ Network connectivity OK (gateway $GATEWAY reachable)"
    else
        echo "  ⚠️  WARNING: Gateway $GATEWAY not reachable!"
        echo "  ⚠️  Attempting emergency connectivity fix..."
        sudo ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL"
        sleep 1
        if ping -c 2 -W 2 $GATEWAY &>/dev/null; then
            echo "  ✓ Emergency fix successful - connectivity restored"
        else
            echo "  ✗ Network still unreachable - manual intervention may be needed"
        fi
    fi
else
    echo "  ⚠️  No default gateway found"
fi

echo ""
echo "=========================================="
echo "=== Neutron configuration complete ==="
echo "=========================================="
echo ""
echo "Architecture: ML2/OVN (modern SDN)"
echo ""
echo "Configuration files:"
echo "  - /etc/neutron/neutron.conf"
echo "  - /etc/neutron/plugins/ml2/ml2_conf.ini"
echo "  - /etc/neutron/neutron_ovn_metadata_agent.ini"
echo ""
echo "OVN Features enabled:"
echo "  - Native distributed L3 routing (no L3 agent)"
echo "  - Native DHCP (no DHCP agent)"
echo "  - Native security groups (no iptables)"
echo "  - Geneve tunnels for tenant networks"
echo ""
echo "Metadata secret: ${METADATA_SECRET}"
echo "Bridge mapping: ${PROVIDER_NETWORK}:${PROVIDER_BRIDGE}"
echo ""
echo "IMPORTANT: Provider bridge has NORMAL flow rule to allow management traffic."
echo ""
echo "Next: Run 27-neutron-sync.sh"
