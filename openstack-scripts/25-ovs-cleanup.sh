#!/bin/bash
###############################################################################
# 25-ovs-cleanup.sh
# Remove OVS bridge and restore Linux bridge (EMERGENCY ROLLBACK)
#
# WARNING: This will disrupt network connectivity!
# Only use if OVS installation failed and you need to restore
# the original Linux bridge configuration.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
fi

PROVIDER_BRIDGE="${PROVIDER_BRIDGE_NAME:-br-provider}"

# Auto-detect physical interface
detect_physical_interface() {
    if command -v ovs-vsctl &>/dev/null; then
        PHYS_IF=$(sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} 2>/dev/null | grep -E "^(en|eth)" | head -1)
        if [ -n "$PHYS_IF" ]; then
            echo "$PHYS_IF"
            return
        fi
    fi
    
    if [ -d "/sys/class/net/${PROVIDER_BRIDGE}/brif" ]; then
        ls /sys/class/net/${PROVIDER_BRIDGE}/brif/ 2>/dev/null | head -1
        return
    fi
    
    ip -br link show | grep -E "^(en|eth)" | awk '{print $1}' | head -1
}

PHYSICAL_INTERFACE=$(detect_physical_interface)

echo "=== OVS Cleanup and Rollback ==="
echo ""
echo "This will:"
echo "  - Remove OVS bridge configuration"
echo "  - Restore Linux bridge"
echo ""
echo "Detected:"
echo "  - Physical interface: ${PHYSICAL_INTERFACE:-UNKNOWN}"
echo "  - Provider bridge: ${PROVIDER_BRIDGE}"
echo ""
echo "⚠️  WARNING: This WILL disrupt network connectivity!"
echo ""
read -p "Are you SURE? (yes/NO): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# Get current IP before changes
CURRENT_IP=$(ip -4 addr show ${PROVIDER_BRIDGE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
CURRENT_GW=$(ip route | grep "^default" | awk '{print $3}' | head -1)

echo ""
echo "[1/3] Saving IP configuration..."
echo "  IP: ${CURRENT_IP:-none}"
echo "  GW: ${CURRENT_GW:-none}"

echo ""
echo "[2/3] Removing OVS bridge..."
if command -v ovs-vsctl &>/dev/null && sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE} 2>/dev/null; then
    for PORT in $(sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} 2>/dev/null); do
        sudo ovs-vsctl del-port ${PROVIDER_BRIDGE} "$PORT" 2>/dev/null || true
        echo "  ✓ Removed port $PORT"
    done
    
    sudo ovs-vsctl del-br ${PROVIDER_BRIDGE} 2>/dev/null || true
    echo "  ✓ Deleted OVS bridge"
fi

echo ""
echo "[3/3] Restoring Linux bridge..."
if [ -n "$PHYSICAL_INTERFACE" ]; then
    sudo ip link add name ${PROVIDER_BRIDGE} type bridge 2>/dev/null || true
    sudo ip link set ${PROVIDER_BRIDGE} up
    sudo ip link set ${PHYSICAL_INTERFACE} up
    sudo ip link set ${PHYSICAL_INTERFACE} master ${PROVIDER_BRIDGE}
    
    if [ -n "$CURRENT_IP" ]; then
        sudo ip addr add ${CURRENT_IP} dev ${PROVIDER_BRIDGE} 2>/dev/null || true
    fi
    
    if [ -n "$CURRENT_GW" ]; then
        sudo ip route add default via ${CURRENT_GW} dev ${PROVIDER_BRIDGE} 2>/dev/null || true
    fi
    
    echo "  ✓ Linux bridge restored"
fi

# Remove OVS network config
if [ -f /etc/network/interfaces.d/openstack-ovs-bridge ]; then
    sudo rm /etc/network/interfaces.d/openstack-ovs-bridge
    echo "  ✓ Removed OVS network config"
fi

# Test connectivity
sleep 2
if ping -c 1 -W 3 ${CURRENT_GW:-8.8.8.8} &>/dev/null; then
    echo "  ✓ Network connectivity restored"
else
    echo "  ✗ Network check failed - manual recovery may be needed"
fi

echo ""
echo "=== Cleanup complete ==="
echo "OVS packages still installed but bridge removed."
