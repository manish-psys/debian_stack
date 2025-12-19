#!/bin/bash
###############################################################################
# 32-nova-ceph.sh
# Configure Nova to use Ceph for ephemeral disks and volume attachments
# Idempotent - safe to run multiple times
#
# This script:
# - Creates libvirt secret for Ceph authentication
# - Configures Nova [libvirt] section for RBD
# - Updates Cinder with consistent secret UUID
# - Configures AppArmor for Ceph keyring access
# - Enables live migration with Ceph
#
# Prerequisites:
# - Script 29-31 completed (Cinder installed)
# - Ceph cluster operational
# - client.cinder user exists with appropriate permissions
# - Nova and Cinder already installed and running
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Source shared environment
# =============================================================================
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

echo "=== Step 32: Nova + Ceph Integration ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo "Using Nova Pool: ${CEPH_NOVA_POOL}"
echo "Using Cinder Pool: ${CEPH_CINDER_POOL}"
echo ""

# Configuration
NOVA_CONF="/etc/nova/nova.conf"
CINDER_CONF="/etc/cinder/cinder.conf"
SECRET_NAME="client.cinder secret"
CEPH_USER="cinder"

# Error counter
ERRORS=0

###############################################################################
# [1/7] Prerequisites Check
###############################################################################
echo "[1/7] Checking prerequisites..."

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
# [2/7] Create/Get Libvirt Secret
###############################################################################
echo ""
echo "[2/7] Setting up libvirt secret for Ceph..."

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
# [3/7] Set Secret Value
###############################################################################
echo ""
echo "[3/7] Setting secret value from Ceph keyring..."

# Get the key from Ceph (already base64 encoded)
CEPH_KEY=$(sudo ceph auth get-key client.${CEPH_USER})

if [ -z "$CEPH_KEY" ]; then
    echo "  ✗ ERROR: Could not retrieve key for client.${CEPH_USER}!"
    exit 1
fi

# Set the secret value
# NOTE: CEPH_KEY is already base64 encoded, pass directly with --base64
sudo virsh secret-set-value --secret "${SECRET_UUID}" --base64 "${CEPH_KEY}"
echo "  ✓ Secret value set"

# Verify secret
if sudo virsh secret-get-value "${SECRET_UUID}" &>/dev/null; then
    echo "  ✓ Secret verified"
else
    echo "  ✗ ERROR: Secret verification failed!"
    exit 1
fi

###############################################################################
# [4/7] Configure AppArmor for Ceph Keyring Access
###############################################################################
echo ""
echo "[4/7] Configuring AppArmor for Ceph keyring access..."

# LESSON LEARNED: AppArmor blocks libvirt/QEMU from accessing Ceph keyrings
# Add local override to allow Ceph keyring access
APPARMOR_LOCAL="/etc/apparmor.d/local/abstractions/libvirt-qemu"
if [ -d /etc/apparmor.d ]; then
    # Check if already configured (idempotent)
    if [ -f "$APPARMOR_LOCAL" ] && grep -q "/etc/ceph/\*\* r," "$APPARMOR_LOCAL" 2>/dev/null; then
        echo "  ✓ AppArmor local override already configured"
    else
        # Create parent directory if it doesn't exist
        sudo mkdir -p "$(dirname "$APPARMOR_LOCAL")"
        cat <<EOF | sudo tee "$APPARMOR_LOCAL" > /dev/null
