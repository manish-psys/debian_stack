#!/bin/bash
###############################################################################
# 26-neutron-install.sh
# Install and configure Neutron (Networking service) with ML2/OVS
# Idempotent - safe to run multiple times
#
# This script installs:
# - neutron-server: API server
# - neutron-plugin-ml2: Modular Layer 2 plugin
# - neutron-openvswitch-agent: OVS agent (replaces linuxbridge-agent)
# - neutron-dhcp-agent: DHCP service for VMs
# - neutron-metadata-agent: Metadata service for VMs
# - neutron-l3-agent: L3 routing (for self-service networks)
#
# Network Architecture:
# - Provider networks: Flat/VLAN on physnet1 (br-provider)
# - Self-service networks: VXLAN tunnels (optional, can enable later)
# - Security groups: OVS firewall driver
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

echo "=== Step 26: Neutron Installation (ML2/OVS) ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo "Using Region: ${REGION_NAME}"

# Configuration
PROVIDER_BRIDGE="${PROVIDER_BRIDGE_NAME:-br-provider}"
PROVIDER_NETWORK="${PROVIDER_NETWORK_NAME:-physnet1}"

# ============================================================================
# PART 0: Prerequisites Check
# ============================================================================
echo ""
echo "[0/10] Checking prerequisites..."

# Check crudini
if ! command -v crudini &>/dev/null; then
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
if ! sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='neutron'" 2>/dev/null | grep -q "neutron"; then
    echo "  ✗ ERROR: Database 'neutron' not found. Run 24-neutron-db.sh first!"
    exit 1
fi
echo "  ✓ Neutron database exists"

# Check Keystone user
if ! openstack user show neutron &>/dev/null; then
    echo "  ✗ ERROR: Keystone user 'neutron' not found. Run 24-neutron-db.sh first!"
    exit 1
fi
echo "  ✓ Keystone user 'neutron' exists"

# Check Neutron service
if ! openstack service show network &>/dev/null; then
    echo "  ✗ ERROR: Network service not found. Run 24-neutron-db.sh first!"
    exit 1
fi
echo "  ✓ Network service registered"

# Check OVS is running
if ! systemctl is-active --quiet openvswitch-switch; then
    echo "  ✗ ERROR: OVS is not running. Run 25-ovs-install.sh first!"
    exit 1
fi
echo "  ✓ OVS is running"

# Check OVS bridge exists
if ! sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE}; then
    echo "  ✗ ERROR: OVS bridge ${PROVIDER_BRIDGE} not found. Run 25-ovs-install.sh first!"
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
if ! sudo rabbitmqctl list_users 2>/dev/null | grep -q "^${RABBIT_USER}"; then
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
# PART 1: Pre-seed dbconfig-common
# ============================================================================
echo ""
echo "[1/10] Configuring dbconfig-common..."

sudo mkdir -p /etc/dbconfig-common

cat <<EOF | sudo tee /etc/dbconfig-common/neutron-server.conf > /dev/null
dbc_install='false'
dbc_upgrade='false'
dbc_remove=''
dbc_dbtype='mysql'
dbc_dbuser='neutron'
dbc_dbpass='${NEUTRON_DB_PASS}'
dbc_dbserver='localhost'
dbc_dbname='neutron'
EOF

echo "neutron-server neutron-server/dbconfig-install boolean false" | sudo debconf-set-selections
echo "  ✓ dbconfig-common configured"

# ============================================================================
# PART 2: Install Neutron packages
# ============================================================================
echo ""
echo "[2/10] Installing Neutron packages..."

export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get -t bullseye-wallaby-backports install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    neutron-server \
    neutron-plugin-ml2 \
    neutron-openvswitch-agent \
    neutron-dhcp-agent \
    neutron-metadata-agent \
    neutron-l3-agent

echo "  ✓ Neutron packages installed"

# ============================================================================
# PART 3: Stop services for configuration
# ============================================================================
echo ""
echo "[3/10] Stopping Neutron services for configuration..."

for SERVICE in neutron-server neutron-openvswitch-agent neutron-dhcp-agent neutron-metadata-agent neutron-l3-agent; do
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        sudo systemctl stop "$SERVICE"
    fi
done
echo "  ✓ Neutron services stopped"

# ============================================================================
# PART 4: Configure neutron.conf
# ============================================================================
echo ""
echo "[4/10] Configuring neutron.conf..."

NEUTRON_CONF="/etc/neutron/neutron.conf"

