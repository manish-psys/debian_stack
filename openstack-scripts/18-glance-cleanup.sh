#!/bin/bash
###############################################################################
# 18-glance-cleanup.sh
# Clean up Glance installation before re-running install script
# Run this ONLY if script 18 failed and you need to start fresh
###############################################################################

echo "=== Glance Cleanup Script ==="
echo ""

# Step 1: Stop services
echo "[1/6] Stopping services..."
sudo systemctl stop glance-api 2>/dev/null || true

# Step 2: Remove glance packages
echo "[2/6] Removing Glance packages..."
sudo dpkg --remove --force-remove-reinstreq glance 2>/dev/null || true
sudo dpkg --remove --force-remove-reinstreq glance-api 2>/dev/null || true
sudo dpkg --remove --force-remove-reinstreq glance-common 2>/dev/null || true
sudo apt-get purge -y glance glance-api glance-common python3-glance 2>/dev/null || true

# Step 3: Clean up configuration files
echo "[3/6] Removing Glance configuration..."
sudo rm -rf /etc/glance
sudo rm -rf /var/lib/glance
sudo rm -rf /var/log/glance
sudo rm -f /etc/dbconfig-common/glance-api.conf

# Step 4: Clean Ceph glance user (optional - keeps pool data)
echo "[4/6] Removing Ceph glance user..."
sudo ceph auth del client.glance 2>/dev/null || true
sudo rm -f /etc/ceph/ceph.client.glance.keyring

# Step 5: Truncate database tables (keep database, just clear data)
echo "[5/6] Clearing Glance database tables..."
sudo mysql -e "DROP DATABASE IF EXISTS glance; CREATE DATABASE glance;" 2>/dev/null || true
sudo mysql -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost';" 2>/dev/null || true
sudo mysql -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%';" 2>/dev/null || true
sudo mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true

# Step 6: Fix broken packages
echo "[6/6] Fixing broken packages..."
sudo apt-get -f install -y 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true

# Verify cleanup
echo ""
echo "Verifying cleanup..."

if dpkg -l 2>/dev/null | grep -q "^ii.*glance "; then
    echo "  ⚠ WARNING: glance package still installed"
else
    echo "  ✓ glance packages removed"
fi

if [ -d /etc/glance ]; then
    echo "  ⚠ WARNING: /etc/glance still exists"
else
    echo "  ✓ /etc/glance removed"
fi

if sudo ceph auth get client.glance &>/dev/null; then
    echo "  ⚠ WARNING: Ceph client.glance still exists"
else
    echo "  ✓ Ceph client.glance removed"
fi

echo ""
echo "=== Cleanup complete ==="
echo ""
echo "NOTE: Keystone glance user/service/endpoints are preserved."
echo "      (Script 17 entities are still valid)"
echo ""
echo "Next: Run ./18-glance-install.sh"
