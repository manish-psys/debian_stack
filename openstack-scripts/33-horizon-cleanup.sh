#!/bin/bash
###############################################################################
# 33-horizon-cleanup.sh
# Remove Horizon Dashboard configuration and packages
# Idempotent - safe to run multiple times
#
# This script:
# - Disables Horizon Apache site
# - Removes Apache configuration
# - Removes openstack-dashboard package
# - Cleans up configuration files, static files, and cache
# - Re-enables default Apache site
# - Restarts Apache
#
# NOTE: Uses safe removal to avoid cascade deletion of dependencies
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Source shared environment (optional for cleanup)
# =============================================================================
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
else
    # Fallback defaults for cleanup
    CONTROLLER_IP="192.168.2.9"
fi

echo "=== Cleanup: Horizon Dashboard ==="

###############################################################################
# [1/6] Disable Horizon Apache Site
###############################################################################
echo ""
echo "[1/6] Disabling Horizon Apache site..."

if [ -L /etc/apache2/sites-enabled/horizon.conf ]; then
    sudo a2dissite horizon 2>/dev/null || true
    echo "  ✓ Disabled Horizon site"
else
    echo "  ✓ Horizon site already disabled"
fi

###############################################################################
# [2/6] Re-enable Default Site
###############################################################################
echo ""
echo "[2/6] Re-enabling default Apache site..."

if [ ! -L /etc/apache2/sites-enabled/000-default.conf ]; then
    sudo a2ensite 000-default 2>/dev/null || true
    echo "  ✓ Enabled default site"
else
    echo "  ✓ Default site already enabled"
fi

###############################################################################
# [3/6] Remove Horizon Apache Config
###############################################################################
echo ""
echo "[3/6] Removing Horizon Apache configuration..."

if [ -f /etc/apache2/sites-available/horizon.conf ]; then
    sudo rm -f /etc/apache2/sites-available/horizon.conf
    echo "  ✓ Removed /etc/apache2/sites-available/horizon.conf"
else
    echo "  ✓ Apache config already removed"
fi

###############################################################################
# [4/6] Remove Horizon Package
###############################################################################
echo ""
echo "[4/6] Removing Horizon package..."

if dpkg -l | grep -q "^ii.*openstack-dashboard"; then
    # Use --no-auto-remove to prevent cascade deletion of shared dependencies
    sudo apt remove --no-auto-remove -y openstack-dashboard 2>/dev/null || true
    echo "  ✓ openstack-dashboard removed"
else
    echo "  ✓ openstack-dashboard not installed"
fi

###############################################################################
# [5/6] Cleanup Files
###############################################################################
echo ""
echo "[5/6] Cleaning up files..."

# Remove config directory
if [ -d /etc/openstack-dashboard ]; then
    sudo rm -rf /etc/openstack-dashboard
    echo "  ✓ Removed /etc/openstack-dashboard"
else
    echo "  ✓ Config directory already removed"
fi

# Remove static files directory
if [ -d /var/lib/openstack-dashboard ]; then
    sudo rm -rf /var/lib/openstack-dashboard
    echo "  ✓ Removed /var/lib/openstack-dashboard"
else
    echo "  ✓ Static directory already removed"
fi

# Remove log files
if [ -f /var/log/apache2/horizon_error.log ]; then
    sudo rm -f /var/log/apache2/horizon_error.log
    echo "  ✓ Removed horizon_error.log"
fi
if [ -f /var/log/apache2/horizon_access.log ]; then
    sudo rm -f /var/log/apache2/horizon_access.log
    echo "  ✓ Removed horizon_access.log"
fi

###############################################################################
# [6/6] Restart Apache
###############################################################################
echo ""
echo "[6/6] Restarting Apache..."

sudo systemctl restart apache2 2>/dev/null || true

if systemctl is-active --quiet apache2; then
    echo "  ✓ Apache restarted"
else
    echo "  ⚠ Apache may have issues - check logs"
fi

# Verify Keystone still works
KEYSTONE_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:5000/v3" 2>/dev/null || echo "000")
if [ "$KEYSTONE_CODE" = "200" ]; then
    echo "  ✓ Keystone still accessible (HTTP 200)"
else
    echo "  ⚠ Keystone returned HTTP ${KEYSTONE_CODE} - may need attention"
fi

echo ""
echo "=========================================="
echo "=== Horizon Cleanup Complete ==="
echo "=========================================="
echo ""
echo "Horizon dashboard has been removed."
echo "Apache continues to serve Keystone on port 5000."
echo ""
echo "To reinstall: ./33-horizon.sh"
