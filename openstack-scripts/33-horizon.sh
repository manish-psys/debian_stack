#!/bin/bash
###############################################################################
# 33-horizon.sh
# Install and configure OpenStack Horizon Dashboard
# Idempotent - safe to run multiple times
#
# This script follows the official OpenStack documentation for Debian:
# https://docs.openstack.org/horizon/latest/install/install-debian.html
#
# This script:
# - Installs openstack-dashboard-apache package (includes Apache config)
# - Configures local_settings.py for Keystone v3
# - Configures memcached session storage
# - Reloads Apache
#
# Prerequisites:
# - Keystone operational (script 15)
# - Memcached running (script 07)
# - Apache2 running (for Keystone)
#
# Key points:
# 1. openstack-dashboard-apache handles Apache configuration automatically
# 2. Dashboard is accessible at /horizon by default
# 3. Uses memcached for session storage
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Source shared environment
# =============================================================================
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

echo "=== Step 33: Horizon Dashboard Installation ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo ""

# Configuration
HORIZON_CONF="/etc/openstack-dashboard/local_settings.py"
TIME_ZONE="Asia/Kolkata"  # Change to your timezone

# Error counter
ERRORS=0

###############################################################################
# [1/7] Fix Apache SSL Configuration (if broken)
###############################################################################
echo "[1/7] Ensuring Apache configuration is valid..."

# LESSON LEARNED: default-ssl.conf may be enabled without SSL module loaded
# This causes Apache to fail. Fix it before proceeding.
if [ -f /etc/apache2/sites-enabled/default-ssl.conf ]; then
    # SSL site is enabled - ensure SSL module is also enabled
    if ! apache2ctl -M 2>/dev/null | grep -q "ssl_module"; then
        echo "  Enabling SSL module (required by default-ssl.conf)..."
        sudo a2enmod ssl
        echo "  ✓ SSL module enabled"
    else
        echo "  ✓ SSL module already enabled"
    fi

    # Generate self-signed certificate if not exists
    SSL_CERT="/etc/ssl/certs/ssl-cert-snakeoil.pem"
    SSL_KEY="/etc/ssl/private/ssl-cert-snakeoil.key"
    if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
        echo "  Generating self-signed SSL certificate..."
        sudo apt-get install -y ssl-cert
        sudo make-ssl-cert generate-default-snakeoil --force-overwrite
        echo "  ✓ Self-signed certificate generated"
    else
        echo "  ✓ SSL certificate exists"
    fi
fi

# Verify Apache config syntax before proceeding
if ! sudo apache2ctl configtest 2>/dev/null; then
    echo "  Apache config has errors. Attempting to fix..."
    # If SSL site causes issues and we can't fix, disable it
    if sudo apache2ctl configtest 2>&1 | grep -q "SSLEngine\|ssl"; then
        echo "  Disabling problematic SSL site..."
        sudo a2dissite default-ssl 2>/dev/null || true
        echo "  ✓ Disabled default-ssl site"
    fi
fi

# Ensure Apache config is now valid
if sudo apache2ctl configtest 2>/dev/null; then
    echo "  ✓ Apache configuration valid"
else
    echo "  ✗ ERROR: Apache configuration still invalid!"
    sudo apache2ctl configtest
    exit 1
fi

# Start Apache if not running
if ! systemctl is-active --quiet apache2; then
    echo "  Starting Apache..."
    sudo systemctl start apache2
    sleep 2
fi

###############################################################################
# [2/7] Prerequisites Check
###############################################################################
echo ""
echo "[2/7] Checking prerequisites..."

# Check Keystone is accessible
if ! curl -s "http://${CONTROLLER_IP}:5000/v3" | grep -q "version"; then
    echo "  ✗ ERROR: Keystone not accessible at http://${CONTROLLER_IP}:5000"
    exit 1
fi
echo "  ✓ Keystone accessible"

# Check memcached is running
if ! systemctl is-active --quiet memcached; then
    echo "  ✗ ERROR: memcached not running!"
    echo "    Start with: sudo systemctl start memcached"
    exit 1
fi
echo "  ✓ Memcached running"

# Check Apache is running
if ! systemctl is-active --quiet apache2; then
    echo "  ✗ ERROR: Apache2 not running!"
    sudo journalctl -u apache2 --no-pager -n 10
    exit 1
