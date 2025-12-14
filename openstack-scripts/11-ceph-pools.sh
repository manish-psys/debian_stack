#!/bin/bash
###############################################################################
# 11-ceph-pools.sh
# Create Ceph pools for ALL OpenStack storage features with full validation
#
# This script creates storage pools for:
# 1. Block Storage (Cinder) - Volumes, snapshots, backups
# 2. VM Images (Glance) - OS images, snapshots
# 3. Ephemeral Storage (Nova) - Temporary VM disks
# 4. S3 Object Storage (RGW) - Bucket storage via S3 API
# 5. Shared Filesystem (CephFS) - Multi-VM file sharing
###############################################################################
set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

# Error counter
ERRORS=0

echo "=== Step 11: Create Ceph Pools for Complete OpenStack Storage ==="
echo "Using pool names from environment:"
echo "  Glance pool: ${CEPH_GLANCE_POOL}"
echo "  Cinder pool: ${CEPH_CINDER_POOL}"
echo "  Nova pool: ${CEPH_NOVA_POOL}"
echo "  Controller: ${CONTROLLER_HOSTNAME}"

# ============================================================================
# PART 0: Prerequisites Check
# ============================================================================
echo ""
echo "[0/8] Checking prerequisites..."

# Check Ceph cluster is healthy enough
if ! sudo ceph health &>/dev/null; then
    echo "  ✗ ERROR: Cannot connect to Ceph cluster!"
    exit 1
fi
echo "  ✓ Ceph cluster accessible"

# Check OSDs are up
OSD_COUNT=$(sudo ceph osd stat | grep -oP '\d+(?= osds:)' || echo "0")
OSD_UP=$(sudo ceph osd stat | grep -oP '\d+(?= up)' || echo "0")
if [ "$OSD_UP" -lt 1 ]; then
    echo "  ✗ ERROR: No OSDs are up! ($OSD_UP/$OSD_COUNT)"
    exit 1
fi
echo "  ✓ OSDs operational: $OSD_UP/$OSD_COUNT up"

# Check MDS daemon is available for CephFS
if ! systemctl is-active --quiet ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null; then
    echo "  ! MDS not running, will start it for CephFS"
    sudo systemctl enable ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null || true
    sudo systemctl start ceph-mds@${CONTROLLER_HOSTNAME} || echo "  ! MDS start failed, will retry"
fi

echo ""
echo "[1/8] Creating RBD pools for OpenStack block storage..."

# Function to create pool with verification
create_pool() {
    local POOL_NAME=$1
    local PG_NUM=$2
    local DESCRIPTION=$3
    
    if sudo ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
        echo "  ✓ ${POOL_NAME} already exists"
    else
        sudo ceph osd pool create ${POOL_NAME} ${PG_NUM}
        # Verify pool was created
        if sudo ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
            echo "  ✓ ${POOL_NAME} created (${DESCRIPTION})"
        else
            echo "  ✗ ERROR: Failed to create ${POOL_NAME}"
            ((ERRORS++))
        fi
    fi
}

# Create RBD pools
create_pool "${CEPH_CINDER_POOL}" 64 "Cinder volumes"
create_pool "${CEPH_GLANCE_POOL}" 64 "Glance images"
create_pool "backups" 32 "Cinder backups"
create_pool "${CEPH_NOVA_POOL}" 32 "Nova ephemeral"

echo ""
echo "[2/8] Creating RGW pools for S3 object storage..."

# Create RGW pools
create_pool ".rgw.root" 8 "RGW root"
create_pool "default.rgw.control" 8 "RGW control"
create_pool "default.rgw.meta" 8 "RGW metadata"
create_pool "default.rgw.log" 8 "RGW logs"
create_pool "default.rgw.buckets.index" 16 "RGW bucket index"
create_pool "default.rgw.buckets.data" 64 "RGW bucket data"

echo ""
echo "[3/8] Creating CephFS pools for shared filesystem..."

# Create CephFS pools
create_pool "cephfs_metadata" 32 "CephFS metadata"
create_pool "cephfs_data" 64 "CephFS data"

# Create CephFS filesystem if not exists
if sudo ceph fs ls | grep -q "name: cephfs"; then
    echo "  ✓ CephFS filesystem 'cephfs' already exists"
else
    sudo ceph fs new cephfs cephfs_metadata cephfs_data
    if sudo ceph fs ls | grep -q "name: cephfs"; then
        echo "  ✓ CephFS filesystem 'cephfs' created"
    else
        echo "  ✗ ERROR: Failed to create CephFS filesystem"
        ((ERRORS++))
    fi
fi

echo ""
echo "[4/8] Initializing RBD pools..."

# Function to initialize RBD pool with verification
init_rbd_pool() {
    local POOL_NAME=$1
    
    if sudo rbd pool stats ${POOL_NAME} &>/dev/null; then
        echo "  ✓ ${POOL_NAME} already initialized for RBD"
    else
        sudo rbd pool init ${POOL_NAME}
        if sudo rbd pool stats ${POOL_NAME} &>/dev/null; then
            echo "  ✓ ${POOL_NAME} initialized for RBD"
        else
            echo "  ✗ ERROR: Failed to initialize ${POOL_NAME} for RBD"
            ((ERRORS++))
        fi
    fi
}

