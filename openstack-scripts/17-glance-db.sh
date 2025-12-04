#!/bin/bash
###############################################################################
# 17-glance-db.sh
# Create Glance database and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
GLANCE_DB_PASS="glancedbpass"    # Change this!
GLANCE_PASS="glancepass"         # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 17: Glance Database and Keystone Setup ==="

echo "[1/3] Creating Glance database..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '${GLANCE_DB_PASS}';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '${GLANCE_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Glance Keystone entities..."
openstack user create --domain default --password ${GLANCE_PASS} glance
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image" image
openstack endpoint create --region RegionOne image public http://${IP_ADDRESS}:9292
openstack endpoint create --region RegionOne image internal http://${IP_ADDRESS}:9292
openstack endpoint create --region RegionOne image admin http://${IP_ADDRESS}:9292

echo ""
echo "=== Glance database and Keystone entities created ==="
echo "DB Password: ${GLANCE_DB_PASS}"
echo "Keystone Password: ${GLANCE_PASS}"
echo ""
echo "IMPORTANT: Save these passwords securely!"
echo "Next: Run 18-glance-install.sh"
