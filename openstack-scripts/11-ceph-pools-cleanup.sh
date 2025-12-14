#!/bin/bash
###############################################################################
# 11-ceph-pools-cleanup.sh
# Cleanup script to remove all Ceph pools created by 11-ceph-pools.sh
#
# WARNING: This will DESTROY all data in the pools!
# Use this only when you need to start fresh.
###############################################################################
set -e

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
echo "[1/4] Removing CephFS filesystem..."
if sudo ceph fs ls | grep -q "name: cephfs"; then
    # Stop MDS first
    sudo systemctl stop ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null || true
    
    # Mark filesystem down
    sudo ceph fs fail cephfs 2>/dev/null || true
    
    # Remove filesystem
    sudo ceph fs rm cephfs --yes-i-really-mean-it 2>/dev/null || true
    echo "  ✓ CephFS filesystem removed"
else
    echo "  ✓ CephFS filesystem not found"
fi

echo ""
echo "[2/4] Deleting client keyrings..."
for client in glance cinder nova rgw.${CONTROLLER_HOSTNAME}; do
    KEYRING="/etc/ceph/ceph.client.${client}.keyring"
    if [ -f "$KEYRING" ]; then
        sudo ceph auth del client.${client} 2>/dev/null || true
        sudo rm -f "$KEYRING"
        echo "  ✓ client.${client} removed"
    else
        echo "  ✓ client.${client} not found"
    fi
done

echo ""
echo "[3/4] Deleting pools..."

# Function to delete pool safely
delete_pool() {
    local POOL_NAME=$1
    
    if sudo ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
        # Allow pool deletion
        sudo ceph tell mon.\* injectargs '--mon-allow-pool-delete=true' 2>/dev/null || true
        
        # Delete pool
        sudo ceph osd pool delete ${POOL_NAME} ${POOL_NAME} --yes-i-really-really-mean-it 2>/dev/null
        
        if sudo ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
            echo "  ✗ Failed to delete ${POOL_NAME}"
        else
            echo "  ✓ ${POOL_NAME} deleted"
        fi
    else
        echo "  ✓ ${POOL_NAME} not found"
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
echo "[4/4] Verification..."
REMAINING_POOLS=$(sudo ceph osd pool ls | wc -l)
echo "  Remaining pools: $REMAINING_POOLS"

REMAINING_KEYRINGS=$(ls /etc/ceph/ceph.client.*.keyring 2>/dev/null | wc -l)
echo "  Remaining keyrings: $REMAINING_KEYRINGS"

echo ""
echo "=== Cleanup complete ==="
echo ""
echo "You can now re-run 11-ceph-pools.sh to recreate pools"