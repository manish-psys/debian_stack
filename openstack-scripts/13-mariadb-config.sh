#!/bin/bash
###############################################################################
# 13-mariadb-config.sh
# Configure MariaDB for OpenStack (Idempotent - safe to re-run)
#
# This script:
# - Creates OpenStack-optimized MariaDB configuration
# - Secures MariaDB non-interactively (reproducible)
# - Verifies MariaDB is ready for OpenStack databases
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 13: MariaDB Configuration ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"
echo ""

# ============================================================================
# PART 1: Create OpenStack-optimized MariaDB configuration
# ============================================================================
echo "[1/4] Creating OpenStack MariaDB config..."

# Note: bind-address should be controller IP for potential multi-node setup
# For all-in-one, services can connect via localhost or controller IP
cat <<EOF | sudo tee /etc/mysql/mariadb.conf.d/99-openstack.cnf
[mysqld]
# Bind to controller IP (allows future multi-node expansion)
# Services on same host can still use localhost or 192.168.2.9
bind-address = ${CONTROLLER_IP}

# Performance and charset settings for OpenStack
default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8

# Additional performance tuning
innodb_buffer_pool_size = 16G
innodb_log_file_size = 512M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
EOF

echo "  ✓ MariaDB config created: /etc/mysql/mariadb.conf.d/99-openstack.cnf"

# ============================================================================
# PART 2: Restart MariaDB to apply configuration
# ============================================================================
echo "[2/4] Restarting MariaDB with new configuration..."
sudo systemctl restart mariadb
sudo systemctl enable mariadb

# Wait for MariaDB to be ready
sleep 3

if systemctl is-active --quiet mariadb; then
    echo "  ✓ MariaDB restarted successfully"
else
    echo "  ✗ ERROR: MariaDB failed to start!"
    echo "  Check logs: sudo journalctl -u mariadb -n 50"
    exit 1
fi

# ============================================================================
# PART 3: Secure MariaDB installation (non-interactive)
# ============================================================================
echo "[3/4] Securing MariaDB installation..."

# Debian MariaDB uses unix_socket authentication for root by default
# This is MORE secure than password auth - root can only login via sudo
# We keep this and just clean up the other security items

# Remove anonymous users
sudo mysql -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true

# Disallow remote root login (only allow via unix socket)
sudo mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true

# Remove test database
sudo mysql -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
sudo mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true

# Flush privileges
sudo mysql -e "FLUSH PRIVILEGES;"

echo "  ✓ MariaDB secured (unix_socket auth for root)"
echo "  ✓ Anonymous users removed"
echo "  ✓ Remote root login disabled"
echo "  ✓ Test database removed"

# ============================================================================
# PART 4: Verify MariaDB is ready
# ============================================================================
echo "[4/4] Verifying MariaDB configuration..."

ERRORS=0

# Check MariaDB is running
if systemctl is-active --quiet mariadb; then
    echo "  ✓ MariaDB service is running"
else
    echo "  ✗ MariaDB is not running!"
    ERRORS=$((ERRORS + 1))
fi

# Check MariaDB is listening on correct IP:port
if sudo ss -tlnp | grep -q "${CONTROLLER_IP}:3306"; then
    echo "  ✓ MariaDB listening on ${CONTROLLER_IP}:3306"
else
    echo "  ✗ MariaDB not listening on ${CONTROLLER_IP}:3306!"
    ERRORS=$((ERRORS + 1))
fi

# Test connection
if sudo mysql -e "SELECT 1;" &>/dev/null; then
    echo "  ✓ MariaDB accepts connections"
else
    echo "  ✗ MariaDB connection test failed!"
    ERRORS=$((ERRORS + 1))
fi

# Check configuration file
if sudo grep -q "bind-address = ${CONTROLLER_IP}" /etc/mysql/mariadb.conf.d/99-openstack.cnf; then
    echo "  ✓ Configuration file correct"
else
    echo "  ✗ Configuration file has wrong bind-address!"
    ERRORS=$((ERRORS + 1))
fi

# Verify InnoDB settings
INNODB_POOL=$(sudo mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" -s -N | awk '{print $2}')
if [ -n "$INNODB_POOL" ]; then
    echo "  ✓ InnoDB buffer pool: $((INNODB_POOL / 1024 / 1024 / 1024))GB"
else
    echo "  ⚠ Could not verify InnoDB settings"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=========================================="
    echo "=== ✓ MariaDB configured successfully ==="
    echo "=========================================="
    echo ""
    echo "MariaDB Configuration:"
    echo "  Bind Address: ${CONTROLLER_IP}:3306"
    echo "  Root Auth: unix_socket (use 'sudo mysql')"
    echo "  Max Connections: 4096"
    echo "  Storage Engine: InnoDB"
    echo "  Character Set: utf8"
    echo ""
    echo "Next: Run 14-keystone-db.sh"
else
    echo "=== MariaDB configuration completed with $ERRORS error(s) ==="
    exit 1
fi
