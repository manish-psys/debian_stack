#!/bin/bash
#===============================================================================
# 28-ovn-version-fix.sh - Fix OVN Version Compatibility for OpenStack Caracal
#===============================================================================
#
# PROBLEM DIAGNOSIS:
# ==================
# Your OVN controller is running but NOT installing OpenFlow rules into OVS.
# Root cause: Version incompatibility between OVN 25.03.0 and Neutron Caracal
#
# Your versions:
#   - Neutron: 26.0.0-9 (Caracal 2024.1)
#   - OVN: 25.03.0-1 (March 2025 - TOO NEW!)
#   - OVS: 3.5.0-1+b1
#
# Required for Caracal (per OpenStack docs):
#   - OVN: v21.06.0 to v24.03.0 (branch-24.03)
#   - OVS: 2.16.x to 3.3.x
#
# Evidence of the problem:
#   1. Chassis.nb_cfg = 0 (controller not processing)
#   2. ZERO flows in br-int (ovs-ofctl dump-flows br-int | wc -l = 0)
#   3. Port bindings show: up: false, chassis: []
#   4. 3.5GB log file (controller in loop or error state)
#
# SOLUTIONS:
# ==========
# Option A: Downgrade OVN to compatible version from Debian Bookworm
# Option B: Nuclear reset with database recreation
# Option C: Try to force compatibility (less reliable)
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

# Load OpenStack credentials
load_credentials() {
    if [[ -f /home/ramanuj/admin-openrc ]]; then
        source /home/ramanuj/admin-openrc
        log_info "Loaded admin credentials"
    else
        log_warn "No admin-openrc found"
    fi
}

#===============================================================================
# DIAGNOSIS SECTION
#===============================================================================

run_diagnosis() {
    print_header "OVN Version Compatibility Diagnosis"
    
    echo "=== Current Package Versions ==="
    dpkg -l | grep -E 'neutron|ovn|openvswitch' | awk '{printf "  %-35s %s\n", $2, $3}'
    
    echo ""
    echo "=== OVN Component Versions ==="
    echo "  ovn-nbctl: $(ovn-nbctl --version | head -1)"
    echo "  ovn-sbctl: $(ovn-sbctl --version | head -1)"
    echo "  ovs-vsctl: $(ovs-vsctl --version | head -1)"
    
    echo ""
    echo "=== OVN Database Schema Versions ==="
    ovn-nbctl --version | grep "DB Schema"
    ovn-sbctl --version | grep "DB Schema"
    
    echo ""
    echo "=== Chassis Status ==="
    ovn-sbctl list Chassis | grep -E "name|hostname|nb_cfg"
    
    echo ""
    echo "=== Chassis_Private Status ==="
    ovn-sbctl list Chassis_Private | grep -E "name|nb_cfg"
    
    echo ""
    echo "=== Global nb_cfg ==="
    echo "  SB_Global nb_cfg: $(ovn-sbctl get SB_Global . nb_cfg)"
    
    echo ""
    echo "=== OpenFlow Rules Count ==="
    echo "  br-int flows:      $(ovs-ofctl dump-flows br-int 2>/dev/null | wc -l)"
    echo "  br-provider flows: $(ovs-ofctl dump-flows br-provider 2>/dev/null | wc -l)"
    
    echo ""
    echo "=== OVN Controller Log Size ==="
    ls -lh /var/log/ovn/ovn-controller.log 2>/dev/null || echo "  Log not found"
    
    echo ""
    echo "=== Recent OVN Controller Errors ==="
    journalctl -u ovn-controller -n 20 --no-pager 2>/dev/null | tail -10 || \
        tail -c 5000 /var/log/ovn/ovn-controller.log 2>/dev/null | tail -20 || \
        echo "  Cannot read logs"
    
    echo ""
    echo "=== Port Bindings ==="
    ovn-sbctl list Port_Binding | grep -E "logical_port|chassis|up" | head -20
    
    echo ""
    print_header "Diagnosis Summary"
    
    local chassis_nb_cfg=$(ovn-sbctl list Chassis | grep "nb_cfg" | awk '{print $3}')
    local global_nb_cfg=$(ovn-sbctl get SB_Global . nb_cfg)
    local br_int_flows=$(ovs-ofctl dump-flows br-int 2>/dev/null | wc -l)
    
    echo "CRITICAL FINDINGS:"
    echo ""
    
    if [[ "$br_int_flows" -eq 0 ]]; then
        echo -e "  ${RED}✗ ZERO flows in br-int - OVN controller NOT installing rules${NC}"
    else
        echo -e "  ${GREEN}✓ br-int has $br_int_flows flows${NC}"
    fi
    
    if [[ "$chassis_nb_cfg" == "0" ]]; then
        echo -e "  ${RED}✗ Chassis nb_cfg is 0 - controller not processing NB database${NC}"
    else
        echo -e "  ${GREEN}✓ Chassis nb_cfg is $chassis_nb_cfg${NC}"
    fi
    
    echo ""
    echo "VERSION COMPATIBILITY ISSUE:"
    echo "  Your OVN version (25.03.0) is from March 2025"
    echo "  OpenStack Caracal was tested with OVN v21.06.0 to v24.03.0"
    echo ""
    echo "RECOMMENDED ACTION:"
    echo "  Option A: Downgrade OVN to compatible version (branch-24.03)"
    echo "  Option B: Nuclear reset with database recreation"
    echo ""
}

