#!/bin/bash
#===============================================================================
# 29-neutron-ovn-sync.sh - Sync Neutron Networks to OVN after Reset
#===============================================================================
#
# PROBLEM:
# ========
# After OVN nuclear reset, the OVN Northbound database is EMPTY but Neutron
# still has networks in its database. When creating VMs, Neutron tries to find
# logical switches in OVN that don't exist:
#   "Cannot find Logical_Switch with name=neutron-<network-id>"
#
# SOLUTION:
# =========
# This script recreates the provider network in both Neutron and OVN:
#   1. Deletes orphaned Neutron networks (that have no OVN counterpart)
#   2. Recreates the provider network with correct OVN mappings
#   3. Verifies the logical switch exists in OVN
#
# CRITICAL: Single-NIC Network Protection
# ========================================
# This script protects SSH connectivity throughout.
#
#===============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $*"; }

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

#===============================================================================
# Configuration - Adjust these for your environment
#===============================================================================
PROVIDER_NETWORK_NAME="${PROVIDER_NETWORK_NAME:-provider-net}"
PROVIDER_SUBNET_NAME="${PROVIDER_SUBNET_NAME:-provider-subnet}"
PROVIDER_PHYSICAL_NETWORK="${PROVIDER_PHYSICAL_NETWORK:-physnet1}"
PROVIDER_NETWORK_TYPE="${PROVIDER_NETWORK_TYPE:-flat}"

# Subnet configuration
SUBNET_RANGE="${SUBNET_RANGE:-192.168.2.0/24}"
SUBNET_GATEWAY="${SUBNET_GATEWAY:-192.168.2.1}"
ALLOCATION_POOL_START="${ALLOCATION_POOL_START:-192.168.2.100}"
ALLOCATION_POOL_END="${ALLOCATION_POOL_END:-192.168.2.200}"
DNS_NAMESERVER="${DNS_NAMESERVER:-8.8.8.8}"

#===============================================================================
# Single-NIC Network Protection
#===============================================================================
PROVIDER_BRIDGE="${PROVIDER_BRIDGE:-br-provider}"

ensure_provider_bridge_connectivity() {
    ovs-vsctl remove bridge ${PROVIDER_BRIDGE} fail_mode secure 2>/dev/null || true
    ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL" 2>/dev/null || true
}

verify_network_connectivity() {
    local gateway=$(ip route | grep "^default" | awk '{print $3}' | head -1)
    if [[ -n "$gateway" ]]; then
        ping -c 1 -W 2 "$gateway" &>/dev/null && return 0
    fi
    ping -c 1 -W 2 192.168.2.9 &>/dev/null && return 0
    return 1
}

#===============================================================================
# Load OpenStack Credentials
#===============================================================================
load_credentials() {
    if [[ -f /home/ramanuj/admin-openrc ]]; then
        source /home/ramanuj/admin-openrc
        log_info "Loaded admin credentials"
    elif [[ -f ~/admin-openrc ]]; then
        source ~/admin-openrc
        log_info "Loaded admin credentials from ~/admin-openrc"
    elif [[ -f /root/admin-openrc.sh ]]; then
        source /root/admin-openrc.sh
        log_info "Loaded admin credentials from /root/admin-openrc.sh"
    else
        log_error "No admin-openrc found!"
        echo "Please create /home/ramanuj/admin-openrc with OpenStack credentials"
        exit 1
    fi
}

#===============================================================================
# Diagnose the sync issue
#===============================================================================
diagnose_sync() {
    print_header "Diagnosing Neutron-OVN Sync Issue"

    load_credentials
    ensure_provider_bridge_connectivity

    echo "=== Neutron Networks ==="
    openstack network list 2>/dev/null || echo "  Cannot list networks"

    echo ""
    echo "=== OVN Logical Switches ==="
    ovn-nbctl show 2>/dev/null || echo "  Cannot query OVN NB"

    echo ""
    echo "=== Comparison ==="

    local neutron_networks=$(openstack network list -f value -c ID 2>/dev/null | wc -l)
    local ovn_switches=$(ovn-nbctl --bare --columns=name list Logical_Switch 2>/dev/null | wc -l)

    echo "  Neutron networks: $neutron_networks"
    echo "  OVN logical switches: $ovn_switches"

    if [[ "$neutron_networks" -gt 0 ]] && [[ "$ovn_switches" -eq 0 ]]; then
        echo ""
        echo -e "${RED}SYNC ISSUE DETECTED!${NC}"
        echo "Neutron has networks but OVN has no logical switches."
        echo ""
        echo "Run: $0 sync"
    elif [[ "$neutron_networks" -eq 0 ]] && [[ "$ovn_switches" -eq 0 ]]; then
        echo ""
        echo -e "${YELLOW}Both empty - need to create provider network${NC}"
        echo ""
        echo "Run: $0 create"
    else
        echo ""
        echo -e "${GREEN}Networks appear to be in sync${NC}"
    fi

    # Check for specific network
    echo ""
    echo "=== Provider Network Details ==="
    local provider_id=$(openstack network list -f value -c ID -c Name 2>/dev/null | grep -i provider | awk '{print $1}' | head -1)
    if [[ -n "$provider_id" ]]; then
        echo "  Neutron ID: $provider_id"
        local ovn_name="neutron-$provider_id"
        if ovn-nbctl --bare --columns=name list Logical_Switch 2>/dev/null | grep -q "$ovn_name"; then
            echo -e "  OVN Switch: ${GREEN}EXISTS${NC}"
        else
            echo -e "  OVN Switch: ${RED}MISSING${NC}"
            echo ""
            echo "This is the sync issue! The logical switch '$ovn_name' doesn't exist in OVN."
        fi
    else
        echo "  No provider network found in Neutron"
    fi
}

