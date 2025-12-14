#!/bin/bash
###############################################################################
# 11-ceph-pools.sh (IMPROVED)
# Create Ceph pools for ALL OpenStack storage features with full validation
#
# FIXES APPLIED:
# 1. Config propagation delay - wait after setting mon_allow_pool_size_one
# 2. Proper error detection without relying on grep for "Error" string
# 3. Better set -e handling with explicit error trapping
# 4. MDS race condition fix with sync and proper wait
# 5. Idempotent pool size setting (skip if already correct)
# 6. CephFS pools need 'cephfs' application, not 'rbd'
###############################################################################

# Don't use set -e globally - handle errors explicitly
set +e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

# Error counter
ERRORS=0

# Colors for output (optional, works without them)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_success() { echo -e "  ${GREEN}✓${NC} $1"; }
log_error() { echo -e "  ${RED}✗${NC} ERROR: $1"; ((ERRORS++)); }
log_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
log_info() { echo "  $1"; }

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
    log_error "Cannot connect to Ceph cluster!"
    exit 1
fi
log_success "Ceph cluster accessible"

# Check OSDs are up
OSD_STAT=$(sudo ceph osd stat 2>/dev/null)
OSD_COUNT=$(echo "$OSD_STAT" | grep -oP '\d+(?= osds:)' || echo "0")
OSD_UP=$(echo "$OSD_STAT" | grep -oP '\d+(?= up)' || echo "0")
if [ "$OSD_UP" -lt 1 ]; then
    log_error "No OSDs are up! ($OSD_UP/$OSD_COUNT)"
    exit 1
fi
log_success "OSDs operational: $OSD_UP/$OSD_COUNT up"

# ============================================================================
# PART 0.5: Enable single-replica pools BEFORE creating pools
# ============================================================================
echo ""
echo "[0.5/8] Configuring single-node cluster settings..."

# FIX #1: Set mon_allow_pool_size_one BEFORE pool creation and WAIT for propagation
CURRENT_SETTING=$(sudo ceph config get mon mon_allow_pool_size_one 2>/dev/null | tr -d '[:space:]')
if [ "$CURRENT_SETTING" != "true" ]; then
    log_info "Enabling mon_allow_pool_size_one..."
    sudo ceph config set global mon_allow_pool_size_one true
    
    # FIX #2: Wait for config to propagate to all monitors
    log_info "Waiting for config propagation (5 seconds)..."
    sleep 5
    
    # Verify it took effect
    NEW_SETTING=$(sudo ceph config get mon mon_allow_pool_size_one 2>/dev/null | tr -d '[:space:]')
    if [ "$NEW_SETTING" = "true" ]; then
        log_success "mon_allow_pool_size_one enabled"
    else
        log_error "Failed to enable mon_allow_pool_size_one (current: $NEW_SETTING)"
        exit 1
    fi
else
    log_success "mon_allow_pool_size_one already enabled"
fi

# ============================================================================
# PART 1: Create RBD Pools
# ============================================================================
echo ""
echo "[1/8] Creating RBD pools for OpenStack block storage..."

# Function to create pool with verification
create_pool() {
    local POOL_NAME=$1
    local PG_NUM=$2
    local DESCRIPTION=$3
    
    if sudo ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
        log_success "${POOL_NAME} already exists"
        return 0
    fi
    
    local OUTPUT
    OUTPUT=$(sudo ceph osd pool create "${POOL_NAME}" "${PG_NUM}" 2>&1)
    local RC=$?
    
    if [ $RC -ne 0 ]; then
        log_error "Failed to create ${POOL_NAME}: $OUTPUT"
        return 1
    fi
    
    # Verify pool was created
    if sudo ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
        log_success "${POOL_NAME} created (${DESCRIPTION})"
        return 0
    else
        log_error "Pool ${POOL_NAME} not found after creation"
        return 1
    fi
}

# Create RBD pools
create_pool "${CEPH_CINDER_POOL}" 64 "Cinder volumes"
create_pool "${CEPH_GLANCE_POOL}" 64 "Glance images"
create_pool "backups" 32 "Cinder backups"
create_pool "${CEPH_NOVA_POOL}" 32 "Nova ephemeral"

# ============================================================================
# PART 2: Create RGW Pools
# ============================================================================
echo ""
echo "[2/8] Creating RGW pools for S3 object storage..."

