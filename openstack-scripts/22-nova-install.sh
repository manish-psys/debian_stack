#!/bin/bash
###############################################################################
# 22-nova-install.sh
# Install and configure Nova (Compute service)
###############################################################################
set -e

# Configuration - EDIT THESE
NOVA_DB_PASS="novadbpass"        # Must match 21-nova-db.sh
NOVA_PASS="novapass"              # Must match 21-nova-db.sh
PLACEMENT_PASS="placementpass"    # Must match 19-placement-db.sh
RABBIT_PASS="guest"               # RabbitMQ password (default is guest)
IP_ADDRESS="192.168.2.9"

echo "=== Step 22: Nova Installation ==="

echo "[1/5] Installing Nova packages..."
sudo apt -t bullseye-wallaby-backports install -y \
    nova-api nova-conductor nova-scheduler nova-novncproxy \
    nova-compute

echo "[2/5] Backing up original config..."
sudo cp /etc/nova/nova.conf /etc/nova/nova.conf.orig

echo "[3/5] Configuring Nova..."
# Default section
sudo crudini --set /etc/nova/nova.conf DEFAULT my_ip "${IP_ADDRESS}"
sudo crudini --set /etc/nova/nova.conf DEFAULT transport_url "rabbit://guest:${RABBIT_PASS}@localhost:5672/"
sudo crudini --set /etc/nova/nova.conf DEFAULT use_neutron "true"
sudo crudini --set /etc/nova/nova.conf DEFAULT firewall_driver "nova.virt.firewall.NoopFirewallDriver"

# API database
sudo crudini --set /etc/nova/nova.conf api_database connection \
    "mysql+pymysql://nova:${NOVA_DB_PASS}@localhost/nova_api"

# Database
sudo crudini --set /etc/nova/nova.conf database connection \
    "mysql+pymysql://nova:${NOVA_DB_PASS}@localhost/nova"

# API
sudo crudini --set /etc/nova/nova.conf api auth_strategy "keystone"

# Keystone auth
sudo crudini --set /etc/nova/nova.conf keystone_authtoken www_authenticate_uri "http://${IP_ADDRESS}:5000/"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000/"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken username "nova"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken password "${NOVA_PASS}"

# VNC
sudo crudini --set /etc/nova/nova.conf vnc enabled "true"
sudo crudini --set /etc/nova/nova.conf vnc server_listen "${IP_ADDRESS}"
sudo crudini --set /etc/nova/nova.conf vnc server_proxyclient_address "${IP_ADDRESS}"
sudo crudini --set /etc/nova/nova.conf vnc novncproxy_base_url "http://${IP_ADDRESS}:6080/vnc_auto.html"

# Glance
sudo crudini --set /etc/nova/nova.conf glance api_servers "http://${IP_ADDRESS}:9292"

# Oslo concurrency
sudo crudini --set /etc/nova/nova.conf oslo_concurrency lock_path "/var/lib/nova/tmp"

# Placement
sudo crudini --set /etc/nova/nova.conf placement region_name "RegionOne"
sudo crudini --set /etc/nova/nova.conf placement project_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf placement project_name "service"
sudo crudini --set /etc/nova/nova.conf placement auth_type "password"
sudo crudini --set /etc/nova/nova.conf placement user_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf placement auth_url "http://${IP_ADDRESS}:5000/v3"
sudo crudini --set /etc/nova/nova.conf placement username "placement"
sudo crudini --set /etc/nova/nova.conf placement password "${PLACEMENT_PASS}"

echo "[4/5] Syncing databases..."
sudo -u nova nova-manage api_db sync
sudo -u nova nova-manage cell_v2 map_cell0
sudo -u nova nova-manage cell_v2 create_cell --name=cell1 --verbose || true
sudo -u nova nova-manage db sync
sudo -u nova nova-manage cell_v2 list_cells

echo "[5/5] Starting Nova services..."
sudo systemctl restart nova-api nova-scheduler nova-conductor nova-novncproxy nova-compute
sudo systemctl enable nova-api nova-scheduler nova-conductor nova-novncproxy nova-compute

echo ""
echo "=== Nova installed ==="
echo "Next: Run 23-nova-discover.sh (after a few seconds for services to start)"
