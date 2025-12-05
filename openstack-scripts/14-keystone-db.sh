#!/bin/bash
###############################################################################
# 14-keystone-db.sh
# Create Keystone database and user
###############################################################################
set -e

# Configuration - EDIT THESE
KEYSTONE_DB_PASS="pspl@#$6321P"  # Change this!

echo "=== Step 14: Keystone Database Setup ==="

echo "Enter MariaDB root password when prompted..."

sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${KEYSTONE_DB_PASS}';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${KEYSTONE_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo ""
echo "=== Keystone database created ==="
echo "Database: keystone"
echo "User: keystone"
echo "Password: ${KEYSTONE_DB_PASS}"
echo ""
echo "IMPORTANT: Save this password securely!"
echo "Next: Run 15-keystone-install.sh"
