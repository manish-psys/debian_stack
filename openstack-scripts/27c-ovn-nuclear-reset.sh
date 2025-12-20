#!/bin/bash
###############################################################################
# 27c-ovn-nuclear-reset.sh
# Complete OVN Nuclear Reset - Rebuilds OVN from scratch
#
# Use this script when:
# - 27b-ovn-full-reset.sh didn't fix the issue
# - OVN controller nb_cfg stays at 0
# - br-int has 0 flows (OVN controller not installing flows)
# - Chassis registered but ports not binding
# - OVN controller log is growing to GB in size
#
# What this script does:
#   1. Protects network connectivity (single-NIC safe)
#   2. Stops all OVN/Neutron services
#   3. DELETES OVN databases completely
#   4. Clears all OVS external-ids and OVN state
#   5. Reinitializes OVN databases fresh
#   6. Restarts all services
#   7. Re-creates provider network in OVN (if needed)
#   8. Validates everything
#
# WARNING: This will delete all OVN configuration!
#          Neutron will need to re-sync networks/ports with OVN.
#
# Prerequisites:
# - Run as root
# - Network connectivity to controller
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

PROVIDER_BRIDGE="${PROVIDER_BRIDGE_NAME:-br-provider}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_step() { echo -e "\n${GREEN}=== $1 ===${NC}"; }
log_info() { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "  ${RED}✗${NC} $1"; }

confirm() {
    if [ "$FORCE_MODE" = true ]; then return 0; fi
    read -p "  Continue? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]]
}

# =============================================================================
# Network Protection Functions
# =============================================================================
ensure_provider_bridge_connectivity() {
    ovs-vsctl remove bridge ${PROVIDER_BRIDGE} fail_mode secure 2>/dev/null || true
    ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL" 2>/dev/null || true
}

verify_network_connectivity() {
    local gateway=$(ip route | grep "^default" | awk '{print $3}' | head -1)
    [ -n "$gateway" ] && ping -c 1 -W 2 "$gateway" &>/dev/null && return 0
    ping -c 1 -W 2 ${CONTROLLER_IP} &>/dev/null && return 0
    return 1
}