# Allow Ceph keyring access for OpenStack Nova
/etc/ceph/** r,
/etc/ceph/ceph.client.*.keyring r,
EOF
        echo "  ✓ AppArmor local override created"
    fi

    # Reload AppArmor if running
    if systemctl is-active --quiet apparmor; then
        sudo systemctl reload apparmor
        echo "  ✓ AppArmor reloaded"
    fi
else
    echo "  ⚠ AppArmor directory not found (may not be installed)"
fi

###############################################################################
# [5/7] Add libvirt-qemu User to Cinder Group
###############################################################################
echo ""
echo "[5/7] Adding libvirt-qemu to cinder group..."

# LESSON LEARNED: libvirt-qemu user needs read access to Ceph keyrings
# Keyrings are owned by ceph:cinder with mode 640
if getent group cinder &>/dev/null; then
    # Check if already in group (idempotent)
    if id -nG libvirt-qemu 2>/dev/null | grep -qw cinder; then
        echo "  ✓ libvirt-qemu already in cinder group"
    else
        sudo usermod -aG cinder libvirt-qemu
        echo "  ✓ libvirt-qemu added to cinder group"
    fi
else
    echo "  ⚠ cinder group not found - will be created when Cinder is installed"
fi

###############################################################################
# [6/7] Configure Nova for Ceph
###############################################################################
echo ""
echo "[6/7] Configuring Nova [libvirt] section..."

# Backup current config (only if not already backed up today)
BACKUP_FILE="${NOVA_CONF}.pre-ceph.$(date +%Y%m%d)"
if [ ! -f "$BACKUP_FILE" ]; then
    sudo cp "$NOVA_CONF" "$BACKUP_FILE"
    echo "  ✓ Backup created: $BACKUP_FILE"
fi

# Configure libvirt section for Ceph RBD
sudo crudini --set "$NOVA_CONF" libvirt images_type rbd
sudo crudini --set "$NOVA_CONF" libvirt images_rbd_pool "${CEPH_NOVA_POOL}"
sudo crudini --set "$NOVA_CONF" libvirt images_rbd_ceph_conf "/etc/ceph/ceph.conf"
sudo crudini --set "$NOVA_CONF" libvirt rbd_user "${CEPH_USER}"
sudo crudini --set "$NOVA_CONF" libvirt rbd_secret_uuid "${SECRET_UUID}"

# Enable live migration with Ceph (no need to copy disk)
# Note: live_migration_tunnelled is preferred for newer libvirt
sudo crudini --set "$NOVA_CONF" libvirt live_migration_tunnelled "true"

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
# [7/7] Update Cinder Secret UUID
###############################################################################
echo ""
echo "[7/7] Updating Cinder with consistent secret UUID..."

# Ensure Cinder uses same secret UUID
sudo crudini --set "$CINDER_CONF" ceph rbd_secret_uuid "${SECRET_UUID}"
echo "  ✓ Cinder [ceph] rbd_secret_uuid updated"

###############################################################################
# Restart Services
###############################################################################
echo ""
echo "Restarting services..."

# Restart Nova compute
sudo systemctl restart nova-compute
sleep 2
if systemctl is-active --quiet nova-compute; then
    echo "  ✓ nova-compute restarted"
else
    echo "  ✗ ERROR: nova-compute failed to start!"
    sudo journalctl -u nova-compute --no-pager -n 20
    ERRORS=$((ERRORS+1))
fi

# Restart Cinder volume
sudo systemctl restart cinder-volume
sleep 2
if systemctl is-active --quiet cinder-volume; then
    echo "  ✓ cinder-volume restarted"
else
    echo "  ✗ ERROR: cinder-volume failed to start!"
    sudo journalctl -u cinder-volume --no-pager -n 20
    ERRORS=$((ERRORS+1))
fi

###############################################################################
# Verification
###############################################################################
echo ""
echo "[Verification] Checking final state..."

# Check Nova compute is up
if systemctl is-active --quiet nova-compute; then
    echo "  ✓ nova-compute running"
else
    echo "  ✗ nova-compute not running"
    ERRORS=$((ERRORS+1))
fi

# Check Cinder volume is up
if systemctl is-active --quiet cinder-volume; then
    echo "  ✓ cinder-volume running"
else
    echo "  ✗ cinder-volume not running"
    ERRORS=$((ERRORS+1))
fi

# Verify libvirt secret
echo ""
echo "Libvirt secret:"
sudo virsh secret-list | grep -E "UUID|${SECRET_NAME}" || true

###############################################################################
# Summary
###############################################################################
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Nova-Ceph Integration Complete ==="
else
    echo "=== Nova-Ceph Integration Completed with $ERRORS Error(s) ==="
fi
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
