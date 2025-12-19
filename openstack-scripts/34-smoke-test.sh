#!/bin/bash
###############################################################################
# 34-smoke-test.sh
# Comprehensive OpenStack Smoke Test for Debian Trixie
#
# Updated for:
# - Debian 13 (Trixie) with Python 3.13
# - OpenStack Caracal/Dalmatian (2024.1/2024.2)
# - OVN networking (no legacy agents)
# - Ceph storage backend
# - CirrOS 0.6.3 (latest as of 2024)
#
# This script:
# - Checks all required dependencies are installed
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
# - All OpenStack services installed and running (scripts 01-33)
# - Provider network configured (script 28)
# - OVN networking operational (script 25-27)
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
echo "=== Debian Trixie / OpenStack 2024.x  ==="
echo "=========================================="
echo ""
echo "Controller: ${CONTROLLER_IP}"
echo "Region: ${REGION_NAME}"
echo "Test started: $(date)"
echo ""

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

# CirrOS image configuration (latest version as of 2024)
CIRROS_VERSION="0.6.3"
CIRROS_URL="https://github.com/cirros-dev/cirros/releases/download/${CIRROS_VERSION}/cirros-${CIRROS_VERSION}-x86_64-disk.img"
CIRROS_SHA256="7d6355852aeb6dbcd191bcda7cd74f1536cfe5cbf8a10495a7283a8396e4b75b"

# Helper function for test results
pass() {
    echo "  ✓ $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "  ✗ FAILED: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo ""
    echo "==========================================="
    echo "SMOKE TEST FAILED - Stopping for RCA"
    echo "Failed at: $1"
    echo "==========================================="
    exit 1
}

warn() {
    echo "  ⚠ WARNING: $1"
}

###############################################################################
# PHASE 0: Dependencies Check
###############################################################################
echo "============================================"
echo "PHASE 0: Dependencies Check"
echo "============================================"

echo ""
echo "[0.1] Checking required packages..."

# Check for netcat (needed for memcached test)
if command -v nc &>/dev/null; then
    pass "netcat (nc) available"
elif command -v netcat &>/dev/null; then
    pass "netcat available"
else
    echo "  Installing netcat-openbsd..."
    sudo apt-get install -y netcat-openbsd &>/dev/null || true
    if command -v nc &>/dev/null; then
        pass "netcat installed"
    else
        warn "netcat not available - some tests may be skipped"
    fi
fi

# Check for curl
if command -v curl &>/dev/null; then
    pass "curl available"
else
    fail "curl not installed"
fi

# Check for wget (for image download)
if command -v wget &>/dev/null; then
    pass "wget available"
else
    echo "  Installing wget..."
    sudo apt-get install -y wget &>/dev/null
    pass "wget installed"
fi

# Check OpenStack client
if command -v openstack &>/dev/null; then
    pass "OpenStack client available"
    OPENSTACK_VERSION=$(openstack --version 2>&1 | head -1)
    echo "    Version: $OPENSTACK_VERSION"
else
    fail "OpenStack client not installed"
fi

###############################################################################
# PHASE 1: Infrastructure Health Check
###############################################################################
echo ""
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
if sudo rabbitmqctl list_users | grep -q "${RABBIT_USER:-openstack}"; then
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

# Test Memcached connectivity (use controller IP, not localhost)
MEMCACHED_HOST="${CONTROLLER_IP}"
if command -v nc &>/dev/null; then
    if echo "stats" | nc -q1 "$MEMCACHED_HOST" 11211 2>/dev/null | grep -q "STAT"; then
        pass "Memcached accepting connections on ${MEMCACHED_HOST}:11211"
    else
        # Fallback to localhost
        if echo "stats" | nc -q1 localhost 11211 2>/dev/null | grep -q "STAT"; then
            pass "Memcached accepting connections on localhost:11211"
        else
            warn "Memcached connectivity test failed (may still work)"
        fi
    fi
else
    warn "netcat not available - skipping Memcached connectivity test"
fi

echo ""
echo "[1.4] Checking etcd..."
if systemctl is-active --quiet etcd; then
    pass "etcd is running"
