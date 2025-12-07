#!/bin/bash
###############################################################################
# 33-horizon-install.sh
# Install and configure OpenStack Horizon Dashboard
#
# This script:
# - Installs openstack-dashboard package
# - Configures local_settings.py for Keystone v3
# - Creates Apache virtual host configuration (Debian package doesn't include it!)
# - Sets up memcached session backend
# - Configures proper API versions
# - Enables all installed OpenStack services in dashboard
#
# Prerequisites:
# - Keystone operational
# - Memcached running
# - Apache2 running (for Keystone)
#
# Note: Debian's openstack-dashboard package does NOT include Apache config.
#       This script creates it manually.
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

# Apache/WSGI paths (determined from package inspection)
APACHE_SITE="/etc/apache2/sites-available/horizon.conf"
WSGI_FILE="/usr/share/openstack-dashboard/wsgi.py"
PYTHON_PATH="/usr/lib/python3/dist-packages"
STATIC_PATH="/var/lib/openstack-dashboard/static"
HORIZON_CONF_DIR="/etc/openstack-dashboard"

###############################################################################
# [1/7] Prerequisites Check
###############################################################################
echo "[1/7] Checking prerequisites..."

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
# [2/7] Install Horizon Package
###############################################################################
echo "[2/7] Installing Horizon dashboard..."

if dpkg -l | grep -q "^ii.*openstack-dashboard "; then
    echo "  ✓ openstack-dashboard already installed"
else
    sudo apt update
    sudo apt install -y openstack-dashboard
    echo "  ✓ openstack-dashboard installed"
fi

# Verify installation
dpkg -l | grep -E "^ii.*openstack-dashboard" | head -1

# Verify WSGI file exists
if [ ! -f "$WSGI_FILE" ]; then
    echo "  ✗ ERROR: WSGI file not found: $WSGI_FILE"
    exit 1
fi
echo "  ✓ WSGI file exists"

###############################################################################
# [3/7] Backup Original Configuration
###############################################################################
echo "[3/7] Backing up original configuration..."

if [ -f "${HORIZON_CONF}.orig" ]; then
    echo "  ✓ Backup already exists"
else
    sudo cp "$HORIZON_CONF" "${HORIZON_CONF}.orig"
    echo "  ✓ Original config backed up"
fi

###############################################################################
# [4/7] Configure Horizon local_settings.py
###############################################################################
echo "[4/7] Configuring Horizon..."

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

# Remove any existing custom config block to avoid duplicates (idempotent)
sudo sed -i '/^# === CUSTOM OPENSTACK CONFIG ===/,/^# === END CUSTOM CONFIG ===/d' "$HORIZON_CONF"

# Add comprehensive configuration block
echo "  Adding custom configuration block..."
cat <<'HORIZON_EOF' | sudo tee -a "$HORIZON_CONF" > /dev/null

# === CUSTOM OPENSTACK CONFIG ===
# Added by 33-horizon-install.sh

# Session engine - use memcached
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
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
    'create_volume': False,
}

# Console settings
CONSOLE_TYPE = "AUTO"

# === END CUSTOM CONFIG ===
HORIZON_EOF

echo "  ✓ local_settings.py configured"

###############################################################################
# [5/7] Create Apache Virtual Host Configuration
###############################################################################
echo "[5/7] Creating Apache configuration..."

# NOTE: Debian's openstack-dashboard package does NOT include Apache config!
# We must create it manually.

sudo tee "$APACHE_SITE" > /dev/null <<APACHE_EOF
# OpenStack Horizon Dashboard Apache Configuration
# Created by 33-horizon-install.sh
#
# Note: Debian's openstack-dashboard package does not include this file.
# This was created manually based on OpenStack documentation.

