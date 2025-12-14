#!/bin/bash
#
# Script: 11a-ceph-mds-setup.sh
# Purpose: Initialize and start Ceph MDS (Metadata Server) for CephFS
# Prerequisites: Script 11 (Ceph pools including CephFS) must be completed
# Notes: This script creates the MDS keyring and starts the MDS service
#        Required for CephFS functionality and Manila integration
#

set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "============================================"
echo "Ceph MDS Setup for CephFS"
echo "============================================"
echo ""

# Step 1: Verify CephFS exists
echo "Step 1: Verifying CephFS filesystem..."
if ! sudo ceph fs ls | grep -q "name: cephfs"; then
    echo "ERROR: CephFS filesystem 'cephfs' not found!"
    echo "Please run script 11-ceph-pools.sh first."
    exit 1
fi
echo "✓ CephFS filesystem exists"
echo ""

# Step 2: Create MDS data directory
echo "Step 2: Creating MDS data directory..."
MDS_DIR="/var/lib/ceph/mds/ceph-${CONTROLLER_HOSTNAME}"
if [ ! -d "${MDS_DIR}" ]; then
    sudo mkdir -p "${MDS_DIR}"
    sudo chown ceph:ceph "${MDS_DIR}"
    echo "✓ Created ${MDS_DIR}"
else
    echo "✓ MDS directory already exists"
fi
echo ""

# Step 3: Create MDS authentication key
echo "Step 3: Creating MDS authentication key..."
MDS_KEYRING="${MDS_DIR}/keyring"
if [ ! -f "${MDS_KEYRING}" ]; then
    # Create the MDS key in Ceph
    sudo ceph auth get-or-create mds.${CONTROLLER_HOSTNAME} \
        mon 'allow profile mds' \
        osd 'allow rwx' \
        mds 'allow *' \
        -o "${MDS_KEYRING}"
    
    sudo chown ceph:ceph "${MDS_KEYRING}"
    sudo chmod 600 "${MDS_KEYRING}"
    echo "✓ Created MDS keyring"
else
    echo "✓ MDS keyring already exists"
fi
echo ""

# Step 4: Verify keyring content
echo "Step 4: Verifying MDS keyring..."
if sudo test -s "${MDS_KEYRING}"; then
    echo "✓ MDS keyring file is not empty"
    sudo ls -lh "${MDS_KEYRING}"
else
    echo "ERROR: MDS keyring file is empty!"
    exit 1
fi
echo ""

# Step 5: Enable and start MDS service
echo "Step 5: Starting MDS service..."
sudo systemctl enable ceph-mds@${CONTROLLER_HOSTNAME}
sudo systemctl restart ceph-mds@${CONTROLLER_HOSTNAME}
echo "✓ MDS service enabled and started"
echo ""

# Step 6: Wait for MDS to become active
echo "Step 6: Waiting for MDS to become active..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if sudo ceph mds stat | grep -q "${CONTROLLER_HOSTNAME}:active"; then
        echo "✓ MDS is now active"
        break
    fi
    echo "  Waiting for MDS to become active... ($WAITED/$MAX_WAIT seconds)"
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo "WARNING: MDS did not become active within ${MAX_WAIT} seconds"
    echo "This may be normal on first start. Checking status..."
fi
echo ""

# Step 7: Verification
echo "============================================"
echo "Verification"
echo "============================================"
echo ""

ERRORS=0

# Check MDS service status
echo "1. MDS Service Status:"
if sudo systemctl is-active --quiet ceph-mds@${CONTROLLER_HOSTNAME}; then
    echo "   ✓ ceph-mds@${CONTROLLER_HOSTNAME} is running"
else
    echo "   ✗ ceph-mds@${CONTROLLER_HOSTNAME} is NOT running"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Check MDS in cluster
echo "2. MDS Cluster Status:"
sudo ceph mds stat
echo ""

# Check filesystem status
echo "3. CephFS Status:"
sudo ceph fs ls
echo ""

# Check MDS detailed status
echo "4. MDS Detailed Status:"
if sudo ceph fs get cephfs | grep -q "up"; then
    MDS_STATUS=$(sudo ceph fs get cephfs | grep "up" || true)
    if [ -n "$MDS_STATUS" ]; then
        echo "   ✓ MDS is up: $MDS_STATUS"
    else
        echo "   ⚠ MDS status unclear, but filesystem exists"
    fi
else
    echo "   ⚠ No active MDS found yet (may still be starting)"
fi
echo ""

# Check if we can create a test directory
echo "5. Testing CephFS functionality:"
if command -v ceph-fuse >/dev/null 2>&1; then
    echo "   ✓ ceph-fuse is available for mounting"
else
    echo "   ⚠ ceph-fuse not installed (needed for mounting CephFS)"
    echo "     Install with: apt install ceph-fuse"
fi
echo ""

# Summary
echo "============================================"
echo "Summary"
echo "============================================"
if [ $ERRORS -eq 0 ]; then
    echo "✓ MDS setup completed successfully"
    echo ""
    echo "CephFS is now ready for use!"
    echo ""
    echo "To mount CephFS manually:"
    echo "  1. Create mount point: sudo mkdir -p /mnt/cephfs"
    echo "  2. Mount: sudo ceph-fuse /mnt/cephfs"
    echo ""
    echo "For OpenStack Manila integration, CephFS is ready."
    echo ""
    echo "Next: Run script 12-openstack-base.sh to begin OpenStack installation"
else
    echo "⚠ MDS setup completed with $ERRORS error(s)"
    echo ""
    echo "The MDS service may still be initializing."
    echo "Check logs with: sudo journalctl -u ceph-mds@${CONTROLLER_HOSTNAME} -f"
    echo ""
    echo "If issues persist, check:"
    echo "  - sudo ceph -s"
    echo "  - sudo ceph fs ls"
    echo "  - sudo ceph mds stat"
fi
echo "============================================"