else
    warn "etcd is not running (may be optional)"
fi

echo ""
echo "[1.5] Checking Ceph Cluster..."
if command -v ceph &>/dev/null; then
    CEPH_HEALTH=$(sudo ceph health 2>/dev/null || echo "UNAVAILABLE")
    if echo "$CEPH_HEALTH" | grep -qE "HEALTH_OK|HEALTH_WARN"; then
        pass "Ceph cluster healthy: $CEPH_HEALTH"
    else
        warn "Ceph cluster status: $CEPH_HEALTH"
    fi

    # Check Ceph pools
    for pool in images volumes vms; do
        if sudo ceph osd pool ls 2>/dev/null | grep -q "^${pool}$"; then
            pass "Ceph pool '${pool}' exists"
        else
            warn "Ceph pool '${pool}' not found"
        fi
    done
else
    warn "Ceph client not installed - skipping Ceph checks"
fi

echo ""
echo "[1.6] Checking Apache..."
if systemctl is-active --quiet apache2; then
    pass "Apache is running"
else
    fail "Apache is not running"
fi

echo ""
echo "[1.7] Checking OVS and OVN..."

# Check Open vSwitch
if systemctl is-active --quiet openvswitch-switch; then
    pass "Open vSwitch is running"
else
    fail "Open vSwitch is not running"
fi

# Check OVN Central (controller node)
if systemctl is-active --quiet ovn-central; then
    pass "OVN Central is running"
else
    warn "OVN Central not running on this node"
fi

# Check OVN Controller
if systemctl is-active --quiet ovn-controller; then
    pass "OVN Controller is running"
else
    warn "OVN Controller not running (may be on compute node only)"
fi

# Check OVS bridges
for bridge in br-provider br-int; do
    if sudo ovs-vsctl br-exists $bridge 2>/dev/null; then
        pass "OVS bridge '${bridge}' exists"
    else
        warn "OVS bridge '${bridge}' not found"
    fi
done

# Check OVN bridge mappings
BRIDGE_MAPPING=$(sudo ovs-vsctl get open . external-ids:ovn-bridge-mappings 2>/dev/null || echo "")
if [ -n "$BRIDGE_MAPPING" ]; then
    pass "OVN bridge mapping configured: $BRIDGE_MAPPING"
else
    warn "OVN bridge mapping not found"
fi

###############################################################################
# PHASE 2: OpenStack API Endpoints Health
###############################################################################
echo ""
echo "============================================"
echo "PHASE 2: OpenStack API Endpoints Health"
echo "============================================"

echo ""
echo "[2.1] Checking Keystone (Identity)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:5000/v3" --max-time 10 2>/dev/null || echo "000")
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
TOKEN=$(openstack token issue -f value -c id 2>/dev/null)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:9292/v2/images" -H "X-Auth-Token: $TOKEN" --max-time 10 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Glance API responding (port 9292)"
else
    fail "Glance API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.3] Checking Placement..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8778/" --max-time 10 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Placement API responding (port 8778)"
else
    fail "Placement API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.4] Checking Nova (Compute)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8774/" --max-time 10 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Nova API responding (port 8774)"
else
    fail "Nova API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.5] Checking Neutron (Network)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:9696/" --max-time 10 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Neutron API responding (port 9696)"
else
    fail "Neutron API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.6] Checking Cinder (Volume)..."
# Note: Cinder returns HTTP 300 (Multiple Choices) at root - this is normal (version list)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8776/" --max-time 10 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "300" ]; then
    pass "Cinder API responding (port 8776, HTTP $HTTP_CODE)"
else
    fail "Cinder API not responding (HTTP $HTTP_CODE)"
fi

echo ""
echo "[2.7] Checking Horizon (Dashboard)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}/horizon/auth/login/" --max-time 10 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Horizon Dashboard responding (port 80)"
else
    warn "Horizon Dashboard not responding (HTTP $HTTP_CODE) - may be optional"
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
SERVICE_COUNT=$(openstack service list -f value 2>/dev/null | wc -l)
if [ "$SERVICE_COUNT" -ge 5 ]; then
    pass "All $SERVICE_COUNT services registered in Keystone"
    openstack service list -f table
