#!/bin/bash
###############################################################################
# 15-keystone-install.sh
# Install and configure Keystone (Identity service)
###############################################################################
set -e

# Configuration - EDIT THESE
KEYSTONE_DB_PASS="pspl@#321P"      # Must match 14-keystone-db.sh
ADMIN_PASS="pspl@#321P"            # Admin user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 15: Keystone Installation ==="

# ============================================================================
# PART 0: Install crudini if not present
# ============================================================================
echo "[0/6] Checking for crudini..."
if ! command -v crudini &> /dev/null; then
    echo "  Installing crudini..."
    sudo apt install -y crudini
    echo "  ✓ crudini installed"
else
    echo "  ✓ crudini already installed"
fi

# ============================================================================
# PART 1: Install Keystone packages
# ============================================================================
echo "[1/6] Installing Keystone packages..."
sudo apt -t bullseye-wallaby-backports install -y keystone \
    apache2 libapache2-mod-wsgi-py3

# ============================================================================
# PART 2: Configure Keystone
# ============================================================================
echo "[2/6] Configuring Keystone..."

# Backup original config if not already backed up
if [ ! -f /etc/keystone/keystone.conf.orig ]; then
    sudo cp /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig
fi

# Update database connection
sudo crudini --set /etc/keystone/keystone.conf database connection \
    "mysql+pymysql://keystone:${KEYSTONE_DB_PASS}@localhost/keystone"

# Configure token provider
sudo crudini --set /etc/keystone/keystone.conf token provider fernet

echo "  ✓ Keystone configuration updated"

# ============================================================================
# PART 3: Sync Keystone database
# ============================================================================
echo "[3/6] Syncing Keystone database..."
sudo -u keystone keystone-manage db_sync
echo "  ✓ Database synced"

# ============================================================================
# PART 4: Initialize Fernet keys
# ============================================================================
echo "[4/6] Initializing Fernet keys..."
sudo keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
sudo keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
echo "  ✓ Fernet keys initialized"

# ============================================================================
# PART 5: Bootstrap Keystone
# ============================================================================
echo "[5/6] Bootstrapping Keystone..."
sudo keystone-manage bootstrap --bootstrap-password ${ADMIN_PASS} \
    --bootstrap-admin-url http://${IP_ADDRESS}:5000/v3/ \
    --bootstrap-internal-url http://${IP_ADDRESS}:5000/v3/ \
    --bootstrap-public-url http://${IP_ADDRESS}:5000/v3/ \
    --bootstrap-region-id RegionOne
echo "  ✓ Keystone bootstrapped"

# ============================================================================
# PART 6: Configure Apache
# ============================================================================
echo "[6/6] Configuring Apache..."

# Set ServerName
echo "ServerName ${IP_ADDRESS}" | sudo tee /etc/apache2/conf-available/servername.conf
sudo a2enconf servername 2>/dev/null || true

# Restart Apache
sudo systemctl restart apache2
sudo systemctl enable apache2

echo "  ✓ Apache configured and restarted"

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "Verifying Keystone..."
sleep 2

# Check Apache is running
if systemctl is-active --quiet apache2; then
    echo "  ✓ Apache is running"
else
    echo "  ✗ Apache is NOT running!"
    exit 1
fi

# Check Keystone port is listening
if sudo ss -tlnp | grep -q ':5000'; then
    echo "  ✓ Keystone is listening on port 5000"
else
    echo "  ✗ Keystone is NOT listening on port 5000!"
    exit 1
fi

echo ""
echo "=== Keystone installed successfully ==="
echo ""
echo "Admin credentials:"
echo "  Username: admin"
echo "  Password: ${ADMIN_PASS}"
echo "  Auth URL: http://${IP_ADDRESS}:5000/v3/"
echo ""
echo "IMPORTANT: Save these credentials securely!"
echo "Next: Run 16-keystone-openrc.sh"
