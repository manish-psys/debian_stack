#!/bin/bash
###############################################################################
# 15-keystone-cleanup.sh
# Clean up Keystone installation before re-running install script
# Run this ONLY if script 15 failed and you need to start fresh
###############################################################################

echo "=== Keystone Cleanup Script ==="
echo ""

# Step 1: Stop services
echo "[1/6] Stopping services..."
sudo systemctl stop keystone 2>/dev/null || true
sudo systemctl stop apache2 2>/dev/null || true

# Step 2: Remove keystone package (force remove even if broken)
echo "[2/6] Removing keystone packages..."
sudo dpkg --remove --force-remove-reinstreq keystone 2>/dev/null || true
sudo apt-get purge -y keystone 2>/dev/null || true
sudo apt-get purge -y python3-keystone 2>/dev/null || true

# Step 3: Clean up keystone configuration files (including keys!)
echo "[3/6] Removing keystone configuration and keys..."
sudo rm -rf /etc/keystone
sudo rm -rf /var/lib/keystone
sudo rm -f /etc/dbconfig-common/keystone.conf

# Step 4: Clean up Apache keystone config
echo "[4/6] Cleaning Apache configuration..."
sudo a2dissite keystone 2>/dev/null || true
sudo a2dissite wsgi-keystone 2>/dev/null || true
sudo a2disconf servername 2>/dev/null || true
sudo rm -f /etc/apache2/sites-available/keystone.conf
sudo rm -f /etc/apache2/sites-available/wsgi-keystone.conf
sudo rm -f /etc/apache2/sites-enabled/keystone.conf
sudo rm -f /etc/apache2/sites-enabled/wsgi-keystone.conf
sudo rm -f /etc/apache2/conf-available/servername.conf
sudo rm -f /etc/apache2/conf-enabled/servername.conf
sudo systemctl restart apache2 2>/dev/null || true

# Step 5: Clear keystone data from database
echo "[5/6] Clearing keystone database tables..."
echo "  (Database will be repopulated on next install)"
# Note: We don't drop the database, just let db_sync recreate tables

# Step 6: Fix any broken packages and autoremove
echo "[6/6] Fixing broken packages..."
sudo apt-get -f install -y 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true

# Verify cleanup
echo ""
echo "Verifying cleanup..."

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

if sudo test -d /etc/keystone/fernet-keys 2>/dev/null; then
    echo "  ⚠ WARNING: fernet-keys directory still exists"
else
    echo "  ✓ fernet-keys removed"
fi

if [ -f /etc/dbconfig-common/keystone.conf ]; then
    echo "  ⚠ WARNING: /etc/dbconfig-common/keystone.conf still exists"
else
    echo "  ✓ dbconfig-common keystone.conf removed"
fi

echo ""
echo "=== Cleanup complete ==="
echo ""
echo "Now run these in order:"
echo "  1. ./14-keystone-db.sh        (to reset database)"
echo "  2. ./15-keystone-install.sh   (to install keystone)"
