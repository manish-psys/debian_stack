#!/bin/bash
###############################################################################
# 32-nova-ceph.sh
# Configure Nova to use Ceph for ephemeral disks and volume attachments
# 
# This script:
# - Creates libvirt secret for Ceph authentication
# - Configures Nova [libvirt] section for RBD
# - Updates Cinder with consistent secret UUID
# - Enables live migration with Ceph
#
# Prerequisites:
# - Ceph cluster operational
# - client.cinder user exists with appropriate permissions
# - Nova and Cinder already installed and running
###############################################################################
set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/openstack-env.sh" ]; then
    source "$SCRIPT_DIR/openstack-env.sh"
elif [ -f "./openstack-env.sh" ]; then
    source "./openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found!"
    exit 1
fi

echo "=== Step 32: Nova + Ceph Integration ==="

# Configuration
NOVA_CONF="/etc/nova/nova.conf"
CINDER_CONF="/etc/cinder/cinder.conf"
SECRET_NAME="client.cinder secret"
CEPH_USER="cinder"

###############################################################################
# [1/6] Prerequisites Check
###############################################################################
echo "[1/6] Checking prerequisites..."

# Check Nova is installed
if ! dpkg -l | grep -q "nova-compute"; then
    echo "  ✗ ERROR: nova-compute not installed!"
    exit 1
fi
echo "  ✓ Nova compute installed"

# Check Ceph cluster
if ! sudo ceph health &>/dev/null; then
    echo "  ✗ ERROR: Ceph cluster not accessible!"
    exit 1
fi
echo "  ✓ Ceph cluster accessible"

# Check client.cinder exists
if ! sudo ceph auth get client.cinder &>/dev/null; then
    echo "  ✗ ERROR: client.cinder not found in Ceph!"
    echo "    Create it with: sudo ceph auth get-or-create client.cinder ..."
    exit 1
fi
echo "  ✓ client.cinder user exists"

# Check vms pool exists
if ! sudo ceph osd pool ls | grep -q "^${CEPH_NOVA_POOL}$"; then
    echo "  ✗ ERROR: Pool '${CEPH_NOVA_POOL}' not found!"
    exit 1
fi
echo "  ✓ Pool '${CEPH_NOVA_POOL}' exists"

# Check libvirt is running
if ! systemctl is-active --quiet libvirtd; then
    echo "  ✗ ERROR: libvirtd not running!"
    exit 1
fi
echo "  ✓ libvirtd running"

###############################################################################
# [2/6] Create/Get Libvirt Secret
###############################################################################
echo "[2/6] Setting up libvirt secret for Ceph..."

# Check if secret already exists
EXISTING_UUID=$(sudo virsh secret-list 2>/dev/null | grep "${SECRET_NAME}" | awk '{print $1}' || true)

if [ -n "$EXISTING_UUID" ]; then
    echo "  ✓ Secret already exists: ${EXISTING_UUID}"
    SECRET_UUID="$EXISTING_UUID"
else
    # Create secret XML
    cat > /tmp/ceph-secret.xml <<EOF
<secret ephemeral='no' private='no'>
  <usage type='ceph'>
    <name>${SECRET_NAME}</name>
  </usage>
</secret>
EOF

    # Define secret
    SECRET_UUID=$(sudo virsh secret-define --file /tmp/ceph-secret.xml | awk '{print $2}' | tr -d '"')
    rm -f /tmp/ceph-secret.xml
    
    if [ -z "$SECRET_UUID" ]; then
        echo "  ✗ ERROR: Failed to create libvirt secret!"
        exit 1
    fi
    echo "  ✓ Secret created: ${SECRET_UUID}"
fi

###############################################################################
# [3/6] Set Secret Value
###############################################################################
echo "[3/6] Setting secret value from Ceph keyring..."

# Get the key from Ceph
CEPH_KEY=$(sudo ceph auth get-key client.${CEPH_USER})

if [ -z "$CEPH_KEY" ]; then
    echo "  ✗ ERROR: Could not retrieve key for client.${CEPH_USER}!"
    exit 1
fi

# Set the secret value
sudo virsh secret-set-value --secret "${SECRET_UUID}" --base64 "$(echo -n "${CEPH_KEY}" | base64)"
echo "  ✓ Secret value set"

# Verify secret
if sudo virsh secret-get-value "${SECRET_UUID}" &>/dev/null; then
    echo "  ✓ Secret verified"
else
    echo "  ✗ ERROR: Secret verification failed!"
    exit 1
fi

###############################################################################
# [4/6] Configure Nova for Ceph
###############################################################################
echo "[4/6] Configuring Nova [libvirt] section..."

# Backup current config
sudo cp "$NOVA_CONF" "${NOVA_CONF}.pre-ceph.$(date +%Y%m%d_%H%M%S)"