recover_network_if_needed() {
    ensure_provider_bridge_connectivity
    if ! verify_network_connectivity; then
        log_warn "Network disrupted - recovering..."
        local current_ip=$(ip -4 addr show ${PROVIDER_BRIDGE} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
        local gateway=$(ip route | grep "^default" | awk '{print $3}' | head -1)
        ip link set ${PROVIDER_BRIDGE} up 2>/dev/null || true
        if [ -n "$gateway" ] && ! ip route | grep -q "^default"; then
            ip route add default via "$gateway" dev ${PROVIDER_BRIDGE} 2>/dev/null || true
        fi
        sleep 2
    fi
}

# =============================================================================
# Pre-flight
# =============================================================================
echo "=========================================="
echo "=== OVN NUCLEAR RESET ==="
echo "=========================================="
echo ""
echo -e "${RED}WARNING: This will DELETE all OVN databases!${NC}"
echo ""
echo "This script will:"
echo "  1. Stop all OVN and Neutron services"
echo "  2. DELETE /var/lib/ovn/*.db"
echo "  3. Clear all OVS OVN configuration"
echo "  4. Reinitialize OVN from scratch"
echo "  5. Restart all services"
echo "  6. Trigger Neutron-OVN re-sync"
echo ""

if [ "$EUID" -ne 0 ]; then
    log_error "Must run as root"
    exit 1
fi

# Source admin credentials
if [ -f /home/*/admin-openrc ]; then
    source $(ls /home/*/admin-openrc | head -1)
elif [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
else
    log_error "admin-openrc not found"
    exit 1
fi

echo -e "${YELLOW}Are you sure you want to proceed?${NC}"
if ! confirm; then
    echo "Aborted."
    exit 0
fi

###############################################################################
# PHASE 0: Protect Network
###############################################################################
log_step "[0/10] Protecting Network"
ensure_provider_bridge_connectivity
log_info "Network protection applied"

###############################################################################
# PHASE 1: Clean Up VMs
###############################################################################
log_step "[1/10] Cleaning Up VMs"
ERROR_VMS=$(/usr/bin/openstack server list --all-projects --status ERROR -f value -c ID 2>/dev/null || true)
SMOKE_VMS=$(/usr/bin/openstack server list --all-projects -f value -c ID -c Name 2>/dev/null | grep -i "smoketest" | awk '{print $1}' || true)
ALL_VMS=$(echo -e "$ERROR_VMS\n$SMOKE_VMS" | sort -u | grep -v "^$" || true)

if [ -n "$ALL_VMS" ]; then
    for VM_ID in $ALL_VMS; do
        echo "  Deleting VM: $VM_ID..."
        /usr/bin/openstack server delete --force "$VM_ID" 2>/dev/null || true
    done
    sleep 3
    log_info "VMs cleaned up"
else
    log_info "No VMs to clean"
fi

###############################################################################
# PHASE 2: Stop ALL Services
###############################################################################
log_step "[2/10] Stopping All Services"
ensure_provider_bridge_connectivity

SERVICES=(
    "neutron-ovn-metadata-agent"
    "neutron-api"
    "neutron-rpc-server"
    "ovn-controller"
    "ovn-host"
    "ovn-central"
)

for SVC in "${SERVICES[@]}"; do
    systemctl stop "$SVC" 2>/dev/null || true
    ensure_provider_bridge_connectivity
done

# Kill any remaining OVN processes
pkill -9 ovn-controller 2>/dev/null || true
pkill -9 ovn-northd 2>/dev/null || true
pkill -9 ovsdb-server 2>/dev/null || true

sleep 3
log_info "All services stopped"
recover_network_if_needed

###############################################################################
# PHASE 3: Delete OVN Databases
###############################################################################
log_step "[3/10] Deleting OVN Databases"

echo "  Removing OVN database files..."
rm -f /var/lib/ovn/ovnnb_db.db
rm -f /var/lib/ovn/ovnsb_db.db
rm -f /var/lib/ovn/.ovnnb_db.db.~lock~
rm -f /var/lib/ovn/.ovnsb_db.db.~lock~

# Also clear OVN log files (they can be huge)
echo "  Truncating OVN logs..."
truncate -s 0 /var/log/ovn/ovn-controller.log 2>/dev/null || true
truncate -s 0 /var/log/ovn/ovn-northd.log 2>/dev/null || true
truncate -s 0 /var/log/ovn/ovsdb-server-nb.log 2>/dev/null || true
truncate -s 0 /var/log/ovn/ovsdb-server-sb.log 2>/dev/null || true

log_info "OVN databases deleted"

###############################################################################
# PHASE 4: Clear OVS OVN State
###############################################################################
log_step "[4/10] Clearing OVS State"
ensure_provider_bridge_connectivity

# Remove all OVN-related external_ids from OVS
echo "  Clearing OVS external-ids..."
ovs-vsctl --if-exists remove open_vswitch . external_ids ovn-installed 2>/dev/null || true
ovs-vsctl --if-exists remove open_vswitch . external_ids ovn-remote-probe-interval 2>/dev/null || true

# Clear flows from br-int
echo "  Clearing br-int flows..."
ovs-ofctl del-flows br-int 2>/dev/null || true

# Ensure br-provider has NORMAL flow
ensure_provider_bridge_connectivity

log_info "OVS state cleared"
recover_network_if_needed

###############################################################################
# PHASE 5: Reinitialize OVN Databases
###############################################################################
log_step "[5/10] Reinitializing OVN Databases"

# Create fresh databases
echo "  Creating new Northbound database..."
ovsdb-tool create /var/lib/ovn/ovnnb_db.db /usr/share/ovn/ovn-nb.ovsschema
echo "  Creating new Southbound database..."
ovsdb-tool create /var/lib/ovn/ovnsb_db.db /usr/share/ovn/ovn-sb.ovsschema

# Set permissions
chmod 640 /var/lib/ovn/*.db

log_info "OVN databases reinitialized"

###############################################################################
# PHASE 6: Start OVN Central
###############################################################################
log_step "[6/10] Starting OVN Central"
ensure_provider_bridge_connectivity

systemctl start ovn-central
sleep 5
ensure_provider_bridge_connectivity

# Wait for databases to be ready
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    ensure_provider_bridge_connectivity
    if ovn-nbctl --no-leader-only show &>/dev/null && ovn-sbctl --no-leader-only show &>/dev/null; then
        break
    fi
    WAIT_COUNT=$((WAIT_COUNT + 3))
    echo "  Waiting for OVN databases... (${WAIT_COUNT}s/${MAX_WAIT}s)"
    sleep 3
done

if systemctl is-active --quiet ovn-central; then
    log_info "ovn-central running"
else
    log_error "ovn-central failed!"
    journalctl -u ovn-central --no-pager -n 20
    exit 1
fi

# Fix socket permissions
chmod 777 /var/run/ovn/ovnnb_db.sock /var/run/ovn/ovnsb_db.sock 2>/dev/null || true
log_info "Socket permissions fixed"

###############################################################################
# PHASE 7: Configure and Start OVN Controller
###############################################################################
log_step "[7/10] Configuring and Starting OVN Controller"
ensure_provider_bridge_connectivity

HOSTNAME=$(hostname)

# Set OVS external-ids for OVN
echo "  Setting OVS external-ids..."
ovs-vsctl set open . external-ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
ovs-vsctl set open . external-ids:ovn-encap-ip=${CONTROLLER_IP}
ovs-vsctl set open . external-ids:system-id="${HOSTNAME}"
ovs-vsctl set open . external-ids:ovn-bridge-mappings=physnet1:${PROVIDER_BRIDGE}
ovs-vsctl set open . external-ids:ovn-monitor-all=true

ensure_provider_bridge_connectivity

# Start OVN controller
echo "  Starting ovn-host..."
systemctl start ovn-host
sleep 3
ensure_provider_bridge_connectivity
sleep 2
ensure_provider_bridge_connectivity

if systemctl is-active --quiet ovn-controller; then
    log_info "ovn-controller running"
else
    log_error "ovn-controller failed!"
    journalctl -u ovn-controller --no-pager -n 20
    exit 1
fi

# Wait for chassis registration
echo "  Waiting for chassis registration..."
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    ensure_provider_bridge_connectivity
    CHASSIS=$(ovn-sbctl --bare --columns=name list Chassis 2>/dev/null | head -1 || true)
    if [ -n "$CHASSIS" ]; then
        log_info "Chassis registered: $CHASSIS"
        break
    fi
    WAIT_COUNT=$((WAIT_COUNT + 3))
    echo "  Waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
    sleep 3
done

recover_network_if_needed

###############################################################################
# PHASE 8: Restart Neutron Services
###############################################################################
log_step "[8/10] Restarting Neutron Services"
ensure_provider_bridge_connectivity

NEUTRON_SERVICES=(
    "neutron-rpc-server"
    "neutron-api"
    "neutron-ovn-metadata-agent"
)

for SVC in "${NEUTRON_SERVICES[@]}"; do
    echo "  Starting $SVC..."
    systemctl restart "$SVC"
    sleep 2
    ensure_provider_bridge_connectivity
done

sleep 5

for SVC in "${NEUTRON_SERVICES[@]}"; do
    if systemctl is-active --quiet "$SVC"; then
        log_info "$SVC running"
    else
        log_warn "$SVC not running"
    fi
done

recover_network_if_needed

###############################################################################
# PHASE 9: Trigger Neutron-OVN Sync
###############################################################################
log_step "[9/10] Triggering Neutron-OVN Sync"
ensure_provider_bridge_connectivity

# The neutron-server will automatically sync resources to OVN
# We need to wait for this to complete
echo "  Waiting for Neutron to sync networks to OVN..."
sleep 10

# Check if provider network was synced
SWITCHES=$(ovn-nbctl --bare --columns=name list Logical_Switch 2>/dev/null | wc -l)
echo "  Logical switches in OVN: $SWITCHES"

if [ "$SWITCHES" -eq 0 ]; then
    log_warn "No logical switches yet - Neutron sync may still be in progress"
    echo "  This is normal - Neutron will sync on first API call"
fi

# Force a sync by listing networks
echo "  Triggering sync by listing networks..."
/usr/bin/openstack network list &>/dev/null || true
sleep 5

SWITCHES=$(ovn-nbctl --bare --columns=name list Logical_Switch 2>/dev/null | wc -l)
echo "  Logical switches in OVN: $SWITCHES"

if [ "$SWITCHES" -gt 0 ]; then
    log_info "Neutron-OVN sync successful"
else
    log_warn "Sync may need more time"
fi

###############################################################################
# PHASE 10: Validation
###############################################################################
log_step "[10/10] Validation"
ensure_provider_bridge_connectivity

ERRORS=0

echo ""
echo "  [Check 1/7] Service Status:"
for SVC in openvswitch-switch ovn-central ovn-host neutron-api neutron-rpc-server neutron-ovn-metadata-agent; do
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        echo "    $SVC: running"
    else
        echo "    $SVC: NOT RUNNING"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""
echo "  [Check 2/7] OVN Databases:"
if [ -f /var/lib/ovn/ovnnb_db.db ] && [ -f /var/lib/ovn/ovnsb_db.db ]; then
    NB_SIZE=$(stat -c%s /var/lib/ovn/ovnnb_db.db)
    SB_SIZE=$(stat -c%s /var/lib/ovn/ovnsb_db.db)
    echo "    Northbound DB: ${NB_SIZE} bytes"
    echo "    Southbound DB: ${SB_SIZE} bytes"
    log_info "Databases exist"
else
    log_error "Databases missing!"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "  [Check 3/7] Chassis Registration:"
CHASSIS_INFO=$(ovn-sbctl list Chassis 2>/dev/null | grep -E "name|nb_cfg" | head -4)
echo "$CHASSIS_INFO" | sed 's/^/    /'
NB_CFG=$(ovn-sbctl --bare --columns=nb_cfg list Chassis 2>/dev/null | head -1 || echo "0")
GLOBAL_CFG=$(ovn-sbctl --bare --columns=nb_cfg list SB_Global 2>/dev/null | head -1 || echo "0")
echo "    Chassis nb_cfg: $NB_CFG (global: $GLOBAL_CFG)"
if [ "$NB_CFG" = "0" ] && [ "$GLOBAL_CFG" != "0" ]; then
    log_warn "Chassis nb_cfg is 0 - may need more time"
else
    log_info "Chassis looks good"
fi

echo ""
echo "  [Check 4/7] OVN Topology:"
ovn-nbctl show 2>/dev/null | sed 's/^/    /' | head -20
SWITCH_COUNT=$(ovn-nbctl --bare --columns=name list Logical_Switch 2>/dev/null | wc -l)
if [ "$SWITCH_COUNT" -gt 0 ]; then
    log_info "$SWITCH_COUNT logical switch(es) configured"
else
    log_warn "No logical switches - networks may need to be recreated"
fi

echo ""
echo "  [Check 5/7] Flows in br-int:"
FLOW_COUNT=$(ovs-ofctl dump-flows br-int 2>/dev/null | wc -l)
echo "    Flow count: $FLOW_COUNT"
if [ "$FLOW_COUNT" -gt 0 ]; then
    log_info "OVN controller is installing flows"
else
    log_warn "No flows yet - controller may need more time"
fi

echo ""
echo "  [Check 6/7] Network Agents:"
/usr/bin/openstack network agent list -f table 2>/dev/null | sed 's/^/    /' || echo "    (failed to list)"

echo ""
echo "  [Check 7/7] Network Connectivity:"
if verify_network_connectivity; then
    log_info "Network connectivity OK"
else
    log_error "Network connectivity failed!"
    recover_network_if_needed
    ERRORS=$((ERRORS + 1))
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}=== OVN Nuclear Reset SUCCESS ===${NC}"
    echo "=========================================="
    echo ""
    echo "OVN has been completely reset. Next steps:"
    echo "  1. Wait 30-60 seconds for OVN to fully stabilize"
    echo "  2. Verify: openstack network agent list"
    echo "  3. Verify: ovs-ofctl dump-flows br-int | wc -l"
    echo "  4. If flows > 0, run: ./34-smoke-test.sh"
else
    echo -e "${YELLOW}=== Reset Completed with $ERRORS Issue(s) ===${NC}"
    echo "=========================================="
    echo ""
    echo "Some checks failed. You may need to:"
    echo "  1. Wait a few minutes and check again"
    echo "  2. Check logs: journalctl -u ovn-controller -n 50"
    echo "  3. Verify OVS: sudo ovs-vsctl show"
fi
echo ""

# Final network protection
ensure_provider_bridge_connectivity
