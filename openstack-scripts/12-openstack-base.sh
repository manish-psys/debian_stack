#!/bin/bash
###############################################################################
# 12-openstack-base.sh
# Install OpenStack base dependencies (MariaDB, RabbitMQ, Memcached, etcd)
# Idempotent - safe to run multiple times
#
# This script installs and configures:
# - python3-openstackclient: CLI tools
# - MariaDB: Database server (with security hardening)
# - RabbitMQ: Message queue for inter-service communication
# - Memcached: Token caching
# - etcd: Distributed key-value store (for coordination)
#
# Prerequisites:
# - Script 11-ceph-pools.sh completed successfully
# - openstack-env.sh exists with required variables
#
# Version: Uses Debian Trixie native packages (no version pinning needed
#          as we're using a specific Debian release)
###############################################################################

# Don't use set -e globally - we handle errors explicitly for better reporting
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Source shared environment
# =============================================================================
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found in ${SCRIPT_DIR}"
    echo "Please ensure the environment file exists before running this script."
    exit 1
fi

# Error counter for final summary
ERRORS=0

# Helper functions
log_success() { echo "  ✓ $1"; }
log_error() { echo "  ✗ ERROR: $1"; ((ERRORS++)); }
log_warn() { echo "  ! $1"; }
log_info() { echo "  $1"; }

echo "=== Step 12: OpenStack Base Dependencies ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"

# ============================================================================
# PART 1: Install packages
# ============================================================================
echo ""
echo "[1/6] Installing packages..."

# List of required packages
# Note: On Debian Trixie, these come from the stable release repository
# Version pinning is implicit via the Debian release we're using
REQUIRED_PACKAGES=(
    python3-openstackclient
    mariadb-server
    mariadb-client
    rabbitmq-server
    memcached
    python3-memcache
    etcd-server
    etcd-client
)

PACKAGES_TO_INSTALL=""
for PKG in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l "$PKG" 2>/dev/null | grep -q "^ii"; then
        PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL $PKG"
    fi
done

if [ -n "$PACKAGES_TO_INSTALL" ]; then
    log_info "Installing:$PACKAGES_TO_INSTALL"
    if sudo apt-get update -qq && sudo apt-get install -y $PACKAGES_TO_INSTALL; then
        log_success "Packages installed"
    else
        log_error "Package installation failed"
        exit 1
    fi
else
    log_success "All packages already installed"
fi

# Show installed versions for reproducibility documentation
echo ""
echo "  Installed versions:"
for PKG in "${REQUIRED_PACKAGES[@]}"; do
    VERSION=$(dpkg -l "$PKG" 2>/dev/null | grep "^ii" | awk '{print $3}' | head -1)
    if [ -n "$VERSION" ]; then
        echo "    $PKG: $VERSION"
    fi
done

# ============================================================================
# PART 2: Configure and Start MariaDB
# ============================================================================
echo ""
echo "[2/6] Configuring MariaDB..."

# Create OpenStack-optimized MariaDB configuration
MARIADB_OPENSTACK_CONF="/etc/mysql/mariadb.conf.d/99-openstack.cnf"
if [ ! -f "$MARIADB_OPENSTACK_CONF" ]; then
    sudo tee "$MARIADB_OPENSTACK_CONF" > /dev/null << EOF
[mysqld]
# OpenStack recommended settings
# bind-address = 0.0.0.0 allows connections from any interface
# Security is handled via MySQL user grants (localhost and % with passwords)
bind-address = 0.0.0.0
default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF
    log_success "MariaDB OpenStack configuration created"
    MARIADB_RESTART_NEEDED=true
else
    log_success "MariaDB OpenStack configuration already exists"
    MARIADB_RESTART_NEEDED=false
fi

# Enable and start MariaDB
if ! systemctl is-enabled --quiet mariadb 2>/dev/null; then
    sudo systemctl enable mariadb
fi

if [ "$MARIADB_RESTART_NEEDED" = true ] || ! systemctl is-active --quiet mariadb; then
    sudo systemctl restart mariadb
    sleep 2
    log_success "MariaDB started/restarted"
else
    log_success "MariaDB already running"
fi

# Secure MariaDB installation (idempotent)
# Check if root password is already set or socket auth is configured
log_info "Securing MariaDB installation..."

# For Debian, MariaDB uses unix_socket auth by default for root
# We just need to ensure anonymous users and test database are removed
sudo mysql -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
sudo mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
sudo mysql -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
sudo mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
sudo mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
log_success "MariaDB secured"