init_rbd_pool "${CEPH_CINDER_POOL}"
init_rbd_pool "${CEPH_GLANCE_POOL}"
init_rbd_pool "backups"
init_rbd_pool "${CEPH_NOVA_POOL}"

echo ""
echo "[5/8] Setting replication size to 1 (single-node cluster)..."

ALL_POOLS="${CEPH_CINDER_POOL} ${CEPH_GLANCE_POOL} backups ${CEPH_NOVA_POOL} .rgw.root default.rgw.control default.rgw.meta default.rgw.log default.rgw.buckets.index default.rgw.buckets.data cephfs_metadata cephfs_data"

for p in ${ALL_POOLS}; do
    sudo ceph osd pool set $p size 1 &>/dev/null
    sudo ceph osd pool set $p min_size 1 &>/dev/null
    
    # Verify settings
    SIZE=$(sudo ceph osd pool get $p size | awk '{print $2}')
    MIN_SIZE=$(sudo ceph osd pool get $p min_size | awk '{print $2}')
    
    if [ "$SIZE" = "1" ] && [ "$MIN_SIZE" = "1" ]; then
        echo "  ✓ $p: size=1, min_size=1"
    else
        echo "  ✗ ERROR: $p: size=$SIZE, min_size=$MIN_SIZE (expected 1,1)"
        ((ERRORS++))
    fi
done

echo ""
echo "[6/8] Enabling RBD application on block storage pools..."

# Function to enable RBD application with verification
enable_rbd_app() {
    local POOL_NAME=$1
    
    # Check if already enabled
    if sudo ceph osd pool application get ${POOL_NAME} rbd &>/dev/null; then
        echo "  ✓ ${POOL_NAME}: RBD application already enabled"
    else
        sudo ceph osd pool application enable ${POOL_NAME} rbd
        if sudo ceph osd pool application get ${POOL_NAME} rbd &>/dev/null; then
            echo "  ✓ ${POOL_NAME}: RBD application enabled"
        else
            echo "  ✗ ERROR: Failed to enable RBD on ${POOL_NAME}"
            ((ERRORS++))
        fi
    fi
}

enable_rbd_app "${CEPH_CINDER_POOL}"
enable_rbd_app "${CEPH_GLANCE_POOL}"
enable_rbd_app "backups"
enable_rbd_app "${CEPH_NOVA_POOL}"

echo ""
echo "[7/8] Creating Ceph client keyrings for OpenStack..."

# Function to create client keyring with verification
create_client() {
    local CLIENT_NAME=$1
    local MON_CAPS=$2
    local OSD_CAPS=$3
    local KEYRING_FILE=$4
    local DESCRIPTION=$5
    
    if [ -f "${KEYRING_FILE}" ]; then
        echo "  ✓ ${CLIENT_NAME} keyring already exists"
    else
        sudo ceph auth get-or-create ${CLIENT_NAME} \
            mon "${MON_CAPS}" \
            osd "${OSD_CAPS}" \
            | sudo tee ${KEYRING_FILE} > /dev/null
        
        sudo chmod 600 ${KEYRING_FILE}
        
        # Verify keyring was created and has correct permissions
        if [ -f "${KEYRING_FILE}" ]; then
            PERMS=$(stat -c %a ${KEYRING_FILE})
            if [ "$PERMS" = "600" ]; then
                echo "  ✓ ${CLIENT_NAME} keyring created (${DESCRIPTION})"
            else
                echo "  ✗ ERROR: ${CLIENT_NAME} keyring has wrong permissions: $PERMS"
                ((ERRORS++))
            fi
        else
            echo "  ✗ ERROR: Failed to create ${CLIENT_NAME} keyring"
            ((ERRORS++))
        fi
    fi
}

# Glance client
create_client "client.glance" \
    "allow r" \
    "allow class-read object_prefix rbd_children, allow rwx pool=${CEPH_GLANCE_POOL}" \
    "/etc/ceph/ceph.client.glance.keyring" \
    "VM images"

# Cinder client
create_client "client.cinder" \
    "allow r" \
    "allow class-read object_prefix rbd_children, allow rwx pool=${CEPH_CINDER_POOL}, allow rwx pool=${CEPH_GLANCE_POOL}, allow rwx pool=backups, allow rwx pool=${CEPH_NOVA_POOL}" \
    "/etc/ceph/ceph.client.cinder.keyring" \
    "block volumes"

# Nova client
create_client "client.nova" \
    "allow r" \
    "allow class-read object_prefix rbd_children, allow rx pool=${CEPH_GLANCE_POOL}, allow rwx pool=${CEPH_NOVA_POOL}" \
    "/etc/ceph/ceph.client.nova.keyring" \
    "ephemeral disks"

# RGW client
create_client "client.rgw.${CONTROLLER_HOSTNAME}" \
    "allow rw" \
    "allow rwx" \
    "/etc/ceph/ceph.client.rgw.${CONTROLLER_HOSTNAME}.keyring" \
    "S3 API"

