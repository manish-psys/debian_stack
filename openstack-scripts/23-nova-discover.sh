#!/bin/bash
###############################################################################
# 23-nova-discover.sh
# Discover compute hosts and verify Nova
# Idempotent - safe to run multiple times
###############################################################################
set -e

# Source shared environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 23: Nova Compute Discovery ==="
echo "Controller: ${CONTROLLER_HOSTNAME} (${CONTROLLER_IP})"
echo ""

echo "[1/2] Discovering compute hosts..."
sudo nova-manage cell_v2 discover_hosts --verbose

echo "[2/2] Verifying Nova services..."
source ~/admin-openrc

echo ""
echo "Compute services:"
/usr/bin/openstack compute service list

echo ""
echo "Hypervisor list:"
/usr/bin/openstack hypervisor list

echo ""
echo "Resource Providers (from Placement):"
/usr/bin/openstack --os-placement-api-version 1.2 resource provider list -f table 2>/dev/null || echo "  (none yet)"

echo ""
echo "=== Nova compute discovery complete ==="
echo "Next: Run 24-neutron-db.sh"
