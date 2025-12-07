#!/bin/bash
###############################################################################
# 30-cinder-install.sh
# Install and configure Cinder (Block Storage) with Ceph backend
###############################################################################
set -e

# Configuration - EDIT THESE
CINDER_DB_PASS="cinderdbpass"    # Must match 28-cinder-db.sh
CINDER_PASS="cinderpass"          # Must match 28-cinder-db.sh
RABBIT_PASS="guest"
IP_ADDRESS="192.168.2.9"

echo "=== Step 30: Cinder Installation ==="

echo "[1/5] Installing Cinder packages..."
sudo apt -t bullseye-wallaby-backports install -y \
    cinder-api cinder-scheduler cinder-volume

echo "[2/5] Backing up original config..."
sudo cp /etc/cinder/cinder.conf /etc/cinder/cinder.conf.orig

echo "[3/5] Configuring Cinder..."
# Database
sudo crudini --set /etc/cinder/cinder.conf database connection \
    "mysql+pymysql://cinder:${CINDER_DB_PASS}@localhost/cinder"

# Default
sudo crudini --set /etc/cinder/cinder.conf DEFAULT transport_url "rabbit://guest:${RABBIT_PASS}@localhost:5672/"
sudo crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy "keystone"
sudo crudini --set /etc/cinder/cinder.conf DEFAULT my_ip "${IP_ADDRESS}"
sudo crudini --set /etc/cinder/cinder.conf DEFAULT enabled_backends "ceph"
sudo crudini --set /etc/cinder/cinder.conf DEFAULT glance_api_servers "http://${IP_ADDRESS}:9292"

# Keystone auth
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken www_authenticate_uri "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken username "cinder"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken password "${CINDER_PASS}"

# Oslo concurrency
sudo crudini --set /etc/cinder/cinder.conf oslo_concurrency lock_path "/var/lib/cinder/tmp"

# Ceph backend
sudo crudini --set /etc/cinder/cinder.conf ceph volume_driver "cinder.volume.drivers.rbd.RBDDriver"
sudo crudini --set /etc/cinder/cinder.conf ceph rbd_pool "volumes"
sudo crudini --set /etc/cinder/cinder.conf ceph rbd_ceph_conf "/etc/ceph/ceph.conf"
sudo crudini --set /etc/cinder/cinder.conf ceph rbd_user "cinder"
sudo crudini --set /etc/cinder/cinder.conf ceph volume_backend_name "ceph"

echo "[4/5] Setting up Ceph keyring for Cinder..."
sudo cp /etc/ceph/ceph.client.cinder.keyring /etc/ceph/ceph.client.cinder.keyring.cinder
sudo chown cinder:cinder /etc/ceph/ceph.client.cinder.keyring.cinder

echo "[5/5] Syncing database and starting services..."
sudo -u cinder cinder-manage db sync

sudo systemctl restart cinder-api cinder-scheduler cinder-volume
sudo systemctl enable cinder-api cinder-scheduler cinder-volume

echo ""
echo "Verifying Cinder..."
sleep 3
source ~/admin-openrc
openstack volume service list

echo ""
echo "=== Cinder installed ==="
echo "Next: Run 30-nova-ceph.sh"
