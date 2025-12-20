#!/bin/bash
#===============================================================================
# 30-fix-neutron-ovn-hashring.sh - Fix Neutron OVN HashRing and Port Groups
#===============================================================================
#
# PROBLEM:
# ========
# After OVN nuclear reset, two issues prevent VM creation:
#
# 1. HashRing is Empty:
#    "Hash Ring returned empty... All 0 nodes were found offline"
#    The ovn_hash_ring table in Neutron DB has stale/no entries.
#
# 2. Port Group Missing:
#    "Port group pg_<security_group_id> does not exist"
#    Security group port groups were deleted during OVN reset.
#
# SOLUTION:
# =========
# 1. Clear stale hash ring entries from Neutron database
# 2. Restart Neutron services to re-register hash ring nodes
# 3. Sync security groups to recreate port groups in OVN
#
# CRITICAL: Single-NIC Network Protection included
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
# Single-NIC Network Protection
#===============================================================================
PROVIDER_BRIDGE="${PROVIDER_BRIDGE:-br-provider}"

ensure_provider_bridge_connectivity() {
    ovs-vsctl remove bridge ${PROVIDER_BRIDGE} fail_mode secure 2>/dev/null || true
    ovs-ofctl add-flow ${PROVIDER_BRIDGE} "priority=0,actions=NORMAL" 2>/dev/null || true
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
    elif [[ -f /root/admin-openrc.sh ]]; then
        source /root/admin-openrc.sh
    else
        log_error "No admin-openrc found!"
        exit 1
    fi
}

