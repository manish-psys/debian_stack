#!/bin/bash
###############################################################################
# 19-placement-db.sh
# Create Placement database and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
PLACEMENT_DB_PASS="placementdbpass"    # Change this!
PLACEMENT_PASS="placementpass"          # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 19: Placement Database and Keystone Setup ==="

echo "[1/3] Creating Placement database..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS placement;
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost' IDENTIFIED BY '${PLACEMENT_DB_PASS}';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%' IDENTIFIED BY '${PLACEMENT_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Placement Keystone entities..."
openstack user create --domain default --password ${PLACEMENT_PASS} placement
openstack role add --project service --user placement admin
openstack service create --name placement --description "Placement API" placement
openstack endpoint create --region RegionOne placement public http://${IP_ADDRESS}:8778
openstack endpoint create --region RegionOne placement internal http://${IP_ADDRESS}:8778
openstack endpoint create --region RegionOne placement admin http://${IP_ADDRESS}:8778

echo ""
echo "=== Placement database and Keystone entities created ==="
echo "DB Password: ${PLACEMENT_DB_PASS}"
echo "Keystone Password: ${PLACEMENT_PASS}"
echo ""
echo "Next: Run 20-placement-install.sh"
