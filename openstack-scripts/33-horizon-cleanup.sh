#!/bin/bash
###############################################################################
# 33-horizon-cleanup.sh
# Remove Horizon Dashboard
#
# This script:
# - Removes openstack-dashboard package
# - Cleans up Apache configuration
# - Removes configuration files
#
# NOTE: Uses safe removal to avoid cascade deletion
###############################################################################
set -e

echo "=== Cleanup: Horizon Dashboard ==="

###############################################################################
# [1/4] Stop Services
###############################################################################
echo "[1/4] Stopping related services..."

# Apache will continue running (needed for Keystone)
echo "  ✓ Apache will remain running (serves Keystone)"

###############################################################################
# [2/4] Remove Package
###############################################################################
echo "[2/4] Removing Horizon package..."

if dpkg -l | grep -q "openstack-dashboard"; then
    # Use --no-auto-remove to prevent cascade deletion
    sudo apt remove --no-auto-remove -y openstack-dashboard
    echo "  ✓ openstack-dashboard removed"
else
    echo "  ✓ openstack-dashboard not installed"
fi

###############################################################################
# [3/4] Disable Apache Config
###############################################################################
echo "[3/4] Disabling Apache configuration..."

if [ -L /etc/apache2/conf-enabled/openstack-dashboard.conf ]; then
    sudo a2disconf openstack-dashboard 2>/dev/null || true
    echo "  ✓ Disabled openstack-dashboard Apache config"
else
    echo "  ✓ Apache config already disabled"
fi

###############################################################################
# [4/4] Cleanup Files
###############################################################################
echo "[4/4] Cleaning up configuration files..."

# Remove config directory
if [ -d /etc/openstack-dashboard ]; then
    sudo rm -rf /etc/openstack-dashboard
    echo "  ✓ Removed /etc/openstack-dashboard"
else
    echo "  ✓ Config directory already removed"
fi

# Remove cache/data
if [ -d /var/lib/openstack-dashboard ]; then
    sudo rm -rf /var/lib/openstack-dashboard
    echo "  ✓ Removed /var/lib/openstack-dashboard"
fi

# Restart Apache to apply changes
sudo systemctl restart apache2
echo "  ✓ Apache restarted"

echo ""
echo "=========================================="
echo "=== Horizon Cleanup Complete ==="
echo "=========================================="
echo ""
echo "Horizon dashboard has been removed."
echo "Apache continues to serve Keystone."
echo ""
echo "To reinstall: ./33-horizon-install.sh"