create_pool "rgw-root" 8 "RGW root"
create_pool "rgw-control" 8 "RGW control"
create_pool "rgw-meta" 8 "RGW metadata"
create_pool "rgw-log" 8 "RGW logs"
create_pool "rgw-buckets-index" 16 "RGW bucket index"
create_pool "rgw-buckets-data" 64 "RGW bucket data"

# ============================================================================
# PART 3: Create CephFS Pools and Filesystem
# ============================================================================
echo ""
echo "[3/8] Creating CephFS pools for shared filesystem..."

create_pool "cephfs_metadata" 32 "CephFS metadata"
create_pool "cephfs_data" 64 "CephFS data"

# Create CephFS filesystem if not exists
if sudo ceph fs ls 2>/dev/null | grep -q "name: cephfs"; then
    log_success "CephFS filesystem 'cephfs' already exists"
else
    log_info "Creating CephFS filesystem..."
    OUTPUT=$(sudo ceph fs new cephfs cephfs_metadata cephfs_data 2>&1)
    RC=$?
    
    if [ $RC -ne 0 ]; then
        log_error "Failed to create CephFS: $OUTPUT"
    elif sudo ceph fs ls | grep -q "name: cephfs"; then
        log_success "CephFS filesystem 'cephfs' created"
    else
        log_error "CephFS filesystem not found after creation"
    fi
fi

# Initialize MDS (Metadata Server) for CephFS
echo ""
log_info "Initializing MDS daemon..."
MDS_DIR="/var/lib/ceph/mds/ceph-${CONTROLLER_HOSTNAME}"
MDS_KEYRING="${MDS_DIR}/keyring"

# Create MDS directory if needed
if [ ! -d "${MDS_DIR}" ]; then
    sudo mkdir -p "${MDS_DIR}"
    sudo chown ceph:ceph "${MDS_DIR}"
    log_success "Created MDS directory"
else
    log_success "MDS directory exists"
fi

# Create MDS keyring if needed
if [ ! -f "${MDS_KEYRING}" ]; then
    sudo ceph auth get-or-create mds.${CONTROLLER_HOSTNAME} \
        mon 'allow profile mds' \
        osd 'allow rwx' \
        mds 'allow *' \
        -o "${MDS_KEYRING}" 2>/dev/null
    sudo chown ceph:ceph "${MDS_KEYRING}"
    sudo chmod 600 "${MDS_KEYRING}"
    
    # FIX #3: Ensure keyring is persisted before starting service
    sync
    sleep 2
    
    log_success "Created MDS keyring"
else
    log_success "MDS keyring already exists"
fi

# Reset any failed state and start MDS service
sudo systemctl reset-failed ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null || true
sudo systemctl enable ceph-mds@${CONTROLLER_HOSTNAME} 2>/dev/null
sudo systemctl restart ceph-mds@${CONTROLLER_HOSTNAME}

# FIX #4: Wait for MDS to become active with timeout
log_info "Waiting for MDS to become active..."
MDS_READY=false
for i in {1..12}; do
    sleep 2
    if sudo ceph mds stat 2>/dev/null | grep -q "up:active"; then
        MDS_READY=true
        break
    fi
done

if [ "$MDS_READY" = true ]; then
    log_success "MDS is active"
else
    if systemctl is-active --quiet ceph-mds@${CONTROLLER_HOSTNAME}; then
        log_warn "MDS service running but not yet active (may need more time)"
    else
        log_error "MDS service failed to start"
    fi
fi

# ============================================================================
# PART 4: Initialize RBD Pools
# ============================================================================
echo ""
echo "[4/8] Initializing RBD pools..."

init_rbd_pool() {
    local POOL_NAME=$1
    
    if sudo rbd pool stats "${POOL_NAME}" &>/dev/null; then
        log_success "${POOL_NAME} already initialized for RBD"
        return 0
    fi
    
    OUTPUT=$(sudo rbd pool init "${POOL_NAME}" 2>&1)
    RC=$?
    
    if [ $RC -ne 0 ]; then
        log_error "Failed to initialize ${POOL_NAME} for RBD: $OUTPUT"
        return 1
    fi
    
    log_success "${POOL_NAME} initialized for RBD"
    return 0
}

init_rbd_pool "${CEPH_CINDER_POOL}"
init_rbd_pool "${CEPH_GLANCE_POOL}"
init_rbd_pool "backups"
init_rbd_pool "${CEPH_NOVA_POOL}"