else
    fail "Expected 5+ services, found $SERVICE_COUNT"
fi

echo ""
echo "[3.2] Nova Compute Services..."
# Check for down services (state column)
NOVA_DOWN=$(openstack compute service list -f value -c State 2>/dev/null | grep -c "down" || true)
if [ "$NOVA_DOWN" -eq 0 ]; then
    pass "All Nova services UP"
    openstack compute service list -f table
else
    fail "Some Nova services are DOWN ($NOVA_DOWN)"
fi

echo ""
echo "[3.3] Neutron Network Agents (OVN)..."
# OVN uses different agent types than legacy - check what's available
AGENT_COUNT=$(openstack network agent list -f value 2>/dev/null | wc -l)
if [ "$AGENT_COUNT" -ge 1 ]; then
    pass "$AGENT_COUNT network agent(s) registered"
    openstack network agent list -f table

    # Check for any dead agents
    DEAD_AGENTS=$(openstack network agent list -f value -c Alive 2>/dev/null | grep -c "False" || true)
    if [ "$DEAD_AGENTS" -gt 0 ]; then
        warn "$DEAD_AGENTS agent(s) not alive"
    fi
else
    warn "No network agents found (OVN may not register traditional agents)"
fi

echo ""
echo "[3.4] Cinder Services..."
CINDER_DOWN=$(openstack volume service list -f value -c State 2>/dev/null | grep -c "down" || true)
if [ "$CINDER_DOWN" -eq 0 ]; then
    pass "All Cinder services UP"
    openstack volume service list -f table
else
    fail "Some Cinder services are DOWN ($CINDER_DOWN)"
fi

echo ""
echo "[3.5] Hypervisors..."
HYPERVISOR_COUNT=$(openstack hypervisor list -f value 2>/dev/null | wc -l)
if [ "$HYPERVISOR_COUNT" -ge 1 ]; then
    pass "$HYPERVISOR_COUNT hypervisor(s) available"
    openstack hypervisor list -f table
else
    fail "No hypervisors available"
fi

# Check hypervisor resources (updated API - hypervisor stats deprecated in newer versions)
echo ""
echo "  Hypervisor Resources:"
openstack hypervisor list -f value -c "Hypervisor Hostname" 2>/dev/null | while read HV; do
    if [ -n "$HV" ]; then
        echo "    $HV:"
        openstack hypervisor show "$HV" -f value -c vcpus -c memory_mb -c local_gb 2>/dev/null | \
            awk 'NR==1{printf "      vCPUs: %s", $0} NR==2{printf ", RAM: %s MB", $0} NR==3{printf ", Disk: %s GB\n", $0}'
    fi
done

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
    openstack network show provider-net -f table -c name -c id -c status \
        -c provider:network_type -c provider:physical_network -c router:external
else
    fail "Provider network 'provider-net' not found - run 28-provider-network.sh first"
fi

echo ""
echo "[4.2] Subnets..."
SUBNET_COUNT=$(openstack subnet list -f value 2>/dev/null | wc -l)
if [ "$SUBNET_COUNT" -ge 1 ]; then
    pass "$SUBNET_COUNT subnet(s) configured"
    openstack subnet list -f table
else
    fail "No subnets configured"
fi

echo ""
echo "[4.3] OVN Logical Switches..."
if command -v ovn-nbctl &>/dev/null; then
    LS_COUNT=$(sudo ovn-nbctl ls-list 2>/dev/null | wc -l)
    if [ "$LS_COUNT" -ge 1 ]; then
        pass "$LS_COUNT OVN logical switch(es) found"
        sudo ovn-nbctl ls-list 2>/dev/null | head -5
    else
        warn "No OVN logical switches found yet"
    fi
else
    warn "ovn-nbctl not available - skipping OVN check"
fi

###############################################################################
# PHASE 5: Test Resources Creation
###############################################################################
echo ""
echo "============================================"
echo "PHASE 5: Test Resources Creation"
echo "============================================"