<VirtualHost *:80>
    ServerName ${CONTROLLER_IP}
    ServerAlias ${CONTROLLER_HOSTNAME}
    
    # Redirect root to horizon
    RedirectMatch ^/\$ /horizon/
    
    # WSGI Configuration for Horizon
    WSGIScriptAlias /horizon ${WSGI_FILE}
    WSGIDaemonProcess horizon user=www-data group=www-data processes=3 threads=10 \\
        python-path=${PYTHON_PATH}:${HORIZON_CONF_DIR} display-name=horizon
    WSGIProcessGroup horizon
    WSGIApplicationGroup %{GLOBAL}
    
    # Horizon WSGI directory permissions
    <Directory /usr/share/openstack-dashboard>
        <Files wsgi.py>
            Require all granted
        </Files>
    </Directory>
    
    # Static files (CSS, JS, images)
    Alias /horizon/static ${STATIC_PATH}
    <Directory ${STATIC_PATH}>
        Options FollowSymLinks
        Require all granted
    </Directory>
    
    # Logging
    ErrorLog \${APACHE_LOG_DIR}/horizon_error.log
    CustomLog \${APACHE_LOG_DIR}/horizon_access.log combined
    LogLevel warn
</VirtualHost>
APACHE_EOF

echo "  ✓ Created Apache config: $APACHE_SITE"

###############################################################################
# [6/7] Enable Apache Modules and Site
###############################################################################
echo "[6/7] Enabling Apache modules and Horizon site..."

# Enable required modules
for mod in wsgi headers rewrite; do
    if ! apache2ctl -M 2>/dev/null | grep -q "${mod}_module"; then
        sudo a2enmod $mod
        echo "  ✓ Enabled mod_$mod"
    else
        echo "  ✓ mod_$mod already enabled"
    fi
done

# Disable default site (conflicts with Horizon on port 80)
if [ -L /etc/apache2/sites-enabled/000-default.conf ]; then
    sudo a2dissite 000-default
    echo "  ✓ Disabled default site"
else
    echo "  ✓ Default site already disabled"
fi

# Enable Horizon site (idempotent)
if [ ! -L /etc/apache2/sites-enabled/horizon.conf ]; then
    sudo a2ensite horizon
    echo "  ✓ Enabled Horizon site"
else
    echo "  ✓ Horizon site already enabled"
fi

###############################################################################
# [7/7] Test and Restart Apache
###############################################################################
echo "[7/7] Testing and restarting Apache..."

# Test Apache configuration syntax
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
    sudo journalctl -u apache2 --no-pager -n 30
    exit 1
fi

###############################################################################
# Verification
###############################################################################
echo ""
echo "Verifying Horizon installation..."

# Wait for WSGI to initialize
sleep 2

# Test Horizon URL
HORIZON_URL="http://${CONTROLLER_IP}/horizon"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${HORIZON_URL}/" --max-time 10 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✓ Horizon accessible (HTTP 200)"
elif [ "$HTTP_CODE" = "302" ]; then
    echo "  ✓ Horizon accessible (HTTP 302 - redirect to login)"
elif [ "$HTTP_CODE" = "500" ]; then
    echo "  ✗ Horizon returned HTTP 500 - check logs"
    echo "    View errors: sudo tail -30 /var/log/apache2/horizon_error.log"
else
    echo "  ⚠ Horizon returned HTTP ${HTTP_CODE}"
    echo "    Check: sudo tail -30 /var/log/apache2/horizon_error.log"
fi

# Verify Keystone is still accessible
KEYSTONE_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:5000/v3" 2>/dev/null || echo "000")
if [ "$KEYSTONE_CODE" = "200" ]; then
    echo "  ✓ Keystone still accessible (HTTP 200)"
else
    echo "  ⚠ Keystone returned HTTP ${KEYSTONE_CODE}"
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
echo "Configuration files:"
echo "  Horizon config: ${HORIZON_CONF}"
echo "  Apache config:  ${APACHE_SITE}"
echo "  Horizon logs:   /var/log/apache2/horizon_error.log"
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
echo "  # View Horizon error logs"
echo "  sudo tail -f /var/log/apache2/horizon_error.log"
echo ""
echo "  # Clear Horizon cache if issues"
echo "  sudo rm -rf /var/lib/openstack-dashboard/secret-key"
echo "  sudo systemctl restart apache2"
echo ""
echo "Next: Access the dashboard in your browser and login"
