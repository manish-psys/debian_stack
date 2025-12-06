#!/bin/bash
###############################################################################
# 22-nova-install.sh
# Install and configure Nova (Compute service)
# Idempotent - safe to run multiple times
#
# Nova Components installed:
# - nova-api: REST API frontend
# - nova-conductor: Database proxy (security layer)
# - nova-scheduler: Decides which host runs instances
# - nova-novncproxy: VNC console proxy
# - nova-compute: Hypervisor management (libvirt/KVM)
#
# Nova Cell Architecture:
# - cell0: Special cell for instances that failed to schedule
# - cell1: Default cell for running instances
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
    echo "Please ensure openstack-env.sh is in the same directory as this script."
    exit 1
fi

echo "=== Step 22: Nova Installation ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo "Using Region: ${REGION_NAME}"

# ============================================================================
# PART 0: Check prerequisites
# ============================================================================
echo ""
echo "[0/8] Checking prerequisites..."

# Check crudini
if ! command -v crudini &>/dev/null; then
    sudo apt-get install -y crudini
fi
echo "  ✓ crudini available"

# Check admin-openrc
if [ ! -f ~/admin-openrc ]; then
    echo "  ✗ ERROR: ~/admin-openrc not found!"
    exit 1
fi
source ~/admin-openrc
echo "  ✓ admin-openrc loaded"

# Check Nova databases exist
for DB in nova_api nova nova_cell0; do
    if ! sudo mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB}'" 2>/dev/null | grep -q "${DB}"; then
        echo "  ✗ ERROR: Database '${DB}' not found. Run 21-nova-db.sh first!"
        exit 1
    fi
done
echo "  ✓ Nova databases exist (nova_api, nova, nova_cell0)"

# Check Nova Keystone user
if ! openstack user show nova &>/dev/null; then
    echo "  ✗ ERROR: Keystone user 'nova' not found. Run 21-nova-db.sh first!"
    exit 1
fi
echo "  ✓ Keystone user 'nova' exists"

# Check Nova service endpoints
if ! openstack service show nova &>/dev/null; then
    echo "  ✗ ERROR: Compute service not found. Run 21-nova-db.sh first!"
    exit 1
fi
echo "  ✓ Compute service registered"

# Check RabbitMQ is running
if ! systemctl is-active --quiet rabbitmq-server; then
    echo "  ✗ ERROR: RabbitMQ is not running!"
    exit 1
fi
echo "  ✓ RabbitMQ is running"

# Check RabbitMQ openstack user exists
if ! sudo rabbitmqctl list_users 2>/dev/null | grep -q "^${RABBIT_USER}"; then
    echo "  ✗ ERROR: RabbitMQ user '${RABBIT_USER}' not found!"
    echo "  Please run 12-openstack-base.sh to create the RabbitMQ user."
    exit 1
fi
echo "  ✓ RabbitMQ user '${RABBIT_USER}' exists"

# Check Placement API is responding
if ! curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8778/" | grep -q "200"; then
    echo "  ✗ ERROR: Placement API not responding on port 8778!"
    exit 1
fi
echo "  ✓ Placement API responding"

# Check Glance API is responding
if ! curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:9292/" | grep -q "200\|300"; then
    echo "  ✗ ERROR: Glance API not responding on port 9292!"
    exit 1
fi
echo "  ✓ Glance API responding"

# Check Memcached is running
if ! systemctl is-active --quiet memcached; then
    echo "  ✗ ERROR: Memcached is not running!"
    exit 1
fi
echo "  ✓ Memcached is running"

# ============================================================================
# PART 1: Pre-seed dbconfig-common
# ============================================================================
echo ""
echo "[1/8] Configuring dbconfig-common..."

sudo mkdir -p /etc/dbconfig-common

# nova-api dbconfig
cat <<EOF | sudo tee /etc/dbconfig-common/nova-api.conf > /dev/null
dbc_install='false'
dbc_upgrade='false'
dbc_remove=''
dbc_dbtype='mysql'
dbc_dbuser='nova'
dbc_dbpass='${NOVA_DB_PASS}'
dbc_dbserver='localhost'
dbc_dbname='nova_api'
EOF

