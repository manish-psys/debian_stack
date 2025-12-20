#!/bin/bash
###############################################################################
# 27b-ovn-full-reset.sh
# Comprehensive OVN reset with cleanup, validation, and verification
#
# CRITICAL: Single-NIC Network Protection
# This script is designed for single-NIC OpenStack deployments where the
# provider bridge (br-provider) carries BOTH management (SSH) and VM traffic.
# Network connectivity is protected throughout the reset process by:
#   - Preserving NORMAL flow rule on br-provider at all times
#   - Removing fail_mode=secure before/after any service restart
#   - Running network recovery checks after each critical operation
#
# Use this script when:
# - VM creation fails with "Failed to allocate the network(s)"
# - OVN agents show "Alive: XXX" (not alive) in network agent list
# - OVN controller is consuming excessive CPU/memory
# - Chassis nb_cfg is stuck at 0
#
# Root Cause Analysis:
# The VirtualInterfaceCreateException with 300s timeout indicates OVN
# controller is not processing port binding events. This script:
#   1. Protects network connectivity (CRITICAL for single-NIC)
#   2. Cleans up any failed VMs to clear stuck ports
#   3. Stops OVN services safely
#   4. Clears stale chassis and port bindings
#   5. Resets OVN controller state
#   6. Restarts all OVN/Neutron services
#   7. Validates connectivity and agent status
#
# Prerequisites:
# - Scripts 25-27 completed
# - Admin credentials available
# - Network connectivity to controller
#
# Usage:
#   sudo ./27b-ovn-full-reset.sh           # Interactive mode
#   sudo ./27b-ovn-full-reset.sh --force   # Skip confirmations
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

# =============================================================================
# Configuration
# =============================================================================
FORCE_MODE=false
if [ "$1" = "--force" ] || [ "$1" = "-f" ]; then
    FORCE_MODE=true
fi

# Provider bridge name (carries management + VM traffic on single-NIC setups)
PROVIDER_BRIDGE="${PROVIDER_BRIDGE_NAME:-br-provider}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================
log_step() {
    echo ""
    echo -e "${GREEN}=== $1 ===${NC}"
}

log_info() {
    echo -e "  ${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "  ${RED}✗${NC} $1"
}

confirm() {
    if [ "$FORCE_MODE" = true ]; then
        return 0
    fi
    read -p "  Continue? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]]
}

# =============================================================================
# CRITICAL: Network Protection Functions for Single-NIC Setups
# =============================================================================
# These functions ensure SSH/management connectivity is NEVER lost during reset.
# OVN sets fail_mode=secure on bridges which drops ALL traffic without explicit
# OpenFlow rules. We must maintain a NORMAL flow rule at all times.

ensure_provider_bridge_connectivity() {
    # This is the MOST CRITICAL function in this script
    # Without it, single-NIC setups lose SSH connectivity

    # Remove fail_mode=secure if set (OVN sets this automatically)
    ovs-vsctl remove bridge ${PROVIDER_BRIDGE} fail_mode secure 2>/dev/null || true

    # Add default NORMAL flow rule to allow all traffic through
    # Priority 0 ensures it's a fallback rule that doesn't interfere with OVN rules
    ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL" 2>/dev/null || true
}

verify_network_connectivity() {
    local gateway
    gateway=$(ip route | grep "^default" | awk '{print $3}' | head -1)

    if [ -n "$gateway" ]; then
        if ping -c 1 -W 2 "$gateway" &>/dev/null; then
            return 0
        fi
    fi

    # Try controller IP as fallback
    if ping -c 1 -W 2 ${CONTROLLER_IP} &>/dev/null; then
        return 0
    fi

    return 1
}

