#!/bin/bash
###############################################################################
# 25-ovs-install.sh
# Install Open vSwitch (OVS) and migrate Linux bridge to OVS bridge
# Idempotent - safe to run multiple times
#
# NOTE: This script installs OVS only (not OVN)
#       OVN packages are not available in Debian 11 Bullseye
#       Neutron will use ML2/OVS mechanism driver instead
#
# This script:
# - Installs openvswitch-switch and related packages
# - Migrates existing Linux bridge (br-provider) to OVS bridge
# - Preserves IP configuration during migration
# - Makes configuration persistent across reboots
#
# WARNING: Bridge migration will briefly disrupt network connectivity.
#          Run from console/IPMI if possible.
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Source shared environment
# =============================================================================
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

echo "=== Step 25: Open vSwitch Installation ==="
echo "Using Controller: ${CONTROLLER_IP}"

# =============================================================================
# Configuration
# =============================================================================
PROVIDER_BRIDGE="${PROVIDER_BRIDGE_NAME:-br-provider}"
PROVIDER_NETWORK="${PROVIDER_NETWORK_NAME:-physnet1}"

# Detect physical interface
detect_physical_interface() {
    # Check if br-provider is a Linux bridge with ports
    if [ -d "/sys/class/net/${PROVIDER_BRIDGE}/brif" ]; then
        PHYS_IF=$(ls /sys/class/net/${PROVIDER_BRIDGE}/brif/ 2>/dev/null | head -1)
        if [ -n "$PHYS_IF" ]; then
            echo "$PHYS_IF"
            return
        fi
    fi
    
    # Check if it's already an OVS bridge
    if command -v ovs-vsctl &>/dev/null; then
        PHYS_IF=$(sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} 2>/dev/null | grep -E "^(en|eth)" | head -1)
        if [ -n "$PHYS_IF" ]; then
            echo "$PHYS_IF"
            return
        fi
    fi
    
    # Find first UP physical interface
    PHYS_IF=$(ip -br link show | grep -E "^(en|eth)" | grep "UP" | awk '{print $1}' | head -1)
    if [ -n "$PHYS_IF" ]; then
        echo "$PHYS_IF"
        return
    fi
    
    # Last resort: first physical interface
    ip -br link show | grep -E "^(en|eth)" | awk '{print $1}' | head -1
}

PHYSICAL_INTERFACE=$(detect_physical_interface)

echo "Detected physical interface: ${PHYSICAL_INTERFACE:-NOT FOUND}"
echo "Provider bridge: ${PROVIDER_BRIDGE}"

# ============================================================================
# PART 0: Prerequisites Check
# ============================================================================
echo ""
echo "[0/6] Checking prerequisites..."

if [ -z "$PHYSICAL_INTERFACE" ]; then
    echo "  ✗ ERROR: No physical interface detected!"
    exit 1
fi
echo "  ✓ Physical interface: ${PHYSICAL_INTERFACE}"

if [ ! -d "/sys/class/net/${PHYSICAL_INTERFACE}" ]; then
    echo "  ✗ ERROR: Interface ${PHYSICAL_INTERFACE} does not exist!"
    exit 1
fi
echo "  ✓ Interface ${PHYSICAL_INTERFACE} exists"