# nova-common dbconfig (main nova database)
cat <<EOF | sudo tee /etc/dbconfig-common/nova-common.conf > /dev/null
dbc_install='false'
dbc_upgrade='false'
dbc_remove=''
dbc_dbtype='mysql'
dbc_dbuser='nova'
dbc_dbpass='${NOVA_DB_PASS}'
dbc_dbserver='localhost'
dbc_dbname='nova'
EOF

echo "nova-api nova-api/dbconfig-install boolean false" | sudo debconf-set-selections
echo "nova-common nova-common/dbconfig-install boolean false" | sudo debconf-set-selections

echo "  ✓ dbconfig-common configured"

# ============================================================================
# PART 2: Install Nova packages
# ============================================================================
echo ""
echo "[2/8] Installing Nova packages..."

export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get -t bullseye-wallaby-backports install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    nova-api nova-conductor nova-scheduler nova-novncproxy nova-compute

echo "  ✓ Nova packages installed"

# Configure nova-consoleproxy to use noVNC (required for Debian)
# Without this, nova-novncproxy service exits immediately
echo "  Configuring console proxy type..."
cat <<EOF | sudo tee /etc/default/nova-consoleproxy > /dev/null
# Console proxy type: novnc or spicehtml5
NOVA_CONSOLE_PROXY_TYPE="novnc"

# Enable serial proxy (TRUE/FALSE)
NOVA_SERIAL_PROXY_START=false
EOF
echo "  ✓ Console proxy configured for noVNC"

# ============================================================================
# PART 3: Stop Nova services before configuration
# ============================================================================
echo ""
echo "[3/8] Stopping Nova services for configuration..."

# Stop all Nova services to prevent race conditions during config
for SERVICE in nova-api nova-conductor nova-scheduler nova-novncproxy nova-compute; do
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        sudo systemctl stop "$SERVICE"
        echo "  ✓ Stopped $SERVICE"
    fi
done
echo "  ✓ All Nova services stopped"

# ============================================================================
# PART 4: Configure Nova
# ============================================================================
echo ""
echo "[4/8] Configuring Nova..."

# Backup original config (only if not already backed up)
if [ -f /etc/nova/nova.conf ] && [ ! -f /etc/nova/nova.conf.orig ]; then
    sudo cp /etc/nova/nova.conf /etc/nova/nova.conf.orig
    echo "  ✓ Original config backed up"
fi

# --- [DEFAULT] section ---
sudo crudini --set /etc/nova/nova.conf DEFAULT my_ip "${CONTROLLER_IP}"
sudo crudini --set /etc/nova/nova.conf DEFAULT transport_url "rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
sudo crudini --set /etc/nova/nova.conf DEFAULT use_neutron "true"
sudo crudini --set /etc/nova/nova.conf DEFAULT firewall_driver "nova.virt.firewall.NoopFirewallDriver"
echo "  ✓ [DEFAULT] section configured"

# --- [api] section ---
sudo crudini --set /etc/nova/nova.conf api auth_strategy "keystone"
echo "  ✓ [api] section configured"

# --- [api_database] section ---
sudo crudini --set /etc/nova/nova.conf api_database connection \
    "mysql+pymysql://nova:${NOVA_DB_PASS}@localhost/nova_api"
echo "  ✓ [api_database] section configured"

# --- [database] section ---
sudo crudini --set /etc/nova/nova.conf database connection \
    "mysql+pymysql://nova:${NOVA_DB_PASS}@localhost/nova"
echo "  ✓ [database] section configured"

# --- [keystone_authtoken] section ---
# Using helper function pattern but inline for reliability
sudo crudini --set /etc/nova/nova.conf keystone_authtoken www_authenticate_uri "${KEYSTONE_AUTH_URL}"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken auth_url "${KEYSTONE_AUTH_URL}"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken username "nova"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken password "${NOVA_PASS}"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken region_name "${REGION_NAME}"
echo "  ✓ [keystone_authtoken] section configured"

# --- [vnc] section ---
sudo crudini --set /etc/nova/nova.conf vnc enabled "true"
sudo crudini --set /etc/nova/nova.conf vnc server_listen "0.0.0.0"
sudo crudini --set /etc/nova/nova.conf vnc server_proxyclient_address "${CONTROLLER_IP}"
sudo crudini --set /etc/nova/nova.conf vnc novncproxy_base_url "http://${CONTROLLER_IP}:6080/vnc_auto.html"
echo "  ✓ [vnc] section configured"

