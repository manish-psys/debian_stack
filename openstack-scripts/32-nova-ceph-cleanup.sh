#!/bin/bash
###############################################################################
# 32-nova-ceph-cleanup.sh
# Remove Nova-Ceph integration configuration
# Idempotent - safe to run multiple times
#
# This script:
# - Removes libvirt secret
# - Reverts Nova [libvirt] configuration to local disk
# - Restarts affected services
#
# NOTE: Does NOT delete data in Ceph pools
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Source shared environment (optional for cleanup)
# =============================================================================
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
fi

echo "=== Cleanup: Nova-Ceph Integration ==="

NOVA_CONF="/etc/nova/nova.conf"
CINDER_CONF="/etc/cinder/cinder.conf"
SECRET_NAME="client.cinder secret"

###############################################################################
# [1/4] Remove Libvirt Secret
###############################################################################
echo ""
echo "[1/4] Removing libvirt secret..."

SECRET_UUID=$(sudo virsh secret-list 2>/dev/null | grep "${SECRET_NAME}" | awk '{print $1}' || true)

if [ -n "$SECRET_UUID" ]; then
    sudo virsh secret-undefine "$SECRET_UUID"
    echo "  ✓ Secret ${SECRET_UUID} removed"
else
    echo "  ✓ No secret found (already removed)"
fi

###############################################################################
# [2/4] Revert Nova Configuration
###############################################################################
echo ""
echo "[2/4] Reverting Nova [libvirt] configuration..."

# Remove Ceph-specific settings (revert to local qcow2)
sudo crudini --del "$NOVA_CONF" libvirt images_type 2>/dev/null || true
sudo crudini --del "$NOVA_CONF" libvirt images_rbd_pool 2>/dev/null || true
sudo crudini --del "$NOVA_CONF" libvirt images_rbd_ceph_conf 2>/dev/null || true
sudo crudini --del "$NOVA_CONF" libvirt rbd_user 2>/dev/null || true
sudo crudini --del "$NOVA_CONF" libvirt rbd_secret_uuid 2>/dev/null || true
sudo crudini --del "$NOVA_CONF" libvirt live_migration_tunnelled 2>/dev/null || true
sudo crudini --del "$NOVA_CONF" libvirt live_migration_flag 2>/dev/null || true
sudo crudini --del "$NOVA_CONF" libvirt inject_password 2>/dev/null || true
sudo crudini --del "$NOVA_CONF" libvirt inject_key 2>/dev/null || true
sudo crudini --del "$NOVA_CONF" libvirt inject_partition 2>/dev/null || true

echo "  ✓ Nova [libvirt] Ceph settings removed"

###############################################################################
# [3/4] Revert Cinder Configuration
###############################################################################
echo ""
echo "[3/4] Reverting Cinder secret UUID..."

# Remove the secret UUID (Cinder will still use Ceph, just without libvirt secret)
sudo crudini --del "$CINDER_CONF" ceph rbd_secret_uuid 2>/dev/null || true

echo "  ✓ Cinder rbd_secret_uuid removed"

###############################################################################
# [4/4] Restart Services
###############################################################################
echo ""
echo "[4/4] Restarting services..."

sudo systemctl restart nova-compute
if systemctl is-active --quiet nova-compute; then
    echo "  ✓ nova-compute restarted"
else
    echo "  ⚠ nova-compute may have issues - check logs"
fi

sudo systemctl restart cinder-volume
if systemctl is-active --quiet cinder-volume; then
    echo "  ✓ cinder-volume restarted"
else
    echo "  ⚠ cinder-volume may have issues - check logs"
fi

echo ""
echo "=========================================="
echo "=== Nova-Ceph Cleanup Complete ==="
echo "=========================================="
echo ""
echo "Nova reverted to local disk storage (qcow2)"
echo "Cinder still uses Ceph backend for volumes"
echo ""
echo "NOTE: Data in Ceph pools was NOT deleted:"
echo "  - Pool 'vms' may contain old VM disks"
echo "  - Pool 'volumes' contains Cinder volumes"
echo ""
echo "To delete pool data (DESTRUCTIVE):"
echo "  sudo rbd -p vms ls | xargs -I {} sudo rbd -p vms rm {}"
