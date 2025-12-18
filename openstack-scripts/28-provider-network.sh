#!/bin/bash
###############################################################################
# 28-provider-network.sh
# Create provider flat network for external VM connectivity (OVN-based)
# Uses existing LAN infrastructure (DHCP from LAN router or static IPs)
#
# OVN Architecture:
# - Provider network mapped via OVN bridge mappings
# - OVN native DHCP (no neutron-dhcp-agent)
# - Flat network type on physnet1
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
# true  = OVN native DHCP provides IPs from allocation pool (RECOMMENDED)
# false = VMs must use static IPs or external DHCP
USE_OPENSTACK_DHCP="true"

# =============================================================================
# LOAD ENVIRONMENT
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

# Source admin credentials
if [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
else
    echo "ERROR: ~/admin-openrc not found!"
    echo "Run the Keystone setup scripts first."
    exit 1
fi

echo "=== Step 28: Provider Network Creation (OVN) ==="
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
if ! /usr/bin/openstack network agent list &>/dev/null; then
    echo "  ✗ ERROR: Neutron API not responding!"
    echo "  Run 27-neutron-sync.sh first."
    exit 1
fi
echo "  ✓ Neutron API responding"

# Verify ML2/OVN is configured (check for OVN mechanism driver)
if ! sudo /usr/bin/grep -q "mechanism_drivers.*ovn" /etc/neutron/plugins/ml2/ml2_conf.ini 2>/dev/null; then
    echo "  ✗ ERROR: ML2/OVN not configured!"
    echo "  Expected mechanism_drivers = ovn in ml2_conf.ini"
    exit 1
fi
echo "  ✓ ML2/OVN mechanism driver configured"

# Check OVN services are running
if ! systemctl is-active --quiet ovn-central; then
    echo "  ✗ ERROR: OVN central is not running!"
    exit 1
fi
echo "  ✓ OVN central is running"

# Check OVS bridge exists
if ! sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE_NAME}; then
    echo "  ✗ ERROR: OVS bridge ${PROVIDER_BRIDGE_NAME} not found!"
    echo "  Run 25-ovs-ovn-install.sh first."
    exit 1
fi
echo "  ✓ OVS bridge ${PROVIDER_BRIDGE_NAME} exists"

# Check OVN bridge mapping in OVS
BRIDGE_MAPPING=$(sudo ovs-vsctl get open . external-ids:ovn-bridge-mappings 2>/dev/null || echo "")
if echo "$BRIDGE_MAPPING" | /usr/bin/grep -q "${PROVIDER_NETWORK_NAME}:${PROVIDER_BRIDGE_NAME}"; then
    echo "  ✓ OVN bridge mapping configured: ${PROVIDER_NETWORK_NAME}:${PROVIDER_BRIDGE_NAME}"
else
    echo "  ⚠ WARNING: OVN bridge mapping may not be configured"
    echo "    Expected: ${PROVIDER_NETWORK_NAME}:${PROVIDER_BRIDGE_NAME}"
    echo "    Found: ${BRIDGE_MAPPING}"
fi

# Check flat_networks in ML2 config
if sudo /usr/bin/grep -q "flat_networks.*${PROVIDER_NETWORK_NAME}" /etc/neutron/plugins/ml2/ml2_conf.ini 2>/dev/null; then
    echo "  ✓ Flat network '${PROVIDER_NETWORK_NAME}' configured in ML2"
else
    echo "  ⚠ WARNING: flat_networks may not include ${PROVIDER_NETWORK_NAME}"
fi

echo "  ✓ Prerequisites OK"

# =============================================================================
# PART 2: Create Provider Network
# =============================================================================
echo ""
echo "[2/4] Creating provider network..."

# Check if network already exists
if /usr/bin/openstack network show "${PROVIDER_NET_NAME}" &>/dev/null; then
    echo "  ✓ Provider network '${PROVIDER_NET_NAME}' already exists"