# Get current IP configuration
CURRENT_IP=$(ip -4 addr show ${PROVIDER_BRIDGE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
if [ -z "$CURRENT_IP" ]; then
    CURRENT_IP=$(ip -4 addr show ${PHYSICAL_INTERFACE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
fi
CURRENT_GW=$(ip route | grep "^default" | awk '{print $3}' | head -1)

echo "  ✓ Current IP: ${CURRENT_IP:-NOT SET}"
echo "  ✓ Current Gateway: ${CURRENT_GW:-NOT SET}"

# Warning about network disruption
echo ""
echo "  ⚠️  WARNING: Bridge migration may briefly disrupt network!"
echo "  ⚠️  Ensure you have console/IPMI access if running remotely."
echo ""
read -p "  Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "  Cancelled."
    exit 0
fi

# ============================================================================
# PART 1: Install OVS
# ============================================================================
echo ""
echo "[1/6] Installing Open vSwitch..."

if command -v ovs-vsctl &>/dev/null; then
    echo "  ✓ OVS already installed"
    ovs-vsctl --version | head -1 | sed 's/^/    /'
else
    sudo apt-get update
    sudo apt-get install -y openvswitch-switch openvswitch-common
    echo "  ✓ OVS packages installed"
fi

# Ensure OVS service is running
sudo systemctl enable openvswitch-switch
sudo systemctl start openvswitch-switch

# Wait for OVS to be ready
MAX_RETRIES=10
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if sudo ovs-vsctl show &>/dev/null; then
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for OVS... (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 2
done

if ! sudo ovs-vsctl show &>/dev/null; then
    echo "  ✗ ERROR: OVS failed to start!"
    exit 1
fi
echo "  ✓ OVS service running"

# ============================================================================
# PART 2: Check if bridge migration is needed
# ============================================================================
echo ""
echo "[2/6] Checking bridge configuration..."

MIGRATION_NEEDED=false

if sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE} 2>/dev/null; then
    echo "  ✓ ${PROVIDER_BRIDGE} is already an OVS bridge"
    
    # Check if physical interface is attached
    if sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} | grep -q "^${PHYSICAL_INTERFACE}$"; then
        echo "  ✓ ${PHYSICAL_INTERFACE} is attached to ${PROVIDER_BRIDGE}"
    else
        echo "  Adding ${PHYSICAL_INTERFACE} to ${PROVIDER_BRIDGE}..."
        sudo ovs-vsctl add-port ${PROVIDER_BRIDGE} ${PHYSICAL_INTERFACE}
        echo "  ✓ ${PHYSICAL_INTERFACE} added"
    fi
    
elif [ -d "/sys/class/net/${PROVIDER_BRIDGE}/bridge" ]; then
    echo "  ! ${PROVIDER_BRIDGE} is a Linux bridge - migration needed"
    MIGRATION_NEEDED=true
    
elif [ -d "/sys/class/net/${PROVIDER_BRIDGE}" ]; then
    echo "  ! ${PROVIDER_BRIDGE} exists but type unknown - will recreate"
    MIGRATION_NEEDED=true
    
else
    echo "  ${PROVIDER_BRIDGE} does not exist - will create"
    MIGRATION_NEEDED=true
fi

# ============================================================================
# PART 3: Migrate Linux bridge to OVS bridge
# ============================================================================
echo ""
echo "[3/6] Bridge migration..."

if [ "$MIGRATION_NEEDED" = true ]; then
    echo "  Starting bridge migration..."
    echo "  ⚠️  Network may be briefly interrupted..."
    
    SAVED_IP="$CURRENT_IP"
    SAVED_GW="$CURRENT_GW"
    
    # Remove from Linux bridge if exists
    if [ -d "/sys/class/net/${PROVIDER_BRIDGE}/bridge" ]; then
        echo "  Removing ${PHYSICAL_INTERFACE} from Linux bridge..."
        sudo ip link set ${PHYSICAL_INTERFACE} nomaster 2>/dev/null || true
        
        echo "  Deleting Linux bridge ${PROVIDER_BRIDGE}..."
        sudo ip link set ${PROVIDER_BRIDGE} down 2>/dev/null || true
        sudo brctl delbr ${PROVIDER_BRIDGE} 2>/dev/null || \
            sudo ip link delete ${PROVIDER_BRIDGE} type bridge 2>/dev/null || true
    fi
    
    # Create OVS bridge
    echo "  Creating OVS bridge ${PROVIDER_BRIDGE}..."
    sudo ovs-vsctl --may-exist add-br ${PROVIDER_BRIDGE}
    
    # Add physical interface
    echo "  Adding ${PHYSICAL_INTERFACE} to OVS bridge..."
    sudo ovs-vsctl --may-exist add-port ${PROVIDER_BRIDGE} ${PHYSICAL_INTERFACE}
    
    # Bring up interfaces
    echo "  Bringing up interfaces..."
    sudo ip link set ${PHYSICAL_INTERFACE} up
    sudo ip link set ${PROVIDER_BRIDGE} up
    
    # Restore IP configuration
    if [ -n "$SAVED_IP" ]; then
        echo "  Restoring IP: ${SAVED_IP}..."
        sudo ip addr add ${SAVED_IP} dev ${PROVIDER_BRIDGE} 2>/dev/null || true
    fi
    
    if [ -n "$SAVED_GW" ]; then
        echo "  Restoring gateway: ${SAVED_GW}..."
        sudo ip route add default via ${SAVED_GW} dev ${PROVIDER_BRIDGE} 2>/dev/null || true
    fi
    
    echo "  ✓ Bridge migration complete"
    
    # Verify connectivity
    sleep 2
    if ping -c 1 -W 2 ${SAVED_GW:-8.8.8.8} &>/dev/null; then
        echo "  ✓ Network connectivity verified"
    else
        echo "  ⚠️  WARNING: Network connectivity check failed!"
    fi
else
    echo "  ✓ No migration needed"
fi

# ============================================================================
# PART 4: Configure bridge mapping for Neutron
# ============================================================================
echo ""
echo "[4/6] Configuring bridge mapping..."

# This will be used by neutron-openvswitch-agent
# The mapping tells Neutron which OVS bridge corresponds to which physical network
echo "  Bridge mapping: ${PROVIDER_NETWORK}:${PROVIDER_BRIDGE}"
echo "  (Will be configured in Neutron OVS agent)"
echo "  ✓ Bridge mapping noted"

# ============================================================================
# PART 5: Make configuration persistent
# ============================================================================
echo ""
echo "[5/6] Making configuration persistent..."

INTERFACES_FILE="/etc/network/interfaces.d/openstack-ovs-bridge"

if [ -f "$INTERFACES_FILE" ]; then
    sudo cp "$INTERFACES_FILE" "${INTERFACES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

# Calculate netmask from CIDR
IP_ADDR=$(echo "$CURRENT_IP" | cut -d'/' -f1)
CIDR=$(echo "$CURRENT_IP" | cut -d'/' -f2)

# Convert CIDR to netmask
cidr_to_netmask() {
    local cidr=$1
    local mask=""
    local full_octets=$((cidr / 8))
    local partial_octet=$((cidr % 8))
    
    for i in $(seq 1 4); do
        if [ $i -le $full_octets ]; then
            mask="${mask}255"
        elif [ $i -eq $((full_octets + 1)) ]; then
            mask="${mask}$((256 - 2**(8-partial_octet)))"
        else
            mask="${mask}0"
        fi
        [ $i -lt 4 ] && mask="${mask}."
    done
    echo $mask
}

IP_NETMASK=$(cidr_to_netmask ${CIDR:-24})

cat <<EOF | sudo tee ${INTERFACES_FILE} > /dev/null
# OpenStack OVS Provider Bridge Configuration
# Generated by 25-ovs-install.sh on $(date)
# DO NOT EDIT MANUALLY - rerun script to update

# Physical interface - no IP, OVS bridge port
auto ${PHYSICAL_INTERFACE}
iface ${PHYSICAL_INTERFACE} inet manual

# OVS Provider Bridge
auto ${PROVIDER_BRIDGE}
iface ${PROVIDER_BRIDGE} inet static
    address ${IP_ADDR}
    netmask ${IP_NETMASK}
    gateway ${CURRENT_GW}
    # OVS bridge setup
    pre-up /usr/bin/ovs-vsctl --may-exist add-br ${PROVIDER_BRIDGE}
    pre-up /usr/bin/ovs-vsctl --may-exist add-port ${PROVIDER_BRIDGE} ${PHYSICAL_INTERFACE}
    post-down /usr/bin/ovs-vsctl --if-exists del-br ${PROVIDER_BRIDGE}
EOF

echo "  ✓ Configuration saved to ${INTERFACES_FILE}"

# Ensure interfaces.d is sourced
if ! grep -q "source /etc/network/interfaces.d" /etc/network/interfaces 2>/dev/null; then
    echo "source /etc/network/interfaces.d/*" | sudo tee -a /etc/network/interfaces > /dev/null
    echo "  ✓ Added interfaces.d sourcing"
fi

# ============================================================================
# PART 6: Verification
# ============================================================================
echo ""
echo "[6/6] Verification..."

ERRORS=0

# Check OVS service
if systemctl is-active --quiet openvswitch-switch; then
    echo "  ✓ openvswitch-switch is running"
else
    echo "  ✗ openvswitch-switch is NOT running!"
    ERRORS=$((ERRORS + 1))
fi

# Check OVS bridge
if sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE}; then
    echo "  ✓ OVS bridge ${PROVIDER_BRIDGE} exists"
else
    echo "  ✗ OVS bridge ${PROVIDER_BRIDGE} NOT found!"
    ERRORS=$((ERRORS + 1))
fi

# Check physical interface attached
if sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} | grep -q "^${PHYSICAL_INTERFACE}$"; then
    echo "  ✓ ${PHYSICAL_INTERFACE} attached to ${PROVIDER_BRIDGE}"
else
    echo "  ✗ ${PHYSICAL_INTERFACE} NOT attached!"
    ERRORS=$((ERRORS + 1))
fi

# Check IP assigned
if ip addr show ${PROVIDER_BRIDGE} | grep -q "inet "; then
    echo "  ✓ IP address configured on ${PROVIDER_BRIDGE}"
else
    echo "  ✗ No IP on ${PROVIDER_BRIDGE}!"
    ERRORS=$((ERRORS + 1))
fi

# Check connectivity
if ping -c 1 -W 2 ${CURRENT_GW:-8.8.8.8} &>/dev/null; then
    echo "  ✓ Network connectivity OK"
else
    echo "  ✗ Network connectivity FAILED!"
    ERRORS=$((ERRORS + 1))
fi

# Show OVS configuration
echo ""
echo "OVS Configuration:"
sudo ovs-vsctl show

# Final summary
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== OVS installation complete ==="
    echo "=========================================="
    echo ""
    echo "Open vSwitch: $(ovs-vsctl --version | head -1)"
    echo ""
    echo "Bridge configuration:"
    echo "  - Provider bridge: ${PROVIDER_BRIDGE} (OVS)"
    echo "  - Physical interface: ${PHYSICAL_INTERFACE}"
    echo "  - Physical network: ${PROVIDER_NETWORK}"
    echo "  - IP: ${CURRENT_IP}"
    echo "  - Gateway: ${CURRENT_GW}"
    echo ""
    echo "Neutron bridge mapping: ${PROVIDER_NETWORK}:${PROVIDER_BRIDGE}"
    echo ""
    echo "NOTE: OVN is not available in Debian 11 Bullseye."
    echo "      Neutron will use ML2/OVS mechanism driver."
    echo ""
    echo "Next: Run 26-neutron-install.sh"
else
    echo "=== Installation completed with $ERRORS error(s) ==="
    echo "=========================================="
    exit 1
fi