# ============================================================================
# PART 5: Set Replication Size (with proper error handling)
# ============================================================================
echo ""
echo "[5/8] Setting replication size to 1 (single-node cluster)..."

# FIX #5: Function that properly checks return code AND current value
set_pool_size() {
    local POOL_NAME=$1
    
    # Check current size first - skip if already correct (idempotent)
    local CURRENT_SIZE=$(sudo ceph osd pool get "$POOL_NAME" size 2>/dev/null | awk '{print $2}')
    local CURRENT_MIN=$(sudo ceph osd pool get "$POOL_NAME" min_size 2>/dev/null | awk '{print $2}')
    
    if [ "$CURRENT_SIZE" = "1" ] && [ "$CURRENT_MIN" = "1" ]; then
        log_success "$POOL_NAME: size=1, min_size=1 (already set)"
        return 0
    fi
    
    # Set size
    local OUTPUT
    OUTPUT=$(sudo ceph osd pool set "$POOL_NAME" size 1 2>&1)
    local RC=$?
    if [ $RC -ne 0 ]; then
        log_error "Failed to set size=1 for $POOL_NAME: $OUTPUT"
        return 1
    fi
    
    # Set min_size
    OUTPUT=$(sudo ceph osd pool set "$POOL_NAME" min_size 1 2>&1)
    RC=$?
    if [ $RC -ne 0 ]; then
        log_error "Failed to set min_size=1 for $POOL_NAME: $OUTPUT"
        return 1
    fi
    
    # Verify
    local SIZE=$(sudo ceph osd pool get "$POOL_NAME" size 2>/dev/null | awk '{print $2}')
    local MIN_SIZE=$(sudo ceph osd pool get "$POOL_NAME" min_size 2>/dev/null | awk '{print $2}')
    
    if [ "$SIZE" = "1" ] && [ "$MIN_SIZE" = "1" ]; then
        log_success "$POOL_NAME: size=1, min_size=1"
        return 0
    else
        log_error "$POOL_NAME: size=$SIZE, min_size=$MIN_SIZE (expected 1,1)"
        return 1
    fi
}

# Apply to all pools
ALL_POOLS="${CEPH_CINDER_POOL} ${CEPH_GLANCE_POOL} backups ${CEPH_NOVA_POOL} rgw-root rgw-control rgw-meta rgw-log rgw-buckets-index rgw-buckets-data cephfs_metadata cephfs_data"

for p in ${ALL_POOLS}; do
    set_pool_size "$p"
done

# ============================================================================
# PART 6: Enable Applications on Pools
# ============================================================================
echo ""
echo "[6/8] Enabling applications on pools..."

enable_pool_app() {
    local POOL_NAME=$1
    local APP_NAME=$2
    
    # Check if already enabled
    if sudo ceph osd pool application get "${POOL_NAME}" "${APP_NAME}" &>/dev/null; then
        log_success "${POOL_NAME}: ${APP_NAME} application already enabled"
        return 0
    fi
    
    OUTPUT=$(sudo ceph osd pool application enable "${POOL_NAME}" "${APP_NAME}" 2>&1)
    RC=$?
    
    if [ $RC -ne 0 ]; then
        log_error "Failed to enable ${APP_NAME} on ${POOL_NAME}: $OUTPUT"
        return 1
    fi
    
    log_success "${POOL_NAME}: ${APP_NAME} application enabled"
    return 0
}

# RBD pools
enable_pool_app "${CEPH_CINDER_POOL}" "rbd"
enable_pool_app "${CEPH_GLANCE_POOL}" "rbd"
enable_pool_app "backups" "rbd"
enable_pool_app "${CEPH_NOVA_POOL}" "rbd"

# RGW pools
enable_pool_app "rgw-root" "rgw"
enable_pool_app "rgw-control" "rgw"
enable_pool_app "rgw-meta" "rgw"
enable_pool_app "rgw-log" "rgw"
enable_pool_app "rgw-buckets-index" "rgw"
enable_pool_app "rgw-buckets-data" "rgw"

# FIX #6: CephFS pools need 'cephfs' application, not 'rbd'
enable_pool_app "cephfs_metadata" "cephfs"
enable_pool_app "cephfs_data" "cephfs"

