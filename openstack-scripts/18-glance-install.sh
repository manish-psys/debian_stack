#!/bin/bash
###############################################################################
# 18-glance-install.sh
# Install and configure Glance (Image service) with Ceph backend
###############################################################################
set -e

# Configuration - EDIT THESE
GLANCE_DB_PASS="glancedbpass"    # Must match 17-glance-db.sh
GLANCE_PASS="glancepass"         # Must match 17-glance-db.sh
IP_ADDRESS="192.168.2.9"

echo "=== Step 18: Glance Installation ==="

echo "[1/5] Installing Glance..."
sudo apt -t bullseye-wallaby-backports install -y glance

echo "[2/5] Backing up original config..."
sudo cp /etc/glance/glance-api.conf /etc/glance/glance-api.conf.orig

echo "[3/5] Configuring Glance..."
# Database
sudo crudini --set /etc/glance/glance-api.conf database connection \
    "mysql+pymysql://glance:${GLANCE_DB_PASS}@localhost/glance"

# Keystone auth
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken www_authenticate_uri "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken username "glance"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken password "${GLANCE_PASS}"

# Paste deploy
sudo crudini --set /etc/glance/glance-api.conf paste_deploy flavor "keystone"

# Ceph backend
sudo crudini --set /etc/glance/glance-api.conf glance_store stores "rbd"
sudo crudini --set /etc/glance/glance-api.conf glance_store default_store "rbd"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_pool "images"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_user "cinder"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_ceph_conf "/etc/ceph/ceph.conf"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_chunk_size "8"

echo "[4/5] Setting up Ceph keyring for Glance..."
sudo cp /etc/ceph/ceph.client.cinder.keyring /etc/ceph/ceph.client.cinder.keyring.glance
sudo chown glance:glance /etc/ceph/ceph.client.cinder.keyring.glance

echo "[5/5] Syncing database and restarting..."
sudo -u glance glance-manage db_sync
sudo systemctl restart glance-api
sudo systemctl enable glance-api

echo ""
echo "Testing Glance..."
source ~/admin-openrc
openstack image list

echo ""
echo "=== Glance installed and configured ==="
echo "Next: Run 19-placement-db.sh"
