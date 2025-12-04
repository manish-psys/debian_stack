#!/bin/bash
###############################################################################
# 25-neutron-install.sh
# Install and configure Neutron (Networking service) with Linux Bridge
###############################################################################
set -e

# Configuration - EDIT THESE
NEUTRON_DB_PASS="neutrondbpass"    # Must match 24-neutron-db.sh
NEUTRON_PASS="neutronpass"          # Must match 24-neutron-db.sh
NOVA_PASS="novapass"                # Must match 21-nova-db.sh
RABBIT_PASS="guest"
IP_ADDRESS="192.168.2.9"
METADATA_SECRET="metadatasecret"    # Shared secret for metadata - Change this!

echo "=== Step 25: Neutron Installation ==="

echo "[1/7] Installing Neutron packages..."
sudo apt -t bullseye-wallaby-backports install -y \
    neutron-server neutron-plugin-ml2 \
    neutron-linuxbridge-agent neutron-dhcp-agent \
    neutron-metadata-agent

echo "[2/7] Backing up original configs..."
sudo cp /etc/neutron/neutron.conf /etc/neutron/neutron.conf.orig
sudo cp /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugins/ml2/ml2_conf.ini.orig
sudo cp /etc/neutron/plugins/ml2/linuxbridge_agent.ini /etc/neutron/plugins/ml2/linuxbridge_agent.ini.orig

echo "[3/7] Configuring neutron.conf..."
# Database
sudo crudini --set /etc/neutron/neutron.conf database connection \
    "mysql+pymysql://neutron:${NEUTRON_DB_PASS}@localhost/neutron"

# Default
sudo crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin "ml2"
sudo crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins ""
sudo crudini --set /etc/neutron/neutron.conf DEFAULT transport_url "rabbit://guest:${RABBIT_PASS}@localhost:5672/"
sudo crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy "keystone"
sudo crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes "true"
sudo crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes "true"

# Keystone auth
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken www_authenticate_uri "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken username "neutron"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken password "${NEUTRON_PASS}"

# Nova notifications
sudo crudini --set /etc/neutron/neutron.conf nova auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/neutron/neutron.conf nova auth_type "password"
sudo crudini --set /etc/neutron/neutron.conf nova project_domain_name "Default"
sudo crudini --set /etc/neutron/neutron.conf nova user_domain_name "Default"
sudo crudini --set /etc/neutron/neutron.conf nova region_name "RegionOne"
sudo crudini --set /etc/neutron/neutron.conf nova project_name "service"
sudo crudini --set /etc/neutron/neutron.conf nova username "nova"
sudo crudini --set /etc/neutron/neutron.conf nova password "${NOVA_PASS}"

# Oslo concurrency
sudo crudini --set /etc/neutron/neutron.conf oslo_concurrency lock_path "/var/lib/neutron/tmp"

echo "[4/7] Configuring ML2 plugin..."
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers "flat"
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types "flat"
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers "linuxbridge"
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 extension_drivers "port_security"
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks "physnet1"

echo "[5/7] Configuring Linux Bridge agent..."
sudo crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini linux_bridge physical_interface_mappings "physnet1:br-provider"
sudo crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan enable_vxlan "false"
sudo crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup enable_security_group "true"
sudo crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup firewall_driver "iptables"

echo "[6/7] Configuring Metadata agent..."
sudo crudini --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_host "${IP_ADDRESS}"
sudo crudini --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret "${METADATA_SECRET}"

echo "[7/7] Updating Nova to use Neutron..."
sudo crudini --set /etc/nova/nova.conf neutron auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/nova/nova.conf neutron auth_type "password"
sudo crudini --set /etc/nova/nova.conf neutron project_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf neutron user_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf neutron region_name "RegionOne"
sudo crudini --set /etc/nova/nova.conf neutron project_name "service"
sudo crudini --set /etc/nova/nova.conf neutron username "neutron"
sudo crudini --set /etc/nova/nova.conf neutron password "${NEUTRON_PASS}"
sudo crudini --set /etc/nova/nova.conf neutron service_metadata_proxy "true"
sudo crudini --set /etc/nova/nova.conf neutron metadata_proxy_shared_secret "${METADATA_SECRET}"

echo ""
echo "=== Neutron configuration complete ==="
echo "Metadata secret: ${METADATA_SECRET}"
echo ""
echo "Next: Run 26-neutron-sync.sh"