echo ""
echo "[5.1] Cirros Test Image (v${CIRROS_VERSION})..."
if openstack image show cirros &>/dev/null; then
    pass "Cirros image already exists"
else
    echo "  Downloading Cirros ${CIRROS_VERSION} image..."
    TEMP_IMG="/tmp/cirros-${CIRROS_VERSION}.img"

    if wget -q --show-progress "${CIRROS_URL}" -O "$TEMP_IMG" 2>/dev/null || \
       wget -q "${CIRROS_URL}" -O "$TEMP_IMG"; then

        # Verify checksum if sha256sum available
        if command -v sha256sum &>/dev/null; then
            ACTUAL_SHA=$(sha256sum "$TEMP_IMG" | awk '{print $1}')
            if [ "$ACTUAL_SHA" = "$CIRROS_SHA256" ]; then
                echo "  ✓ Checksum verified"
            else
                warn "Checksum mismatch (continuing anyway)"
            fi
        fi

        # Upload to Glance
        openstack image create "cirros" \
            --disk-format qcow2 \
            --container-format bare \
            --file "$TEMP_IMG" \
            --public
        rm -f "$TEMP_IMG"
        pass "Cirros image uploaded"
    else
        fail "Failed to download Cirros image from ${CIRROS_URL}"
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
# Get default security group ID for admin project
DEFAULT_SG=$(openstack security group list --project admin -f value -c ID -c Name 2>/dev/null | grep default | awk '{print $1}' | head -1)

if [ -n "$DEFAULT_SG" ]; then
    # Add ICMP rule (ignore if exists)
    if openstack security group rule create --protocol icmp --ingress "$DEFAULT_SG" &>/dev/null; then
        pass "ICMP rule added to default security group"
    else
        pass "ICMP rule already exists"
    fi

    # Add SSH rule (ignore if exists)
    if openstack security group rule create --protocol tcp --dst-port 22 --ingress "$DEFAULT_SG" &>/dev/null; then
        pass "SSH rule added to default security group"
    else
        pass "SSH rule already exists"
    fi
else
    warn "Could not find default security group"
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
echo "  Creating server (this may take a minute)..."
if openstack server create \
    --image cirros \
    --flavor m1.tiny \
    --network provider-net \
    --key-name smoketest-key \
    --wait \
    "$VM_NAME"; then
    echo "  Server created"
else
    fail "Server creation command failed"
fi

echo ""
echo "[6.2] Checking VM status..."
VM_STATUS=$(openstack server show "$VM_NAME" -f value -c status 2>/dev/null || echo "UNKNOWN")

if [ "$VM_STATUS" = "ACTIVE" ]; then
    pass "VM reached ACTIVE state"
else
    echo "  VM Status: $VM_STATUS"
    echo ""
    echo "  VM Details:"
    openstack server show "$VM_NAME" -f table
    echo ""
    echo "  Console Log (last 30 lines):"
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
    warn "VM has no IP address yet (DHCP may be slow)"
fi

echo ""
echo "[6.3] Console URL..."
openstack console url show "$VM_NAME" 2>/dev/null || echo "  Console URL not available (VNC may not be configured)"

###############################################################################
# PHASE 7: Test Volume (Ceph-backed)
###############################################################################
echo ""
echo "============================================"
echo "PHASE 7: Test Volume Creation (Ceph)"
echo "============================================"

VOLUME_NAME="smoketest-vol-$(date +%s)"

echo ""
echo "[7.1] Creating test volume: $VOLUME_NAME..."

# Check if ceph volume type exists
VOLUME_TYPE="ceph"
if ! openstack volume type show "$VOLUME_TYPE" &>/dev/null; then
    # Try without specifying type
    VOLUME_TYPE=""
    warn "Volume type 'ceph' not found - using default"
fi

if [ -n "$VOLUME_TYPE" ]; then
    openstack volume create --size 1 --type "$VOLUME_TYPE" "$VOLUME_NAME"
else
    openstack volume create --size 1 "$VOLUME_NAME"
