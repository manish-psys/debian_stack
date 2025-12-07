#!/bin/bash
###############################################################################
# 33-horizon-install.sh
# Install and configure OpenStack Horizon Dashboard
#
# This script:
# - Installs openstack-dashboard package
# - Configures local_settings.py for Keystone v3
# - Sets up memcached session backend
# - Configures proper API versions
# - Enables all installed OpenStack services in dashboard
#
# Prerequisites:
# - Keystone operational
# - Memcached running
# - Apache2 running (for Keystone)
###############################################################################
set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/openstack-env.sh" ]; then
    source "$SCRIPT_DIR/openstack-env.sh"
elif [ -f "./openstack-env.sh" ]; then
    source "./openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found!"
    exit 1
fi

echo "=== Step 33: Horizon Dashboard Installation ==="

# Configuration
HORIZON_CONF="/etc/openstack-dashboard/local_settings.py"
TIME_ZONE="Asia/Kolkata"  # Change to your timezone

###############################################################################
# [1/6] Prerequisites Check
###############################################################################
echo "[1/6] Checking prerequisites..."

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
    exit 1
fi
echo "  ✓ Apache2 running"

###############################################################################
# [2/6] Install Horizon Package
###############################################################################
echo "[2/6] Installing Horizon dashboard..."

if dpkg -l | grep -q "openstack-dashboard"; then
    echo "  ✓ openstack-dashboard already installed"
else
    sudo apt update
    sudo apt install -y openstack-dashboard
    echo "  ✓ openstack-dashboard installed"
fi

# Verify installation
dpkg -l | grep -E "openstack-dashboard" | head -3

###############################################################################
# [3/6] Backup Original Configuration
###############################################################################
echo "[3/6] Backing up original configuration..."

if [ -f "${HORIZON_CONF}.orig" ]; then
    echo "  ✓ Backup already exists"
else
    sudo cp "$HORIZON_CONF" "${HORIZON_CONF}.orig"
    echo "  ✓ Original config backed up"
fi

###############################################################################
# [4/6] Configure Horizon
###############################################################################
echo "[4/6] Configuring Horizon..."

# Function to update Python settings file
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

# Basic settings
echo "  Configuring basic settings..."
update_setting "OPENSTACK_HOST" "\"${CONTROLLER_IP}\""
update_setting "ALLOWED_HOSTS" "['*', 'localhost', '${CONTROLLER_IP}', '${CONTROLLER_HOSTNAME}']"
update_setting "TIME_ZONE" "\"${TIME_ZONE}\""

# Keystone settings
echo "  Configuring Keystone integration..."
update_setting "OPENSTACK_KEYSTONE_URL" "\"http://${CONTROLLER_IP}:5000/v3\""
update_setting "OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT" "True"
update_setting "OPENSTACK_KEYSTONE_DEFAULT_DOMAIN" "\"Default\""

# Remove any existing custom config block to avoid duplicates
sudo sed -i '/^# === CUSTOM OPENSTACK CONFIG ===/,/^# === END CUSTOM CONFIG ===/d' "$HORIZON_CONF"

# Add comprehensive configuration block
echo "  Adding custom configuration block..."
cat <<EOF | sudo tee -a "$HORIZON_CONF" > /dev/null

# === CUSTOM OPENSTACK CONFIG ===
# Added by 33-horizon-install.sh

# Session engine - use memcached
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': '127.0.0.1:11211',
    },
}

# API versions
OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "image": 2,
    "volume": 3,
}

# Default role for new users
OPENSTACK_KEYSTONE_DEFAULT_ROLE = "member"

# Disable SSL certificate verification (for self-signed certs)
OPENSTACK_SSL_NO_VERIFY = True

# Enable services in dashboard
OPENSTACK_NEUTRON_NETWORK = {
    'enable_router': True,
    'enable_quotas': True,
    'enable_ipv6': False,
    'enable_distributed_router': False,
    'enable_ha_router': False,
    'enable_fip_topology_check': True,
}

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
    'create_volume': False,  # Don't create volume by default for Ceph
}

