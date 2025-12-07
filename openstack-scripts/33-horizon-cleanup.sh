#!/bin/bash
###############################################################################
# 33-horizon-cleanup.sh
# Remove Horizon Dashboard
#
# This script:
# - Disables and removes Horizon Apache site
# - Removes openstack-dashboard package
# - Cleans up configuration files and static directory
# - Re-enables default Apache site
#
# NOTE: Uses safe removal to avoid cascade deletion
###############################################################################
set -e

echo "=== Cleanup: Horizon Dashboard ==="

###############################################################################
# [1/5] Disable Horizon Apache Site
###############################################################################
echo "[1/5] Disabling Horizon Apache site..."

if [ -L /etc/apache2/sites-enabled/horizon.conf ]; then
    sudo a2dissite horizon
    echo "  ✓ Disabled Horizon site"
else
    echo "  ✓ Horizon site already disabled"
fi

###############################################################################
# [2/5] Re-enable Default Site
###############################################################################
echo "[2/5] Re-enabling default Apache site..."

if [ ! -L /etc/apache2/sites-enabled/000-default.conf ]; then
    sudo a2ensite 000-default
    echo "  ✓ Enabled default site"
else
    echo "  ✓ Default site already enabled"
fi

###############################################################################
# [3/5] Remove Horizon Apache Config
###############################################################################
echo "[3/5] Removing Horizon Apache configuration..."

if [ -f /etc/apache2/sites-available/horizon.conf ]; then
    sudo rm -f /etc/apache2/sites-available/horizon.conf
    echo "  ✓ Removed /etc/apache2/sites-available/horizon.conf"
else
    echo "  ✓ Apache config already removed"
fi

###############################################################################
# [4/5] Remove Package
###############################################################################
echo "[4/5] Removing Horizon package..."

if dpkg -l | grep -q "^ii.*openstack-dashboard"; then
    # Use --no-auto-remove to prevent cascade deletion
    sudo apt remove --no-auto-remove -y openstack-dashboard
    echo "  ✓ openstack-dashboard removed"
else
    echo "  ✓ openstack-dashboard not installed"
fi

###############################################################################
# [5/5] Cleanup Files and Restart Apache
###############################################################################
echo "[5/5] Cleaning up files and restarting Apache..."

# Remove config directory
if [ -d /etc/openstack-dashboard ]; then
    sudo rm -rf /etc/openstack-dashboard
    echo "  ✓ Removed /etc/openstack-dashboard"
else
    echo "  ✓ Config directory already removed"
fi

# Remove static files and cache
if [ -d /var/lib/openstack-dashboard ]; then
    sudo rm -rf /var/lib/openstack-dashboard
    echo "  ✓ Removed /var/lib/openstack-dashboard"
fi

# Restart Apache to apply changes
sudo systemctl restart apache2
echo "  ✓ Apache restarted"

# Verify Keystone still works
if curl -s "http://localhost:5000/v3" | grep -q "version"; then
    echo "  ✓ Keystone still accessible"
else
    echo "  ⚠ Keystone may need attention"
fi

echo ""
echo "=========================================="
echo "=== Horizon Cleanup Complete ==="
echo "=========================================="
echo ""
echo "Horizon dashboard has been removed."
echo "Apache continues to serve Keystone on port 5000."
echo ""
echo "To reinstall: ./33-horizon-install.sh"
