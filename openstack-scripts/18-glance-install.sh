#!/bin/bash
###############################################################################
# 18-glance-install.sh
# Install and configure Glance (Image service) with Ceph backend
# Idempotent - safe to run multiple times
#
# For Debian 13 (Trixie) with native OpenStack packages
# Glance version: 2:30.0.0-3 (OpenStack 2024.2 Dalmatian)
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 18: Glance Installation ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"
echo ""

# ============================================================================
# PART 0: Prerequisites check
# ============================================================================
echo "[0/8] Checking prerequisites..."

# Check crudini using absolute path (avoid PATH issues in different contexts)
if [ ! -x /usr/bin/crudini ]; then
    sudo apt-get install -y crudini
fi
echo "  ✓ crudini available"

# Verify Ceph is running
if ! sudo ceph health &>/dev/null; then
    echo "  ✗ ERROR: Ceph cluster not accessible!"
    exit 1
fi
echo "  ✓ Ceph cluster accessible"

# ============================================================================
# PART 1: Create Ceph pool for Glance images
# ============================================================================
echo "[1/8] Creating Ceph pool for images..."

if sudo ceph osd pool ls | grep -q "^${CEPH_GLANCE_POOL}$"; then
    echo "  ✓ Pool '${CEPH_GLANCE_POOL}' already exists"
else
    sudo ceph osd pool create ${CEPH_GLANCE_POOL} 32
    sudo ceph osd pool set ${CEPH_GLANCE_POOL} size 2
    sudo ceph osd pool application enable ${CEPH_GLANCE_POOL} rbd
    echo "  ✓ Pool '${CEPH_GLANCE_POOL}' created"
fi

# Initialize RBD on the pool
sudo rbd pool init ${CEPH_GLANCE_POOL} 2>/dev/null || true

# ============================================================================
# PART 2: Create Ceph user for Glance
# ============================================================================
echo "[2/8] Creating Ceph user for Glance..."

if sudo ceph auth get client.glance &>/dev/null; then
    echo "  ✓ Ceph user 'glance' already exists"
else
    sudo ceph auth get-or-create client.glance \
        mon 'allow r' \
        osd "allow class-read object_prefix rbd_children, allow rwx pool=${CEPH_GLANCE_POOL}" \
        -o /etc/ceph/ceph.client.glance.keyring
    echo "  ✓ Ceph user 'glance' created"
fi

# Ensure keyring file exists and has correct permissions
if [ ! -f /etc/ceph/ceph.client.glance.keyring ]; then
    sudo ceph auth get client.glance -o /etc/ceph/ceph.client.glance.keyring
fi

# ============================================================================
# PART 3: Pre-seed dbconfig-common
# ============================================================================
echo "[3/8] Configuring dbconfig-common..."

sudo mkdir -p /etc/dbconfig-common
cat <<EOF | sudo tee /etc/dbconfig-common/glance-api.conf > /dev/null
dbc_install='false'
dbc_upgrade='false'
dbc_remove=''
dbc_dbtype='mysql'
dbc_dbuser='glance'
dbc_dbpass='${GLANCE_DB_PASS}'
dbc_dbserver='${CONTROLLER_IP}'
dbc_dbname='glance'
EOF

echo "glance-api glance/dbconfig-install boolean false" | sudo debconf-set-selections
echo "glance-common glance/dbconfig-install boolean false" | sudo debconf-set-selections

echo "  ✓ dbconfig-common configured"

# ============================================================================
# PART 4: Install Glance packages
# ============================================================================
echo "[4/8] Installing Glance packages..."

export DEBIAN_FRONTEND=noninteractive

# Debian Trixie has Glance in main repositories - no backports needed
# Package version: 2:30.0.0-3 (OpenStack 2024.2 Dalmatian)
sudo -E apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    glance python3-rbd

echo "  ✓ Glance packages installed"

# Display installed version
GLANCE_VERSION=$(dpkg -l glance | grep "^ii" | awk '{print $3}')
echo "  Installed version: glance ${GLANCE_VERSION}"

# ============================================================================
# PART 5: Configure Glance
# ============================================================================
echo "[5/8] Configuring Glance..."

# Backup original config
if [ -f /etc/glance/glance-api.conf ] && [ ! -f /etc/glance/glance-api.conf.orig ]; then
    sudo cp /etc/glance/glance-api.conf /etc/glance/glance-api.conf.orig
fi