# Console settings
CONSOLE_TYPE = "AUTO"

# Password validation (optional - simplify for lab)
# HORIZON_PASSWORD_REQUIREMENTS = {}

# === END CUSTOM CONFIG ===
EOF

echo "  ✓ Configuration updated"

###############################################################################
# [5/6] Fix Apache Configuration
###############################################################################
echo "[5/6] Checking Apache configuration..."

# Debian-specific: Ensure horizon is enabled in Apache
APACHE_HORIZON_CONF="/etc/apache2/conf-available/openstack-dashboard.conf"

if [ -f "$APACHE_HORIZON_CONF" ]; then
    # Enable the config if not already
    if [ ! -L /etc/apache2/conf-enabled/openstack-dashboard.conf ]; then
        sudo a2enconf openstack-dashboard
        echo "  ✓ Enabled openstack-dashboard Apache config"
    else
        echo "  ✓ Apache config already enabled"
    fi
else
    echo "  ⚠ Apache config not found at expected location"
    echo "    Dashboard may need manual Apache configuration"
fi

# Ensure mod_wsgi is enabled
if ! apache2ctl -M 2>/dev/null | grep -q wsgi; then
    sudo a2enmod wsgi
    echo "  ✓ Enabled mod_wsgi"
else
    echo "  ✓ mod_wsgi already enabled"
fi

###############################################################################
# [6/6] Restart Services
###############################################################################
echo "[6/6] Restarting Apache..."

# Collect static files (may be needed after config changes)
# sudo python3 /usr/share/openstack-dashboard/manage.py collectstatic --noinput 2>/dev/null || true

# Test Apache config
if sudo apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    echo "  ✓ Apache config syntax OK"
else
    echo "  ✗ Apache config error!"
    sudo apache2ctl configtest
    exit 1
fi

# Restart Apache
sudo systemctl restart apache2
sleep 3

if systemctl is-active --quiet apache2; then
    echo "  ✓ Apache restarted successfully"
else
    echo "  ✗ Apache failed to start!"
    sudo journalctl -u apache2 --no-pager -n 20
    exit 1
fi

###############################################################################
# Verification
###############################################################################
echo ""
echo "Verifying Horizon installation..."

# Check if Horizon is accessible
HORIZON_URL="http://${CONTROLLER_IP}/horizon"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${HORIZON_URL}/auth/login/" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✓ Horizon dashboard accessible (HTTP 200)"
elif [ "$HTTP_CODE" = "302" ]; then
    echo "  ✓ Horizon dashboard accessible (HTTP 302 redirect)"
else
    echo "  ⚠ Horizon returned HTTP ${HTTP_CODE}"
    echo "    This might be normal - try accessing in browser"
fi

# Check Apache error log for horizon issues
if sudo grep -i "error" /var/log/apache2/error.log 2>/dev/null | tail -5 | grep -qi "horizon\|dashboard"; then
    echo "  ⚠ Found recent Horizon-related errors in Apache log"
    echo "    Check: sudo tail -20 /var/log/apache2/error.log"
fi

echo ""
echo "=========================================="
echo "=== Horizon Dashboard Installed ==="
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
echo "Apache config: ${APACHE_HORIZON_CONF}"
echo ""
echo "Available features:"
echo "  ✓ Identity (Keystone) - Users, Projects, Roles"
echo "  ✓ Compute (Nova) - Instances, Flavors, Keypairs"
echo "  ✓ Network (Neutron) - Networks, Routers, Security Groups"
echo "  ✓ Volume (Cinder) - Volumes, Snapshots"
echo "  ✓ Image (Glance) - Images"
echo ""
echo "Troubleshooting:"
echo "  # Check Apache status"
echo "  sudo systemctl status apache2"
echo ""
echo "  # View Horizon logs"
echo "  sudo tail -f /var/log/apache2/error.log"
echo ""
echo "  # Clear Horizon cache if issues"
echo "  sudo rm -rf /var/lib/openstack-dashboard/secret-key"
echo "  sudo systemctl restart apache2"
echo ""
echo "Next: Access the dashboard and verify all services are visible"