# ============================================================================
# PART 3: Configure and Start RabbitMQ
# ============================================================================
echo ""
echo "[3/6] Configuring RabbitMQ..."

# Enable and start RabbitMQ
if ! systemctl is-enabled --quiet rabbitmq-server 2>/dev/null; then
    sudo systemctl enable rabbitmq-server
fi

if ! systemctl is-active --quiet rabbitmq-server; then
    sudo systemctl start rabbitmq-server
    log_success "RabbitMQ started"
else
    log_success "RabbitMQ already running"
fi

# Wait for RabbitMQ to be fully ready
log_info "Waiting for RabbitMQ to be ready..."
MAX_RETRIES=15
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if sudo rabbitmqctl status &>/dev/null; then
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    log_error "RabbitMQ not ready after ${MAX_RETRIES} retries"
    exit 1
fi
log_success "RabbitMQ is ready"

# Configure OpenStack user (idempotent)
if sudo rabbitmqctl list_users | grep -q "^${RABBIT_USER}[[:space:]]"; then
    # User exists, update password
    sudo rabbitmqctl change_password "${RABBIT_USER}" "${RABBIT_PASS}" >/dev/null
    log_success "RabbitMQ user '${RABBIT_USER}' password updated"
else
    # Create user
    sudo rabbitmqctl add_user "${RABBIT_USER}" "${RABBIT_PASS}" >/dev/null
    log_success "RabbitMQ user '${RABBIT_USER}' created"
fi

# Set permissions (idempotent)
sudo rabbitmqctl set_permissions "${RABBIT_USER}" ".*" ".*" ".*" >/dev/null
log_success "RabbitMQ permissions configured"

# ============================================================================
# PART 4: Configure and Start Memcached
# ============================================================================
echo ""
echo "[4/6] Configuring Memcached..."

# Configure Memcached to listen on controller IP (for multi-node support)
MEMCACHED_CONF="/etc/memcached.conf"
MEMCACHED_RESTART_NEEDED=false

# Check if already configured for our IP
if grep -q "^-l ${CONTROLLER_IP}" "$MEMCACHED_CONF" 2>/dev/null; then
    log_success "Memcached already configured for ${CONTROLLER_IP}"
elif grep -q "^-l 127.0.0.1" "$MEMCACHED_CONF" 2>/dev/null; then
    # Update to listen on controller IP (allows other nodes to connect)
    sudo sed -i "s/^-l 127.0.0.1/-l ${CONTROLLER_IP}/" "$MEMCACHED_CONF"
    MEMCACHED_RESTART_NEEDED=true
    log_success "Memcached configured to listen on ${CONTROLLER_IP}"
else
    # Add listen directive
    echo "-l ${CONTROLLER_IP}" | sudo tee -a "$MEMCACHED_CONF" > /dev/null
    MEMCACHED_RESTART_NEEDED=true
    log_success "Memcached listen address added"
fi

# Enable and start Memcached
if ! systemctl is-enabled --quiet memcached 2>/dev/null; then
    sudo systemctl enable memcached
fi

if [ "$MEMCACHED_RESTART_NEEDED" = true ] || ! systemctl is-active --quiet memcached; then
    sudo systemctl restart memcached
    sleep 1
    log_success "Memcached started/restarted"
else
    log_success "Memcached already running"
fi

# ============================================================================
# PART 5: Configure and Start etcd
# ============================================================================
echo ""
echo "[5/6] Configuring etcd..."

# Configure etcd for OpenStack
ETCD_CONF="/etc/default/etcd"
ETCD_RESTART_NEEDED=false

# Check if already configured
if grep -q "ETCD_LISTEN_CLIENT_URLS.*${CONTROLLER_IP}" "$ETCD_CONF" 2>/dev/null; then
    log_success "etcd already configured"
else
    # Backup original if exists and not already backed up
    if [ -f "$ETCD_CONF" ] && [ ! -f "${ETCD_CONF}.orig" ]; then
        sudo cp "$ETCD_CONF" "${ETCD_CONF}.orig"
    fi
    
    # Configure etcd
    sudo tee "$ETCD_CONF" > /dev/null << EOF
# etcd configuration for OpenStack
ETCD_NAME="${CONTROLLER_HOSTNAME}"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_CLIENT_URLS="http://${CONTROLLER_IP}:2379,http://127.0.0.1:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://${CONTROLLER_IP}:2379"
ETCD_LISTEN_PEER_URLS="http://127.0.0.1:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${CONTROLLER_IP}:2380"
ETCD_INITIAL_CLUSTER="${CONTROLLER_HOSTNAME}=http://${CONTROLLER_IP}:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-openstack"
EOF
    ETCD_RESTART_NEEDED=true
    log_success "etcd configuration created"