# Database connection (use CONTROLLER_IP for consistency)
sudo crudini --set /etc/glance/glance-api.conf database connection \
    "mysql+pymysql://glance:${GLANCE_DB_PASS}@${CONTROLLER_IP}/glance"

# Keystone authentication - using helper function from openstack-env.sh
configure_keystone_authtoken /etc/glance/glance-api.conf glance "$GLANCE_PASS"

# Paste deploy
sudo crudini --set /etc/glance/glance-api.conf paste_deploy flavor "keystone"

# Ceph/RBD backend configuration
sudo crudini --set /etc/glance/glance-api.conf glance_store stores "rbd,file,http"
sudo crudini --set /etc/glance/glance-api.conf glance_store default_store "rbd"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_pool "${CEPH_GLANCE_POOL}"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_user "glance"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_ceph_conf "/etc/ceph/ceph.conf"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_chunk_size "8"

# Enable image format options
sudo crudini --set /etc/glance/glance-api.conf DEFAULT show_image_direct_url "True"

echo "  ✓ Glance configured"

# ============================================================================
# PART 6: Fix keyring permissions
# ============================================================================
echo "[6/8] Fixing Ceph keyring permissions..."

sudo chown glance:glance /etc/ceph/ceph.client.glance.keyring
sudo chmod 640 /etc/ceph/ceph.client.glance.keyring

echo "  ✓ Keyring permissions set"

# ============================================================================
# PART 7: Sync database
# ============================================================================
echo "[7/8] Syncing Glance database..."

if sudo -u glance glance-manage db_sync 2>&1; then
    echo "  ✓ Database synced"
else
    echo "  ✗ ERROR: Database sync failed!"
    exit 1
fi

# ============================================================================
# PART 8: Start services
# ============================================================================
echo "[8/8] Starting Glance services..."

sudo systemctl restart glance-api
sudo systemctl enable glance-api

# Wait for service to start
sleep 3

echo "  ✓ Glance services started"

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "Verifying Glance installation..."

ERRORS=0

# Check service is running
if systemctl is-active --quiet glance-api; then
    echo "  ✓ glance-api service is running"
else
    echo "  ✗ glance-api service is NOT running!"
    ERRORS=$((ERRORS + 1))
fi

# Check port is listening
if sudo ss -tlnp | grep -q ':9292'; then
    echo "  ✓ Glance is listening on port 9292"
else
    echo "  ✗ Glance is NOT listening on port 9292!"
    ERRORS=$((ERRORS + 1))
fi

# Check Ceph pool
if sudo rados -p ${CEPH_GLANCE_POOL} ls &>/dev/null; then
    echo "  ✓ Ceph pool '${CEPH_GLANCE_POOL}' accessible"
else
    echo "  ✗ Ceph pool '${CEPH_GLANCE_POOL}' not accessible!"
    ERRORS=$((ERRORS + 1))
fi

# Verify region configuration
CONFIGURED_REGION=$(sudo crudini --get /etc/glance/glance-api.conf keystone_authtoken region_name 2>/dev/null || echo "NOT SET")
if [ "$CONFIGURED_REGION" = "$REGION_NAME" ]; then
    echo "  ✓ Region correctly set to: $CONFIGURED_REGION"
else
    echo "  ✗ Region mismatch! Expected: $REGION_NAME, Got: $CONFIGURED_REGION"
    ERRORS=$((ERRORS + 1))
fi

# Test API via OpenStack client
source ~/admin-openrc
if openstack image list &>/dev/null; then
    echo "  ✓ Glance API responding"
    IMAGE_COUNT=$(openstack image list -f value | wc -l)
    echo "  ✓ Current images: ${IMAGE_COUNT}"
else
    echo "  ✗ Glance API not responding!"
    echo "  Check logs: sudo tail -50 /var/log/glance/glance-api.log"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=== Glance installed successfully ==="
else
    echo "=== Glance installation completed with $ERRORS error(s) ==="
    echo "Check logs: sudo journalctl -u glance-api -n 50"
fi

echo ""
echo "To upload a test image:"
echo "  wget http://download.cirros-cloud.net/0.5.2/cirros-0.5.2-x86_64-disk.img"
echo "  openstack image create --disk-format qcow2 --container-format bare \\"
echo "    --public --file cirros-0.5.2-x86_64-disk.img cirros"
echo ""
echo "Next: Run 19-placement-db.sh"