# ============================================================================
# PART 7: Create Client Keyrings
# ============================================================================
echo ""
echo "[7/8] Creating Ceph client keyrings for OpenStack..."

create_client() {
    local CLIENT_NAME=$1
    local MON_CAPS=$2
    local OSD_CAPS=$3
    local KEYRING_FILE=$4
    local DESCRIPTION=$5
    
    if [ -f "${KEYRING_FILE}" ]; then
        log_success "${CLIENT_NAME} keyring already exists"
        return 0
    fi
    
    sudo ceph auth get-or-create ${CLIENT_NAME} \
        mon "${MON_CAPS}" \
        osd "${OSD_CAPS}" \
        2>/dev/null | sudo tee ${KEYRING_FILE} > /dev/null
    
    sudo chmod 600 ${KEYRING_FILE}
    
    if [ -f "${KEYRING_FILE}" ] && [ -s "${KEYRING_FILE}" ]; then
        log_success "${CLIENT_NAME} keyring created (${DESCRIPTION})"
        return 0
    else
        log_error "Failed to create ${CLIENT_NAME} keyring"
        return 1
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

# ============================================================================
# PART 8: Final Verification
# ============================================================================
echo ""
echo "[8/8] Final verification..."

# Count pools
EXPECTED_POOLS=12
ACTUAL_POOLS=$(sudo ceph osd pool ls | wc -l)
if [ "$ACTUAL_POOLS" -ge "$EXPECTED_POOLS" ]; then
    log_success "Pool count: $ACTUAL_POOLS (expected >= $EXPECTED_POOLS)"
else
    log_error "Pool count: $ACTUAL_POOLS (expected >= $EXPECTED_POOLS)"
fi

# Verify CephFS
if sudo ceph fs ls | grep -q "name: cephfs"; then
    log_success "CephFS filesystem exists"
    if sudo ceph mds stat | grep -q "up:active"; then
        log_success "MDS is active"
    elif systemctl is-active --quiet ceph-mds@${CONTROLLER_HOSTNAME}; then
        log_warn "MDS service running (may still be initializing)"
    else
        log_error "MDS service not running properly"
    fi
else
    log_error "CephFS not found"
fi

# Verify keyrings
EXPECTED_KEYRINGS=4
ACTUAL_KEYRINGS=$(ls /etc/ceph/ceph.client.glance.keyring /etc/ceph/ceph.client.cinder.keyring /etc/ceph/ceph.client.nova.keyring /etc/ceph/ceph.client.rgw.*.keyring 2>/dev/null | wc -l)
if [ "$ACTUAL_KEYRINGS" -ge "$EXPECTED_KEYRINGS" ]; then
    log_success "Client keyrings: $ACTUAL_KEYRINGS (expected >= $EXPECTED_KEYRINGS)"
else
    log_error "Client keyrings: $ACTUAL_KEYRINGS (expected >= $EXPECTED_KEYRINGS)"
fi

# Test RBD functionality
log_info "Testing RBD functionality..."
TEST_IMAGE="test-image-$$"
if sudo rbd create ${CEPH_CINDER_POOL}/${TEST_IMAGE} --size 1M 2>/dev/null; then
    if sudo rbd ls ${CEPH_CINDER_POOL} | grep -q "${TEST_IMAGE}"; then
        sudo rbd rm ${CEPH_CINDER_POOL}/${TEST_IMAGE} &>/dev/null
        log_success "RBD create/delete test passed"
    else
        log_error "RBD image not found after creation"
    fi
else
    log_error "RBD image creation failed"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Detailed Status ==="
echo ""
echo "Pool list with applications:"
sudo ceph osd pool ls detail | grep -E "^pool|application"

echo ""
echo "CephFS status:"
sudo ceph fs ls

echo ""
echo "MDS status:"
sudo ceph mds stat

echo ""
echo "Client keyrings:"
ls -lh /etc/ceph/ceph.client.*.keyring 2>/dev/null

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
echo "Storage Summary:"
echo "  ✓ Block Storage (RBD): ${CEPH_CINDER_POOL}, ${CEPH_GLANCE_POOL}, backups, ${CEPH_NOVA_POOL}"
echo "  ✓ Object Storage (RGW): 6 pools ready (requires radosgw service)"
echo "  ✓ Filesystem (CephFS): cephfs (requires Manila for managed shares)"
echo ""
echo "Next: Run 12-openstack-base.sh"
