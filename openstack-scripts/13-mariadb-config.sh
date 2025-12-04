#!/bin/bash
###############################################################################
# 13-mariadb-config.sh
# Configure MariaDB for OpenStack
###############################################################################
set -e

echo "=== Step 13: MariaDB Configuration ==="

echo "[1/3] Creating OpenStack MariaDB config..."
cat <<'EOF' | sudo tee /etc/mysql/mariadb.conf.d/99-openstack.cnf
[mysqld]
bind-address = 127.0.0.1

default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF

echo "[2/3] Restarting MariaDB..."
sudo systemctl restart mariadb

echo "[3/3] Running mysql_secure_installation..."
echo ""
echo "Follow the prompts to secure MariaDB:"
echo "  - Set root password"
echo "  - Remove anonymous users"
echo "  - Disallow root login remotely"
echo "  - Remove test database"
echo "  - Reload privilege tables"
echo ""
sudo mysql_secure_installation

echo ""
echo "=== MariaDB configured ==="
echo "Next: Run 14-keystone-db.sh"