# Configure libvirt section for Ceph RBD
sudo crudini --set "$NOVA_CONF" libvirt images_type rbd
sudo crudini --set "$NOVA_CONF" libvirt images_rbd_pool "${CEPH_NOVA_POOL}"
sudo crudini --set "$NOVA_CONF" libvirt images_rbd_ceph_conf "/etc/ceph/ceph.conf"
sudo crudini --set "$NOVA_CONF" libvirt rbd_user "${CEPH_USER}"
sudo crudini --set "$NOVA_CONF" libvirt rbd_secret_uuid "${SECRET_UUID}"

# Enable live migration with Ceph (no need to copy disk)
sudo crudini --set "$NOVA_CONF" libvirt live_migration_flag "VIR_MIGRATE_UNDEFINE_SOURCE,VIR_MIGRATE_PEER2PEER,VIR_MIGRATE_LIVE"

# Inject password disabled (Ceph doesn't support it)
sudo crudini --set "$NOVA_CONF" libvirt inject_password false
sudo crudini --set "$NOVA_CONF" libvirt inject_key false
sudo crudini --set "$NOVA_CONF" libvirt inject_partition -2

echo "  ✓ Nova [libvirt] configured for RBD"

# Verify configuration
echo "  Configuration applied:"
echo "    images_type: $(sudo crudini --get "$NOVA_CONF" libvirt images_type)"
echo "    images_rbd_pool: $(sudo crudini --get "$NOVA_CONF" libvirt images_rbd_pool)"
echo "    rbd_user: $(sudo crudini --get "$NOVA_CONF" libvirt rbd_user)"
echo "    rbd_secret_uuid: $(sudo crudini --get "$NOVA_CONF" libvirt rbd_secret_uuid)"

###############################################################################
# [5/6] Update Cinder Secret UUID
###############################################################################
echo "[5/6] Updating Cinder with consistent secret UUID..."

# Ensure Cinder uses same secret UUID
sudo crudini --set "$CINDER_CONF" ceph rbd_secret_uuid "${SECRET_UUID}"
echo "  ✓ Cinder [ceph] rbd_secret_uuid updated"

###############################################################################
# [6/6] Restart Services
###############################################################################
echo "[6/6] Restarting services..."

# Restart Nova compute
sudo systemctl restart nova-compute
sleep 2
if systemctl is-active --quiet nova-compute; then
    echo "  ✓ nova-compute restarted"
else
    echo "  ✗ ERROR: nova-compute failed to start!"
    sudo journalctl -u nova-compute --no-pager -n 20
    exit 1
fi

# Restart Cinder volume
sudo systemctl restart cinder-volume
sleep 2
if systemctl is-active --quiet cinder-volume; then
    echo "  ✓ cinder-volume restarted"
else
    echo "  ✗ ERROR: cinder-volume failed to start!"
    sudo journalctl -u cinder-volume --no-pager -n 20
    exit 1
fi

###############################################################################
# Verification
###############################################################################
echo ""
echo "Verifying configuration..."

# Check Nova compute is up
if systemctl is-active --quiet nova-compute; then
    echo "  ✓ nova-compute running"
else
    echo "  ✗ nova-compute not running"
fi

# Check Cinder volume is up
if systemctl is-active --quiet cinder-volume; then
    echo "  ✓ cinder-volume running"
else
    echo "  ✗ cinder-volume not running"
fi

# Verify libvirt secret
echo ""
echo "Libvirt secret:"
sudo virsh secret-list | grep -E "UUID|${SECRET_NAME}" || true

echo ""
echo "=========================================="
echo "=== Nova-Ceph Integration Complete ==="
echo "=========================================="
echo ""
echo "Configuration summary:"
echo "  Libvirt Secret UUID: ${SECRET_UUID}"
echo "  Nova ephemeral pool: ${CEPH_NOVA_POOL}"
echo "  Cinder volume pool: ${CEPH_CINDER_POOL}"
echo "  Ceph user: ${CEPH_USER}"
echo ""
echo "Features enabled:"
echo "  - VM ephemeral disks stored in Ceph (pool: ${CEPH_NOVA_POOL})"
echo "  - Cinder volumes attachable to VMs"
echo "  - Live migration support (shared storage)"
echo ""
echo "Test commands:"
echo "  # Check services"
echo "  openstack compute service list"
echo "  openstack volume service list"
echo ""
echo "  # Create a VM with Ceph-backed disk"
echo "  openstack server create --flavor m1.tiny --image cirros \\"
echo "    --network provider-net test-vm"
echo ""
echo "  # Attach a volume"
echo "  openstack server add volume test-vm test-vol-1"
echo ""
echo "Next: Run 33-horizon.sh to install the web dashboard"