# --- [glance] section ---
sudo crudini --set /etc/nova/nova.conf glance api_servers "${GLANCE_API_URL}"
echo "  ✓ [glance] section configured"

# --- [oslo_concurrency] section ---
sudo crudini --set /etc/nova/nova.conf oslo_concurrency lock_path "/var/lib/nova/tmp"
echo "  ✓ [oslo_concurrency] section configured"

# --- [placement] section ---
sudo crudini --set /etc/nova/nova.conf placement region_name "${REGION_NAME}"
sudo crudini --set /etc/nova/nova.conf placement project_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf placement project_name "service"
sudo crudini --set /etc/nova/nova.conf placement auth_type "password"
sudo crudini --set /etc/nova/nova.conf placement user_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf placement auth_url "${KEYSTONE_AUTH_URL_V3}"
sudo crudini --set /etc/nova/nova.conf placement username "placement"
sudo crudini --set /etc/nova/nova.conf placement password "${PLACEMENT_PASS}"
echo "  ✓ [placement] section configured"

# --- [libvirt] section (for nova-compute) ---
# Detect virtualization support
if grep -qE '(vmx|svm)' /proc/cpuinfo; then
    VIRT_TYPE="kvm"
    echo "  ✓ Hardware virtualization detected (KVM)"
else
    VIRT_TYPE="qemu"
    echo "  ⚠ No hardware virtualization, using QEMU (slower)"
fi

sudo crudini --set /etc/nova/nova.conf libvirt virt_type "${VIRT_TYPE}"
sudo crudini --set /etc/nova/nova.conf libvirt cpu_mode "host-passthrough"
echo "  ✓ [libvirt] section configured (virt_type=${VIRT_TYPE})"

# Ensure lock directory exists
sudo mkdir -p /var/lib/nova/tmp
sudo chown nova:nova /var/lib/nova/tmp

echo "  ✓ Nova configuration complete"

# ============================================================================
# PART 5: Sync databases and setup cells
# ============================================================================
echo ""
echo "[5/8] Syncing databases and configuring cells..."

# Sync API database
echo "  Syncing API database..."
sudo nova-manage api_db sync
echo "  ✓ API database synced"