recover_network_if_needed() {
    local context="$1"

    # Always ensure provider bridge connectivity first
    ensure_provider_bridge_connectivity

    if ! verify_network_connectivity; then
        log_warn "Network disrupted after: $context - recovering..."

        # Get current IP from br-provider
        local current_ip
        current_ip=$(ip -4 addr show ${PROVIDER_BRIDGE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
        local gateway
        gateway=$(ip route | grep "^default" | awk '{print $3}' | head -1)

        # Re-add IP if missing
        if [ -z "$current_ip" ]; then
            # Try to get IP from physical interface as fallback
            local phys_if
            phys_if=$(ovs-vsctl list-ports ${PROVIDER_BRIDGE} 2>/dev/null | grep -E "^(en|eth)" | head -1)
            if [ -n "$phys_if" ]; then
                current_ip=$(ip -4 addr show "$phys_if" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
            fi

            if [ -n "$current_ip" ]; then
                ip addr add "$current_ip" dev ${PROVIDER_BRIDGE} 2>/dev/null || true
            fi
        fi

        # Ensure bridge is up
        ip link set ${PROVIDER_BRIDGE} up 2>/dev/null || true

        # Re-add default route if missing
        if [ -n "$gateway" ] && ! ip route | grep -q "^default"; then
            ip route add default via "$gateway" dev ${PROVIDER_BRIDGE} 2>/dev/null || true
        fi

        sleep 2
        if verify_network_connectivity; then
            log_info "Network recovered"
        else
            log_error "CRITICAL: Network recovery failed!"
            log_error "You may need console/IPMI access to recover."
        fi
    fi
}

# =============================================================================
# Pre-flight Checks
# =============================================================================
echo "=========================================="
echo "=== OVN Full Reset with Validation ==="
echo "=========================================="
echo ""
echo "This script will:"
echo "  1. Protect network connectivity (single-NIC safe)"
echo "  2. Clean up any failed/stuck VMs"
echo "  3. Reset OVN chassis registration"
echo "  4. Restart all networking services"
echo "  5. Validate the fix"
echo ""
echo -e "${YELLOW}IMPORTANT: Provider bridge connectivity will be protected${NC}"
echo -e "${YELLOW}           throughout this process to prevent SSH loss.${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (sudo)"
    exit 1
fi

# Source admin credentials
if [ -f /home/*/admin-openrc ]; then
    ADMIN_RC=$(ls /home/*/admin-openrc | head -1)
    source "$ADMIN_RC"
    log_info "Loaded admin credentials from $ADMIN_RC"
elif [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
    log_info "Loaded admin credentials from ~/admin-openrc"
else
    log_error "admin-openrc not found!"
    exit 1
fi

###############################################################################
# PHASE 0: Protect Network BEFORE Anything Else
###############################################################################
log_step "[0/8] Protecting Network Connectivity (Single-NIC Safety)"

# Apply network protection FIRST before any other operations
ensure_provider_bridge_connectivity
log_info "Provider bridge NORMAL flow rule ensured"

# Verify we have connectivity
if verify_network_connectivity; then
    log_info "Network connectivity verified"
else
    log_warn "Network connectivity check failed - proceeding with caution"
fi

# Show current bridge state
echo "  Current br-provider state:"
echo "    fail_mode: $(ovs-vsctl get bridge ${PROVIDER_BRIDGE} fail_mode 2>/dev/null || echo 'not set')"
echo "    NORMAL flows: $(ovs-ofctl dump-flows ${PROVIDER_BRIDGE} 2>/dev/null | grep -c 'NORMAL' || echo '0')"

###############################################################################
# PHASE 1: Pre-Reset Diagnostics
###############################################################################
log_step "[1/8] Collecting Pre-Reset Diagnostics"

echo "  Current OVN Agent Status:"
/usr/bin/openstack network agent list -f table 2>/dev/null | sed 's/^/    /' || echo "    (failed to list agents)"

echo ""
echo "  Current Chassis State:"
CHASSIS_INFO=$(ovn-sbctl list Chassis 2>/dev/null | grep -E "name|nb_cfg|hostname" | head -6 || echo "    (failed to query)")
echo "$CHASSIS_INFO" | sed 's/^/    /'

# Get chassis nb_cfg before reset
OLD_NB_CFG=$(ovn-sbctl --bare --columns=nb_cfg list Chassis 2>/dev/null | head -1 || echo "0")
GLOBAL_NB_CFG=$(ovn-sbctl --bare --columns=nb_cfg list SB_Global 2>/dev/null | head -1 || echo "0")
echo ""
echo "  Chassis nb_cfg: $OLD_NB_CFG (should match global: $GLOBAL_NB_CFG)"

if [ "$OLD_NB_CFG" = "0" ]; then
    log_warn "Chassis nb_cfg is 0 - confirms OVN controller is stuck"
fi

echo ""
if ! confirm; then
    echo "Aborted."
    exit 0
fi

###############################################################################
# PHASE 2: Clean Up Failed VMs
###############################################################################
log_step "[2/8] Cleaning Up Failed/Stuck VMs"

# Protect network before VM cleanup
ensure_provider_bridge_connectivity

# Find all smoketest or ERROR VMs
ERROR_VMS=$(/usr/bin/openstack server list --all-projects --status ERROR -f value -c ID 2>/dev/null || true)
SMOKE_VMS=$(/usr/bin/openstack server list --all-projects -f value -c ID -c Name 2>/dev/null | grep -i "smoketest" | awk '{print $1}' || true)

ALL_VMS=$(echo -e "$ERROR_VMS\n$SMOKE_VMS" | sort -u | grep -v "^$" || true)

if [ -n "$ALL_VMS" ]; then
    VM_COUNT=$(echo "$ALL_VMS" | wc -l)
    echo "  Found $VM_COUNT VM(s) to clean up"

    for VM_ID in $ALL_VMS; do
        VM_NAME=$(/usr/bin/openstack server show "$VM_ID" -f value -c name 2>/dev/null || echo "$VM_ID")
        echo "  Deleting VM: $VM_NAME ($VM_ID)..."
        /usr/bin/openstack server delete --force "$VM_ID" 2>/dev/null || true
    done

    # Wait for deletion
    sleep 5
    REMAINING=$(/usr/bin/openstack server list --all-projects -f value -c ID 2>/dev/null | wc -l || echo "0")
    log_info "VMs cleaned up ($REMAINING remaining total)"
else
    log_info "No failed VMs to clean up"
fi

# Verify network after VM cleanup
recover_network_if_needed "VM cleanup"

###############################################################################
# PHASE 3: Stop Services Gracefully
###############################################################################
log_step "[3/8] Stopping OVN and Neutron Services"

# PROTECT NETWORK before stopping services
ensure_provider_bridge_connectivity

# Stop in correct order (reverse dependency order)
SERVICES_TO_STOP=(
    "neutron-ovn-metadata-agent"
    "neutron-api"
    "neutron-rpc-server"
    "ovn-controller"
    "ovn-host"
)

for SVC in "${SERVICES_TO_STOP[@]}"; do
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        echo "  Stopping $SVC..."
        systemctl stop "$SVC" 2>/dev/null || true

        # CRITICAL: Protect network after each service stop
        ensure_provider_bridge_connectivity
    fi
done

# Give processes time to exit
sleep 3

# PROTECT NETWORK after all stops
ensure_provider_bridge_connectivity

# Verify they're stopped
for SVC in "${SERVICES_TO_STOP[@]}"; do
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        log_warn "$SVC still running - force killing..."
        pkill -9 -f "$SVC" 2>/dev/null || true
    fi
done

log_info "Services stopped"

# Verify network after service stops
recover_network_if_needed "service stops"

###############################################################################
# PHASE 4: Clear Stale OVN State
###############################################################################
log_step "[4/8] Clearing Stale OVN State"

# PROTECT NETWORK before clearing state
ensure_provider_bridge_connectivity

# Get chassis name before deleting
CHASSIS_NAME=$(ovn-sbctl --bare --columns=name list Chassis 2>/dev/null | head -1 || true)
HOSTNAME=$(hostname)

if [ -n "$CHASSIS_NAME" ]; then
    echo "  Deleting chassis: $CHASSIS_NAME"
    ovn-sbctl chassis-del "$CHASSIS_NAME" 2>/dev/null || true
    log_info "Chassis deleted from Southbound DB"
else
    log_warn "No chassis found to delete"
fi

# Clear any stale port bindings for this host
echo "  Clearing port bindings for host: $HOSTNAME"
# Port bindings are auto-deleted when chassis is removed

# Clear OVN controller local state from OVS
echo "  Clearing OVN controller state from OVS..."
ovs-vsctl --if-exists remove open_vswitch . external_ids ovn-installed 2>/dev/null || true
ovs-vsctl --if-exists remove open_vswitch . external_ids ovn-remote-probe-interval 2>/dev/null || true

# Clear stale flow tables on br-int (NOT br-provider!)
# br-provider MUST keep NORMAL rule for connectivity
echo "  Resetting br-int flow tables..."
ovs-ofctl del-flows br-int 2>/dev/null || true

# CRITICAL: Re-apply NORMAL flow to br-provider after any OVS operations
ensure_provider_bridge_connectivity

log_info "OVN state cleared"

# Verify network after state clearing
recover_network_if_needed "OVN state clearing"

###############################################################################
# PHASE 5: Restart OVN Central
###############################################################################
log_step "[5/8] Restarting OVN Central Services"

# PROTECT NETWORK before restart
ensure_provider_bridge_connectivity

# Restart OVN central (NB/SB databases and northd)
echo "  Restarting ovn-central..."
systemctl restart ovn-central

# IMMEDIATELY protect network after restart
sleep 1
ensure_provider_bridge_connectivity

# Wait for databases to be ready
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Protect network on each iteration
    ensure_provider_bridge_connectivity

    if ovn-nbctl --no-leader-only show &>/dev/null && ovn-sbctl --no-leader-only show &>/dev/null; then
        break
    fi
    WAIT_COUNT=$((WAIT_COUNT + 2))
    echo "  Waiting for OVN databases... (${WAIT_COUNT}s/${MAX_WAIT}s)"
    sleep 2
done

if systemctl is-active --quiet ovn-central; then
    log_info "ovn-central running"
else
    log_error "ovn-central failed to start!"
    journalctl -u ovn-central --no-pager -n 20
    # Still try to protect network
    ensure_provider_bridge_connectivity
    exit 1
fi

# Fix socket permissions for Neutron access
chmod 777 /var/run/ovn/ovnnb_db.sock /var/run/ovn/ovnsb_db.sock 2>/dev/null || true
log_info "OVN socket permissions set"

# Verify network after OVN central restart
recover_network_if_needed "ovn-central restart"

###############################################################################
# PHASE 6: Restart OVN Controller
###############################################################################
log_step "[6/8] Restarting OVN Controller"

# PROTECT NETWORK before controller restart
ensure_provider_bridge_connectivity

# Ensure OVS external-ids are set correctly
echo "  Configuring OVN external-ids..."
ovs-vsctl set open . external-ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
ovs-vsctl set open . external-ids:ovn-encap-ip=${CONTROLLER_IP}
ovs-vsctl set open . external-ids:system-id="${HOSTNAME}"
ovs-vsctl set open . external-ids:ovn-bridge-mappings=physnet1:${PROVIDER_BRIDGE}
ovs-vsctl set open . external-ids:ovn-monitor-all=true
ovs-vsctl set open . external-ids:ovn-openflow-probe-interval=60

# PROTECT NETWORK after external-ids changes
ensure_provider_bridge_connectivity

# Restart OVN host (controller)
echo "  Restarting ovn-host..."
systemctl restart ovn-host

# IMMEDIATELY protect network after OVN controller restart
# This is CRITICAL because OVN controller will try to set fail_mode=secure
sleep 2
ensure_provider_bridge_connectivity
sleep 1
ensure_provider_bridge_connectivity

if systemctl is-active --quiet ovn-controller; then
    log_info "ovn-controller running"
else
    log_error "ovn-controller failed to start!"
    journalctl -u ovn-controller --no-pager -n 20
    # Still protect network
    ensure_provider_bridge_connectivity
    exit 1
fi

# Wait for chassis to register with updated nb_cfg
echo "  Waiting for chassis registration..."
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Protect network on each iteration
    ensure_provider_bridge_connectivity

    NEW_NB_CFG=$(ovn-sbctl --bare --columns=nb_cfg list Chassis 2>/dev/null | head -1 || echo "0")
    if [ "$NEW_NB_CFG" != "0" ] 2>/dev/null; then
        log_info "Chassis registered with nb_cfg: $NEW_NB_CFG"
        break
    fi
    WAIT_COUNT=$((WAIT_COUNT + 3))
    echo "  Waiting... (${WAIT_COUNT}s/${MAX_WAIT}s) - nb_cfg: $NEW_NB_CFG"
    sleep 3
done

if [ "$NEW_NB_CFG" = "0" ]; then
    log_warn "Chassis nb_cfg still 0 after restart - may need more time"
fi

# Verify network after OVN controller restart
recover_network_if_needed "ovn-controller restart"

###############################################################################
# PHASE 7: Restart Neutron Services
###############################################################################
log_step "[7/8] Restarting Neutron Services"

# PROTECT NETWORK before Neutron restart
ensure_provider_bridge_connectivity

NEUTRON_SERVICES=(
    "neutron-rpc-server"
    "neutron-api"
    "neutron-ovn-metadata-agent"
)

for SVC in "${NEUTRON_SERVICES[@]}"; do
    echo "  Restarting $SVC..."
    systemctl restart "$SVC" 2>/dev/null || true
    sleep 2

    # PROTECT NETWORK after each Neutron service restart
    ensure_provider_bridge_connectivity
done

# Verify Neutron services
sleep 3
for SVC in "${NEUTRON_SERVICES[@]}"; do
    if systemctl is-active --quiet "$SVC"; then
        log_info "$SVC running"
    else
        log_warn "$SVC not running"
    fi
done

# Final network protection after all Neutron services
ensure_provider_bridge_connectivity

# Verify network after Neutron restart
recover_network_if_needed "Neutron services restart"

###############################################################################
# PHASE 8: Validation
###############################################################################
log_step "[8/8] Validation and Verification"

# PROTECT NETWORK during validation
ensure_provider_bridge_connectivity

ERRORS=0

# Check 1: OVN Services Status
echo ""
echo "  [Check 1/6] OVN Service Status:"
for SVC in openvswitch-switch ovn-central ovn-host; do
    if systemctl is-active --quiet "$SVC"; then
        echo "    $SVC: running"
    else
        echo "    $SVC: NOT RUNNING"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check 2: Neutron Services Status
echo ""
echo "  [Check 2/6] Neutron Service Status:"
for SVC in neutron-api neutron-rpc-server neutron-ovn-metadata-agent; do
    if systemctl is-active --quiet "$SVC"; then
        echo "    $SVC: running"
    else
        echo "    $SVC: NOT RUNNING"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check 3: OVN Agent Status (Alive check)
echo ""
echo "  [Check 3/6] Neutron Network Agents:"
sleep 5  # Give agents time to register
AGENT_OUTPUT=$(/usr/bin/openstack network agent list -f table 2>/dev/null || echo "    (failed to list)")
echo "$AGENT_OUTPUT" | sed 's/^/    /'

# Count alive vs dead agents
ALIVE_COUNT=$(echo "$AGENT_OUTPUT" | grep -c ":-)" || echo "0")
DEAD_COUNT=$(echo "$AGENT_OUTPUT" | grep -c "XXX" || echo "0")

if [ "$DEAD_COUNT" -gt 0 ]; then
    log_warn "$DEAD_COUNT agent(s) still showing as not alive"
    echo "    This may take up to 75s for heartbeat to update"
    ERRORS=$((ERRORS + 1))
else
    log_info "All agents showing as alive"
fi

# Check 4: Chassis nb_cfg Sync
echo ""
echo "  [Check 4/6] OVN Chassis Synchronization:"
FINAL_CHASSIS_NB_CFG=$(ovn-sbctl --bare --columns=nb_cfg list Chassis 2>/dev/null | head -1 || echo "0")
FINAL_GLOBAL_NB_CFG=$(ovn-sbctl --bare --columns=nb_cfg list SB_Global 2>/dev/null | head -1 || echo "0")
echo "    Chassis nb_cfg: $FINAL_CHASSIS_NB_CFG"
echo "    Global nb_cfg:  $FINAL_GLOBAL_NB_CFG"

if [ "$FINAL_CHASSIS_NB_CFG" = "$FINAL_GLOBAL_NB_CFG" ] && [ "$FINAL_CHASSIS_NB_CFG" != "0" ]; then
    log_info "Chassis is in sync with northbound"
elif [ "$FINAL_CHASSIS_NB_CFG" != "0" ]; then
    log_warn "Chassis nb_cfg ($FINAL_CHASSIS_NB_CFG) differs from global ($FINAL_GLOBAL_NB_CFG) - catching up"
else
    log_error "Chassis nb_cfg is still 0!"
    ERRORS=$((ERRORS + 1))
fi

# Check 5: Provider Bridge Configuration (CRITICAL for single-NIC)
echo ""
echo "  [Check 5/6] Provider Bridge Configuration (Single-NIC Safety):"
OVS_SHOW=$(ovs-vsctl show 2>/dev/null | head -20)
if echo "$OVS_SHOW" | grep -q "${PROVIDER_BRIDGE}"; then
    log_info "${PROVIDER_BRIDGE} exists"

    # Check port membership
    PORTS=$(ovs-vsctl list-ports ${PROVIDER_BRIDGE} 2>/dev/null || true)
    echo "    Ports: $PORTS"

    # Check bridge mappings
    BRIDGE_MAP=$(ovs-vsctl get open . external-ids:ovn-bridge-mappings 2>/dev/null || echo "not set")
    echo "    OVN bridge-mappings: $BRIDGE_MAP"

    # Check fail_mode (should NOT be 'secure' for provider bridge)
    FAIL_MODE=$(ovs-vsctl get bridge ${PROVIDER_BRIDGE} fail_mode 2>/dev/null || echo "not set")
    echo "    fail_mode: $FAIL_MODE"
    if echo "$FAIL_MODE" | grep -q "secure"; then
        log_error "fail_mode is still 'secure' - fixing..."
        ensure_provider_bridge_connectivity
    else
        log_info "fail_mode is not 'secure' (good)"
    fi

    # Check NORMAL flow rule exists
    NORMAL_FLOWS=$(ovs-ofctl dump-flows ${PROVIDER_BRIDGE} 2>/dev/null | grep -c "actions=NORMAL" || echo "0")
    echo "    NORMAL flow rules: $NORMAL_FLOWS"
    if [ "$NORMAL_FLOWS" -gt 0 ]; then
        log_info "NORMAL flow rule present (good for connectivity)"
    else
        log_warn "No NORMAL flow rule - adding..."
        ensure_provider_bridge_connectivity
    fi
else
    log_error "${PROVIDER_BRIDGE} not found!"
    ERRORS=$((ERRORS + 1))
fi

# Check 6: Network connectivity
echo ""
echo "  [Check 6/6] Network Connectivity:"
if verify_network_connectivity; then
    log_info "Network connectivity OK"
else
    log_error "Network connectivity check failed!"
    log_warn "Attempting recovery..."
    recover_network_if_needed "final validation"
    ERRORS=$((ERRORS + 1))
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}=== OVN Full Reset SUCCESS ===${NC}"
    echo "=========================================="
    echo ""
    echo "All checks passed. OVN should now be operational."
    echo ""
    echo "Next steps:"
    echo "  1. Wait 60-75 seconds for agent heartbeats to stabilize"
    echo "  2. Verify agents: openstack network agent list"
    echo "  3. Run smoke test: ./34-smoke-test.sh"
else
    echo -e "${YELLOW}=== OVN Reset Completed with $ERRORS Issue(s) ===${NC}"
    echo "=========================================="
    echo ""
    echo "Some checks failed. Troubleshooting steps:"
    echo ""
    echo "  1. Check OVN controller logs:"
    echo "     sudo journalctl -u ovn-controller -n 50 --no-pager"
    echo ""
    echo "  2. Check for high CPU usage:"
    echo "     top -p \$(pgrep ovn-controller)"
    echo ""
    echo "  3. If agents still dead after 75s, check Neutron logs:"
    echo "     sudo tail -50 /var/log/neutron/neutron-api.log"
    echo ""
    echo "  4. If network was lost, run the rescue script:"
    echo "     sudo /usr/local/bin/fix-provider-bridge.sh ${PROVIDER_BRIDGE}"
    echo ""
    echo "  5. If issues persist, consider full OVN reinstall:"
    echo "     sudo apt purge ovn-central ovn-host"
    echo "     sudo rm -rf /var/lib/ovn/"
    echo "     sudo ./25-ovs-ovn-install.sh"
fi
echo ""

# Final network protection
ensure_provider_bridge_connectivity
