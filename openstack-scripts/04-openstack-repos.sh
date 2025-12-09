#!/bin/bash
###############################################################################
# 04-openstack-repos.sh
# Configure OpenStack repositories for Debian 13 (Trixie)
#
# Debian Trixie includes native OpenStack packages in the main repository:
# - Keystone 27.0.0 (Caracal)
# - Nova 31.0.0 (Dalmatian)
# - Neutron 26.0.0 (Caracal)
# - Ceph 18.2.7 (Reef LTS)
# - OVS 3.5.0 / OVN 25.03.0
#
# No additional repositories are needed for Trixie!
###############################################################################
set -e

echo "=== Step 4: OpenStack Repository Configuration ==="

echo "[1/3] Verifying Debian Trixie repositories..."
if ! grep -q "trixie" /etc/apt/sources.list; then
    echo "  ✗ ERROR: Trixie repositories not found in /etc/apt/sources.list"
    exit 1
fi
echo "  ✓ Trixie main repository configured"

echo "[2/3] Ensuring contrib and non-free components are enabled..."
# Check if contrib and non-free are already present
if ! grep -q "contrib" /etc/apt/sources.list; then
    echo "  Adding contrib and non-free components..."
    sudo sed -i 's/main non-free-firmware/main contrib non-free non-free-firmware/g' /etc/apt/sources.list
    echo "  ✓ Added contrib and non-free components"
else
    echo "  ✓ contrib and non-free already enabled"
fi

echo "[3/3] Updating package lists..."
sudo apt update

echo ""
echo "=== Verification: Available OpenStack Packages ==="
echo "Keystone: $(apt-cache policy keystone | grep Candidate | awk '{print $2}')"
echo "Nova: $(apt-cache policy nova-compute | grep Candidate | awk '{print $2}')"
echo "Neutron: $(apt-cache policy neutron-server | grep Candidate | awk '{print $2}')"
echo "Glance: $(apt-cache policy glance | grep Candidate | awk '{print $2}')"
echo "Cinder: $(apt-cache policy cinder-volume | grep Candidate | awk '{print $2}')"
echo "Ceph: $(apt-cache policy ceph | grep Candidate | awk '{print $2}')"
echo "OVS: $(apt-cache policy openvswitch-switch | grep Candidate | awk '{print $2}')"
echo "OVN: $(apt-cache policy ovn-central | grep Candidate | awk '{print $2}')"

echo ""
echo "=== OpenStack repository setup complete ==="
echo "Note: Debian Trixie includes native OpenStack packages - no backports needed!"
echo "Next: Run 05-ceph-install.sh"