# Verify API database has tables
API_TABLE_COUNT=$(sudo mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='nova_api';" 2>/dev/null || echo "0")
if [ "$API_TABLE_COUNT" -lt 5 ]; then
    echo "  ✗ ERROR: API database sync failed! Tables: ${API_TABLE_COUNT}"
    exit 1
fi
echo "  ✓ API database tables: ${API_TABLE_COUNT}"

# Map cell0 (idempotent - will update if exists)
echo "  Mapping cell0..."
sudo nova-manage cell_v2 map_cell0
echo "  ✓ cell0 mapped"

# Create cell1 if not exists
echo "  Creating cell1..."
if sudo nova-manage cell_v2 list_cells 2>/dev/null | grep -q "cell1"; then
    echo "  ✓ cell1 already exists"
else
    sudo nova-manage cell_v2 create_cell --name=cell1 --verbose
    echo "  ✓ cell1 created"
fi

# Sync main database
echo "  Syncing main database..."
sudo nova-manage db sync
echo "  ✓ Main database synced"

# Verify main database has tables
MAIN_TABLE_COUNT=$(sudo mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='nova';" 2>/dev/null || echo "0")
if [ "$MAIN_TABLE_COUNT" -lt 50 ]; then
    echo "  ✗ ERROR: Main database sync failed! Tables: ${MAIN_TABLE_COUNT}"
    exit 1
fi
echo "  ✓ Main database tables: ${MAIN_TABLE_COUNT}"

# List cells for verification
echo ""
echo "  Cell configuration:"
sudo nova-manage cell_v2 list_cells

# ============================================================================
# PART 6: Start Nova services
# ============================================================================
echo ""
echo "[6/8] Starting Nova services..."

# Start and enable all Nova services
for SERVICE in nova-api nova-conductor nova-scheduler nova-novncproxy nova-compute; do
    sudo systemctl start "$SERVICE"
    sudo systemctl enable "$SERVICE"
    
    # nova-novncproxy is a proxy service that may show as "activating" briefly
    # Give it a moment and check again
    sleep 1
    
    if systemctl is-active --quiet "$SERVICE"; then
        echo "  ✓ $SERVICE started"
    else
        # For novncproxy, check if it's enabled and was recently active (it starts on demand)
        if [ "$SERVICE" = "nova-novncproxy" ]; then
            if systemctl is-enabled --quiet "$SERVICE"; then
                echo "  ✓ $SERVICE enabled (starts on VNC connection)"
            else
                echo "  ✗ ERROR: $SERVICE failed to enable!"
                exit 1
            fi
        else
            echo "  ✗ ERROR: $SERVICE failed to start!"
            sudo journalctl -u "$SERVICE" -n 10 --no-pager
            exit 1
        fi
    fi
done

# ============================================================================
# PART 7: Wait for services and discover compute host
# ============================================================================
echo ""
echo "[7/8] Waiting for services and discovering compute hosts..."

# Wait for nova-api to be ready
MAX_RETRIES=15
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8774/" 2>/dev/null | grep -qE "200|300|401"; then
        echo "  ✓ Nova API responding"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for Nova API... (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "  ✗ ERROR: Nova API did not respond in time!"
    exit 1
fi

# Wait a bit for compute to register
echo "  Waiting for compute host to register..."
sleep 5

# Discover compute hosts
echo "  Discovering compute hosts..."
sudo nova-manage cell_v2 discover_hosts --verbose

# ============================================================================
# PART 8: Verification
# ============================================================================
echo ""
echo "[8/8] Verifying Nova installation..."
echo ""

ERRORS=0

# Check all services are running
for SERVICE in nova-api nova-conductor nova-scheduler nova-novncproxy nova-compute; do
    if systemctl is-active --quiet "$SERVICE"; then
        echo "  ✓ $SERVICE is running"
    else
        echo "  ✗ $SERVICE is NOT running!"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check ports are listening
for PORT in 8774 6080; do
    if sudo ss -tlnp | grep -q ":${PORT}"; then
        echo "  ✓ Port ${PORT} is listening"
    else
        echo "  ✗ Port ${PORT} is NOT listening!"
        ERRORS=$((ERRORS + 1))
    fi
done

# Verify region configuration
CONFIGURED_REGION=$(sudo crudini --get /etc/nova/nova.conf keystone_authtoken region_name 2>/dev/null || echo "NOT SET")
if [ "$CONFIGURED_REGION" = "$REGION_NAME" ]; then
    echo "  ✓ Region correctly set: $CONFIGURED_REGION"
else
    echo "  ✗ Region mismatch! Expected: $REGION_NAME, Got: $CONFIGURED_REGION"
    ERRORS=$((ERRORS + 1))
fi

# Test Nova API via OpenStack CLI
source ~/admin-openrc
if openstack compute service list &>/dev/null; then
    echo "  ✓ Nova API responding to OpenStack CLI"
    echo ""
    echo "Compute Services:"
    openstack compute service list -f table
else
    echo "  ✗ Nova API not responding to OpenStack CLI!"
    ERRORS=$((ERRORS + 1))
fi

# Check hypervisors
echo ""
echo "Hypervisors:"
openstack hypervisor list -f table 2>/dev/null || echo "  (no hypervisors registered yet)"

# Check Placement integration
echo ""
echo "Resource Providers (from Placement):"
openstack --os-placement-api-version 1.2 resource provider list -f table 2>/dev/null || echo "  (checking...)"

# Final summary
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Nova installed successfully ==="
    echo "=========================================="
    echo ""
    echo "Services: nova-api, nova-conductor, nova-scheduler,"
    echo "          nova-novncproxy, nova-compute"
    echo ""
    echo "Ports:"
    echo "  - 8774: Nova API"
    echo "  - 6080: noVNC Proxy"
    echo ""
    echo "Config:  /etc/nova/nova.conf"
    echo "Logs:    /var/log/nova/"
    echo ""
    echo "Quick test commands:"
    echo "  openstack compute service list"
    echo "  openstack hypervisor list"
    echo "  openstack server list"
    echo ""
    echo "Next: Run 24-neutron-db.sh"
else
    echo "=== Nova installation completed with $ERRORS error(s) ==="
    echo "=========================================="
    echo ""
    echo "Check logs:"
    echo "  sudo journalctl -u nova-api -n 50"
    echo "  sudo journalctl -u nova-compute -n 50"
    echo "  sudo tail -50 /var/log/nova/nova-api.log"
fi
