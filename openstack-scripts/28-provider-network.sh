#!/bin/bash
###############################################################################
# 28-provider-network.sh
# Create provider flat network for external VM connectivity
# Uses existing LAN infrastructure (DHCP from LAN router or static IPs)
###############################################################################

# Exit on undefined variables only - we handle errors manually
set -u

# =============================================================================
# CONFIGURATION - Edit these for your network
# =============================================================================
# Provider network settings (your LAN)
PROVIDER_SUBNET_RANGE="192.168.2.0/24"
PROVIDER_GATEWAY="192.168.2.1"
PROVIDER_DNS="8.8.8.8"

# Allocation pool for OpenStack to assign to VMs
# IMPORTANT: This range must NOT overlap with:
#   - Your LAN DHCP range
#   - Any static IPs on your LAN
#   - Controller IP (192.168.2.9)
ALLOCATION_POOL_START="192.168.2.100"
ALLOCATION_POOL_END="192.168.2.199"

# Network names
PROVIDER_NET_NAME="provider-net"
PROVIDER_SUBNET_NAME="provider-subnet"

# Use OpenStack DHCP or rely on external LAN DHCP?
# true  = OpenStack DHCP agent provides IPs from allocation pool (RECOMMENDED)
# false = VMs must use static IPs or external DHCP
USE_OPENSTACK_DHCP="true"

# =============================================================================
# LOAD ENVIRONMENT
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/openstack-env.sh"

if [ ! -f "$ENV_FILE" ]; then
    # Try parent directory
    ENV_FILE="${SCRIPT_DIR}/../openstack-env.sh"
fi

if [ ! -f "$ENV_FILE" ]; then
    # Try home directory
    ENV_FILE=~/openstack-env.sh
fi

if [ ! -f "$ENV_FILE" ]; then
    # Try outputs directory
    ENV_FILE=/mnt/user-data/outputs/openstack-env.sh
fi

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "WARNING: openstack-env.sh not found, using defaults"
    export PROVIDER_NETWORK_NAME="physnet1"
    export PROVIDER_BRIDGE_NAME="br-provider"
    export CONTROLLER_IP="192.168.2.9"
fi

# Source admin credentials
if [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
else
    echo "ERROR: ~/admin-openrc not found!"
    echo "Run the Keystone setup scripts first."
    exit 1
fi

echo "=== Step 28: Provider Network Creation ==="
echo "Using physical network: ${PROVIDER_NETWORK_NAME}"
echo "Using OVS bridge: ${PROVIDER_BRIDGE_NAME}"
echo ""

# Error counter
ERRORS=0

# =============================================================================
# PART 1: Prerequisites Check
# =============================================================================
echo "[1/4] Checking prerequisites..."

# Check Neutron API is responding
if ! openstack network agent list &>/dev/null; then
    echo "  ✗ ERROR: Neutron API not responding!"
    echo "  Run 27-neutron-sync.sh first."
    exit 1
fi
echo "  ✓ Neutron API responding"

# Check OVS agent is running
if ! openstack network agent list -f value -c Binary | grep -q "neutron-openvswitch-agent"; then
    echo "  ✗ ERROR: OVS agent not registered!"
    exit 1
fi
echo "  ✓ OVS agent registered"

# Check DHCP agent is running (if we're using OpenStack DHCP)
if [ "$USE_OPENSTACK_DHCP" = "true" ]; then
    if ! openstack network agent list -f value -c Binary | grep -q "neutron-dhcp-agent"; then
        echo "  ✗ ERROR: DHCP agent not registered!"
        exit 1
    fi
    echo "  ✓ DHCP agent registered"
fi

# Check OVS bridge exists
if ! sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE_NAME}; then
    echo "  ✗ ERROR: OVS bridge ${PROVIDER_BRIDGE_NAME} not found!"
    echo "  Run 25-ovs-install.sh first."
    exit 1
fi
echo "  ✓ OVS bridge ${PROVIDER_BRIDGE_NAME} exists"

# Check bridge mapping in OVS agent config
if ! sudo grep -q "bridge_mappings.*${PROVIDER_NETWORK_NAME}:${PROVIDER_BRIDGE_NAME}" \
    /etc/neutron/plugins/ml2/openvswitch_agent.ini 2>/dev/null; then
    echo "  ⚠ WARNING: Bridge mapping may not be configured correctly"
    echo "    Expected: ${PROVIDER_NETWORK_NAME}:${PROVIDER_BRIDGE_NAME}"
fi
echo "  ✓ Prerequisites OK"

# =============================================================================
# PART 2: Create Provider Network
# =============================================================================
echo ""
echo "[2/4] Creating provider network..."

# Check if network already exists
if openstack network show "${PROVIDER_NET_NAME}" &>/dev/null; then
    echo "  ✓ Provider network '${PROVIDER_NET_NAME}' already exists"
