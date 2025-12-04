#!/bin/bash
###############################################################################
# 15-keystone-install.sh
# Install and configure Keystone (Identity service)
###############################################################################
set -e

# Configuration - EDIT THESE
KEYSTONE_DB_PASS="keystonedbpass"  # Must match 14-keystone-db.sh
ADMIN_PASS="adminpass"             # Admin user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 15: Keystone Installation ==="

echo "[1/6] Installing Keystone packages..."
sudo apt -t bullseye-wallaby-backports install -y keystone \
    apache2 libapache2-mod-wsgi-py3

echo "[2/6] Configuring Keystone..."
sudo cp /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig

# Update database connection
sudo crudini --set /etc/keystone/keystone.conf database connection \
    "mysql+pymysql://keystone:${KEYSTONE_DB_PASS}@localhost/keystone"

# Configure token provider
sudo crudini --set /etc/keystone/keystone.conf token provider fernet

echo "[3/6] Syncing Keystone database..."
sudo -u keystone keystone-manage db_sync

echo "[4/6] Initializing Fernet keys..."
sudo keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
sudo keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

echo "[5/6] Bootstrapping Keystone..."
sudo keystone-manage bootstrap --bootstrap-password ${ADMIN_PASS} \
    --bootstrap-admin-url http://${IP_ADDRESS}:5000/v3/ \
    --bootstrap-internal-url http://${IP_ADDRESS}:5000/v3/ \
    --bootstrap-public-url http://${IP_ADDRESS}:5000/v3/ \
    --bootstrap-region-id RegionOne

echo "[6/6] Configuring Apache..."
# Set ServerName
echo "ServerName ${IP_ADDRESS}" | sudo tee /etc/apache2/conf-available/servername.conf
sudo a2enconf servername

# Restart Apache
sudo systemctl restart apache2

echo ""
echo "=== Keystone installed ==="
echo "Admin password: ${ADMIN_PASS}"
echo ""
echo "IMPORTANT: Save this password securely!"
echo "Next: Run 16-keystone-openrc.sh"
