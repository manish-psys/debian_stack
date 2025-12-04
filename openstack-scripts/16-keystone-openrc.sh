#!/bin/bash
###############################################################################
# 16-keystone-openrc.sh
# Create OpenStack admin credentials file
###############################################################################
set -e

# Configuration - EDIT THESE
ADMIN_PASS="adminpass"    # Must match 15-keystone-install.sh
IP_ADDRESS="192.168.2.9"

echo "=== Step 16: Create Admin Credentials File ==="

echo "[1/2] Creating admin-openrc..."
cat <<EOF > ~/admin-openrc
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_AUTH_URL=http://${IP_ADDRESS}:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

chmod 600 ~/admin-openrc

echo "[2/2] Testing Keystone..."
source ~/admin-openrc
openstack token issue

echo ""
echo "=== Admin credentials created ==="
echo "File: ~/admin-openrc"
echo ""
echo "To use OpenStack CLI, run: source ~/admin-openrc"
echo "Next: Run 17-glance-db.sh"
