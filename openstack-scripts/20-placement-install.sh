#!/bin/bash
###############################################################################
# 20-placement-install.sh
# Install and configure Placement service
###############################################################################
set -e

# Configuration - EDIT THESE
PLACEMENT_DB_PASS="placementdbpass"    # Must match 19-placement-db.sh
PLACEMENT_PASS="placementpass"          # Must match 19-placement-db.sh
IP_ADDRESS="192.168.2.9"

echo "=== Step 20: Placement Installation ==="

echo "[1/4] Installing Placement..."
sudo apt -t bullseye-wallaby-backports install -y placement-api

echo "[2/4] Configuring Placement..."
sudo cp /etc/placement/placement.conf /etc/placement/placement.conf.orig

# Database
sudo crudini --set /etc/placement/placement.conf placement_database connection \
    "mysql+pymysql://placement:${PLACEMENT_DB_PASS}@localhost/placement"

# API
sudo crudini --set /etc/placement/placement.conf api auth_strategy "keystone"

# Keystone auth
sudo crudini --set /etc/placement/placement.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000/v3"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken username "placement"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken password "${PLACEMENT_PASS}"

echo "[3/4] Syncing database..."
sudo -u placement placement-manage db sync

echo "[4/4] Restarting Apache..."
sudo systemctl restart apache2

echo ""
echo "Testing Placement..."
source ~/admin-openrc
openstack --os-placement-api-version 1.2 resource class list --sort-column name | head -20

echo ""
echo "=== Placement installed ==="
echo "Next: Run 21-nova-db.sh"
