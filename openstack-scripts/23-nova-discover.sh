#!/bin/bash
###############################################################################
# 23-nova-discover.sh
# Discover compute hosts and verify Nova
###############################################################################
set -e

echo "=== Step 23: Nova Compute Discovery ==="

echo "[1/2] Discovering compute hosts..."
sudo -u nova nova-manage cell_v2 discover_hosts --verbose

echo "[2/2] Verifying Nova services..."
source ~/admin-openrc

echo ""
echo "Compute services:"
openstack compute service list

echo ""
echo "Hypervisor list:"
openstack hypervisor list

echo ""
echo "=== Nova compute discovery complete ==="
echo "Next: Run 24-neutron-db.sh"