# Backup original
if [ -f "$NEUTRON_CONF" ] && [ ! -f "${NEUTRON_CONF}.orig" ]; then
    sudo cp "$NEUTRON_CONF" "${NEUTRON_CONF}.orig"
fi

# [database] section
sudo crudini --set $NEUTRON_CONF database connection \
    "mysql+pymysql://neutron:${NEUTRON_DB_PASS}@localhost/neutron"
echo "  ✓ [database] configured"

# [DEFAULT] section
sudo crudini --set $NEUTRON_CONF DEFAULT core_plugin "ml2"
sudo crudini --set $NEUTRON_CONF DEFAULT service_plugins "router"
sudo crudini --set $NEUTRON_CONF DEFAULT transport_url "rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
sudo crudini --set $NEUTRON_CONF DEFAULT auth_strategy "keystone"
sudo crudini --set $NEUTRON_CONF DEFAULT notify_nova_on_port_status_changes "true"
sudo crudini --set $NEUTRON_CONF DEFAULT notify_nova_on_port_data_changes "true"
sudo crudini --set $NEUTRON_CONF DEFAULT allow_overlapping_ips "true"
echo "  ✓ [DEFAULT] configured"

# [keystone_authtoken] section
sudo crudini --set $NEUTRON_CONF keystone_authtoken www_authenticate_uri "http://${CONTROLLER_IP}:5000"
sudo crudini --set $NEUTRON_CONF keystone_authtoken auth_url "http://${CONTROLLER_IP}:5000"
sudo crudini --set $NEUTRON_CONF keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set $NEUTRON_CONF keystone_authtoken auth_type "password"
sudo crudini --set $NEUTRON_CONF keystone_authtoken project_domain_name "Default"
sudo crudini --set $NEUTRON_CONF keystone_authtoken user_domain_name "Default"
sudo crudini --set $NEUTRON_CONF keystone_authtoken project_name "service"
sudo crudini --set $NEUTRON_CONF keystone_authtoken username "neutron"
sudo crudini --set $NEUTRON_CONF keystone_authtoken password "${NEUTRON_PASS}"
sudo crudini --set $NEUTRON_CONF keystone_authtoken region_name "${REGION_NAME}"
echo "  ✓ [keystone_authtoken] configured"

# [nova] section - for notifications to Nova
sudo crudini --set $NEUTRON_CONF nova auth_url "http://${CONTROLLER_IP}:5000"
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
echo "  ✓ [oslo_concurrency] configured"

# ============================================================================
# PART 5: Configure ML2 plugin
# ============================================================================
echo ""
echo "[5/10] Configuring ML2 plugin..."

ML2_CONF="/etc/neutron/plugins/ml2/ml2_conf.ini"

if [ -f "$ML2_CONF" ] && [ ! -f "${ML2_CONF}.orig" ]; then
    sudo cp "$ML2_CONF" "${ML2_CONF}.orig"
fi

# [ml2] section
# type_drivers: flat for provider, vxlan for self-service (tenant) networks
sudo crudini --set $ML2_CONF ml2 type_drivers "flat,vlan,vxlan"
sudo crudini --set $ML2_CONF ml2 tenant_network_types "vxlan"
sudo crudini --set $ML2_CONF ml2 mechanism_drivers "openvswitch,l2population"
sudo crudini --set $ML2_CONF ml2 extension_drivers "port_security"
echo "  ✓ [ml2] configured"

# [ml2_type_flat] section
sudo crudini --set $ML2_CONF ml2_type_flat flat_networks "${PROVIDER_NETWORK}"
echo "  ✓ [ml2_type_flat] configured"

# [ml2_type_vxlan] section - for self-service networks
sudo crudini --set $ML2_CONF ml2_type_vxlan vni_ranges "1:1000"
echo "  ✓ [ml2_type_vxlan] configured"

# [securitygroup] section
sudo crudini --set $ML2_CONF securitygroup enable_ipset "true"
echo "  ✓ [securitygroup] configured"

# ============================================================================
# PART 6: Configure OVS agent
# ============================================================================
echo ""
echo "[6/10] Configuring OVS agent..."

OVS_AGENT_CONF="/etc/neutron/plugins/ml2/openvswitch_agent.ini"

if [ -f "$OVS_AGENT_CONF" ] && [ ! -f "${OVS_AGENT_CONF}.orig" ]; then
    sudo cp "$OVS_AGENT_CONF" "${OVS_AGENT_CONF}.orig"
fi

