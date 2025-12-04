#!/bin/bash
###############################################################################
# 28-cinder-db.sh
# Create Cinder database and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
CINDER_DB_PASS="cinderdbpass"    # Change this!
CINDER_PASS="cinderpass"          # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 28: Cinder Database and Keystone Setup ==="

echo "[1/3] Creating Cinder database..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS cinder;
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '${CINDER_DB_PASS}';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '${CINDER_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Cinder Keystone entities..."
openstack user create --domain default --password ${CINDER_PASS} cinder
openstack role add --project service --user cinder admin

# Cinder v3 service
openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3
openstack endpoint create --region RegionOne volumev3 public http://${IP_ADDRESS}:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 internal http://${IP_ADDRESS}:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 admin http://${IP_ADDRESS}:8776/v3/%\(project_id\)s

echo ""
echo "=== Cinder database and Keystone entities created ==="
echo "DB Password: ${CINDER_DB_PASS}"
echo "Keystone Password: ${CINDER_PASS}"
echo ""
echo "Next: Run 29-cinder-install.sh"