#===============================================================================
# Clean up orphaned Neutron resources
#===============================================================================
cleanup_neutron() {
    print_header "Cleaning Up Orphaned Neutron Resources"

    load_credentials
    ensure_provider_bridge_connectivity

    echo "This will delete all networks and subnets from Neutron."
    echo "They will be recreated with proper OVN sync."
    echo ""
    read -p "Continue? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { log_info "Aborted"; return 1; }

    # Delete VMs first
    log_step "[1/4] Deleting VMs..."
    for server in $(openstack server list --all-projects -f value -c ID 2>/dev/null); do
        echo "  Deleting server: $server"
        openstack server delete --force "$server" 2>/dev/null || true
    done
    ensure_provider_bridge_connectivity
    sleep 2

    # Delete floating IPs
    log_step "[2/4] Deleting floating IPs..."
    for fip in $(openstack floating ip list -f value -c ID 2>/dev/null); do
        echo "  Deleting floating IP: $fip"
        openstack floating ip delete "$fip" 2>/dev/null || true
    done
    ensure_provider_bridge_connectivity

    # Delete routers
    log_step "[3/4] Deleting routers..."
    for router in $(openstack router list -f value -c ID 2>/dev/null); do
        echo "  Clearing router interfaces: $router"
        for subnet in $(openstack router show "$router" -f json 2>/dev/null | grep -oP '"subnet_id": "\K[^"]+' || true); do
            openstack router remove subnet "$router" "$subnet" 2>/dev/null || true
        done
        echo "  Deleting router: $router"
        openstack router delete "$router" 2>/dev/null || true
    done
    ensure_provider_bridge_connectivity

    # Delete networks (this also deletes subnets and ports)
    log_step "[4/4] Deleting networks..."
    for network in $(openstack network list -f value -c ID 2>/dev/null); do
        local net_name=$(openstack network show "$network" -f value -c name 2>/dev/null || echo "$network")
        echo "  Deleting network: $net_name ($network)"

        # Delete all ports first
        for port in $(openstack port list --network "$network" -f value -c ID 2>/dev/null); do
            openstack port delete "$port" 2>/dev/null || true
        done

        # Delete subnets
        for subnet in $(openstack subnet list --network "$network" -f value -c ID 2>/dev/null); do
            openstack subnet delete "$subnet" 2>/dev/null || true
        done

        # Delete network
        openstack network delete "$network" 2>/dev/null || true
    done
    ensure_provider_bridge_connectivity

    log_info "Cleanup complete"
    echo ""
    echo "Verify cleanup:"
    echo "  Networks: $(openstack network list -f value -c ID 2>/dev/null | wc -l)"
    echo "  Subnets:  $(openstack subnet list -f value -c ID 2>/dev/null | wc -l)"
    echo "  Ports:    $(openstack port list -f value -c ID 2>/dev/null | wc -l)"
}