# [ovs] section
sudo crudini --set $OVS_AGENT_CONF ovs bridge_mappings "${PROVIDER_NETWORK}:${PROVIDER_BRIDGE}"
sudo crudini --set $OVS_AGENT_CONF ovs local_ip "${CONTROLLER_IP}"
echo "  ✓ [ovs] configured"

# [agent] section
sudo crudini --set $OVS_AGENT_CONF agent tunnel_types "vxlan"
sudo crudini --set $OVS_AGENT_CONF agent l2_population "true"
echo "  ✓ [agent] configured"

# [securitygroup] section
sudo crudini --set $OVS_AGENT_CONF securitygroup enable_security_group "true"
sudo crudini --set $OVS_AGENT_CONF securitygroup firewall_driver "openvswitch"
echo "  ✓ [securitygroup] configured"

# ============================================================================
# PART 7: Configure L3 agent
# ============================================================================
echo ""
echo "[7/10] Configuring L3 agent..."

L3_AGENT_CONF="/etc/neutron/l3_agent.ini"

if [ -f "$L3_AGENT_CONF" ] && [ ! -f "${L3_AGENT_CONF}.orig" ]; then
    sudo cp "$L3_AGENT_CONF" "${L3_AGENT_CONF}.orig"
fi

sudo crudini --set $L3_AGENT_CONF DEFAULT interface_driver "openvswitch"
echo "  ✓ L3 agent configured"

# ============================================================================
# PART 8: Configure DHCP agent
# ============================================================================
echo ""
echo "[8/10] Configuring DHCP agent..."

DHCP_AGENT_CONF="/etc/neutron/dhcp_agent.ini"

if [ -f "$DHCP_AGENT_CONF" ] && [ ! -f "${DHCP_AGENT_CONF}.orig" ]; then
    sudo cp "$DHCP_AGENT_CONF" "${DHCP_AGENT_CONF}.orig"
fi

sudo crudini --set $DHCP_AGENT_CONF DEFAULT interface_driver "openvswitch"
sudo crudini --set $DHCP_AGENT_CONF DEFAULT dhcp_driver "neutron.agent.linux.dhcp.Dnsmasq"
sudo crudini --set $DHCP_AGENT_CONF DEFAULT enable_isolated_metadata "true"
echo "  ✓ DHCP agent configured"

# ============================================================================
# PART 9: Configure Metadata agent
# ============================================================================
echo ""
echo "[9/10] Configuring Metadata agent..."

METADATA_AGENT_CONF="/etc/neutron/metadata_agent.ini"

if [ -f "$METADATA_AGENT_CONF" ] && [ ! -f "${METADATA_AGENT_CONF}.orig" ]; then
    sudo cp "$METADATA_AGENT_CONF" "${METADATA_AGENT_CONF}.orig"
fi

sudo crudini --set $METADATA_AGENT_CONF DEFAULT nova_metadata_host "${CONTROLLER_IP}"
sudo crudini --set $METADATA_AGENT_CONF DEFAULT metadata_proxy_shared_secret "${METADATA_SECRET}"
echo "  ✓ Metadata agent configured"

# ============================================================================
# PART 10: Configure Nova for Neutron integration
# ============================================================================
echo ""
echo "[10/10] Configuring Nova for Neutron..."

NOVA_CONF="/etc/nova/nova.conf"

# [neutron] section
sudo crudini --set $NOVA_CONF neutron auth_url "http://${CONTROLLER_IP}:5000"
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

# Ensure ML2 plugin symlink exists
if [ ! -L /etc/neutron/plugin.ini ]; then
    sudo ln -sf /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
    echo "  ✓ ML2 plugin symlink created"
else
    echo "  ✓ ML2 plugin symlink exists"
fi

echo ""
echo "=========================================="
echo "=== Neutron configuration complete ==="
echo "=========================================="
echo ""
echo "Configuration files:"
echo "  - /etc/neutron/neutron.conf"
echo "  - /etc/neutron/plugins/ml2/ml2_conf.ini"
echo "  - /etc/neutron/plugins/ml2/openvswitch_agent.ini"
echo "  - /etc/neutron/l3_agent.ini"
echo "  - /etc/neutron/dhcp_agent.ini"
echo "  - /etc/neutron/metadata_agent.ini"
echo ""
echo "Metadata secret: ${METADATA_SECRET}"
echo "Bridge mapping: ${PROVIDER_NETWORK}:${PROVIDER_BRIDGE}"
echo ""
echo "Next: Run 27-neutron-sync.sh"