#===============================================================================
# OPTION A: DOWNGRADE OVN
#===============================================================================

check_bookworm_packages() {
    print_header "Checking Debian Bookworm Package Availability"
    
    # Check if bookworm repo is available
    if ! grep -r "bookworm" /etc/apt/sources.list* 2>/dev/null | grep -v ".save" | head -1; then
        log_warn "Debian Bookworm repository not configured"
        echo ""
        echo "To add Bookworm repository, create:"
        echo "  /etc/apt/sources.list.d/bookworm.list"
        echo ""
        echo "With contents:"
        echo "  deb http://deb.debian.org/debian bookworm main"
        echo ""
        echo "Then run: apt update"
        return 1
    fi
    
    log_info "Checking available OVN versions..."
    apt-cache policy ovn-central ovn-host 2>/dev/null || true
}

downgrade_ovn_to_bookworm() {
    print_header "Downgrade OVN to Debian Bookworm Version"
    
    log_warn "This will downgrade OVN packages to Bookworm versions"
    log_warn "Bookworm has OVN 23.03.0 which is compatible with Neutron Caracal"
    echo ""
    
    read -p "Continue with downgrade? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { log_info "Aborted"; return 1; }
    
    # Stop services first
    log_step "Stopping OVN and Neutron services..."
    systemctl stop neutron-ovn-metadata-agent || true
    systemctl stop neutron-api || true
    systemctl stop neutron-rpc-server || true
    systemctl stop ovn-host || true
    systemctl stop ovn-central || true
    
    # Backup databases
    log_step "Backing up OVN databases..."
    mkdir -p /var/lib/ovn/backup-$(date +%Y%m%d-%H%M%S)
    cp /var/lib/ovn/*.db /var/lib/ovn/backup-$(date +%Y%m%d-%H%M%S)/ 2>/dev/null || true
    
    # Add bookworm repo if not present
    if ! grep -r "bookworm" /etc/apt/sources.list* 2>/dev/null | grep -qv ".save"; then
        log_step "Adding Debian Bookworm repository..."
        cat > /etc/apt/sources.list.d/bookworm.list << 'EOF'
# Debian Bookworm - for OVN compatibility with OpenStack Caracal
deb http://deb.debian.org/debian bookworm main
EOF
        
        # Pin OVN packages to bookworm
        cat > /etc/apt/preferences.d/ovn-bookworm << 'EOF'
# Pin OVN packages to Bookworm for OpenStack Caracal compatibility
Package: ovn-*
Pin: release n=bookworm
Pin-Priority: 1001

Package: openvswitch-*
Pin: release n=bookworm
Pin-Priority: 1001
EOF
        apt-get update
    fi
    
    # Downgrade packages
    log_step "Downgrading OVN packages..."
    apt-get install -y --allow-downgrades \
        ovn-central/bookworm \
        ovn-host/bookworm \
        ovn-common/bookworm \
        openvswitch-common/bookworm \
        openvswitch-switch/bookworm \
        python3-openvswitch/bookworm
    
    log_info "Downgrade complete. Now run Option B to reinitialize databases."
}

#===============================================================================
# OPTION B: NUCLEAR RESET
#===============================================================================

nuclear_reset() {
    print_header "Nuclear OVN Reset with Database Recreation"
    
    log_warn "This will COMPLETELY reset OVN including databases!"
    log_warn "All OVN configuration will be lost and must be recreated by Neutron"
    echo ""
    
    read -p "Continue with nuclear reset? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { log_info "Aborted"; return 1; }
    
    # Protect network connectivity first
    log_step "[1/10] Protecting network connectivity..."
    ovs-ofctl add-flow br-provider "priority=0,actions=NORMAL" 2>/dev/null || true
    
    # Stop all services
    log_step "[2/10] Stopping all services..."
    systemctl stop neutron-ovn-metadata-agent 2>/dev/null || true
    systemctl stop neutron-api 2>/dev/null || true
    systemctl stop neutron-rpc-server 2>/dev/null || true
    systemctl stop ovn-controller 2>/dev/null || true
    systemctl stop ovn-host 2>/dev/null || true
    systemctl stop ovn-central 2>/dev/null || true
    
    # Kill any remaining processes
    pkill -9 ovn-controller 2>/dev/null || true
    pkill -9 ovn-northd 2>/dev/null || true
    pkill -9 ovsdb-server 2>/dev/null || true
    sleep 2
    
    # Backup databases
    log_step "[3/10] Backing up OVN databases..."
    local backup_dir="/var/lib/ovn/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    cp /var/lib/ovn/*.db "$backup_dir/" 2>/dev/null || true
    log_info "Backup saved to: $backup_dir"
    
    # Remove OVN databases
    log_step "[4/10] Removing OVN databases..."
    rm -f /var/lib/ovn/ovnnb_db.db
    rm -f /var/lib/ovn/ovnsb_db.db
    rm -f /var/lib/ovn/.ovnnb_db.db.~lock~
    rm -f /var/lib/ovn/.ovnsb_db.db.~lock~
    
    # Clear OVN run files
    log_step "[5/10] Clearing OVN runtime files..."
    rm -f /var/run/ovn/*.sock
    rm -f /var/run/ovn/*.ctl
    rm -f /var/run/ovn/*.pid
    
    # Clear OVN state from OVS
    log_step "[6/10] Clearing OVN state from OVS..."
    ovs-vsctl --no-wait remove open_vswitch . external-ids ovn-encap-type 2>/dev/null || true
    ovs-vsctl --no-wait remove open_vswitch . external-ids ovn-encap-ip 2>/dev/null || true
    ovs-vsctl --no-wait remove open_vswitch . external-ids ovn-remote 2>/dev/null || true
    ovs-vsctl --no-wait remove open_vswitch . external-ids ovn-bridge 2>/dev/null || true
    ovs-vsctl --no-wait remove open_vswitch . external-ids ovn-cms-options 2>/dev/null || true
    
    # Reset br-int
    log_step "[7/10] Resetting br-int flow tables..."
    ovs-ofctl del-flows br-int 2>/dev/null || true
    
    # Truncate huge log file
    log_step "[8/10] Truncating OVN controller log..."
    if [[ -f /var/log/ovn/ovn-controller.log ]]; then
        local log_size=$(stat -f%z /var/log/ovn/ovn-controller.log 2>/dev/null || stat -c%s /var/log/ovn/ovn-controller.log)
        if [[ $log_size -gt 100000000 ]]; then
            log_info "Log file is $(($log_size / 1024 / 1024))MB, truncating..."
            > /var/log/ovn/ovn-controller.log
        fi
    fi
    
    # Start OVN Central and initialize databases
    log_step "[9/10] Starting OVN Central and initializing databases..."
    systemctl start ovn-central
    sleep 3
    
    # Verify databases were created
    if [[ ! -f /var/lib/ovn/ovnnb_db.db ]] || [[ ! -f /var/lib/ovn/ovnsb_db.db ]]; then
        log_error "OVN databases not created!"
        return 1
    fi
    log_info "OVN databases recreated"
    
    # Set socket permissions
    chmod 666 /var/run/ovn/ovnnb_db.sock 2>/dev/null || true
    chmod 666 /var/run/ovn/ovnsb_db.sock 2>/dev/null || true
    
    # Configure OVS for OVN
    log_step "[10/10] Configuring OVS for OVN..."
    local controller_ip="${CONTROLLER_IP:-192.168.2.9}"
    local system_id="$(hostname)"
    
    ovs-vsctl set open . external-ids:ovn-remote="unix:/var/run/ovn/ovnsb_db.sock"
    ovs-vsctl set open . external-ids:ovn-encap-type="geneve"
    ovs-vsctl set open . external-ids:ovn-encap-ip="$controller_ip"
    ovs-vsctl set open . external-ids:system-id="$system_id"
    ovs-vsctl set open . external-ids:ovn-bridge="br-int"
    ovs-vsctl set open . external-ids:ovn-bridge-mappings="physnet1:br-provider"
    ovs-vsctl set open . external-ids:ovn-cms-options=""
    
    log_info "OVS configured with:"
    ovs-vsctl get open . external-ids
    
    # Start OVN host/controller
    systemctl start ovn-host
    sleep 3
    
    # Restart Neutron services to recreate OVN resources
    log_step "Restarting Neutron services..."
    systemctl restart neutron-rpc-server
    systemctl restart neutron-api
    systemctl restart neutron-ovn-metadata-agent
    sleep 5
    
    print_header "Nuclear Reset Complete"
    echo "Neutron will now recreate the OVN resources (networks, ports, etc.)"
    echo ""
    echo "Run './28-ovn-version-fix.sh verify' to check the status"
}

#===============================================================================
# OPTION C: FORCE COMPATIBILITY
#===============================================================================

force_compatibility() {
    print_header "Attempting to Force OVN Compatibility"
    
    log_warn "This attempts to work around version incompatibility"
    log_warn "Results may be unpredictable - downgrade is more reliable"
    echo ""
    
    # Stop services
    log_step "Stopping OVN controller..."
    systemctl stop ovn-host
    
    # Clear all OVN state
    log_step "Clearing OVN controller state..."
    ovs-vsctl --no-wait remove open_vswitch . external-ids ovn-encap-type 2>/dev/null || true
    ovs-vsctl --no-wait remove open_vswitch . external-ids ovn-encap-ip 2>/dev/null || true
    
    # Delete all chassis
    log_step "Deleting all chassis registrations..."
    for chassis in $(ovn-sbctl list Chassis | grep "name" | awk '{print $3}' | tr -d '"'); do
        ovn-sbctl chassis-del "$chassis" 2>/dev/null || true
    done
    
    # Clear Chassis_Private
    for chassis in $(ovn-sbctl list Chassis_Private | grep "name" | awk '{print $3}' | tr -d '"'); do
        ovn-sbctl destroy Chassis_Private "$chassis" 2>/dev/null || true
    done
    
    # Reset br-int
    log_step "Resetting br-int..."
    ovs-ofctl del-flows br-int 2>/dev/null || true
    
    # Reconfigure
    local controller_ip="${CONTROLLER_IP:-192.168.2.9}"
    
    log_step "Reconfiguring OVS external-ids..."
    ovs-vsctl set open . external-ids:ovn-remote="unix:/var/run/ovn/ovnsb_db.sock"
    ovs-vsctl set open . external-ids:ovn-encap-type="geneve"
    ovs-vsctl set open . external-ids:ovn-encap-ip="$controller_ip"
    ovs-vsctl set open . external-ids:system-id="$(hostname)"
    ovs-vsctl set open . external-ids:ovn-bridge="br-int"
    ovs-vsctl set open . external-ids:ovn-bridge-mappings="physnet1:br-provider"
    ovs-vsctl set open . external-ids:ovn-monitor-all="true"
    
    # Restart services
    log_step "Restarting OVN controller..."
    systemctl restart ovn-host
    sleep 5
    
    # Check if it's working
    log_step "Checking controller status..."
    local flows=$(ovs-ofctl dump-flows br-int 2>/dev/null | wc -l)
    local chassis_cfg=$(ovn-sbctl list Chassis 2>/dev/null | grep "nb_cfg" | awk '{print $3}')
    
    if [[ "$flows" -gt 0 ]] && [[ "$chassis_cfg" != "0" ]]; then
        log_info "Controller appears to be working!"
        echo "  br-int flows: $flows"
        echo "  Chassis nb_cfg: $chassis_cfg"
    else
        log_warn "Controller still not working properly"
        echo "  br-int flows: $flows"
        echo "  Chassis nb_cfg: $chassis_cfg"
        echo ""
        echo "Recommendation: Use Option A (downgrade) or Option B (nuclear reset)"
    fi
}

#===============================================================================
# VERIFICATION
#===============================================================================

verify_ovn() {
    print_header "OVN Status Verification"
    
    load_credentials
    
    echo "=== Service Status ==="
    for svc in ovn-central ovn-host openvswitch-switch neutron-api neutron-rpc-server neutron-ovn-metadata-agent; do
        if systemctl is-active --quiet $svc 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $svc: running"
        else
            echo -e "  ${RED}✗${NC} $svc: not running"
        fi
    done
    
    echo ""
    echo "=== OVN Agent Status ==="
    openstack network agent list 2>/dev/null || echo "  Cannot query agents"
    
    echo ""
    echo "=== Chassis Status ==="
    echo "  Chassis:"
    ovn-sbctl list Chassis | grep -E "name|hostname|nb_cfg" | sed 's/^/    /'
    echo ""
    echo "  Chassis_Private:"
    ovn-sbctl list Chassis_Private | grep -E "name|nb_cfg" | sed 's/^/    /'
    echo ""
    echo "  Global nb_cfg: $(ovn-sbctl get SB_Global . nb_cfg)"
    
    echo ""
    echo "=== OpenFlow Rules ==="
    local br_int_flows=$(ovs-ofctl dump-flows br-int 2>/dev/null | wc -l)
    local br_provider_flows=$(ovs-ofctl dump-flows br-provider 2>/dev/null | wc -l)
    echo "  br-int flows: $br_int_flows"
    echo "  br-provider flows: $br_provider_flows"
    
    echo ""
    echo "=== Port Bindings ==="
    ovn-sbctl list Port_Binding | grep -E "logical_port|chassis|up" | head -15 | sed 's/^/  /'
    
    echo ""
    echo "=== OVN Logical Topology ==="
    ovn-nbctl show | sed 's/^/  /'
    
    echo ""
    echo "=== Network Connectivity ==="
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} External connectivity OK"
    else
        echo -e "  ${RED}✗${NC} No external connectivity"
    fi
    
    # Summary
    echo ""
    print_header "Summary"
    
    local chassis_nb_cfg=$(ovn-sbctl list Chassis | grep "nb_cfg" | awk '{print $3}' | head -1)
    local global_nb_cfg=$(ovn-sbctl get SB_Global . nb_cfg)
    
    if [[ "$br_int_flows" -gt 10 ]] && [[ "$chassis_nb_cfg" == "$global_nb_cfg" ]]; then
        echo -e "${GREEN}OVN appears to be working correctly!${NC}"
        echo ""
        echo "Ready for VM smoke test:"
        echo "  ./27c-smoketest.sh"
    else
        echo -e "${RED}OVN is still not working properly${NC}"
        echo ""
        echo "Issues detected:"
        [[ "$br_int_flows" -lt 10 ]] && echo "  - br-int has only $br_int_flows flows (should be >50)"
        [[ "$chassis_nb_cfg" != "$global_nb_cfg" ]] && echo "  - Chassis nb_cfg ($chassis_nb_cfg) != global ($global_nb_cfg)"
        echo ""
        echo "Recommendations:"
        echo "  1. Check OVN versions: dpkg -l | grep ovn"
        echo "  2. Check logs: journalctl -u ovn-controller -n 50"
        echo "  3. Try nuclear reset: $0 nuclear"
        echo "  4. Consider downgrading OVN: $0 downgrade"
    fi
}

#===============================================================================
# MAIN
#===============================================================================

usage() {
    echo "Usage: $0 {diagnose|downgrade|nuclear|force|verify|help}"
    echo ""
    echo "Commands:"
    echo "  diagnose   - Diagnose OVN version and compatibility issues"
    echo "  downgrade  - Downgrade OVN to Debian Bookworm compatible version"
    echo "  nuclear    - Complete reset with database recreation"
    echo "  force      - Attempt to force compatibility (less reliable)"
    echo "  verify     - Verify OVN status after fix"
    echo "  help       - Show this help"
    echo ""
    echo "Recommended workflow:"
    echo "  1. Run '$0 diagnose' to confirm the issue"
    echo "  2. Run '$0 downgrade' to get compatible OVN version"
    echo "  3. Run '$0 nuclear' to reinitialize databases"
    echo "  4. Run '$0 verify' to confirm fix"
}

main() {
    [[ $EUID -ne 0 ]] && { log_error "This script must be run as root (sudo)"; exit 1; }
    
    case "${1:-help}" in
        diagnose)
            run_diagnosis
            ;;
        downgrade)
            check_bookworm_packages
            downgrade_ovn_to_bookworm
            ;;
        nuclear)
            nuclear_reset
            ;;
        force)
            force_compatibility
            ;;
        verify)
            verify_ovn
            ;;
        help|*)
            usage
            ;;
    esac
}

main "$@"