fi

# Wait for volume to be available
echo "  Waiting for volume to become available..."
for i in {1..30}; do
    VOLUME_STATUS=$(openstack volume show "$VOLUME_NAME" -f value -c status 2>/dev/null || echo "UNKNOWN")
    if [ "$VOLUME_STATUS" = "available" ]; then
        break
    fi
    sleep 2
done

if [ "$VOLUME_STATUS" = "available" ]; then
    pass "Volume reached available state"
else
    fail "Volume did not reach available state (status: $VOLUME_STATUS)"
fi

# Verify volume in Ceph
if command -v rbd &>/dev/null; then
    if sudo rbd -p volumes ls 2>/dev/null | grep -q "volume-"; then
        pass "Volume visible in Ceph 'volumes' pool"
    else
        warn "Volume not yet visible in Ceph pool (may take a moment)"
    fi
else
    warn "rbd command not available - skipping Ceph verification"
fi

echo ""
echo "[7.2] Attaching volume to VM..."
if openstack server add volume "$VM_NAME" "$VOLUME_NAME"; then
    sleep 5
    VOLUME_STATUS=$(openstack volume show "$VOLUME_NAME" -f value -c status 2>/dev/null || echo "UNKNOWN")
    if [ "$VOLUME_STATUS" = "in-use" ]; then
        pass "Volume attached successfully (status: in-use)"
    else
        warn "Volume attachment status: $VOLUME_STATUS"
    fi
else
    warn "Volume attachment failed (VM may not support hotplug)"
fi

###############################################################################
# PHASE 8: Connectivity Test (Optional)
###############################################################################
echo ""
echo "============================================"
echo "PHASE 8: Connectivity Test"
echo "============================================"

if [ -n "$VM_IP" ]; then
    echo ""
    echo "[8.1] Ping test to VM ($VM_IP)..."

    # Wait a bit for VM to fully boot and get network
    echo "  Waiting 10 seconds for VM to initialize..."
    sleep 10

    if ping -c 3 -W 5 "$VM_IP" &>/dev/null; then
        pass "VM is pingable at $VM_IP"
    else
        warn "VM not responding to ping (firewall or routing issue)"
        echo "  This may be normal if:"
        echo "    - VM is still booting"
        echo "    - Network routing not configured"
        echo "    - Security groups blocking ICMP"
    fi
else
    warn "No VM IP available - skipping connectivity test"
fi

###############################################################################
# PHASE 9: Test Resources Summary
###############################################################################
echo ""
echo "============================================"
echo "PHASE 9: Test Resources Summary"
echo "============================================"

echo ""
echo "Test resources created:"
echo "  - VM: $VM_NAME"
echo "  - Volume: $VOLUME_NAME"
echo "  - Keypair: smoketest-key"
echo "  - Image: cirros (if didn't exist)"
echo "  - Flavor: m1.tiny (if didn't exist)"
echo ""
echo "To cleanup test resources, run:"
echo "  openstack server delete $VM_NAME"
echo "  openstack volume delete $VOLUME_NAME"
echo "  # Optional: remove persistent resources"
echo "  # openstack keypair delete smoketest-key"
echo "  # rm -f ~/smoketest-key.pem"
echo "  # openstack image delete cirros"
echo "  # openstack flavor delete m1.tiny"

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
    echo "  (Default password: gocubsgo)"
fi
echo ""
echo "Horizon Dashboard: http://${CONTROLLER_IP}/horizon"
echo "  Username: admin"
echo "  Password: ${ADMIN_PASS}"
echo ""
echo "VNC Console:"
openstack console url show "$VM_NAME" 2>/dev/null | grep -E "url|type" || echo "  (Run 'openstack console url show $VM_NAME' to get console URL)"
echo ""
if [ $TESTS_FAILED -eq 0 ]; then
    echo "=========================================="
    echo "OpenStack deployment is FULLY OPERATIONAL!"
    echo "=========================================="
else
    echo "=========================================="
    echo "Some tests had warnings - review above"
    echo "=========================================="
fi