fi
echo "  ✓ Apache2 running"

###############################################################################
# [3/7] Install Horizon Package
###############################################################################
echo ""
echo "[3/7] Installing Horizon dashboard..."

# Use openstack-dashboard-apache which includes Apache configuration
if dpkg -l | grep -q "^ii.*openstack-dashboard-apache"; then
    echo "  ✓ openstack-dashboard-apache already installed"
else
    sudo apt update
    # Pre-configure debconf to use /horizon URL (not webroot)
    echo "openstack-dashboard-apache openstack-dashboard/activate-vhost boolean true" | sudo debconf-set-selections
    echo "openstack-dashboard-apache openstack-dashboard/use-ssl boolean false" | sudo debconf-set-selections

    # Install with automatic Apache configuration
    sudo DEBIAN_FRONTEND=noninteractive apt install -y openstack-dashboard-apache
    echo "  ✓ openstack-dashboard-apache installed"
fi

# Verify installation
dpkg -l | grep -E "^ii.*(openstack-dashboard|horizon)" | head -5

# Ensure wsgi module is enabled (package dependency doesn't auto-enable it)
if ! apache2ctl -M 2>/dev/null | grep -q "wsgi_module"; then
    sudo a2enmod wsgi
    echo "  ✓ Enabled mod_wsgi"
else
    echo "  ✓ mod_wsgi already enabled"
fi

###############################################################################
# [4/7] Backup Original Configuration
###############################################################################
echo ""
echo "[4/7] Backing up original configuration..."

if [ -f "${HORIZON_CONF}.orig" ]; then
    echo "  ✓ Backup already exists"
else
    sudo cp "$HORIZON_CONF" "${HORIZON_CONF}.orig"
    echo "  ✓ Original config backed up"
fi

###############################################################################
# [5/7] Configure Horizon local_settings.py
###############################################################################
echo ""
echo "[5/7] Configuring Horizon..."

# Function to update Python settings file (idempotent)
update_setting() {
    local key="$1"
    local value="$2"
    local file="$HORIZON_CONF"

    # Check if setting exists (uncommented)
    if sudo grep -q "^${key} = " "$file"; then
        sudo sed -i "s|^${key} = .*|${key} = ${value}|" "$file"
    # Check if setting exists (commented)
    elif sudo grep -q "^#${key} = " "$file"; then
        sudo sed -i "s|^#${key} = .*|${key} = ${value}|" "$file"
    else
        # Append if not found
        echo "${key} = ${value}" | sudo tee -a "$file" > /dev/null
    fi
}

# Basic settings per official docs
echo "  Configuring OPENSTACK_HOST..."
update_setting "OPENSTACK_HOST" "\"${CONTROLLER_IP}\""

echo "  Configuring ALLOWED_HOSTS..."
update_setting "ALLOWED_HOSTS" "['*', 'localhost', '${CONTROLLER_IP}', '${CONTROLLER_HOSTNAME}']"

echo "  Configuring TIME_ZONE..."
update_setting "TIME_ZONE" "\"${TIME_ZONE}\""

# Keystone URL - per official docs format
echo "  Configuring OPENSTACK_KEYSTONE_URL..."
update_setting "OPENSTACK_KEYSTONE_URL" "\"http://${CONTROLLER_IP}:5000/identity/v3\""

echo "  Configuring OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT..."
update_setting "OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT" "True"

echo "  Configuring OPENSTACK_KEYSTONE_DEFAULT_DOMAIN..."
update_setting "OPENSTACK_KEYSTONE_DEFAULT_DOMAIN" "\"Default\""

# Remove any existing custom config block to avoid duplicates (idempotent)
sudo sed -i '/^# === CUSTOM OPENSTACK CONFIG ===/,/^# === END CUSTOM CONFIG ===/d' "$HORIZON_CONF"

# Add configuration block per official docs
echo "  Adding configuration block..."
cat <<'HORIZON_EOF' | sudo tee -a "$HORIZON_CONF" > /dev/null

# === CUSTOM OPENSTACK CONFIG ===
# Added by 33-horizon.sh
# Based on: https://docs.openstack.org/horizon/latest/install/install-debian.html

# =============================================================================
# Session Configuration - use memcached (per official docs)
# =============================================================================
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'

