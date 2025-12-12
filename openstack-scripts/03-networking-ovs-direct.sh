#!/bin/bash
###############################################################################
# 03-networking-ovs-direct.sh
# Configure OVS bridge directly for OpenStack provider network (Debian Trixie)
#
# This script creates an OVS bridge from the start, avoiding the need for
# Linux bridge migration later. This is the recommended approach for Trixie
# which has native OVS 3.5.0 support.
#
# Network Architecture:
# - Physical NIC (eno1) → OVS bridge (br-provider) → Host IP
# - Same bridge will be used by Neutron for VM connectivity
#
# IMPORTANT: This will briefly disconnect your network!
###############################################################################
set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

echo "=== Step 3: OVS Bridge Configuration (Direct) ==="

# Configuration
PHYSICAL_NIC="eno1"
IP_ADDRESS="${CONTROLLER_IP}"
NETMASK="255.255.255.0"
GATEWAY="192.168.2.1"
BRIDGE_NAME="br-provider"

# ============================================================================
# PART 1: Install OVS
# ============================================================================
echo ""
echo "[1/5] Installing Open vSwitch..."

if command -v ovs-vsctl &>/dev/null; then
    echo "  ✓ OVS already installed"
    ovs-vsctl --version | head -1
else
    sudo apt install -y openvswitch-switch openvswitch-common
    echo "  ✓ OVS packages installed"
fi

# Enable and start OVS
sudo systemctl enable openvswitch-switch
sudo systemctl start openvswitch-switch

# Wait for OVS to be ready
echo "  Waiting for OVS to initialize..."
sleep 3

if ! sudo ovs-vsctl show &>/dev/null; then
    echo "  ✗ ERROR: OVS failed to start!"
    exit 1
fi
echo "  ✓ OVS service running"

# ============================================================================
# PART 2: Get current network configuration
# ============================================================================
echo ""
echo "[2/5] Detecting current network configuration..."

CURRENT_IP=$(ip -4 addr show ${PHYSICAL_NIC} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
CURRENT_GW=$(ip route | grep "^default" | awk '{print $3}' | head -1)

echo "  Current interface: ${PHYSICAL_NIC}"
echo "  Current IP: ${CURRENT_IP}"
echo "  Current gateway: ${CURRENT_GW}"
echo "  Target bridge: ${BRIDGE_NAME}"
echo "  Target IP: ${IP_ADDRESS}/${NETMASK}"

# ============================================================================
# PART 3: Create OVS bridge
# ============================================================================
echo ""
echo "[3/5] Creating OVS bridge..."
echo "  ⚠️  WARNING: Network will be briefly interrupted!"
read -p "  Press Enter to continue or Ctrl+C to cancel..."

# Create OVS bridge if it doesn't exist
if sudo ovs-vsctl br-exists ${BRIDGE_NAME} 2>/dev/null; then
    echo "  ✓ Bridge ${BRIDGE_NAME} already exists"
else
    sudo ovs-vsctl add-br ${BRIDGE_NAME}
    echo "  ✓ Bridge ${BRIDGE_NAME} created"
fi

# Add physical interface to bridge if not already added
if sudo ovs-vsctl list-ports ${BRIDGE_NAME} | grep -q "^${PHYSICAL_NIC}$"; then
    echo "  ✓ ${PHYSICAL_NIC} already attached to bridge"
else
    # Flush IP from physical interface
    sudo ip addr flush dev ${PHYSICAL_NIC}
    
    # Add to bridge
    sudo ovs-vsctl add-port ${BRIDGE_NAME} ${PHYSICAL_NIC}
    echo "  ✓ ${PHYSICAL_NIC} added to bridge"
fi

# ============================================================================
# PART 4: Configure IP on bridge
# ============================================================================
echo ""
echo "[4/5] Configuring IP on bridge..."

# Bring up interfaces
sudo ip link set ${PHYSICAL_NIC} up
sudo ip link set ${BRIDGE_NAME} up

# Add IP to bridge
sudo ip addr add ${IP_ADDRESS}/24 dev ${BRIDGE_NAME} 2>/dev/null || echo "  IP already configured"

# Add default route
sudo ip route add default via ${GATEWAY} dev ${BRIDGE_NAME} 2>/dev/null || echo "  Route already configured"

echo "  ✓ IP configuration applied"

# Test connectivity
sleep 2
if ping -c 2 ${GATEWAY} &>/dev/null; then
    echo "  ✓ Network connectivity verified"
else
    echo "  ⚠️  WARNING: Cannot ping gateway!"
fi

# ============================================================================
# PART 5: Make configuration persistent
# ============================================================================
echo ""
echo "[5/5] Making configuration persistent..."

# Backup existing interfaces file
sudo cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)

# Create new configuration
cat <<EOF | sudo tee /etc/network/interfaces
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# Physical interface - no IP, member of OVS bridge
auto ${PHYSICAL_NIC}
allow-ovs ${PHYSICAL_NIC}
iface ${PHYSICAL_NIC} inet manual
    ovs_bridge ${BRIDGE_NAME}
    ovs_type OVSPort

# OVS Provider Bridge - used by host and OpenStack
auto ${BRIDGE_NAME}
allow-ovs ${BRIDGE_NAME}
iface ${BRIDGE_NAME} inet static
    address ${IP_ADDRESS}
    netmask ${NETMASK}
    gateway ${GATEWAY}
    ovs_type OVSBridge
    ovs_ports ${PHYSICAL_NIC}
EOF

echo "  ✓ Network configuration saved"

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "=== Verification ==="
echo ""

# Check OVS service
if systemctl is-active --quiet openvswitch-switch; then
    echo "  ✓ OVS service is running"
else
    echo "  ✗ OVS service is NOT running!"
fi

# Check bridge exists
if sudo ovs-vsctl br-exists ${BRIDGE_NAME}; then
    echo "  ✓ Bridge ${BRIDGE_NAME} exists"
else
    echo "  ✗ Bridge ${BRIDGE_NAME} NOT found!"
fi

# Check physical interface attached
if sudo ovs-vsctl list-ports ${BRIDGE_NAME} | grep -q "^${PHYSICAL_NIC}$"; then
    echo "  ✓ ${PHYSICAL_NIC} attached to bridge"
else
    echo "  ✗ ${PHYSICAL_NIC} NOT attached!"
fi

# Check IP configured
if ip addr show ${BRIDGE_NAME} | grep -q "inet ${IP_ADDRESS}"; then
    echo "  ✓ IP ${IP_ADDRESS} configured on bridge"
else
    echo "  ✗ IP not configured on bridge!"
fi

# Show OVS configuration
echo ""
echo "OVS Configuration:"
sudo ovs-vsctl show

echo ""
echo "Network Configuration:"
ip addr show ${BRIDGE_NAME}

echo ""
echo "=== OVS bridge setup complete ==="
echo "Bridge: ${BRIDGE_NAME}"
echo "Physical port: ${PHYSICAL_NIC}"
echo "IP: ${IP_ADDRESS}/24"
echo "Gateway: ${GATEWAY}"
echo ""
echo "Next: Run 04-openstack-repos.sh"