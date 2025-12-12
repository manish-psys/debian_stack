#!/bin/bash
###############################################################################
# 03-networking-bridge.sh
# Configure Linux bridge for OpenStack provider network
#
# This creates br-provider bridge that will be used by:
# - Host system for network connectivity
# - OpenStack Neutron for provider network (direct VM connectivity)
#
# IMPORTANT: This will briefly disconnect your network!
###############################################################################
set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

# Configuration
PHYSICAL_NIC="eno1"        # Your actual NIC name
IP_ADDRESS="${CONTROLLER_IP}"
NETMASK="255.255.255.0"
GATEWAY="192.168.2.1"      # Adjust if your gateway is different

echo "=== Step 3: Network Bridge Configuration ==="

echo "[1/6] Installing bridge-utils if needed..."
if ! command -v brctl &>/dev/null; then
    echo "  Installing bridge-utils..."
    sudo apt install -y bridge-utils
else
    echo "  ✓ bridge-utils already installed"
fi

echo "[2/6] Removing any existing br-provider bridge..."
sudo ip link set br-provider down 2>/dev/null || true
sudo brctl delbr br-provider 2>/dev/null || true

echo "[3/6] Backing up current network config..."
sudo cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)

echo "[4/6] Writing new network configuration..."
cat <<EOF | sudo tee /etc/network/interfaces
auto lo
iface lo inet loopback

# Physical NIC - no IP here
auto ${PHYSICAL_NIC}
iface ${PHYSICAL_NIC} inet manual

# Bridge used by host AND by OpenStack (provider network)
auto br-provider
iface br-provider inet static
    address ${IP_ADDRESS}
    netmask ${NETMASK}
    gateway ${GATEWAY}
    bridge_ports ${PHYSICAL_NIC}
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
EOF

echo "[5/6] Applying network configuration..."
echo "WARNING: This may briefly disconnect your network!"
echo "Current config: eno1 with DHCP (192.168.2.9)"
echo "New config: br-provider with static IP (192.168.2.9)"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

# Bring down existing interface and flush IP
sudo ip addr flush dev ${PHYSICAL_NIC} 2>/dev/null || true
sudo ifdown ${PHYSICAL_NIC} 2>/dev/null || true

# Bring up the bridge
sudo ifup br-provider

echo "[6/6] Verifying network..."
echo ""
echo "Bridge status:"
ip a show br-provider
echo ""
echo "Bridge ports:"
brctl show br-provider
echo ""
echo "Routes:"
ip r
echo ""
echo "Testing connectivity..."
ping -c2 8.8.8.8 || echo "WARNING: Internet connectivity test failed!"

echo ""
echo "=== Network bridge setup complete ==="
echo "Next: Run 04-openstack-repos.sh"