CACHES = {
    'default': {
         'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
HORIZON_EOF

# Add memcached location with variable substitution
echo "         'LOCATION': '${CONTROLLER_IP}:11211'," | sudo tee -a "$HORIZON_CONF" > /dev/null

cat <<'HORIZON_EOF' | sudo tee -a "$HORIZON_CONF" > /dev/null
    }
}

# =============================================================================
# API Versions (per official docs)
# =============================================================================
OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "image": 2,
    "volume": 3,
}

# =============================================================================
# Neutron Network Settings (with router support for OVN)
# =============================================================================
OPENSTACK_NEUTRON_NETWORK = {
    'enable_router': True,
    'enable_quotas': True,
    'enable_ipv6': False,
    'enable_distributed_router': False,
    'enable_ha_router': False,
    'enable_fip_topology_check': True,
}

# =============================================================================
# Additional Settings
# =============================================================================

# Default role for new users
OPENSTACK_KEYSTONE_DEFAULT_ROLE = "member"

# Disable SSL certificate verification (for self-signed certs)
OPENSTACK_SSL_NO_VERIFY = True

# Cinder (Volume) settings
OPENSTACK_CINDER_FEATURES = {
    'enable_backup': False,
}

# Default settings for new instances
LAUNCH_INSTANCE_DEFAULTS = {
    'config_drive': False,
    'enable_scheduler_hints': True,
    'disable_image': False,
    'disable_instance_snapshot': False,
    'disable_volume': False,
    'disable_volume_snapshot': False,
    'create_volume': False,
}

# Console settings
CONSOLE_TYPE = "AUTO"

# === END CUSTOM CONFIG ===
HORIZON_EOF

echo "  ✓ local_settings.py configured"

###############################################################################
# [6/7] Reload Apache
###############################################################################
echo ""
echo "[6/7] Reloading Apache..."

# Reload Apache configuration (per official docs)
sudo systemctl reload apache2
sleep 2

if systemctl is-active --quiet apache2; then
    echo "  ✓ Apache reloaded successfully"
else
    echo "  ✗ Apache failed!"
    sudo journalctl -u apache2 --no-pager -n 20
    ERRORS=$((ERRORS+1))
fi

###############################################################################
# [7/7] Verification
###############################################################################
echo ""
echo "[7/7] Verifying Horizon installation..."

# Wait for WSGI to initialize
sleep 3

# Check if Horizon is accessible
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}/horizon/auth/login/" --max-time 30 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✓ Horizon login page accessible (HTTP 200)"
elif [ "$HTTP_CODE" = "302" ]; then
    echo "  ✓ Horizon responding with redirect (HTTP 302)"
else
    echo "  ⚠ Horizon returned HTTP ${HTTP_CODE}"
    echo "    Check: sudo tail -30 /var/log/apache2/error.log"
    ERRORS=$((ERRORS+1))
fi

# Verify Keystone is still accessible
KEYSTONE_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:5000/v3" 2>/dev/null || echo "000")
if [ "$KEYSTONE_CODE" = "200" ]; then
    echo "  ✓ Keystone still accessible (HTTP 200)"
else
    echo "  ⚠ Keystone returned HTTP ${KEYSTONE_CODE}"
    ERRORS=$((ERRORS+1))
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Horizon Dashboard Installed ==="
else
    echo "=== Horizon Installed with $ERRORS Error(s) ==="
fi
echo "=========================================="
echo ""
echo "Dashboard URL: http://${CONTROLLER_IP}/horizon"
echo ""
echo "Login credentials:"
echo "  Domain:   Default"
echo "  Username: admin"
echo "  Password: ${ADMIN_PASS}"
echo ""
echo "Configuration file: ${HORIZON_CONF}"
echo ""
echo "Apache logs:"
echo "  sudo tail -f /var/log/apache2/error.log"
echo ""
echo "Troubleshooting:"
echo "  # If login fails, restart Apache"
echo "  sudo systemctl restart apache2"
echo ""
echo "  # Check Horizon config syntax"
echo "  sudo python3 -c \"import sys; sys.path.insert(0,'/etc/openstack-dashboard'); import local_settings\""
echo ""
echo "Next: Access the dashboard at http://${CONTROLLER_IP}/horizon"
