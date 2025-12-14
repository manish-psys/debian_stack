#!/bin/bash
###############################################################################
# 16-keystone-openrc.sh
# Create OpenStack admin credentials file
# Sources openstack-env.sh for centralized configuration
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 16: Create Admin Credentials File ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"
echo ""

echo "[1/2] Creating admin-openrc..."
cat <<EOF > ~/admin-openrc
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_AUTH_URL=${KEYSTONE_AUTH_URL_V3}
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

chmod 600 ~/admin-openrc
echo "  ✓ admin-openrc created"

echo "[2/2] Testing Keystone authentication..."
source ~/admin-openrc

if openstack token issue; then
    echo ""
    echo "  ✓ Authentication successful"
else
    echo ""
    echo "  ✗ Authentication failed!"
    echo "  Check password matches between scripts 15 and 16"
    exit 1
fi

echo ""
echo "=== Admin credentials created ==="
echo "File: ~/admin-openrc"
echo ""
echo "To use OpenStack CLI, run: source ~/admin-openrc"
echo ""
echo "Quick test commands:"
echo "  openstack user list"
echo "  openstack project list"
echo "  openstack service list"
echo ""
echo "Next: Run 17-glance-db.sh"
