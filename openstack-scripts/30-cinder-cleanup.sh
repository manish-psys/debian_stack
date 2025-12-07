#!/bin/bash
###############################################################################
# 30-cinder-cleanup.sh
# Remove Cinder packages and configuration
# WARNING: This will remove Cinder but NOT delete volumes in Ceph!
###############################################################################

set -u

echo "=== Cleanup: Cinder Installation ==="
echo ""
echo "WARNING: This will:"
echo "  - Stop and disable all Cinder services"
echo "  - Remove Cinder packages"
echo "  - Remove configuration files"
echo ""
echo "NOTE: Volumes in Ceph will NOT be deleted."
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "[1/4] Stopping Cinder services..."
for SERVICE in cinder-api cinder-scheduler cinder-volume; do
    sudo systemctl stop ${SERVICE} 2>/dev/null || true
    sudo systemctl disable ${SERVICE} 2>/dev/null || true
done
echo "  ✓ Services stopped"

echo ""
echo "[2/4] Removing Cinder packages..."
sudo apt purge -y cinder-api cinder-scheduler cinder-volume cinder-common python3-cinderclient 2>/dev/null || true
sudo apt autoremove -y 2>/dev/null || true
echo "  ✓ Packages removed"

echo ""
echo "[3/4] Removing configuration..."
sudo rm -rf /etc/cinder 2>/dev/null || true
sudo rm -rf /var/lib/cinder 2>/dev/null || true
sudo rm -rf /var/log/cinder 2>/dev/null || true
echo "  ✓ Configuration removed"

echo ""
echo "[4/4] Cleaning up systemd..."
sudo systemctl daemon-reload
echo "  ✓ Systemd reloaded"

echo ""
echo "=== Cinder Cleanup Complete ==="
echo ""
echo "To fully clean up, also run:"
echo "  ./29-cinder-db-cleanup.sh  (removes database and Keystone entities)"
echo ""
echo "Volumes in Ceph pool '${CEPH_CINDER_POOL:-volumes}' are preserved."
echo "To delete them: sudo rbd -p volumes ls | xargs -I {} sudo rbd -p volumes rm {}"