#===============================================================================
# Create provider network
#===============================================================================
create_provider_network() {
    print_header "Creating Provider Network"

    load_credentials
    ensure_provider_bridge_connectivity

    echo "Configuration:"
    echo "  Network Name: $PROVIDER_NETWORK_NAME"
    echo "  Physical Network: $PROVIDER_PHYSICAL_NETWORK"
    echo "  Network Type: $PROVIDER_NETWORK_TYPE"
    echo "  Subnet Range: $SUBNET_RANGE"
    echo "  Gateway: $SUBNET_GATEWAY"
    echo "  Allocation Pool: $ALLOCATION_POOL_START - $ALLOCATION_POOL_END"
    echo "  DNS: $DNS_NAMESERVER"
    echo ""

    # Check if network already exists
    if openstack network show "$PROVIDER_NETWORK_NAME" &>/dev/null; then
        log_warn "Network '$PROVIDER_NETWORK_NAME' already exists"
        openstack network show "$PROVIDER_NETWORK_NAME"
        return 0
    fi

    # Create network
    log_step "[1/3] Creating provider network..."
    openstack network create --share --external \
        --provider-physical-network "$PROVIDER_PHYSICAL_NETWORK" \
        --provider-network-type "$PROVIDER_NETWORK_TYPE" \
        "$PROVIDER_NETWORK_NAME"

    ensure_provider_bridge_connectivity

    # Get network ID
    local network_id=$(openstack network show "$PROVIDER_NETWORK_NAME" -f value -c id)
    log_info "Network created with ID: $network_id"

    # Create subnet
    log_step "[2/3] Creating subnet..."
    openstack subnet create --network "$PROVIDER_NETWORK_NAME" \
        --subnet-range "$SUBNET_RANGE" \
        --gateway "$SUBNET_GATEWAY" \
        --allocation-pool "start=$ALLOCATION_POOL_START,end=$ALLOCATION_POOL_END" \
        --dns-nameserver "$DNS_NAMESERVER" \
        "$PROVIDER_SUBNET_NAME"

    ensure_provider_bridge_connectivity

    # Wait for OVN sync
    log_step "[3/3] Waiting for OVN sync..."
    sleep 3

    # Verify OVN logical switch was created
    local ovn_switch_name="neutron-$network_id"
    if ovn-nbctl --bare --columns=name list Logical_Switch 2>/dev/null | grep -q "$ovn_switch_name"; then
        echo -e "${GREEN}SUCCESS: Logical switch created in OVN${NC}"
        echo ""
        echo "OVN Topology:"
        ovn-nbctl show | head -20
    else
        echo -e "${RED}WARNING: Logical switch not found in OVN${NC}"
        echo "Expected: $ovn_switch_name"
        echo ""
        echo "Current OVN switches:"
        ovn-nbctl --bare --columns=name list Logical_Switch
    fi

    ensure_provider_bridge_connectivity
}

#===============================================================================
# Full sync - cleanup + create
#===============================================================================
full_sync() {
    print_header "Full Neutron-OVN Sync"

    echo "This will:"
    echo "  1. Delete all VMs"
    echo "  2. Delete all networks from Neutron"
    echo "  3. Recreate the provider network"
    echo "  4. Verify OVN sync"
    echo ""
    read -p "Continue? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { log_info "Aborted"; return 1; }

    cleanup_neutron
    echo ""
    create_provider_network

    print_header "Sync Complete"

    echo "Next steps:"
    echo "  1. Verify with: $0 verify"
    echo "  2. Run smoke test: ./34-smoke-test.sh"
}

#===============================================================================
# Verify sync status
#===============================================================================
verify_sync() {
    print_header "Verifying Neutron-OVN Sync"

    load_credentials
    ensure_provider_bridge_connectivity

    echo "=== Neutron Networks ==="
    openstack network list

    echo ""
    echo "=== OVN Logical Switches ==="
    ovn-nbctl show

    echo ""
    echo "=== Sync Status ==="

    local all_synced=true

    for network_id in $(openstack network list -f value -c ID 2>/dev/null); do
        local net_name=$(openstack network show "$network_id" -f value -c name 2>/dev/null)
        local ovn_switch="neutron-$network_id"

        if ovn-nbctl --bare --columns=name list Logical_Switch 2>/dev/null | grep -q "$ovn_switch"; then
            echo -e "  ${GREEN}✓${NC} $net_name ($network_id) -> $ovn_switch"
        else
            echo -e "  ${RED}✗${NC} $net_name ($network_id) -> MISSING in OVN"
            all_synced=false
        fi
    done

    echo ""
    if [[ "$all_synced" == "true" ]]; then
        echo -e "${GREEN}All networks are synced with OVN!${NC}"
        echo ""
        echo "Ready for VM creation. Run: ./34-smoke-test.sh"
    else
        echo -e "${RED}Some networks are not synced with OVN${NC}"
        echo ""
        echo "Run: $0 sync"
    fi

    ensure_provider_bridge_connectivity
}

