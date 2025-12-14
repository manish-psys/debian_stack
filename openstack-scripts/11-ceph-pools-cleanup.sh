#!/bin/bash
###############################################################################
# 11-ceph-pools-cleanup.sh (IMPROVED)
# Cleanup script to remove all Ceph pools created by 11-ceph-pools.sh
#
# FIXES APPLIED:
# 1. Proper wait for MDS to stop before removing filesystem
# 2. Force fail CephFS before deletion
# 3. Better error handling without set -e
###############################################################################

# Don't use set -e - handle errors explicitly
set +e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Ceph Pools Cleanup ==="
echo ""
echo "⚠️  WARNING: This will DELETE all pools and their data!"
echo ""
echo "Pools to be deleted:"
echo "  - ${CEPH_CINDER_POOL} (Cinder volumes)"
echo "  - ${CEPH_GLANCE_POOL} (Glance images)"
echo "  - backups (Cinder backups)"
echo "  - ${CEPH_NOVA_POOL} (Nova ephemeral)"
echo "  - rgw-* (6 RGW pools for S3)"
echo "  - cephfs_* (2 CephFS pools)"
echo "  - CephFS filesystem 'cephfs'"
echo ""
echo "Client keyrings to be deleted:"
echo "  - client.glance"
echo "  - client.cinder"
echo "  - client.nova"
echo "  - client.rgw.${CONTROLLER_HOSTNAME}"
echo ""

read -p "Type 'DELETE' to confirm: " CONFIRM
if [ "$CONFIRM" != "DELETE" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "[1/5] Stopping and cleaning MDS..."

# Stop MDS service first
if systemctl is-active --quiet ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null; then
    sudo systemctl stop ceph-mds@${CONTROLLER_HOSTNAME}
    # Wait for MDS to fully stop
    for i in {1..10}; do
        if ! systemctl is-active --quiet ceph-mds@${CONTROLLER_HOSTNAME}; then
            break
        fi
        sleep 1
    done
    echo "  ✓ MDS service stopped"
else
    echo "  ✓ MDS service not running"
fi

if systemctl is-enabled --quiet ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null; then
    sudo systemctl disable ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null
    echo "  ✓ MDS service disabled"
fi

# Remove MDS keyring from Ceph auth
if sudo ceph auth get mds.${CONTROLLER_HOSTNAME} &>/dev/null; then
    sudo ceph auth del mds.${CONTROLLER_HOSTNAME} 2>/dev/null
    echo "  ✓ MDS auth key removed"
fi

# Remove MDS data directory
MDS_DIR="/var/lib/ceph/mds/ceph-${CONTROLLER_HOSTNAME}"
if [ -d "${MDS_DIR}" ]; then
    sudo rm -rf "${MDS_DIR}"
    echo "  ✓ MDS directory removed"
fi

echo ""
echo "[2/5] Removing CephFS filesystem..."

if sudo ceph fs ls 2>/dev/null | grep -q "name: cephfs"; then
    # FIX: Properly fail and remove CephFS
    echo "  Marking CephFS as failed..."
    sudo ceph fs fail cephfs 2>/dev/null || true
    sleep 2
    
    echo "  Removing CephFS filesystem..."
    sudo ceph fs rm cephfs --yes-i-really-mean-it 2>/dev/null
    
    if ! sudo ceph fs ls 2>/dev/null | grep -q "name: cephfs"; then
        echo "  ✓ CephFS filesystem removed"
    else
        echo "  ✗ Failed to remove CephFS (may need manual intervention)"
    fi
else
    echo "  ✓ CephFS filesystem not found (already removed)"
fi

echo ""
echo "[3/5] Deleting client keyrings..."

delete_client() {
    local CLIENT=$1
    local KEYRING="/etc/ceph/ceph.client.${CLIENT}.keyring"
    
    # Remove from Ceph auth
    if sudo ceph auth get client.${CLIENT} &>/dev/null; then
        sudo ceph auth del client.${CLIENT} 2>/dev/null
    fi
    
    # Remove keyring file
    if [ -f "$KEYRING" ]; then
        sudo rm -f "$KEYRING"
        echo "  ✓ client.${CLIENT} removed"
    else
        echo "  ✓ client.${CLIENT} not found"
    fi
}

delete_client "glance"
delete_client "cinder"
delete_client "nova"
delete_client "rgw.${CONTROLLER_HOSTNAME}"

echo ""
echo "[4/5] Deleting pools..."

# Enable pool deletion
sudo ceph config set mon mon_allow_pool_delete true 2>/dev/null
# Also use the old method for compatibility
sudo ceph tell mon.\* injectargs '--mon-allow-pool-delete=true' 2>/dev/null || true
sleep 2

delete_pool() {
    local POOL_NAME=$1
    
    if ! sudo ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
        echo "  ✓ ${POOL_NAME} not found"
        return 0
    fi
    
    OUTPUT=$(sudo ceph osd pool delete "${POOL_NAME}" "${POOL_NAME}" --yes-i-really-really-mean-it 2>&1)
    RC=$?
    
    if [ $RC -eq 0 ] && ! sudo ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
        echo "  ✓ ${POOL_NAME} deleted"
    else
        echo "  ✗ Failed to delete ${POOL_NAME}: $OUTPUT"
    fi
}

# Delete all pools
delete_pool "${CEPH_CINDER_POOL}"
delete_pool "${CEPH_GLANCE_POOL}"
delete_pool "backups"
delete_pool "${CEPH_NOVA_POOL}"
delete_pool "rgw-root"
delete_pool "rgw-control"
delete_pool "rgw-meta"
delete_pool "rgw-log"
delete_pool "rgw-buckets-index"
delete_pool "rgw-buckets-data"
delete_pool "cephfs_metadata"
delete_pool "cephfs_data"

echo ""
echo "[5/5] Verification..."

REMAINING_POOLS=$(sudo ceph osd pool ls 2>/dev/null | wc -l)
echo "  Remaining pools: $REMAINING_POOLS"

REMAINING_KEYRINGS=$(ls /etc/ceph/ceph.client.*.keyring 2>/dev/null | grep -v admin | wc -l)
echo "  Remaining client keyrings (excluding admin): $REMAINING_KEYRINGS"

# Show what's left
if [ "$REMAINING_POOLS" -gt 0 ]; then
    echo ""
    echo "  Remaining pools:"
    sudo ceph osd pool ls | sed 's/^/    /'
fi

echo ""
echo "=== Cleanup complete ==="
echo ""
echo "You can now re-run 11-ceph-pools.sh to recreate pools"
