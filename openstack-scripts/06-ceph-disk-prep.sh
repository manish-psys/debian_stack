#!/bin/bash
###############################################################################
# 06-ceph-disk-prep.sh
# Prepare disks for Ceph OSDs
###############################################################################
set -e

# Configuration - EDIT THESE
# List your OSD disks (WARNING: ALL DATA WILL BE DESTROYED!)
OSD_DISKS="/dev/sdb /dev/sdc /dev/sdd /dev/sde"

echo "=== Step 6: Ceph Disk Preparation ==="
echo ""
echo "WARNING: This will DESTROY all data on the following disks:"
echo "${OSD_DISKS}"
echo ""

# Show current disk info
echo "Current disk layout:"
lsblk
echo ""

read -p "Are you SURE you want to proceed? Type 'yes' to continue: " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "[1/1] Wiping disks..."
for d in ${OSD_DISKS}; do
    echo "  Wiping ${d}..."
    sudo sgdisk --zap-all "${d}"
    sudo wipefs -a "${d}"
done

echo ""
echo "=== Disk preparation complete ==="
echo "Disks are now ready for Ceph OSD creation."
echo "Next: Run 07-ceph-config.sh"