else
    echo "  Creating network '${PROVIDER_NET_NAME}'..."
    if /usr/bin/openstack network create \
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
/usr/bin/openstack network show "${PROVIDER_NET_NAME}" -f table -c name -c id -c status \
    -c provider:network_type -c provider:physical_network -c router:external 2>/dev/null || true

# =============================================================================
# PART 3: Create Provider Subnet
# =============================================================================
echo ""
echo "[3/4] Creating provider subnet..."

# Check if subnet already exists
if /usr/bin/openstack subnet show "${PROVIDER_SUBNET_NAME}" &>/dev/null; then
    echo "  ✓ Provider subnet '${PROVIDER_SUBNET_NAME}' already exists"
else
    echo "  Creating subnet '${PROVIDER_SUBNET_NAME}'..."

    # Build subnet create command
    SUBNET_CMD="/usr/bin/openstack subnet create"
    SUBNET_CMD+=" --network ${PROVIDER_NET_NAME}"
    SUBNET_CMD+=" --subnet-range ${PROVIDER_SUBNET_RANGE}"
    SUBNET_CMD+=" --gateway ${PROVIDER_GATEWAY}"
    SUBNET_CMD+=" --dns-nameserver ${PROVIDER_DNS}"

    if [ "$USE_OPENSTACK_DHCP" = "true" ]; then
        SUBNET_CMD+=" --dhcp"
        SUBNET_CMD+=" --allocation-pool start=${ALLOCATION_POOL_START},end=${ALLOCATION_POOL_END}"
        echo "  Using OVN native DHCP with pool: ${ALLOCATION_POOL_START} - ${ALLOCATION_POOL_END}"
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
/usr/bin/openstack subnet show "${PROVIDER_SUBNET_NAME}" -f table -c name -c id -c cidr \
    -c gateway_ip -c enable_dhcp -c allocation_pools -c dns_nameservers 2>/dev/null || true

# =============================================================================
# PART 4: Verification
# =============================================================================
echo ""
echo "[4/4] Verifying provider network..."

# List networks
echo ""
echo "Networks:"
/usr/bin/openstack network list

# List subnets
echo ""
echo "Subnets:"
/usr/bin/openstack subnet list

# Verify network is external
EXTERNAL=$(/usr/bin/openstack network show "${PROVIDER_NET_NAME}" -f value -c router:external 2>/dev/null || echo "unknown")
if [ "$EXTERNAL" = "True" ]; then
    echo ""
    echo "  ✓ Network is marked as external (can be used as floating IP pool)"
else
    echo ""
    echo "  ⚠ Network may not be marked as external"
fi

# Check OVN logical switch was created
echo ""
echo "OVN Logical Switches:"
if sudo ovn-nbctl ls-list 2>/dev/null | /usr/bin/grep -i "neutron"; then
    sudo ovn-nbctl ls-list 2>/dev/null | /usr/bin/grep -i "neutron" | head -5
    echo "  ✓ OVN logical switch created for network"
else
    echo "  (OVN logical switch will be created when first port is attached)"
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
echo "Architecture: ML2/OVN (modern SDN)"
echo ""
echo "Network: ${PROVIDER_NET_NAME}"
echo "Subnet:  ${PROVIDER_SUBNET_NAME}"
echo "Range:   ${PROVIDER_SUBNET_RANGE}"
echo "Gateway: ${PROVIDER_GATEWAY}"
echo "DNS:     ${PROVIDER_DNS}"
if [ "$USE_OPENSTACK_DHCP" = "true" ]; then
    echo "DHCP:    Enabled (OVN native)"
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
echo "  sudo ovn-nbctl ls-list"
echo "  sudo ovn-nbctl show"
echo ""
echo "Next: Run 29-cinder-db.sh (if using Cinder for block storage)"
echo "  Or: Run 30-cirros-test.sh to test VM creation"
