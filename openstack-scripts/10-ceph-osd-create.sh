#!/bin/bash
###############################################################################
# 10-ceph-osd-create.sh
# Create Ceph OSDs on prepared disks
###############################################################################
set -e

# Configuration - EDIT THESE
# Disk device names (without /dev/ prefix)
OSD_DISKS="sdb sdc sdd sde"

echo "=== Step 10: Create Ceph OSDs ==="

echo "[1/2] Creating OSDs..."
for d in ${OSD_DISKS}; do
    echo "  Creating OSD on /dev/${d}..."
    sudo ceph-volume lvm create --data /dev/${d}
done

echo "[2/2] Verifying Ceph cluster..."
echo ""
echo "Ceph status:"
sudo ceph -s
echo ""
echo "OSD tree:"
sudo ceph osd tree

echo ""
echo "=== Ceph OSDs created ==="
echo "If HEALTH_OK and all OSDs are up,in - Ceph is ready!"
echo "Next: Run 11-ceph-pools.sh"
