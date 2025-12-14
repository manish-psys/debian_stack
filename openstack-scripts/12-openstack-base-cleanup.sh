#!/bin/bash
###############################################################################
# 12-openstack-base-cleanup.sh
# Cleanup script to reset base dependencies to pre-installation state
#
# WARNING: This will:
# - Stop and disable services
# - Remove RabbitMQ openstack user
# - Remove OpenStack MariaDB configuration
# - Reset etcd configuration
# - Optionally purge packages
#
# Use this when you need to re-run 12-openstack-base.sh from scratch
###############################################################################

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source environment for variables
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
else
    RABBIT_USER="openstack"
    CONTROLLER_IP="192.168.2.9"
fi

echo "=== OpenStack Base Dependencies Cleanup ==="
echo ""
echo "This will reset:"
echo "  - RabbitMQ user '${RABBIT_USER}'"
echo "  - MariaDB OpenStack configuration"
echo "  - Memcached configuration"
echo "  - etcd configuration and data"
echo ""
echo "Services will remain installed but reset to defaults."
echo ""

read -p "Type 'RESET' to confirm: " CONFIRM
if [ "$CONFIRM" != "RESET" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "[1/5] Cleaning RabbitMQ..."
if systemctl is-active --quiet rabbitmq-server; then
    if sudo rabbitmqctl list_users | grep -q "^${RABBIT_USER}[[:space:]]"; then
        sudo rabbitmqctl delete_user "${RABBIT_USER}" 2>/dev/null || true
        echo "  ✓ RabbitMQ user '${RABBIT_USER}' removed"
    else
        echo "  ✓ RabbitMQ user '${RABBIT_USER}' not found"
    fi
else
    echo "  ✓ RabbitMQ not running"
fi

echo ""
echo "[2/5] Cleaning MariaDB configuration..."
MARIADB_OPENSTACK_CONF="/etc/mysql/mariadb.conf.d/99-openstack.cnf"
if [ -f "$MARIADB_OPENSTACK_CONF" ]; then
    sudo rm -f "$MARIADB_OPENSTACK_CONF"
    echo "  ✓ MariaDB OpenStack config removed"
    
    # Restart MariaDB to apply default config
    if systemctl is-active --quiet mariadb; then
        sudo systemctl restart mariadb
        echo "  ✓ MariaDB restarted with default config"
    fi
else
    echo "  ✓ MariaDB OpenStack config not found"
fi

echo ""
echo "[3/5] Resetting Memcached configuration..."
MEMCACHED_CONF="/etc/memcached.conf"
if grep -q "^-l ${CONTROLLER_IP}" "$MEMCACHED_CONF" 2>/dev/null; then
    sudo sed -i "s/^-l ${CONTROLLER_IP}/-l 127.0.0.1/" "$MEMCACHED_CONF"
    sudo systemctl restart memcached 2>/dev/null || true
    echo "  ✓ Memcached reset to localhost"
else
    echo "  ✓ Memcached already on default config"
fi

echo ""
echo "[4/5] Resetting etcd..."
sudo systemctl stop etcd 2>/dev/null || true

# Remove etcd data
if [ -d "/var/lib/etcd/member" ]; then
    sudo rm -rf /var/lib/etcd/member
    echo "  ✓ etcd data removed"
fi

# Restore original config or remove custom config
ETCD_CONF="/etc/default/etcd"
if [ -f "${ETCD_CONF}.orig" ]; then
    sudo mv "${ETCD_CONF}.orig" "$ETCD_CONF"
    echo "  ✓ etcd config restored from backup"
elif [ -f "$ETCD_CONF" ]; then
    sudo rm -f "$ETCD_CONF"
    echo "  ✓ etcd config removed"
fi

echo ""
echo "[5/5] Service status..."
for SVC in mariadb rabbitmq-server memcached etcd; do
    if systemctl is-active --quiet "$SVC"; then
        echo "  $SVC: running"
    else
        echo "  $SVC: stopped"
    fi
done

echo ""
echo "=== Cleanup complete ==="
echo ""
echo "To fully remove packages (optional):"
echo "  sudo apt-get purge mariadb-server rabbitmq-server memcached etcd-server"
echo "  sudo apt-get autoremove"
echo ""
echo "To re-run installation:"
echo "  ./12-openstack-base.sh"
