#!/bin/bash
###############################################################################
# 14-keystone-db.sh
# Create Keystone database and user (Idempotent - safe to re-run)
###############################################################################
set -e

# Configuration
KEYSTONE_DB_PASS="keystonepass123"

echo "=== Step 14: Keystone Database Setup ==="
echo "Enter MariaDB root password when prompted..."

sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${KEYSTONE_DB_PASS}';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${KEYSTONE_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo ""
echo "=== Keystone database created/updated ==="
echo "Database: keystone"
echo "User: keystone"
echo "Password: ${KEYSTONE_DB_PASS}"
echo ""
echo "Next: Run 15-keystone-cleanup.sh (if needed), then 15-keystone-install.sh"
