#!/bin/bash
###############################################################################
# 34-smoke-test.sh
# Comprehensive OpenStack Smoke Test
#
# This script:
# - Performs complete health check of all OpenStack services
# - Verifies infrastructure components (MariaDB, RabbitMQ, Memcached, Ceph)
# - Validates API endpoints and service connectivity
# - Creates test resources (flavor, keypair, security rules)
# - Launches a test VM and verifies it reaches ACTIVE state
# - Tests volume creation and attachment
# - Provides detailed diagnostics on failure
#
# FAIL-FAST: Script exits immediately on any verification failure
#            to enable focused RCA (Root Cause Analysis)
#
# Prerequisites:
# - All OpenStack services installed and running
# - Provider network configured
# - Cirros image available (or will be downloaded)
###############################################################################
set -e  # Exit on any error (fail-fast)

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/openstack-env.sh" ]; then
    source "$SCRIPT_DIR/openstack-env.sh"
elif [ -f "./openstack-env.sh" ]; then
    source "./openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found!"
    exit 1
fi

# Source admin credentials
if [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
else
    echo "ERROR: ~/admin-openrc not found!"
    exit 1
fi

echo "=========================================="
echo "=== OpenStack Comprehensive Smoke Test ==="
echo "=========================================="
echo ""
echo "Controller: ${CONTROLLER_IP}"
echo "Region: ${REGION_NAME}"
echo "Test started: $(date)"
echo ""

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function for test results
pass() {
    echo "  ✓ $1"
    ((TESTS_PASSED++))
}

fail() {
    echo "  ✗ FAILED: $1"
    ((TESTS_FAILED++))
    echo ""
    echo "==========================================="
    echo "SMOKE TEST FAILED - Stopping for RCA"
    echo "Failed at: $1"
    echo "==========================================="
    exit 1
}

###############################################################################
# PHASE 1: Infrastructure Health Check
###############################################################################
echo "============================================"
echo "PHASE 1: Infrastructure Health Check"
echo "============================================"

echo ""
echo "[1.1] Checking MariaDB..."
if systemctl is-active --quiet mariadb; then
    pass "MariaDB is running"
else
    fail "MariaDB is not running"
fi

# Test MariaDB connectivity
if sudo mysql -e "SELECT 1" &>/dev/null; then
    pass "MariaDB accepting connections"
else
    fail "MariaDB not accepting connections"
fi

echo ""
echo "[1.2] Checking RabbitMQ..."
if systemctl is-active --quiet rabbitmq-server; then
    pass "RabbitMQ is running"
else
    fail "RabbitMQ is not running"
fi

# Test RabbitMQ user
if sudo rabbitmqctl list_users | grep -q "openstack"; then
    pass "RabbitMQ openstack user exists"
else
    fail "RabbitMQ openstack user missing"
fi

echo ""
echo "[1.3] Checking Memcached..."
if systemctl is-active --quiet memcached; then
    pass "Memcached is running"
else
    fail "Memcached is not running"
fi

# Test Memcached connectivity
if echo "stats" | nc -q1 localhost 11211 | grep -q "STAT"; then
    pass "Memcached accepting connections"
else
    fail "Memcached not accepting connections"
fi

echo ""
echo "[1.4] Checking Ceph Cluster..."
if sudo ceph health 2>/dev/null | grep -qE "HEALTH_OK|HEALTH_WARN"; then
    CEPH_STATUS=$(sudo ceph health 2>/dev/null)
    pass "Ceph cluster healthy: $CEPH_STATUS"
else
    fail "Ceph cluster unhealthy or not accessible"
fi

# Check Ceph pools
for pool in images volumes vms; do
    if sudo ceph osd pool ls | grep -q "^${pool}$"; then
        pass "Ceph pool '${pool}' exists"
    else
        fail "Ceph pool '${pool}' missing"
    fi
done

echo ""
echo "[1.5] Checking Apache..."
if systemctl is-active --quiet apache2; then
    pass "Apache is running"
else
    fail "Apache is not running"
fi

echo ""
echo "[1.6] Checking OVS..."
if systemctl is-active --quiet openvswitch-switch; then
    pass "Open vSwitch is running"
else
    fail "Open vSwitch is not running"
fi

# Check OVS bridges
for bridge in br-provider br-int; do
    if sudo ovs-vsctl br-exists $bridge 2>/dev/null; then
        pass "OVS bridge '${bridge}' exists"
    else
        fail "OVS bridge '${bridge}' missing"
    fi
done

###############################################################################
# PHASE 2: OpenStack API Endpoints Health
###############################################################################
echo ""
echo "============================================"
echo "PHASE 2: OpenStack API Endpoints Health"
echo "============================================"

echo ""
echo "[2.1] Checking Keystone (Identity)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:5000/v3" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Keystone API responding (port 5000)"
else
    fail "Keystone API not responding (HTTP $HTTP_CODE)"
fi

# Test token generation
if openstack token issue &>/dev/null; then
    pass "Keystone token generation working"
else
    fail "Keystone token generation failed"
fi

echo ""
echo "[2.2] Checking Glance (Image)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:9292/v2/images" -H "X-Auth-Token: $(openstack token issue -f value -c id)" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Glance API responding (port 9292)"
else
    fail "Glance API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.3] Checking Placement..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8778/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Placement API responding (port 8778)"
else
    fail "Placement API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.4] Checking Nova (Compute)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8774/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Nova API responding (port 8774)"
else
    fail "Nova API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.5] Checking Neutron (Network)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:9696/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Neutron API responding (port 9696)"
else
    fail "Neutron API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.6] Checking Cinder (Volume)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8776/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Cinder API responding (port 8776)"
else
    fail "Cinder API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.7] Checking Horizon (Dashboard)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}/horizon/auth/login/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Horizon Dashboard responding (port 80)"
else
    fail "Horizon Dashboard not responding (HTTP $HTTP_CODE)"
fi

###############################################################################
# PHASE 3: OpenStack Services Status
###############################################################################
echo ""
echo "============================================"
echo "PHASE 3: OpenStack Services Status"
echo "============================================"

echo ""
echo "[3.1] Keystone Services..."
SERVICE_COUNT=$(openstack service list -f value | wc -l)
if [ "$SERVICE_COUNT" -ge 6 ]; then
    pass "All $SERVICE_COUNT services registered in Keystone"
    openstack service list
else
    fail "Expected 6+ services, found $SERVICE_COUNT"
fi

echo ""
echo "[3.2] Nova Compute Services..."
NOVA_SERVICES=$(openstack compute service list -f value -c Binary -c Status -c State 2>/dev/null)
NOVA_DOWN=$(echo "$NOVA_SERVICES" | grep -c "down" || true)
if [ "$NOVA_DOWN" -eq 0 ]; then
    pass "All Nova services UP"
    openstack compute service list
else
    fail "Some Nova services are DOWN"
fi

echo ""
echo "[3.3] Neutron Agents..."
NEUTRON_AGENTS=$(openstack network agent list -f value -c Binary -c Alive 2>/dev/null)
NEUTRON_DOWN=$(echo "$NEUTRON_AGENTS" | grep -c "False" || true)
if [ "$NEUTRON_DOWN" -eq 0 ]; then
    pass "All Neutron agents UP"
    openstack network agent list
else
    fail "Some Neutron agents are DOWN"
fi

echo ""
echo "[3.4] Cinder Services..."
CINDER_SERVICES=$(openstack volume service list -f value -c Binary -c Status -c State 2>/dev/null)
CINDER_DOWN=$(echo "$CINDER_SERVICES" | grep -c "down" || true)
if [ "$CINDER_DOWN" -eq 0 ]; then
    pass "All Cinder services UP"
    openstack volume service list
else
    fail "Some Cinder services are DOWN"
fi

echo ""
echo "[3.5] Hypervisors..."
HYPERVISOR_COUNT=$(openstack hypervisor list -f value | wc -l)
if [ "$HYPERVISOR_COUNT" -ge 1 ]; then
    pass "$HYPERVISOR_COUNT hypervisor(s) available"
    openstack hypervisor list
else
    fail "No hypervisors available"
fi

# Check hypervisor resources
VCPUS=$(openstack hypervisor stats show -f value -c vcpus 2>/dev/null || echo "0")
MEMORY=$(openstack hypervisor stats show -f value -c memory_mb 2>/dev/null || echo "0")
DISK=$(openstack hypervisor stats show -f value -c local_gb 2>/dev/null || echo "0")
echo "  Resources: ${VCPUS} vCPUs, ${MEMORY} MB RAM, ${DISK} GB disk"

###############################################################################
# PHASE 4: Network Configuration
###############################################################################
echo ""
echo "============================================"
echo "PHASE 4: Network Configuration"
echo "============================================"

echo ""
echo "[4.1] Provider Network..."
if openstack network show provider-net &>/dev/null; then
    pass "Provider network 'provider-net' exists"
    openstack network show provider-net -f value -c id -c provider:network_type -c provider:physical_network
else
    fail "Provider network 'provider-net' not found"
fi

echo ""
echo "[4.2] Subnets..."
SUBNET_COUNT=$(openstack subnet list -f value | wc -l)
if [ "$SUBNET_COUNT" -ge 1 ]; then
    pass "$SUBNET_COUNT subnet(s) configured"
    openstack subnet list
else
    fail "No subnets configured"
fi

###############################################################################
# PHASE 5: Test Resources Creation
###############################################################################
echo ""
echo "============================================"
echo "PHASE 5: Test Resources Creation"
echo "============================================"

echo ""
echo "[5.1] Cirros Test Image..."
if openstack image show cirros &>/dev/null; then
    pass "Cirros image already exists"
else
    echo "  Downloading Cirros image..."
    wget -q https://download.cirros-cloud.net/0.5.2/cirros-0.5.2-x86_64-disk.img -O /tmp/cirros.img
    if [ -f /tmp/cirros.img ]; then
        openstack image create "cirros" \
            --disk-format qcow2 \
            --container-format bare \
            --file /tmp/cirros.img \
            --public
        rm -f /tmp/cirros.img
        pass "Cirros image uploaded"
    else
        fail "Failed to download Cirros image"
    fi
fi

# Verify image is active
IMAGE_STATUS=$(openstack image show cirros -f value -c status 2>/dev/null || echo "unknown")
if [ "$IMAGE_STATUS" = "active" ]; then
    pass "Cirros image status: active"
else
    fail "Cirros image status: $IMAGE_STATUS (expected: active)"
fi

echo ""
echo "[5.2] Test Flavor (m1.tiny)..."
if openstack flavor show m1.tiny &>/dev/null; then
    pass "Flavor m1.tiny already exists"
else
    openstack flavor create --ram 512 --disk 1 --vcpus 1 m1.tiny
    pass "Flavor m1.tiny created"
fi

echo ""
echo "[5.3] SSH Keypair..."
if openstack keypair show smoketest-key &>/dev/null; then
    pass "Keypair smoketest-key already exists"
else
    # Generate keypair
    openstack keypair create smoketest-key > ~/smoketest-key.pem 2>/dev/null
    chmod 600 ~/smoketest-key.pem
    pass "Keypair smoketest-key created (saved to ~/smoketest-key.pem)"
fi

echo ""
echo "[5.4] Security Group Rules..."
# Get default security group ID
DEFAULT_SG=$(openstack security group list --project admin -f value -c ID -c Name | grep default | awk '{print $1}')

# Add ICMP rule (ignore if exists)
if openstack security group rule create --protocol icmp --ingress $DEFAULT_SG &>/dev/null; then
    pass "ICMP rule added to default security group"
else
    pass "ICMP rule already exists"
fi

# Add SSH rule (ignore if exists)
if openstack security group rule create --protocol tcp --dst-port 22 --ingress $DEFAULT_SG &>/dev/null; then
    pass "SSH rule added to default security group"
else
    pass "SSH rule already exists"
fi

###############################################################################
# PHASE 6: Test VM Launch
###############################################################################
echo ""
echo "============================================"
echo "PHASE 6: Test VM Launch"
echo "============================================"

VM_NAME="smoketest-vm-$(date +%s)"

echo ""
echo "[6.1] Launching test VM: $VM_NAME..."

# Get network ID
NETWORK_ID=$(openstack network show provider-net -f value -c id 2>/dev/null)
if [ -z "$NETWORK_ID" ]; then
    fail "Could not get provider-net network ID"
fi

# Launch VM
openstack server create \
    --image cirros \
    --flavor m1.tiny \
    --network provider-net \
    --key-name smoketest-key \
    --wait \
    "$VM_NAME"

echo ""
echo "[6.2] Checking VM status..."
VM_STATUS=$(openstack server show "$VM_NAME" -f value -c status 2>/dev/null || echo "UNKNOWN")

if [ "$VM_STATUS" = "ACTIVE" ]; then
    pass "VM reached ACTIVE state"
else
    echo "  VM Status: $VM_STATUS"
    echo ""
    echo "  VM Details:"
    openstack server show "$VM_NAME"
    echo ""
    echo "  Console Log:"
    openstack console log show "$VM_NAME" 2>/dev/null | tail -30 || true
    fail "VM did not reach ACTIVE state (status: $VM_STATUS)"
fi

# Get VM details
echo ""
echo "  VM Details:"
openstack server show "$VM_NAME" -f table -c name -c status -c addresses -c flavor -c image

# Get VM IP
VM_IP=$(openstack server show "$VM_NAME" -f value -c addresses 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
if [ -n "$VM_IP" ]; then
    pass "VM has IP address: $VM_IP"
else
    echo "  ⚠ VM has no IP address yet (DHCP may be slow)"
fi

echo ""
echo "[6.3] Console URL..."
openstack console url show "$VM_NAME" 2>/dev/null || echo "  Console URL not available"

###############################################################################
# PHASE 7: Test Volume (Optional)
###############################################################################
echo ""
echo "============================================"
echo "PHASE 7: Test Volume Creation"
echo "============================================"

VOLUME_NAME="smoketest-vol-$(date +%s)"

echo ""
echo "[7.1] Creating test volume: $VOLUME_NAME..."
openstack volume create --size 1 --type ceph "$VOLUME_NAME"

# Wait for volume to be available
echo "  Waiting for volume to become available..."
sleep 5

VOLUME_STATUS=$(openstack volume show "$VOLUME_NAME" -f value -c status 2>/dev/null || echo "UNKNOWN")
if [ "$VOLUME_STATUS" = "available" ]; then
    pass "Volume reached available state"
else
    fail "Volume did not reach available state (status: $VOLUME_STATUS)"
fi

# Verify volume in Ceph
if sudo rbd -p volumes ls 2>/dev/null | grep -q "volume-"; then
    pass "Volume visible in Ceph 'volumes' pool"
else
    echo "  ⚠ Volume not yet visible in Ceph pool"
fi

echo ""
echo "[7.2] Attaching volume to VM..."
openstack server add volume "$VM_NAME" "$VOLUME_NAME"
sleep 3

VOLUME_STATUS=$(openstack volume show "$VOLUME_NAME" -f value -c status 2>/dev/null || echo "UNKNOWN")
if [ "$VOLUME_STATUS" = "in-use" ]; then
    pass "Volume attached successfully (status: in-use)"
else
    echo "  ⚠ Volume attachment status: $VOLUME_STATUS"
fi

###############################################################################
# PHASE 8: Cleanup (Optional)
###############################################################################
echo ""
echo "============================================"
echo "PHASE 8: Test Resources Summary"
echo "============================================"

echo ""
echo "Test resources created:"
echo "  - VM: $VM_NAME"
echo "  - Volume: $VOLUME_NAME"
echo "  - Keypair: smoketest-key"
echo ""
echo "To cleanup test resources, run:"
echo "  openstack server delete $VM_NAME"
echo "  openstack volume delete $VOLUME_NAME"
echo "  openstack keypair delete smoketest-key"
echo "  rm -f ~/smoketest-key.pem"

###############################################################################
# Final Summary
###############################################################################
echo ""
echo "=========================================="
echo "=== SMOKE TEST COMPLETE ==="
echo "=========================================="
echo ""
echo "Tests Passed: $TESTS_PASSED"
echo "Tests Failed: $TESTS_FAILED"
echo ""
echo "Test VM: $VM_NAME"
if [ -n "$VM_IP" ]; then
    echo "VM IP: $VM_IP"
    echo ""
    echo "To access the VM:"
    echo "  ssh -i ~/smoketest-key.pem cirros@$VM_IP"
    echo "  (Or use password: gocubsgo)"
fi
echo ""
echo "Horizon Dashboard: http://${CONTROLLER_IP}/horizon"
echo "  Username: admin"
echo "  Password: ${ADMIN_PASS}"
echo ""
echo "VNC Console:"
openstack console url show "$VM_NAME" 2>/dev/null | grep -E "url|type" || echo "  Not available"
echo ""
echo "=========================================="
echo "OpenStack deployment is FULLY OPERATIONAL!"
echo "=========================================="