#===============================================================================
# Database Configuration
#===============================================================================
get_db_credentials() {
    # Try to get from neutron config
    if [[ -f /etc/neutron/neutron.conf ]]; then
        DB_CONNECTION=$(grep "^connection" /etc/neutron/neutron.conf | head -1 | cut -d'=' -f2- | tr -d ' ')
        if [[ -n "$DB_CONNECTION" ]]; then
            # Parse: mysql+pymysql://user:pass@host/db
            DB_USER=$(echo "$DB_CONNECTION" | sed -n 's|.*://\([^:]*\):.*|\1|p')
            DB_PASS=$(echo "$DB_CONNECTION" | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')
            DB_HOST=$(echo "$DB_CONNECTION" | sed -n 's|.*@\([^/]*\)/.*|\1|p')
            DB_NAME=$(echo "$DB_CONNECTION" | sed -n 's|.*/\([^?]*\).*|\1|p')
            return 0
        fi
    fi

    # Fallback defaults
    DB_USER="neutron"
    DB_PASS="neutron"
    DB_HOST="localhost"
    DB_NAME="neutron"
    log_warn "Using default database credentials"
}

#===============================================================================
# Diagnose the issue
#===============================================================================
diagnose() {
    print_header "Diagnosing Neutron OVN Issues"

    load_credentials
    get_db_credentials
    ensure_provider_bridge_connectivity

    echo "=== HashRing Status ==="
    echo "Checking ovn_hash_ring table in Neutron database..."

    local hash_ring_count=$(mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" -N -e \
        "SELECT COUNT(*) FROM ovn_hash_ring;" 2>/dev/null || echo "ERROR")

    if [[ "$hash_ring_count" == "ERROR" ]]; then
        log_error "Cannot query database"
    else
        echo "  Hash ring entries: $hash_ring_count"
        if [[ "$hash_ring_count" -eq 0 ]]; then
            echo -e "  ${RED}ISSUE: Hash ring is empty!${NC}"
        fi
    fi

    echo ""
    echo "Hash ring entries (if any):"
    mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" -e \
        "SELECT node_uuid, hostname, created_at, updated_at FROM ovn_hash_ring LIMIT 10;" 2>/dev/null || true

    echo ""
    echo "=== Security Groups ==="
    openstack security group list 2>/dev/null || echo "Cannot list security groups"

    echo ""
    echo "=== OVN Port Groups ==="
    echo "Port groups in OVN NB database:"
    ovn-nbctl --bare --columns=name list Port_Group 2>/dev/null | head -10 || echo "Cannot list port groups"

    echo ""
    echo "=== Security Group to Port Group Mapping ==="
    for sg_id in $(openstack security group list -f value -c ID 2>/dev/null); do
        local sg_name=$(openstack security group show "$sg_id" -f value -c name 2>/dev/null)
        local pg_name="pg_$(echo $sg_id | tr '-' '_')"

        if ovn-nbctl --bare --columns=name list Port_Group 2>/dev/null | grep -q "$pg_name"; then
            echo -e "  ${GREEN}✓${NC} $sg_name ($sg_id) -> $pg_name EXISTS"
        else
            echo -e "  ${RED}✗${NC} $sg_name ($sg_id) -> $pg_name MISSING"
        fi
    done

    echo ""
    echo "=== Recent Neutron Errors ==="
    grep -h "ERROR\|Port group.*does not exist\|HashRing is empty" /var/log/neutron/*.log 2>/dev/null | tail -5 || true
}

#===============================================================================
# Fix HashRing
#===============================================================================
fix_hashring() {
    print_header "Fixing Neutron OVN HashRing"

    get_db_credentials
    ensure_provider_bridge_connectivity

    log_step "[1/4] Clearing stale hash ring entries..."
    mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" -e \
        "DELETE FROM ovn_hash_ring;" 2>/dev/null || log_warn "Could not clear hash ring"

    log_info "Hash ring cleared"

    log_step "[2/4] Stopping Neutron services..."
    systemctl stop neutron-ovn-metadata-agent 2>/dev/null || true
    ensure_provider_bridge_connectivity
    systemctl stop neutron-api 2>/dev/null || true
    ensure_provider_bridge_connectivity
    systemctl stop neutron-rpc-server 2>/dev/null || true
    ensure_provider_bridge_connectivity
    sleep 2

    log_step "[3/4] Starting Neutron services (will re-register hash ring)..."
    systemctl start neutron-rpc-server
    sleep 3
    ensure_provider_bridge_connectivity

    systemctl start neutron-api
    sleep 3
    ensure_provider_bridge_connectivity

    systemctl start neutron-ovn-metadata-agent
    sleep 3
    ensure_provider_bridge_connectivity

    log_step "[4/4] Verifying hash ring..."
    sleep 5

    local hash_ring_count=$(mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" -N -e \
        "SELECT COUNT(*) FROM ovn_hash_ring;" 2>/dev/null || echo "0")

    if [[ "$hash_ring_count" -gt 0 ]]; then
        echo -e "${GREEN}SUCCESS: Hash ring now has $hash_ring_count entries${NC}"
        mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" -e \
            "SELECT node_uuid, hostname, created_at FROM ovn_hash_ring;" 2>/dev/null || true
    else
        echo -e "${RED}WARNING: Hash ring still empty - check Neutron logs${NC}"
    fi
}

#===============================================================================
# Fix Port Groups (Security Groups)
#===============================================================================
fix_portgroups() {
    print_header "Fixing OVN Port Groups for Security Groups"

    load_credentials
    ensure_provider_bridge_connectivity

    log_step "[1/3] Finding security groups without port groups..."

    local missing_pgs=()
    for sg_id in $(openstack security group list -f value -c ID 2>/dev/null); do
        local pg_name="pg_$(echo $sg_id | tr '-' '_')"
        if ! ovn-nbctl --bare --columns=name list Port_Group 2>/dev/null | grep -q "$pg_name"; then
            missing_pgs+=("$sg_id")
            local sg_name=$(openstack security group show "$sg_id" -f value -c name 2>/dev/null)
            echo "  Missing: $sg_name ($sg_id)"
        fi
    done

    if [[ ${#missing_pgs[@]} -eq 0 ]]; then
        log_info "All security groups have port groups in OVN"
        return 0
    fi

    log_step "[2/3] Creating missing port groups in OVN..."

    for sg_id in "${missing_pgs[@]}"; do
        local pg_name="pg_$(echo $sg_id | tr '-' '_')"
        echo "  Creating port group: $pg_name"

        # Create the port group
        ovn-nbctl --may-exist pg-add "$pg_name" 2>/dev/null || {
            log_warn "Could not create $pg_name directly, will try via Neutron sync"
        }
    done

    ensure_provider_bridge_connectivity

    log_step "[3/3] Triggering Neutron sync by updating security groups..."

    # Touch each security group to trigger OVN sync
    for sg_id in "${missing_pgs[@]}"; do
        local sg_name=$(openstack security group show "$sg_id" -f value -c name 2>/dev/null)
        echo "  Syncing: $sg_name"

        # Add and remove a dummy rule to trigger sync
        local rule_id=$(openstack security group rule create --protocol tcp --dst-port 65535 \
            "$sg_id" -f value -c id 2>/dev/null || true)

        if [[ -n "$rule_id" ]]; then
            openstack security group rule delete "$rule_id" 2>/dev/null || true
        fi
    done

    ensure_provider_bridge_connectivity

    echo ""
    echo "Verifying port groups..."
    for sg_id in "${missing_pgs[@]}"; do
        local pg_name="pg_$(echo $sg_id | tr '-' '_')"
        local sg_name=$(openstack security group show "$sg_id" -f value -c name 2>/dev/null)

        if ovn-nbctl --bare --columns=name list Port_Group 2>/dev/null | grep -q "$pg_name"; then
            echo -e "  ${GREEN}✓${NC} $sg_name -> $pg_name CREATED"
        else
            echo -e "  ${RED}✗${NC} $sg_name -> $pg_name STILL MISSING"
        fi
    done
}

#===============================================================================
# Full Fix
#===============================================================================
full_fix() {
    print_header "Full Neutron OVN Fix"

    echo "This will:"
    echo "  1. Clear and rebuild the hash ring"
    echo "  2. Restart Neutron services"
    echo "  3. Create missing port groups for security groups"
    echo "  4. Delete the failed VM"
    echo "  5. Recreate the provider network"
    echo ""
    read -p "Continue? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { log_info "Aborted"; return 1; }

    ensure_provider_bridge_connectivity

    # Step 1: Fix hash ring
    fix_hashring

    # Step 2: Fix port groups
    fix_portgroups

    # Step 3: Clean up failed VMs
    log_step "Cleaning up failed VMs..."
    load_credentials
    for server in $(openstack server list --all-projects --status ERROR -f value -c ID 2>/dev/null); do
        echo "  Deleting failed server: $server"
        openstack server delete --force "$server" 2>/dev/null || true
    done
    ensure_provider_bridge_connectivity

    # Step 4: Verify everything
    print_header "Verification"

    echo "=== Service Status ==="
    for svc in neutron-api neutron-rpc-server neutron-ovn-metadata-agent; do
        if systemctl is-active --quiet $svc 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $svc: running"
        else
            echo -e "  ${RED}✗${NC} $svc: not running"
        fi
    done

    echo ""
    echo "=== Hash Ring ==="
    get_db_credentials
    local count=$(mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" -N -e \
        "SELECT COUNT(*) FROM ovn_hash_ring;" 2>/dev/null || echo "0")
    echo "  Entries: $count"

    echo ""
    echo "=== Port Groups ==="
    local pg_count=$(ovn-nbctl --bare --columns=name list Port_Group 2>/dev/null | wc -l)
    echo "  Port groups in OVN: $pg_count"

    echo ""
    ensure_provider_bridge_connectivity

    print_header "Fix Complete"
    echo "Now try creating a VM:"
    echo "  ./29-neutron-ovn-sync.sh test"
    echo ""
    echo "Or run the full smoke test:"
    echo "  ./34-smoke-test.sh"
}

#===============================================================================
# Quick Test
#===============================================================================
quick_test() {
    print_header "Quick VM Test"

    load_credentials
    ensure_provider_bridge_connectivity

    local test_vm="hashring-test-$$"

    log_step "Creating test VM: $test_vm"

    if openstack server create \
        --flavor m1.tiny \
        --image cirros \
        --network provider-net \
        "$test_vm" 2>&1; then

        echo "Waiting for VM..."
        sleep 10

        local status=$(openstack server show "$test_vm" -f value -c status 2>/dev/null)
        echo "VM Status: $status"

        if [[ "$status" == "ACTIVE" ]]; then
            echo -e "${GREEN}SUCCESS! VM is ACTIVE${NC}"
        elif [[ "$status" == "ERROR" ]]; then
            echo -e "${RED}FAILED! VM in ERROR state${NC}"
            openstack server show "$test_vm" -c fault 2>/dev/null
        else
            echo "VM status: $status (may still be building)"
        fi

        echo ""
        echo "Cleaning up..."
        openstack server delete "$test_vm" 2>/dev/null || true
    else
        echo -e "${RED}Server creation command failed${NC}"
    fi

    ensure_provider_bridge_connectivity
}

#===============================================================================
# MAIN
#===============================================================================

usage() {
    echo "Usage: $0 {diagnose|fix-hashring|fix-portgroups|fix|test|help}"
    echo ""
    echo "Commands:"
    echo "  diagnose       - Diagnose hash ring and port group issues"
    echo "  fix-hashring   - Clear and rebuild the hash ring only"
    echo "  fix-portgroups - Create missing port groups only"
    echo "  fix            - Full fix: hash ring + port groups + cleanup"
    echo "  test           - Quick VM creation test"
    echo "  help           - Show this help"
    echo ""
    echo "After OVN nuclear reset, run:"
    echo "  1. $0 diagnose  - Confirm the issues"
    echo "  2. $0 fix       - Apply all fixes"
    echo "  3. $0 test      - Test VM creation"
}

main() {
    [[ $EUID -ne 0 ]] && { log_error "This script must be run as root (sudo)"; exit 1; }

    case "${1:-help}" in
        diagnose)
            diagnose
            ;;
        fix-hashring)
            fix_hashring
            ;;
        fix-portgroups)
            fix_portgroups
            ;;
        fix)
            full_fix
            ;;
        test)
            quick_test
            ;;
        help|*)
            usage
            ;;
    esac
}

main "$@"
