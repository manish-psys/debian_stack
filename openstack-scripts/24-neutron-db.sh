#!/bin/bash
###############################################################################
# 24-neutron-db.sh
# Create Neutron database and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
NEUTRON_DB_PASS="neutrondbpass"    # Change this!
NEUTRON_PASS="neutronpass"          # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 24: Neutron Database and Keystone Setup ==="

echo "[1/3] Creating Neutron database..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS neutron;
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '${NEUTRON_DB_PASS}';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '${NEUTRON_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Neutron Keystone entities..."
openstack user create --domain default --password ${NEUTRON_PASS} neutron
openstack role add --project service --user neutron admin
openstack service create --name neutron --description "OpenStack Networking" network
openstack endpoint create --region RegionOne network public http://${IP_ADDRESS}:9696
openstack endpoint create --region RegionOne network internal http://${IP_ADDRESS}:9696
openstack endpoint create --region RegionOne network admin http://${IP_ADDRESS}:9696

echo ""
echo "=== Neutron database and Keystone entities created ==="
echo "DB Password: ${NEUTRON_DB_PASS}"
echo "Keystone Password: ${NEUTRON_PASS}"
echo ""
echo "Next: Run 25-neutron-install.sh"