else
    echo "  Creating network '${PROVIDER_NET_NAME}'..."
    if openstack network create \
        --external \
        --share \
        --provider-physical-network "${PROVIDER_NETWORK_NAME}" \
        --provider-network-type flat \
        "${PROVIDER_NET_NAME}"; then
        echo "  ✓ Provider network created"
    else
        echo "  ✗ ERROR: Failed to create provider network!"
        ((ERRORS++))
    fi
fi

# Verify network was created with correct settings
echo ""
echo "  Network details:"
openstack network show "${PROVIDER_NET_NAME}" -f table -c name -c id -c status \
    -c provider:network_type -c provider:physical_network -c router:external 2>/dev/null || true

# =============================================================================
# PART 3: Create Provider Subnet
# =============================================================================
echo ""
echo "[3/4] Creating provider subnet..."

# Check if subnet already exists
if openstack subnet show "${PROVIDER_SUBNET_NAME}" &>/dev/null; then
    echo "  ✓ Provider subnet '${PROVIDER_SUBNET_NAME}' already exists"
else
    echo "  Creating subnet '${PROVIDER_SUBNET_NAME}'..."
    
    # Build subnet create command
    SUBNET_CMD="openstack subnet create"
    SUBNET_CMD+=" --network ${PROVIDER_NET_NAME}"
    SUBNET_CMD+=" --subnet-range ${PROVIDER_SUBNET_RANGE}"
    SUBNET_CMD+=" --gateway ${PROVIDER_GATEWAY}"
    SUBNET_CMD+=" --dns-nameserver ${PROVIDER_DNS}"
    
    if [ "$USE_OPENSTACK_DHCP" = "true" ]; then
        SUBNET_CMD+=" --dhcp"
        SUBNET_CMD+=" --allocation-pool start=${ALLOCATION_POOL_START},end=${ALLOCATION_POOL_END}"
        echo "  Using OpenStack DHCP with pool: ${ALLOCATION_POOL_START} - ${ALLOCATION_POOL_END}"
    else
        SUBNET_CMD+=" --no-dhcp"
        echo "  DHCP disabled - VMs will need static IPs or external DHCP"
    fi
    
    SUBNET_CMD+=" ${PROVIDER_SUBNET_NAME}"
    
    if eval $SUBNET_CMD; then
        echo "  ✓ Provider subnet created"
    else
        echo "  ✗ ERROR: Failed to create provider subnet!"
        ((ERRORS++))
    fi
fi

# Verify subnet was created
echo ""
echo "  Subnet details:"
openstack subnet show "${PROVIDER_SUBNET_NAME}" -f table -c name -c id -c cidr \
    -c gateway_ip -c enable_dhcp -c allocation_pools -c dns_nameservers 2>/dev/null || true

# =============================================================================
# PART 4: Verification
# =============================================================================
echo ""
echo "[4/4] Verifying provider network..."

# List networks
echo ""
echo "Networks:"
openstack network list

# List subnets
echo ""
echo "Subnets:"
openstack subnet list

# Check DHCP agent scheduling (if using OpenStack DHCP)
if [ "$USE_OPENSTACK_DHCP" = "true" ]; then
    echo ""
    echo "DHCP Agent hosting this network:"
    openstack network agent list --network "${PROVIDER_NET_NAME}" 2>/dev/null || \
        echo "  (DHCP agent will be scheduled when first port is created)"
fi

# Verify network is external
EXTERNAL=$(openstack network show "${PROVIDER_NET_NAME}" -f value -c router:external 2>/dev/null || echo "unknown")
if [ "$EXTERNAL" = "True" ]; then
    echo ""
    echo "  ✓ Network is marked as external (can be used as floating IP pool)"
else
    echo ""
    echo "  ⚠ Network may not be marked as external"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Provider Network Created Successfully ==="
else
    echo "=== Provider Network Creation Had Errors ==="
fi
echo "=========================================="
echo ""
echo "Network: ${PROVIDER_NET_NAME}"
echo "Subnet:  ${PROVIDER_SUBNET_NAME}"
echo "Range:   ${PROVIDER_SUBNET_RANGE}"
echo "Gateway: ${PROVIDER_GATEWAY}"
echo "DNS:     ${PROVIDER_DNS}"
if [ "$USE_OPENSTACK_DHCP" = "true" ]; then
    echo "DHCP:    Enabled (OpenStack)"
    echo "Pool:    ${ALLOCATION_POOL_START} - ${ALLOCATION_POOL_END}"
else
    echo "DHCP:    Disabled (use static or external DHCP)"
fi
echo ""
echo "Physical mapping: ${PROVIDER_NETWORK_NAME} → ${PROVIDER_BRIDGE_NAME}"
echo ""
echo "Quick test commands:"
echo "  openstack network list"
echo "  openstack subnet list"
echo "  openstack network show ${PROVIDER_NET_NAME}"
echo ""
echo "Next: Run 29-cinder-db.sh (if using Cinder for block storage)"
echo "  Or: Run 30-cirros-test.sh to test VM creation"