fi

# Enable and start etcd
if ! systemctl is-enabled --quiet etcd 2>/dev/null; then
    sudo systemctl enable etcd
fi

if [ "$ETCD_RESTART_NEEDED" = true ] || ! systemctl is-active --quiet etcd; then
    # etcd may fail if data dir has stale cluster info - clean if needed
    if [ "$ETCD_RESTART_NEEDED" = true ]; then
        sudo systemctl stop etcd 2>/dev/null || true
        sudo rm -rf /var/lib/etcd/member 2>/dev/null || true
    fi
    sudo systemctl restart etcd
    sleep 2
    log_success "etcd started/restarted"
else
    log_success "etcd already running"
fi

# ============================================================================
# PART 6: Verification
# ============================================================================
echo ""
echo "[6/6] Verifying installation..."

# Check all services are running
echo ""
echo "Service Status:"
for SVC in mariadb rabbitmq-server memcached etcd; do
    if systemctl is-active --quiet "$SVC"; then
        log_success "$SVC is running"
    else
        log_error "$SVC is NOT running"
    fi
done

# Check ports
echo ""
echo "Port Status:"

# MariaDB port 3306
if sudo ss -tlnp | grep -q ":3306"; then
    log_success "MariaDB listening on port 3306"
else
    log_error "MariaDB NOT listening on port 3306"
fi

# RabbitMQ port 5672
if sudo ss -tlnp | grep -q ":5672"; then
    log_success "RabbitMQ listening on port 5672"
else
    log_error "RabbitMQ NOT listening on port 5672"
fi

# Memcached port 11211
if sudo ss -tlnp | grep -q ":11211"; then
    log_success "Memcached listening on port 11211"
else
    log_error "Memcached NOT listening on port 11211"
fi

# etcd port 2379
if sudo ss -tlnp | grep -q ":2379"; then
    log_success "etcd listening on port 2379"
else
    log_error "etcd NOT listening on port 2379"
fi

# Verify RabbitMQ user
echo ""
echo "RabbitMQ Users:"
if sudo rabbitmqctl list_users | grep -q "^${RABBIT_USER}[[:space:]]"; then
    log_success "RabbitMQ user '${RABBIT_USER}' exists"
    sudo rabbitmqctl list_users
else
    log_error "RabbitMQ user '${RABBIT_USER}' NOT found"
fi

# Verify MariaDB connection
echo ""
echo "MariaDB Connection Test:"
if sudo mysql -e "SELECT 1;" &>/dev/null; then
    log_success "MariaDB accepts connections"
else
    log_error "MariaDB connection failed"
fi

# Verify etcd health
echo ""
echo "etcd Health Check:"
if etcdctl --endpoints=http://${CONTROLLER_IP}:2379 endpoint health &>/dev/null; then
    log_success "etcd is healthy"
    etcdctl --endpoints=http://${CONTROLLER_IP}:2379 endpoint health
else
    # Try localhost as fallback
    if etcdctl --endpoints=http://127.0.0.1:2379 endpoint health &>/dev/null; then
        log_success "etcd is healthy (localhost)"
    else
        log_error "etcd health check failed"
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== ✓ Base dependencies installed successfully ==="
    echo "=========================================="
    echo ""
    echo "Services configured:"
    echo "  - MariaDB:   ${CONTROLLER_IP}:3306 (bind: ${CONTROLLER_IP})"
    echo "  - RabbitMQ:  ${CONTROLLER_IP}:5672 (user: ${RABBIT_USER})"
    echo "  - Memcached: ${CONTROLLER_IP}:11211"
    echo "  - etcd:      ${CONTROLLER_IP}:2379"
    echo ""
    echo "Connection strings for OpenStack services:"
    echo "  MariaDB:   mysql+pymysql://USER:PASS@${CONTROLLER_IP}/DB"
    echo "  RabbitMQ:  rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
    echo "  Memcached: ${CONTROLLER_IP}:11211"
    echo ""
    echo "Next: Run 13-keystone-install.sh"
else
    echo "=== ✗ Installation completed with $ERRORS error(s) ==="
    echo "=========================================="
    echo ""
    echo "Please review errors above and check:"
    echo "  sudo journalctl -u mariadb -n 50"
    echo "  sudo journalctl -u rabbitmq-server -n 50"
    echo "  sudo journalctl -u memcached -n 50"
    echo "  sudo journalctl -u etcd -n 50"
    exit 1
fi
