#!/bin/bash
###############################################################################
# 25-ovs-ovn-cleanup.sh
# Remove OVS/OVN and restore Linux bridge (EMERGENCY ROLLBACK)
#
# WARNING: This will disrupt network connectivity!
# Only use if OVS/OVN installation failed and you need to restore
# the original Linux bridge configuration.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared environment
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
fi

PROVIDER_BRIDGE="br-provider"

# Auto-detect physical interface
detect_physical_interface() {
    # Check OVS bridge ports
    if command -v ovs-vsctl &>/dev/null; then
        PHYS_IF=$(sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} 2>/dev/null | grep -E "^(en|eth)" | head -1)
        if [ -n "$PHYS_IF" ]; then
            echo "$PHYS_IF"
            return
        fi
    fi
    
    # Check Linux bridge
    if [ -d "/sys/class/net/${PROVIDER_BRIDGE}/brif" ]; then
        ls /sys/class/net/${PROVIDER_BRIDGE}/brif/ 2>/dev/null | head -1
        return
    fi
    
    # Fallback to first physical interface
    ip -br link show | grep -E "^(en|eth)" | awk '{print $1}' | head -1
}

PHYSICAL_INTERFACE=$(detect_physical_interface)

echo "=== OVS/OVN Cleanup and Rollback ==="
echo ""
echo "This will:"
echo "  - Stop and remove OVN services"
echo "  - Stop and remove OVS"
echo "  - Restore Linux bridge configuration"
echo ""
echo "Detected:"
echo "  - Physical interface: ${PHYSICAL_INTERFACE:-UNKNOWN}"
echo "  - Provider bridge: ${PROVIDER_BRIDGE}"
echo ""
echo "⚠️  WARNING: This WILL disrupt network connectivity!"
echo "⚠️  Make sure you have console/IPMI access!"
echo ""
read -p "Are you SURE you want to continue? (yes/NO): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# Get current IP config before we break things
CURRENT_IP=$(ip -4 addr show ${PROVIDER_BRIDGE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
CURRENT_GW=$(ip route | grep "^default" | awk '{print $3}' | head -1)

echo ""
echo "[1/5] Stopping OVN services..."
for SVC in ovn-host ovn-central; do
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        sudo systemctl stop "$SVC"
        sudo systemctl disable "$SVC" 2>/dev/null || true
        echo "  ✓ Stopped $SVC"
    fi
done

echo ""
echo "[2/5] Saving IP configuration from OVS bridge..."
if [ -n "$CURRENT_IP" ]; then
    echo "  IP: $CURRENT_IP"
    echo "  GW: $CURRENT_GW"
fi

echo ""
echo "[3/5] Removing OVS bridge..."
if command -v ovs-vsctl &>/dev/null && sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE} 2>/dev/null; then
    # Remove ports first
    for PORT in $(sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} 2>/dev/null); do
        sudo ovs-vsctl del-port ${PROVIDER_BRIDGE} "$PORT" 2>/dev/null || true
        echo "  ✓ Removed port $PORT"
    done
    
    # Delete bridge
    sudo ovs-vsctl del-br ${PROVIDER_BRIDGE} 2>/dev/null || true
    echo "  ✓ Deleted OVS bridge ${PROVIDER_BRIDGE}"
fi

echo ""
echo "[4/5] Stopping OVS service..."
if systemctl is-active --quiet openvswitch-switch 2>/dev/null; then
    sudo systemctl stop openvswitch-switch
    echo "  ✓ Stopped openvswitch-switch"
fi

echo ""
echo "[5/5] Restoring Linux bridge..."
if [ -n "$PHYSICAL_INTERFACE" ]; then
    # Create Linux bridge
    sudo ip link add name ${PROVIDER_BRIDGE} type bridge 2>/dev/null || true
    sudo ip link set ${PROVIDER_BRIDGE} up
    
    # Add physical interface
    sudo ip link set ${PHYSICAL_INTERFACE} up
    sudo ip link set ${PHYSICAL_INTERFACE} master ${PROVIDER_BRIDGE}
    
    # Restore IP
    if [ -n "$CURRENT_IP" ]; then
        sudo ip addr add ${CURRENT_IP} dev ${PROVIDER_BRIDGE} 2>/dev/null || true
    fi
    
    if [ -n "$CURRENT_GW" ]; then
        sudo ip route add default via ${CURRENT_GW} dev ${PROVIDER_BRIDGE} 2>/dev/null || true
    fi
    
    echo "  ✓ Linux bridge ${PROVIDER_BRIDGE} restored"
fi

# Remove OVS network config
if [ -f /etc/network/interfaces.d/openstack-bridge ]; then
    sudo rm /etc/network/interfaces.d/openstack-bridge
    echo "  ✓ Removed OVS network configuration"
fi

# Test connectivity
echo ""
echo "Testing network connectivity..."
sleep 2
if ping -c 1 -W 3 ${CURRENT_GW:-8.8.8.8} &>/dev/null; then
    echo "  ✓ Network connectivity restored"
else
    echo "  ✗ Network connectivity FAILED!"
    echo ""
    echo "  Manual recovery commands:"
    echo "    sudo ip link add ${PROVIDER_BRIDGE} type bridge"
    echo "    sudo ip link set ${PHYSICAL_INTERFACE} master ${PROVIDER_BRIDGE}"
    echo "    sudo ip link set ${PROVIDER_BRIDGE} up"
    echo "    sudo ip addr add ${CURRENT_IP} dev ${PROVIDER_BRIDGE}"
    echo "    sudo ip route add default via ${CURRENT_GW}"
fi

echo ""
echo "=== Cleanup complete ==="
echo ""
echo "OVS/OVN packages are still installed but services are stopped."
echo "To completely remove packages:"
echo "  sudo apt remove --purge ovn-central ovn-host openvswitch-switch"
echo "  sudo apt autoremove"
