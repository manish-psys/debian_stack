#!/bin/bash
###############################################################################
# 33-horizon-cleanup.sh
# Remove Horizon Dashboard configuration and packages
# Idempotent - safe to run multiple times
#
# This script:
# - Removes openstack-dashboard-apache package
# - Cleans up configuration files
# - Reloads Apache
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
# [1/4] Remove Horizon Packages
###############################################################################
echo ""
echo "[1/4] Removing Horizon packages..."

if dpkg -l | grep -q "^ii.*openstack-dashboard-apache"; then
    sudo apt remove --purge --no-auto-remove -y openstack-dashboard-apache 2>/dev/null || true
    echo "  ✓ openstack-dashboard-apache removed"
else
    echo "  ✓ openstack-dashboard-apache not installed"
fi

if dpkg -l | grep -q "^ii.*openstack-dashboard "; then
    sudo apt remove --purge --no-auto-remove -y openstack-dashboard 2>/dev/null || true
    echo "  ✓ openstack-dashboard removed"
else
    echo "  ✓ openstack-dashboard not installed"
fi

if dpkg -l | grep -q "^ii.*python3-django-horizon"; then
    sudo apt remove --purge --no-auto-remove -y python3-django-horizon 2>/dev/null || true
    echo "  ✓ python3-django-horizon removed"
else
    echo "  ✓ python3-django-horizon not installed"
fi

###############################################################################
# [2/4] Cleanup Configuration Files
###############################################################################
echo ""
echo "[2/4] Cleaning up configuration files..."

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

###############################################################################
# [3/4] Cleanup Apache Configuration
###############################################################################
echo ""
echo "[3/4] Cleaning up Apache configuration..."

# Disable horizon sites first (to remove symlinks properly)
sudo a2dissite openstack-dashboard-alias-only 2>/dev/null || true
sudo a2dissite openstack-dashboard 2>/dev/null || true
sudo a2disconf openstack-dashboard 2>/dev/null || true

# Remove any horizon Apache configs (both sites-available and conf-available)
for conf in /etc/apache2/conf-available/openstack-dashboard.conf \
            /etc/apache2/conf-enabled/openstack-dashboard.conf \
            /etc/apache2/sites-available/openstack-dashboard.conf \
            /etc/apache2/sites-available/openstack-dashboard-alias-only.conf \
            /etc/apache2/sites-available/horizon.conf \
            /etc/apache2/sites-enabled/openstack-dashboard.conf \
            /etc/apache2/sites-enabled/openstack-dashboard-alias-only.conf \
            /etc/apache2/sites-enabled/horizon.conf; do
    if [ -f "$conf" ] || [ -L "$conf" ]; then
        sudo rm -f "$conf"
        echo "  ✓ Removed $conf"
    fi
done

echo "  ✓ Apache Horizon configuration cleaned"

###############################################################################
# [4/4] Reload Apache
###############################################################################
echo ""
echo "[4/4] Reloading Apache..."

sudo systemctl reload apache2 2>/dev/null || sudo systemctl restart apache2 || true

if systemctl is-active --quiet apache2; then
    echo "  ✓ Apache reloaded"
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
