#!/bin/bash
###############################################################################
# 21-nova-db.sh
# Create Nova databases and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
NOVA_DB_PASS="novadbpass"    # Change this!
NOVA_PASS="novapass"          # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 21: Nova Database and Keystone Setup ==="

echo "[1/3] Creating Nova databases..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS nova_api;
CREATE DATABASE IF NOT EXISTS nova;
CREATE DATABASE IF NOT EXISTS nova_cell0;

GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Nova Keystone entities..."
openstack user create --domain default --password ${NOVA_PASS} nova
openstack role add --project service --user nova admin
openstack service create --name nova --description "OpenStack Compute" compute
openstack endpoint create --region RegionOne compute public http://${IP_ADDRESS}:8774/v2.1
openstack endpoint create --region RegionOne compute internal http://${IP_ADDRESS}:8774/v2.1
openstack endpoint create --region RegionOne compute admin http://${IP_ADDRESS}:8774/v2.1

echo ""
echo "=== Nova databases and Keystone entities created ==="
echo "DB Password: ${NOVA_DB_PASS}"
echo "Keystone Password: ${NOVA_PASS}"
echo ""
echo "Next: Run 22-nova-install.sh"
