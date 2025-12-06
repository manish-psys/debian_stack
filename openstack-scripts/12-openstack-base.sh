#!/bin/bash
###############################################################################
# 12-openstack-base.sh
# Install OpenStack base dependencies (MariaDB, RabbitMQ, Memcached, etcd)
# Idempotent - safe to run multiple times
#
# This script installs and configures:
# - python3-openstackclient: CLI tools
# - MariaDB: Database server
# - RabbitMQ: Message queue for inter-service communication
# - Memcached: Token caching
# - etcd: Distributed key-value store (for coordination)
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Source shared environment (if available)
# =============================================================================
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
    echo "OpenStack environment loaded"
else
    # Fallback defaults if openstack-env.sh doesn't exist yet
    RABBIT_USER="openstack"
    RABBIT_PASS="rabbitpass123"
    CONTROLLER_IP="192.168.2.9"
    echo "Using default RabbitMQ credentials (openstack-env.sh not found)"
fi

echo "=== Step 12: OpenStack Base Dependencies ==="

# ============================================================================
# PART 1: Install packages
# ============================================================================
echo ""
echo "[1/5] Installing packages..."

# Check if packages already installed
PACKAGES_NEEDED=""
for PKG in python3-openstackclient mariadb-server rabbitmq-server memcached python3-memcache etcd-server; do
    if ! dpkg -l "$PKG" 2>/dev/null | grep -q "^ii"; then
        PACKAGES_NEEDED="$PACKAGES_NEEDED $PKG"
    fi
done

if [ -n "$PACKAGES_NEEDED" ]; then
    sudo apt-get update
    sudo apt-get install -y $PACKAGES_NEEDED
    echo "  ✓ Packages installed"
else
    echo "  ✓ All packages already installed"
fi

# ============================================================================
# PART 2: Enable and start services
# ============================================================================
echo ""
echo "[2/5] Starting services..."

for SVC in mariadb rabbitmq-server memcached etcd; do
    if ! systemctl is-enabled --quiet "$SVC" 2>/dev/null; then
        sudo systemctl enable "$SVC"
    fi
    
    if ! systemctl is-active --quiet "$SVC"; then
        sudo systemctl start "$SVC"
        echo "  ✓ Started $SVC"
    else
        echo "  ✓ $SVC already running"
    fi
done

# ============================================================================
# PART 3: Configure RabbitMQ user for OpenStack
# ============================================================================
echo ""
echo "[3/5] Configuring RabbitMQ..."

# Wait for RabbitMQ to be fully ready
MAX_RETRIES=10
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if sudo rabbitmqctl status &>/dev/null; then
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for RabbitMQ... (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "  ✗ ERROR: RabbitMQ not ready!"
    exit 1
fi

# Check if openstack user exists
if sudo rabbitmqctl list_users | grep -q "^${RABBIT_USER}"; then
    echo "  ✓ RabbitMQ user '${RABBIT_USER}' already exists"
    # Update password to ensure it matches
    sudo rabbitmqctl change_password "${RABBIT_USER}" "${RABBIT_PASS}"
    echo "  ✓ RabbitMQ user '${RABBIT_USER}' password updated"
else
    # Create the openstack user
    sudo rabbitmqctl add_user "${RABBIT_USER}" "${RABBIT_PASS}"
    echo "  ✓ RabbitMQ user '${RABBIT_USER}' created"
fi

# Set permissions for the openstack user (idempotent)
sudo rabbitmqctl set_permissions "${RABBIT_USER}" ".*" ".*" ".*"
echo "  ✓ RabbitMQ permissions set for '${RABBIT_USER}'"

# Verify RabbitMQ user
if sudo rabbitmqctl list_users | grep -q "^${RABBIT_USER}"; then
    echo "  ✓ RabbitMQ user '${RABBIT_USER}' verified"
else
    echo "  ✗ ERROR: RabbitMQ user creation failed!"
    exit 1
fi

# ============================================================================
# PART 4: Configure Memcached
# ============================================================================
echo ""
echo "[4/5] Configuring Memcached..."

# Memcached should listen on localhost (default) or controller IP
# Check current config
if grep -q "^-l 127.0.0.1" /etc/memcached.conf 2>/dev/null; then
    echo "  ✓ Memcached listening on localhost (default)"
elif grep -q "^-l" /etc/memcached.conf 2>/dev/null; then
    MEMCACHED_LISTEN=$(grep "^-l" /etc/memcached.conf | awk '{print $2}')
    echo "  ✓ Memcached listening on: ${MEMCACHED_LISTEN}"
else
    echo "  ✓ Memcached using default configuration"
fi

# ============================================================================
# PART 5: Verification
# ============================================================================
echo ""
echo "[5/5] Verifying installation..."

ERRORS=0

# Check all services are running
for SVC in mariadb rabbitmq-server memcached etcd; do
    if systemctl is-active --quiet "$SVC"; then
        echo "  ✓ $SVC is running"
    else
        echo "  ✗ $SVC is NOT running!"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check MariaDB port
if sudo ss -tlnp | grep -q ':3306'; then
    echo "  ✓ MariaDB listening on port 3306"
else
    echo "  ✗ MariaDB NOT listening on port 3306!"
    ERRORS=$((ERRORS + 1))
fi

# Check RabbitMQ port
if sudo ss -tlnp | grep -q ':5672'; then
    echo "  ✓ RabbitMQ listening on port 5672"
else
    echo "  ✗ RabbitMQ NOT listening on port 5672!"
    ERRORS=$((ERRORS + 1))
fi

# Check Memcached port
if sudo ss -tlnp | grep -q ':11211'; then
    echo "  ✓ Memcached listening on port 11211"
else
    echo "  ✗ Memcached NOT listening on port 11211!"
    ERRORS=$((ERRORS + 1))
fi

# Check RabbitMQ openstack user
if sudo rabbitmqctl list_users | grep -q "^${RABBIT_USER}"; then
    echo "  ✓ RabbitMQ user '${RABBIT_USER}' exists"
else
    echo "  ✗ RabbitMQ user '${RABBIT_USER}' NOT found!"
    ERRORS=$((ERRORS + 1))
fi

# Show RabbitMQ users
echo ""
echo "RabbitMQ Users:"
sudo rabbitmqctl list_users

# Final summary
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Base dependencies installed successfully ==="
    echo "=========================================="
    echo ""
    echo "Services running:"
    echo "  - MariaDB: port 3306"
    echo "  - RabbitMQ: port 5672 (user: ${RABBIT_USER})"
    echo "  - Memcached: port 11211"
    echo "  - etcd: port 2379"
    echo ""
    echo "RabbitMQ credentials:"
    echo "  User: ${RABBIT_USER}"
    echo "  Pass: ${RABBIT_PASS}"
    echo ""
    echo "Next: Run 13-mariadb-config.sh"
else
    echo "=== Installation completed with $ERRORS error(s) ==="
    echo "=========================================="
    exit 1
fi