echo ""
echo "[8/8] Final verification..."

# Count pools
EXPECTED_POOLS=13
ACTUAL_POOLS=$(sudo ceph osd pool ls | wc -l)
if [ "$ACTUAL_POOLS" -ge "$EXPECTED_POOLS" ]; then
    echo "  ✓ Pool count: $ACTUAL_POOLS (expected >= $EXPECTED_POOLS)"
else
    echo "  ✗ ERROR: Pool count: $ACTUAL_POOLS (expected >= $EXPECTED_POOLS)"
    ((ERRORS++))
fi

# Verify CephFS
if sudo ceph fs ls | grep -q "name: cephfs"; then
    FS_STATUS=$(sudo ceph fs status cephfs 2>/dev/null | grep -oP '\d+(?= up)' || echo "0")
    if [ "$FS_STATUS" -ge 1 ]; then
        echo "  ✓ CephFS operational: $FS_STATUS MDS up"
    else
        echo "  ! CephFS created but MDS not fully up yet (may need time)"
    fi
else
    echo "  ✗ ERROR: CephFS not found"
    ((ERRORS++))
fi

# Verify keyrings
EXPECTED_KEYRINGS=4
ACTUAL_KEYRINGS=$(ls /etc/ceph/ceph.client.*.keyring 2>/dev/null | wc -l)
if [ "$ACTUAL_KEYRINGS" -ge "$EXPECTED_KEYRINGS" ]; then
    echo "  ✓ Client keyrings: $ACTUAL_KEYRINGS (expected >= $EXPECTED_KEYRINGS)"
else
    echo "  ✗ ERROR: Client keyrings: $ACTUAL_KEYRINGS (expected >= $EXPECTED_KEYRINGS)"
    ((ERRORS++))
fi

# Test RBD functionality
echo "  Testing RBD functionality..."
TEST_IMAGE="test-image-$$"
if sudo rbd create ${CEPH_CINDER_POOL}/${TEST_IMAGE} --size 1M &>/dev/null; then
    if sudo rbd ls ${CEPH_CINDER_POOL} | grep -q "${TEST_IMAGE}"; then
        sudo rbd rm ${CEPH_CINDER_POOL}/${TEST_IMAGE} &>/dev/null
        echo "  ✓ RBD create/delete test passed"
    else
        echo "  ✗ ERROR: RBD image not found after creation"
        ((ERRORS++))
    fi
else
    echo "  ✗ ERROR: RBD image creation failed"
    ((ERRORS++))
fi

echo ""
echo "=== Detailed Status ==="
echo ""
echo "Pool list:"
sudo ceph osd pool ls detail

echo ""
echo "CephFS status:"
sudo ceph fs ls
sudo ceph fs status cephfs 2>/dev/null || echo "  (CephFS status not available yet)"

echo ""
echo "MDS status:"
sudo ceph mds stat

echo ""
echo "Client authentication:"
sudo ceph auth ls | grep -A 3 "client\." | head -20

echo ""
echo "Created keyrings:"
ls -lh /etc/ceph/ceph.client.*.keyring

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=========================================="
    echo "=== ✓ All Storage Features Configured ==="
    echo "=========================================="
else
    echo "=========================================="
    echo "=== ✗ Configuration completed with $ERRORS error(s) ==="
    echo "=========================================="
    echo ""
    echo "Please review errors above and re-run script if needed."
    exit 1
fi

echo ""
echo "✓ BLOCK STORAGE (Cinder + RBD):"
echo "  - Primary volumes: ${CEPH_CINDER_POOL}"
echo "  - Volume backups: backups"
echo "  - Volume snapshots: Enabled"
echo "  - Volume clones: Enabled"
echo ""
echo "✓ VM IMAGES (Glance + RBD):"
echo "  - Image storage: ${CEPH_GLANCE_POOL}"
echo "  - Image snapshots: Enabled"
echo "  - Boot from volume: Supported"
echo ""
echo "✓ EPHEMERAL STORAGE (Nova + RBD):"
echo "  - Ephemeral disks: ${CEPH_NOVA_POOL}"
echo ""
echo "✓ S3 OBJECT STORAGE (RGW):"
echo "  - Pools ready: 6 RGW pools created"
echo "  - Client: client.rgw.${CONTROLLER_HOSTNAME}"
echo "  - Note: Requires radosgw service configuration"
echo ""
echo "✓ SHARED FILESYSTEM (CephFS):"
echo "  - Filesystem: cephfs"
echo "  - Pools: cephfs_metadata, cephfs_data"
echo "  - Note: Requires Manila service for managed shares"
echo ""
echo "Customer Features Available:"
echo "  ✓ Create/delete/resize volumes"
echo "  ✓ Volume snapshots and restore"
echo "  ✓ Volume backups and restore"
echo "  ✓ Clone volumes (instant)"
echo "  ✓ Upload/download VM images"
echo "  ✓ Create VMs from images"
echo "  ✓ Create VMs from volumes"
echo "  ✓ S3 bucket operations (after RGW setup)"
echo "  ✓ Shared filesystem across VMs (after Manila setup)"
echo ""
echo "Next: Run 12-openstack-base.sh"
