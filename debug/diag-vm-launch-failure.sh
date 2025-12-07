#!/bin/bash
###############################################################################
# diag-vm-launch-failure.sh
# Diagnostic script for "No valid host was found" errors
#
# This script collects all relevant information to diagnose why Nova scheduler
# cannot find a valid host for VM placement.
###############################################################################

echo "=========================================="
echo "=== VM Launch Failure Diagnostics ==="
echo "=========================================="
echo "Timestamp: $(date)"
echo ""

# Source credentials
source ~/admin-openrc 2>/dev/null || true

echo "============================================"
echo "1. PLACEMENT - Resource Provider Status"
echo "============================================"
echo ""
echo "--- Resource Providers ---"
openstack resource provider list

PROVIDER_UUID=$(openstack resource provider list -f value -c uuid | head -1)
echo ""
echo "--- Provider UUID: $PROVIDER_UUID ---"

echo ""
echo "--- Resource Provider Inventory ---"
openstack resource provider inventory list $PROVIDER_UUID 2>/dev/null || echo "ERROR: Could not get inventory"

echo ""
echo "--- Resource Provider Traits ---"
openstack resource provider trait list $PROVIDER_UUID 2>/dev/null | head -20 || echo "ERROR: Could not get traits"

echo ""
echo "--- Resource Provider Usages ---"
openstack resource provider usage show $PROVIDER_UUID 2>/dev/null || echo "ERROR: Could not get usage"

echo ""
echo "============================================"
echo "2. NOVA - Scheduler Configuration"
echo "============================================"
echo ""
echo "--- Enabled Filters ---"
sudo grep -E "^enabled_filters|^available_filters|driver.*filter" /etc/nova/nova.conf 2>/dev/null || echo "Using defaults"

echo ""
echo "--- Scheduler Driver ---"
sudo grep -E "^\[scheduler\]" -A10 /etc/nova/nova.conf 2>/dev/null | head -15

echo ""
echo "============================================"
echo "3. NOVA - Compute Node Status"
echo "============================================"
echo ""
echo "--- Hypervisor List ---"
openstack hypervisor list

echo ""
echo "--- Hypervisor Details ---"
openstack hypervisor show osctl1 2>/dev/null || echo "ERROR: Could not get hypervisor details"

echo ""
echo "--- Nova Compute Services ---"
openstack compute service list

echo ""
echo "============================================"
echo "4. NOVA - Database vs Placement UUID Check"
echo "============================================"
echo ""
echo "--- Nova DB compute_nodes UUID ---"
sudo mysql -e "SELECT uuid, hypervisor_hostname, deleted FROM nova.compute_nodes;" 2>/dev/null

echo ""
echo "--- Placement resource provider UUID ---"
openstack resource provider list -f value

echo ""
echo "============================================"
echo "5. LOG ANALYSIS - Recent Errors"
echo "============================================"
echo ""
echo "--- Nova Scheduler Log (last 30 lines with filter/error) ---"
sudo tail -100 /var/log/nova/nova-scheduler.log 2>/dev/null | grep -iE "filter|error|reject|fail|host" | tail -30

echo ""
echo "--- Nova Compute Log (last 20 error lines) ---"
sudo tail -100 /var/log/nova/nova-compute.log 2>/dev/null | grep -iE "error|fail|ceph|rbd|placement" | tail -20

echo ""
echo "--- Nova Conductor Log (last 20 error lines) ---"
sudo tail -100 /var/log/nova/nova-conductor.log 2>/dev/null | grep -iE "error|fail|novalidhost" | tail -20

echo ""
echo "============================================"
echo "6. CEPH - Storage Backend Status"
echo "============================================"
echo ""
echo "--- Ceph Health ---"
sudo ceph health 2>/dev/null

echo ""
echo "--- Ceph Pool Stats ---"
sudo ceph df 2>/dev/null

echo ""
echo "--- Nova Ceph Connectivity Test ---"
echo "Testing as nova user..."
sudo -u nova ceph df --id cinder --conf /etc/ceph/ceph.conf --keyring /etc/ceph/ceph.client.cinder.keyring 2>&1 | head -5 || echo "FAILED: Nova cannot connect to Ceph"

echo ""
echo "============================================"
echo "7. FLAVOR - Resource Requirements"
echo "============================================"
echo ""
echo "--- m1.tiny Flavor ---"
openstack flavor show m1.tiny 2>/dev/null || echo "ERROR: m1.tiny not found"

echo ""
echo "============================================"
echo "8. NETWORK - Provider Network Status"
echo "============================================"
echo ""
echo "--- Networks ---"
openstack network list

echo ""
echo "--- Neutron Agents ---"
openstack network agent list

echo ""
echo "============================================"
echo "9. SERVICE STATUS - All OpenStack Services"
echo "============================================"
echo ""
echo "--- SystemD Service Status ---"
for svc in nova-api nova-scheduler nova-conductor nova-compute neutron-server neutron-openvswitch-agent neutron-dhcp-agent neutron-metadata-agent neutron-l3-agent; do
    status=$(systemctl is-active $svc 2>/dev/null || echo "not-found")
    printf "%-30s %s\n" "$svc:" "$status"
done

echo ""
echo "============================================"
echo "10. QUICK FIX SUGGESTIONS"
echo "============================================"
echo ""
echo "If UUID mismatch found above, run:"
echo "  sudo mysql -e \"UPDATE nova.compute_nodes SET uuid='<PLACEMENT_UUID>' WHERE hypervisor_hostname='osctl1';\""
echo "  sudo systemctl restart nova-compute"
echo ""
echo "If Ceph connectivity failed, check:"
echo "  - /etc/ceph/ceph.client.cinder.keyring permissions"
echo "  - nova user in cinder group: groups nova"
echo ""
echo "If scheduler filters rejecting, check:"
echo "  - /etc/nova/nova.conf [scheduler] section"
echo "  - Resource provider inventory vs flavor requirements"
echo ""
echo "=========================================="
echo "=== Diagnostics Complete ==="
echo "=========================================="
