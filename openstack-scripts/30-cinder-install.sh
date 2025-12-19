#!/bin/bash
###############################################################################
# 30-cinder-install.sh
# Install and configure Cinder (Block Storage) with Ceph backend
# Idempotent - safe to run multiple times
#
# Prerequisites:
#   - Script 29 completed (database and Keystone setup)
#   - Ceph cluster operational with 'volumes' pool
#   - Ceph client keyring for cinder user
#
# This script:
#   - Installs Cinder packages (API, scheduler, volume)
#   - Configures Cinder with Ceph RBD backend
#   - Sets up Ceph authentication for Cinder
#   - Does NOT sync database or start services (see script 31)
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

# Source admin credentials for verification
if [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
else
    echo "ERROR: ~/admin-openrc not found!"
    exit 1
fi

echo "=== Step 30: Cinder Installation (Ceph Backend) ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo "Using Region: ${REGION_NAME}"
echo "Using Ceph Pool: ${CEPH_CINDER_POOL}"
echo ""

# Error counter
ERRORS=0

# =============================================================================
# PART 0: Check Prerequisites
# =============================================================================
echo "[0/8] Checking prerequisites..."

# Check crudini is available
if ! command -v crudini &>/dev/null; then
    echo "  Installing crudini..."
    sudo apt install -y crudini
fi
echo "  ✓ crudini available"

# Check Cinder database exists
if ! mysql -u cinder -p"${CINDER_DB_PASS}" -e "SELECT 1;" cinder &>/dev/null; then
    echo "  ✗ ERROR: Cannot connect to Cinder database!"
    echo "  Run 29-cinder-db.sh first."
    exit 1
fi
echo "  ✓ Cinder database accessible"

# Check Keystone user exists
if ! /usr/bin/openstack user show cinder &>/dev/null; then
    echo "  ✗ ERROR: Keystone user 'cinder' not found!"
    echo "  Run 29-cinder-db.sh first."
    exit 1
fi
echo "  ✓ Keystone user 'cinder' exists"

# Check Cinder service registered
if ! /usr/bin/openstack service show cinderv3 &>/dev/null; then
    echo "  ✗ ERROR: Service 'cinderv3' not found!"
    echo "  Run 29-cinder-db.sh first."
    exit 1
fi
echo "  ✓ Service 'cinderv3' registered"

# Check Ceph is available
if ! command -v ceph &>/dev/null; then
    echo "  ✗ ERROR: Ceph client not installed!"
    exit 1
fi
echo "  ✓ Ceph client available"

# Check Ceph cluster health
if ! sudo ceph health &>/dev/null; then
    echo "  ✗ ERROR: Cannot connect to Ceph cluster!"
    exit 1
fi
echo "  ✓ Ceph cluster accessible"

# Check Ceph volumes pool exists
if ! sudo ceph osd pool ls | grep -q "^${CEPH_CINDER_POOL}$"; then
    echo "  ✗ ERROR: Ceph pool '${CEPH_CINDER_POOL}' not found!"
    echo "  Create pool with: sudo ceph osd pool create ${CEPH_CINDER_POOL} 128"
    exit 1
fi
echo "  ✓ Ceph pool '${CEPH_CINDER_POOL}' exists"

# Check RabbitMQ is running
if ! systemctl is-active --quiet rabbitmq-server; then
    echo "  ✗ ERROR: RabbitMQ is not running!"
    exit 1
fi
echo "  ✓ RabbitMQ is running"

# Check if RabbitMQ user exists
if ! sudo rabbitmqctl list_users 2>/dev/null | grep -q "^${RABBIT_USER}"; then
    echo "  ✗ ERROR: RabbitMQ user '${RABBIT_USER}' not found!"
    exit 1
fi
echo "  ✓ RabbitMQ user '${RABBIT_USER}' exists"

# =============================================================================
# PART 1: Configure dbconfig-common to skip automatic DB config
# =============================================================================
echo ""
echo "[1/8] Configuring dbconfig-common..."

# Pre-seed debconf to skip database configuration during package install
sudo debconf-set-selections <<EOF
cinder-common cinder/configure_db boolean false
cinder-common cinder/auth-host string ${CONTROLLER_IP}
cinder-api cinder/configure_db boolean false
EOF
echo "  ✓ dbconfig-common configured"

# =============================================================================
# PART 2: Install Cinder Packages
# =============================================================================
echo ""
echo "[2/8] Installing Cinder packages..."

# Install from Debian Trixie native packages (Cinder 2:26.0.0-2 Caracal)
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    cinder-api \
    cinder-scheduler \
    cinder-volume \
    python3-cinderclient

if [ $? -eq 0 ]; then
    echo "  ✓ Cinder packages installed"
else
    echo "  ✗ ERROR: Failed to install Cinder packages!"
    ERRORS=$((ERRORS+1))
fi

# Verify installation
dpkg -l | grep -E "^ii.*cinder" | head -5

# =============================================================================
# PART 3: Stop Services for Configuration
# =============================================================================
echo ""
echo "[3/8] Stopping Cinder services for configuration..."

# Stop all Cinder services
for SERVICE in cinder-api cinder-scheduler cinder-volume; do
    sudo systemctl stop ${SERVICE} 2>/dev/null || true
done
echo "  ✓ Cinder services stopped"

# =============================================================================
# PART 4: Backup Original Configuration
# =============================================================================
echo ""
echo "[4/8] Backing up original configuration..."

CINDER_CONF="/etc/cinder/cinder.conf"
BACKUP_SUFFIX=".orig.$(date +%Y%m%d_%H%M%S)"

if [ -f "$CINDER_CONF" ]; then
    if [ ! -f "${CINDER_CONF}.orig" ]; then
        sudo cp "$CINDER_CONF" "${CINDER_CONF}.orig"
        echo "  ✓ Backed up ${CINDER_CONF}"
    else
        sudo cp "$CINDER_CONF" "${CINDER_CONF}${BACKUP_SUFFIX}"
        echo "  ✓ Additional backup: ${CINDER_CONF}${BACKUP_SUFFIX}"
    fi
fi

# =============================================================================
# PART 5: Configure cinder.conf
# =============================================================================
echo ""
echo "[5/8] Configuring cinder.conf..."

# [database] section
# NOTE: Use CONTROLLER_IP not localhost - MariaDB binds to controller IP only
echo "  Configuring [database]..."
sudo crudini --set "$CINDER_CONF" database connection \
    "mysql+pymysql://cinder:${CINDER_DB_PASS}@${CONTROLLER_IP}/cinder"
echo "  ✓ [database] configured"

# [DEFAULT] section
echo "  Configuring [DEFAULT]..."
sudo crudini --set "$CINDER_CONF" DEFAULT transport_url \
    "rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
sudo crudini --set "$CINDER_CONF" DEFAULT auth_strategy "keystone"
sudo crudini --set "$CINDER_CONF" DEFAULT my_ip "${CONTROLLER_IP}"
sudo crudini --set "$CINDER_CONF" DEFAULT enabled_backends "ceph"
sudo crudini --set "$CINDER_CONF" DEFAULT glance_api_servers "http://${CONTROLLER_IP}:9292"
# For single-node, disable volume clear (faster deletion)
sudo crudini --set "$CINDER_CONF" DEFAULT volume_clear "none"
# Default volume type
sudo crudini --set "$CINDER_CONF" DEFAULT default_volume_type "ceph"
echo "  ✓ [DEFAULT] configured"

# [keystone_authtoken] section - use helper function from openstack-env.sh
echo "  Configuring [keystone_authtoken]..."
configure_keystone_authtoken "$CINDER_CONF" "cinder" "${CINDER_PASS}"
echo "  ✓ [keystone_authtoken] configured"

# [oslo_concurrency] section
echo "  Configuring [oslo_concurrency]..."
sudo crudini --set "$CINDER_CONF" oslo_concurrency lock_path "/var/lib/cinder/tmp"
# Create lock directory
sudo mkdir -p /var/lib/cinder/tmp
sudo chown cinder:cinder /var/lib/cinder/tmp
echo "  ✓ [oslo_concurrency] configured"

# =============================================================================
# PART 6: Configure Ceph Backend
# =============================================================================
echo ""
echo "[6/8] Configuring Ceph backend..."

# [ceph] backend section
sudo crudini --set "$CINDER_CONF" ceph volume_driver "cinder.volume.drivers.rbd.RBDDriver"
sudo crudini --set "$CINDER_CONF" ceph volume_backend_name "ceph"
sudo crudini --set "$CINDER_CONF" ceph rbd_pool "${CEPH_CINDER_POOL}"
sudo crudini --set "$CINDER_CONF" ceph rbd_ceph_conf "/etc/ceph/ceph.conf"
sudo crudini --set "$CINDER_CONF" ceph rbd_flatten_volume_from_snapshot "false"
sudo crudini --set "$CINDER_CONF" ceph rbd_max_clone_depth "5"
sudo crudini --set "$CINDER_CONF" ceph rbd_store_chunk_size "4"
sudo crudini --set "$CINDER_CONF" ceph rados_connect_timeout "-1"
# Ceph user for Cinder (created during Ceph setup)
sudo crudini --set "$CINDER_CONF" ceph rbd_user "cinder"
# Secret UUID for libvirt (needed for Nova to attach volumes)
# Generate a consistent UUID based on cluster
CINDER_SECRET_UUID=$(sudo ceph fsid 2>/dev/null || echo "457eb676-33da-42ec-9a8c-9293d545c337")
sudo crudini --set "$CINDER_CONF" ceph rbd_secret_uuid "${CINDER_SECRET_UUID}"
echo "  ✓ [ceph] backend configured"
echo "  Ceph secret UUID: ${CINDER_SECRET_UUID}"

# =============================================================================
# PART 7: Setup Ceph Keyring for Cinder
# =============================================================================
echo ""
echo "[7/8] Setting up Ceph keyring for Cinder..."

CEPH_KEYRING="/etc/ceph/ceph.client.cinder.keyring"

# Check if Ceph cinder keyring exists
if [ -f "$CEPH_KEYRING" ]; then
    echo "  ✓ Ceph keyring exists: ${CEPH_KEYRING}"

    # Ensure cinder user can read the keyring
    sudo chown ceph:cinder "$CEPH_KEYRING" 2>/dev/null || \
        sudo chown root:cinder "$CEPH_KEYRING"
    sudo chmod 640 "$CEPH_KEYRING"
    echo "  ✓ Keyring permissions set (cinder can read)"
else
    echo "  ⚠ WARNING: Ceph keyring not found: ${CEPH_KEYRING}"
    echo "  You may need to create a Ceph user for Cinder:"
    echo "    sudo ceph auth get-or-create client.cinder mon 'profile rbd' osd 'profile rbd pool=${CEPH_CINDER_POOL}, profile rbd pool=${CEPH_NOVA_POOL}' -o ${CEPH_KEYRING}"
    ERRORS=$((ERRORS+1))
fi

# Also check for images pool access (for volume from image)
if sudo ceph auth get client.cinder 2>/dev/null | grep -q "${CEPH_GLANCE_POOL}"; then
    echo "  ✓ Cinder has access to images pool (for volume-from-image)"
else
    echo "  ⚠ NOTE: Consider giving cinder access to images pool for faster volume creation from images"
fi

# =============================================================================
# PART 8: Final Verification
# =============================================================================
echo ""
echo "[8/8] Verifying configuration..."

# Check config file syntax by parsing it
if sudo crudini --get "$CINDER_CONF" database connection &>/dev/null; then
    echo "  ✓ Configuration file syntax OK"
else
    echo "  ✗ ERROR: Configuration file has syntax errors!"
    ERRORS=$((ERRORS+1))
fi

# Show key configuration values
echo ""
echo "Configuration summary:"
echo "  Database: $(sudo crudini --get "$CINDER_CONF" database connection 2>/dev/null | sed 's/:[^:@]*@/:****@/')"
echo "  RabbitMQ: $(sudo crudini --get "$CINDER_CONF" DEFAULT transport_url 2>/dev/null | sed 's/:[^:@]*@/:****@/')"
echo "  Backend: $(sudo crudini --get "$CINDER_CONF" DEFAULT enabled_backends 2>/dev/null)"
echo "  Ceph Pool: $(sudo crudini --get "$CINDER_CONF" ceph rbd_pool 2>/dev/null)"
echo "  Ceph User: $(sudo crudini --get "$CINDER_CONF" ceph rbd_user 2>/dev/null)"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Cinder Configuration Complete ==="
else
    echo "=== Cinder Configuration Completed with $ERRORS Warning(s) ==="
fi
echo "=========================================="
echo ""
echo "Configuration file: ${CINDER_CONF}"
echo "Backend: Ceph RBD (pool: ${CEPH_CINDER_POOL})"
echo "Ceph secret UUID: ${CINDER_SECRET_UUID}"
echo ""
echo "Services configured (not yet started):"
echo "  - cinder-api (API service)"
echo "  - cinder-scheduler (scheduling)"
echo "  - cinder-volume (Ceph backend)"
echo ""
echo "Next: Run 31-cinder-sync.sh to sync database and start services"
