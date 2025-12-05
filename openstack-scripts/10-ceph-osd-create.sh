#!/bin/bash
###############################################################################
# 10-ceph-osd-create.sh
# Create Ceph OSDs on prepared disks (Improved & Idempotent)
###############################################################################
set -e

# Configuration - EDIT THESE
# Disk device names (without /dev/ prefix)
OSD_DISKS="sdb sdc sdd sde"
HOSTNAME="osctl1"

echo "=== Step 10: Create Ceph OSDs ==="

# ============================================================================
# PART 1: Create bootstrap-osd keyring (if not exists)
# ============================================================================
echo "[1/5] Setting up bootstrap-osd keyring..."
BOOTSTRAP_DIR="/var/lib/ceph/bootstrap-osd"
BOOTSTRAP_KEYRING="${BOOTSTRAP_DIR}/ceph.keyring"

if [ -f "${BOOTSTRAP_KEYRING}" ]; then
    echo "  ✓ Bootstrap-osd keyring already exists, skipping creation"
else
    echo "  Creating bootstrap-osd directory and keyring..."
    sudo mkdir -p "${BOOTSTRAP_DIR}"
    
    # Create bootstrap-osd keyring
    sudo ceph auth get-or-create client.bootstrap-osd \
        mon 'allow profile bootstrap-osd' \
        -o "${BOOTSTRAP_KEYRING}"
    
    # Set correct ownership
    sudo chown -R ceph:ceph "${BOOTSTRAP_DIR}"
    echo "  ✓ Bootstrap-osd keyring created"
fi

# ============================================================================
# PART 2: Verify disks are available
# ============================================================================
echo "[2/5] Verifying disks are available..."
for d in ${OSD_DISKS}; do
    if [ ! -b "/dev/${d}" ]; then
        echo "  ERROR: /dev/${d} does not exist!"
        exit 1
    fi
    echo "  ✓ /dev/${d} exists"
done

# ============================================================================
# PART 3: Create OSDs
# ============================================================================
echo "[3/5] Creating OSDs..."
for d in ${OSD_DISKS}; do
    # Check if this disk is already an OSD
    if sudo ceph-volume lvm list /dev/${d} 2>/dev/null | grep -q "osd id"; then
        echo "  ✓ /dev/${d} is already an OSD, skipping"
    else
        echo "  Creating OSD on /dev/${d}..."
        sudo ceph-volume lvm create --data /dev/${d}
        echo "  ✓ OSD created on /dev/${d}"
    fi
done

# ============================================================================
# PART 4: Enable OSD services permanently (fix runtime-only enable)
# ============================================================================
echo "[4/5] Ensuring OSD services are permanently enabled for reboot..."

# Get list of OSD IDs from ceph
OSD_IDS=$(sudo ceph osd ls 2>/dev/null)

for osd_id in ${OSD_IDS}; do
    # Check current enable status
    current_status=$(systemctl is-enabled ceph-osd@${osd_id} 2>/dev/null || echo "disabled")
    
    if [ "$current_status" = "enabled" ]; then
        echo "  ✓ ceph-osd@${osd_id} is already permanently enabled"
    else
        echo "  Enabling ceph-osd@${osd_id} permanently..."
        sudo systemctl enable ceph-osd@${osd_id}
        echo "  ✓ ceph-osd@${osd_id} enabled"
    fi
done

# ============================================================================
# PART 5: Verify Ceph cluster
# ============================================================================
echo "[5/5] Verifying Ceph cluster..."
echo ""

# Wait for OSDs to register
echo "Waiting for OSDs to register..."
sleep 5

echo "Ceph status:"
echo "------------"
sudo ceph -s

echo ""
echo "OSD tree:"
echo "---------"
sudo ceph osd tree

echo ""
echo "OSD disk mapping:"
echo "-----------------"
sudo ceph-volume lvm list 2>/dev/null | grep -E "osd id|devices" || echo "  (use 'sudo ceph-volume lvm list' for details)"

echo ""
echo "OSD service status (should all be 'enabled'):"
echo "----------------------------------------------"
for osd_id in ${OSD_IDS}; do
    status=$(systemctl is-enabled ceph-osd@${osd_id} 2>/dev/null || echo "unknown")
    echo "  ceph-osd@${osd_id}: ${status}"
done

echo ""
echo "=== Ceph OSDs created ==="
echo "If HEALTH_OK (or HEALTH_WARN with only clock/msgr2 warnings) and all OSDs are up,in - Ceph is ready!"
echo "Next: Run 11-ceph-pools.sh"
