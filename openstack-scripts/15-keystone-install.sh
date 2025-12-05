#!/bin/bash
###############################################################################
# 15-keystone-install.sh
# Install and configure Keystone (Identity service)
# Robust version with dbconfig-common handling
###############################################################################
set -e

# Configuration - EDIT THESE
KEYSTONE_DB_PASS="keystonepass123"    # Must match 14-keystone-db.sh
ADMIN_PASS="keystonepass123"          # Admin user password
IP_ADDRESS="192.168.2.9"

echo "=== Step 15: Keystone Installation ==="

# ============================================================================
# PART 0: Install prerequisites
# ============================================================================
echo "[0/7] Installing prerequisites..."
if ! command -v crudini &> /dev/null; then
    sudo apt install -y crudini
    echo "  ✓ crudini installed"
else
    echo "  ✓ crudini already installed"
fi

# ============================================================================
# PART 1: Pre-seed dbconfig-common to skip automatic database configuration
# ============================================================================
echo "[1/7] Configuring dbconfig-common to skip automatic DB setup..."
sudo mkdir -p /etc/dbconfig-common

cat <<EOF | sudo tee /etc/dbconfig-common/keystone.conf > /dev/null
# Managed by OpenStack deployment scripts
dbc_install='false'
dbc_upgrade='false'
dbc_remove=''
dbc_dbtype='mysql'
dbc_dbuser='keystone'
dbc_dbpass='${KEYSTONE_DB_PASS}'
dbc_dbserver='localhost'
dbc_dbport=''
dbc_dbname='keystone'
dbc_dbadmin='root'
dbc_basepath=''
dbc_ssl=''
dbc_authmethod_admin=''
dbc_authmethod_user=''
EOF

# Pre-seed debconf to skip all interactive prompts
echo "keystone keystone/dbconfig-install boolean false" | sudo debconf-set-selections
echo "keystone keystone/dbconfig-upgrade boolean false" | sudo debconf-set-selections
echo "keystone keystone/dbconfig-remove boolean false" | sudo debconf-set-selections

echo "  ✓ dbconfig-common configured to skip automatic setup"

# ============================================================================
# PART 2: Install Keystone packages (non-interactive)
# ============================================================================
echo "[2/7] Installing Keystone packages..."
export DEBIAN_FRONTEND=noninteractive

sudo -E apt-get -t bullseye-wallaby-backports install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    keystone apache2 libapache2-mod-wsgi-py3

echo "  ✓ Keystone packages installed"

# ============================================================================
# PART 3: Configure Keystone
# ============================================================================
echo "[3/7] Configuring Keystone..."

# Backup original config if not already backed up
if [ -f /etc/keystone/keystone.conf ] && [ ! -f /etc/keystone/keystone.conf.orig ]; then
    sudo cp /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig
fi

# Update database connection
sudo crudini --set /etc/keystone/keystone.conf database connection \
    "mysql+pymysql://keystone:${KEYSTONE_DB_PASS}@localhost/keystone"

# Configure token provider
sudo crudini --set /etc/keystone/keystone.conf token provider fernet

# Verify configuration was set
if sudo grep -q "^connection = mysql" /etc/keystone/keystone.conf; then
    echo "  ✓ Database connection configured"
else
    echo "  ✗ ERROR: Database connection not set!"
    exit 1
fi

# ============================================================================
# PART 4: Sync Keystone database
# ============================================================================
echo "[4/7] Syncing Keystone database..."

if sudo -u keystone keystone-manage db_sync 2>&1; then
    echo "  ✓ Database synced successfully"
else
    echo "  ✗ ERROR: Database sync failed!"
    echo "  Check database connection and credentials"
    exit 1
fi

# ============================================================================
# PART 5: Initialize Fernet keys
# ============================================================================
echo "[5/7] Initializing Fernet keys..."

sudo mkdir -p /etc/keystone/fernet-keys
sudo mkdir -p /etc/keystone/credential-keys

sudo keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
sudo keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

echo "  ✓ Fernet keys initialized"

# ============================================================================
# PART 6: Bootstrap Keystone
# ============================================================================
echo "[6/7] Bootstrapping Keystone..."

sudo keystone-manage bootstrap --bootstrap-password "${ADMIN_PASS}" \
    --bootstrap-admin-url "http://${IP_ADDRESS}:5000/v3/" \
    --bootstrap-internal-url "http://${IP_ADDRESS}:5000/v3/" \
    --bootstrap-public-url "http://${IP_ADDRESS}:5000/v3/" \
    --bootstrap-region-id RegionOne

echo "  ✓ Keystone bootstrapped"

# ============================================================================
# PART 7: Configure Apache
# ============================================================================
echo "[7/7] Configuring Apache..."

# Set ServerName to avoid warning
echo "ServerName ${IP_ADDRESS}" | sudo tee /etc/apache2/conf-available/servername.conf > /dev/null
sudo a2enconf servername 2>/dev/null || true

# Enable keystone site if available
if [ -f /etc/apache2/sites-available/keystone.conf ]; then
    sudo a2ensite keystone 2>/dev/null || true
fi

# Restart Apache
sudo systemctl restart apache2
sudo systemctl enable apache2

echo "  ✓ Apache configured and restarted"

# ============================================================================
# Complete any pending package configuration
# ============================================================================
sudo dpkg --configure -a 2>/dev/null || true

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "Verifying Keystone installation..."
sleep 3

ERRORS=0

# Check Apache is running
if systemctl is-active --quiet apache2; then
    echo "  ✓ Apache is running"
else
    echo "  ✗ Apache is NOT running!"
    ERRORS=$((ERRORS + 1))
fi

# Check Keystone port is listening
if sudo ss -tlnp | grep -q ':5000'; then
    echo "  ✓ Keystone is listening on port 5000"
else
    echo "  ✗ Keystone is NOT listening on port 5000!"
    ERRORS=$((ERRORS + 1))
fi

# Check keystone package is properly configured
if dpkg -l keystone 2>/dev/null | grep -q "^ii"; then
    echo "  ✓ Keystone package is properly installed"
else
    echo "  ✗ Keystone package has issues!"
    ERRORS=$((ERRORS + 1))
fi

# Test Keystone API
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${IP_ADDRESS}:5000/v3/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "300" ]; then
    echo "  ✓ Keystone API is responding (HTTP $HTTP_CODE)"
else
    echo "  ⚠ Keystone API returned HTTP $HTTP_CODE (may still be starting)"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=== Keystone installed successfully ==="
else
    echo "=== Keystone installation completed with $ERRORS error(s) ==="
    echo "Check logs: sudo journalctl -u apache2 -n 50"
fi

echo ""
echo "Admin credentials:"
echo "  Username: admin"
echo "  Password: ${ADMIN_PASS}"
echo "  Auth URL: http://${IP_ADDRESS}:5000/v3/"
echo ""
echo "IMPORTANT: Save these credentials securely!"
echo "Next: Run 16-keystone-openrc.sh"
