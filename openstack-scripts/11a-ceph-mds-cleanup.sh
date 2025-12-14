#!/bin/bash
#
# Script: 11a-ceph-mds-cleanup.sh
# Purpose: Clean up Ceph MDS configuration and stop the service
# Notes: Use this to reset MDS to a clean state before re-running 11a-ceph-mds-setup.sh
#

set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "============================================"
echo "Ceph MDS Cleanup"
echo "============================================"
echo ""

# Step 1: Stop MDS service
echo "Step 1: Stopping MDS service..."
if sudo systemctl is-active --quiet ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null; then
    sudo systemctl stop ceph-mds@${CONTROLLER_HOSTNAME}
    echo "✓ Stopped ceph-mds@${CONTROLLER_HOSTNAME}"
else
    echo "✓ MDS service already stopped"
fi

if sudo systemctl is-enabled --quiet ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null; then
    sudo systemctl disable ceph-mds@${CONTROLLER_HOSTNAME}
    echo "✓ Disabled ceph-mds@${CONTROLLER_HOSTNAME}"
fi
echo ""

# Step 2: Remove MDS authentication key from Ceph
echo "Step 2: Removing MDS authentication key from Ceph..."
if sudo ceph auth get mds.${CONTROLLER_HOSTNAME} >/dev/null 2>&1; then
    sudo ceph auth del mds.${CONTROLLER_HOSTNAME}
    echo "✓ Removed MDS auth key from Ceph"
else
    echo "✓ MDS auth key not found in Ceph"
fi
echo ""

# Step 3: Remove MDS data directory
echo "Step 3: Removing MDS data directory..."
MDS_DIR="/var/lib/ceph/mds/ceph-${CONTROLLER_HOSTNAME}"
if [ -d "${MDS_DIR}" ]; then
    sudo rm -rf "${MDS_DIR}"
    echo "✓ Removed ${MDS_DIR}"
else
    echo "✓ MDS directory does not exist"
fi
echo ""

# Step 4: Verify cleanup
echo "============================================"
echo "Verification"
echo "============================================"
echo ""

echo "1. MDS service status:"
if sudo systemctl is-active --quiet ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null; then
    echo "   ✗ MDS service is still running"
else
    echo "   ✓ MDS service is stopped"
fi
echo ""

echo "2. MDS auth key in Ceph:"
if sudo ceph auth get mds.${CONTROLLER_HOSTNAME} >/dev/null 2>&1; then
    echo "   ✗ MDS auth key still exists in Ceph"
else
    echo "   ✓ MDS auth key removed from Ceph"
fi
echo ""

echo "3. MDS data directory:"
if [ -d "${MDS_DIR}" ]; then
    echo "   ✗ MDS directory still exists"
else
    echo "   ✓ MDS directory removed"
fi
echo ""

echo "4. CephFS status:"
sudo ceph fs ls
echo ""

echo "============================================"
echo "MDS cleanup completed"
echo "============================================"
echo ""
echo "Note: The CephFS filesystem itself is NOT removed."
echo "Only the MDS daemon configuration has been cleaned up."
echo ""
echo "To reinitialize MDS, run: ./11a-ceph-mds-setup.sh"
echo "============================================"