#!/bin/bash
###############################################################################
# 15-keystone-cleanup.sh
# Clean up broken Keystone installation before re-running install script
# Run this ONLY if script 15 failed previously
###############################################################################

echo "=== Keystone Cleanup Script ==="
echo ""

# Step 1: Remove keystone package (force remove even if broken)
echo "[1/4] Removing keystone packages..."
sudo dpkg --remove --force-remove-reinstreq keystone 2>/dev/null || true
sudo apt-get purge -y keystone 2>/dev/null || true
sudo apt-get purge -y python3-keystone 2>/dev/null || true

# Step 2: Clean up keystone configuration files
echo "[2/4] Removing keystone configuration..."
sudo rm -rf /etc/keystone
sudo rm -rf /var/lib/keystone
sudo rm -f /etc/dbconfig-common/keystone.conf

# Step 3: Fix any broken packages
echo "[3/4] Fixing broken packages..."
sudo apt-get -f install -y 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true

# Step 4: Verify cleanup
echo "[4/4] Verifying cleanup..."
if dpkg -l 2>/dev/null | grep -q "^ii.*keystone"; then
    echo "  ⚠ WARNING: keystone package still shows as installed"
else
    echo "  ✓ keystone package removed"
fi

if [ -d /etc/keystone ]; then
    echo "  ⚠ WARNING: /etc/keystone still exists"
else
    echo "  ✓ /etc/keystone removed"
fi

echo ""
echo "=== Cleanup complete ==="
echo ""
echo "Now run these in order:"
echo "  1. ./14-keystone-db.sh        (to set new password)"
echo "  2. ./15-keystone-install.sh   (to install keystone)"