#===============================================================================
# Quick smoke test
#===============================================================================
smoke_test() {
    print_header "Quick VM Smoke Test"

    load_credentials
    ensure_provider_bridge_connectivity

    local test_vm_name="sync-test-vm-$$"

    # Check prerequisites
    log_step "[1/5] Checking prerequisites..."

    local network=$(openstack network list -f value -c Name | grep -i provider | head -1)
    if [[ -z "$network" ]]; then
        log_error "No provider network found!"
        echo "Run: $0 create"
        return 1
    fi
    echo "  Network: $network"

    local image=$(openstack image list -f value -c Name | head -1)
    if [[ -z "$image" ]]; then
        log_error "No images found!"
        return 1
    fi
    echo "  Image: $image"

    local flavor=$(openstack flavor list -f value -c Name | head -1)
    if [[ -z "$flavor" ]]; then
        log_error "No flavors found!"
        return 1
    fi
    echo "  Flavor: $flavor"

    ensure_provider_bridge_connectivity

    # Create VM
    log_step "[2/5] Creating test VM: $test_vm_name..."
    if ! openstack server create \
        --flavor "$flavor" \
        --image "$image" \
        --network "$network" \
        "$test_vm_name" 2>&1; then
        log_error "VM creation command failed!"
        ensure_provider_bridge_connectivity
        return 1
    fi

    ensure_provider_bridge_connectivity

    # Wait for VM
    log_step "[3/5] Waiting for VM to become active..."
    local max_wait=60
    local waited=0
    local status=""

    while [[ $waited -lt $max_wait ]]; do
        ensure_provider_bridge_connectivity
        status=$(openstack server show "$test_vm_name" -f value -c status 2>/dev/null || echo "UNKNOWN")

        if [[ "$status" == "ACTIVE" ]]; then
            break
        elif [[ "$status" == "ERROR" ]]; then
            log_error "VM went into ERROR state!"
            openstack server show "$test_vm_name" 2>/dev/null
            break
        fi

        echo "  Status: $status (waiting... ${waited}s/${max_wait}s)"
        sleep 5
        waited=$((waited + 5))
    done

    ensure_provider_bridge_connectivity

    # Show result
    log_step "[4/5] VM Status..."
    openstack server show "$test_vm_name"

    # Cleanup
    log_step "[5/5] Cleaning up test VM..."
    openstack server delete "$test_vm_name" 2>/dev/null || true

    ensure_provider_bridge_connectivity

    echo ""
    if [[ "$status" == "ACTIVE" ]]; then
        echo -e "${GREEN}SUCCESS! VM creation works!${NC}"
        return 0
    else
        echo -e "${RED}FAILED! VM did not become ACTIVE (status: $status)${NC}"
        return 1
    fi
}

#===============================================================================
# MAIN
#===============================================================================

usage() {
    echo "Usage: $0 {diagnose|cleanup|create|sync|verify|test|help}"
    echo ""
    echo "Commands:"
    echo "  diagnose  - Check if Neutron and OVN are out of sync"
    echo "  cleanup   - Delete all Neutron networks (use after nuclear reset)"
    echo "  create    - Create provider network with OVN sync"
    echo "  sync      - Full sync: cleanup + create (RECOMMENDED)"
    echo "  verify    - Verify networks are synced with OVN"
    echo "  test      - Quick smoke test (create and delete a VM)"
    echo "  help      - Show this help"
    echo ""
    echo "After OVN nuclear reset, run:"
    echo "  1. $0 diagnose   - Confirm sync issue"
    echo "  2. $0 sync       - Delete old networks and recreate"
    echo "  3. $0 verify     - Confirm sync is working"
    echo "  4. $0 test       - Test VM creation"
    echo ""
    echo "Environment variables for customization:"
    echo "  PROVIDER_NETWORK_NAME     - Name for provider network (default: provider-net)"
    echo "  PROVIDER_PHYSICAL_NETWORK - Physical network name (default: physnet1)"
    echo "  SUBNET_RANGE              - Subnet CIDR (default: 192.168.2.0/24)"
    echo "  SUBNET_GATEWAY            - Gateway IP (default: 192.168.2.1)"
    echo "  ALLOCATION_POOL_START     - First IP in pool (default: 192.168.2.100)"
    echo "  ALLOCATION_POOL_END       - Last IP in pool (default: 192.168.2.200)"
}

main() {
    [[ $EUID -ne 0 ]] && { log_error "This script must be run as root (sudo)"; exit 1; }

    case "${1:-help}" in
        diagnose)
            diagnose_sync
            ;;
        cleanup)
            cleanup_neutron
            ;;
        create)
            create_provider_network
            ;;
        sync)
            full_sync
            ;;
        verify)
            verify_sync
            ;;
        test)
            smoke_test
            ;;
        help|*)
            usage
            ;;
    esac
}

main "$@"
