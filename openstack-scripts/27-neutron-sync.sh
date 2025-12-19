#!/bin/bash
###############################################################################
# 27-neutron-sync.sh
# Sync Neutron database and start services (OVN-based)
# Idempotent - safe to run multiple times
#
# This script:
# - Syncs Neutron database schema
# - Restarts Nova API (for Neutron integration)
# - Starts Neutron services (OVN-based - minimal services)
# - Verifies OVN integration is working
#
# OVN Architecture Benefits:
# - No neutron-dhcp-agent (OVN native DHCP)
# - No neutron-l3-agent (OVN native L3 routing)
# - No neutron-openvswitch-agent (OVN handles this)
# - Only neutron-server + neutron-ovn-metadata-agent needed
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

echo "=== Step 27: Neutron Database Sync and Service Start (OVN) ==="

# ============================================================================
# PART 1: Check prerequisites
# ============================================================================
echo ""
echo "[1/6] Checking prerequisites..."

# Check Neutron config exists (needs sudo due to permissions)
if ! sudo test -f /etc/neutron/neutron.conf; then
    echo "  ✗ ERROR: /etc/neutron/neutron.conf not found!"
    echo "  Run 26-neutron-install.sh first."
    exit 1
fi
echo "  ✓ Neutron config exists"

# Check ML2 config exists
if ! sudo test -f /etc/neutron/plugins/ml2/ml2_conf.ini; then
    echo "  ✗ ERROR: ML2 config not found!"
    exit 1
fi
echo "  ✓ ML2 config exists"

# Check OVN metadata agent config exists
if ! sudo test -f /etc/neutron/neutron_ovn_metadata_agent.ini; then
    echo "  ✗ ERROR: OVN metadata agent config not found!"
    exit 1
fi
echo "  ✓ OVN metadata agent config exists"

# Verify ML2 is configured for OVN (not legacy OVS)
if sudo /usr/bin/grep -q "mechanism_drivers.*ovn" /etc/neutron/plugins/ml2/ml2_conf.ini; then
    echo "  ✓ ML2 configured for OVN mechanism driver"
else
    echo "  ✗ ERROR: ML2 not configured for OVN!"
    echo "  Expected mechanism_drivers = ovn in ml2_conf.ini"
    exit 1
fi

# Check database connectivity
if ! mysql -u neutron -p"${NEUTRON_DB_PASS}" -e "SELECT 1" neutron &>/dev/null; then
    echo "  ✗ ERROR: Cannot connect to Neutron database!"
    exit 1
fi
echo "  ✓ Database connection OK"

# Check OVN central is running
if ! systemctl is-active --quiet ovn-central; then
    echo "  ✗ ERROR: OVN central is not running!"
    exit 1
fi
echo "  ✓ OVN central is running"

# Check OVN controller is running
if ! systemctl is-active --quiet ovn-host; then
    echo "  ✗ ERROR: OVN host (controller) is not running!"
    exit 1
fi
echo "  ✓ OVN host is running"

# ============================================================================
# PART 2: Sync Neutron database
# ============================================================================
echo ""
echo "[2/6] Syncing Neutron database..."

# Run database migration
sudo neutron-db-manage --config-file /etc/neutron/neutron.conf \
    --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head

# Count tables to verify
TABLE_COUNT=$(mysql -u neutron -p"${NEUTRON_DB_PASS}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='neutron'" 2>/dev/null)
echo "  ✓ Database synced (${TABLE_COUNT} tables)"

# ============================================================================
# PART 3: Restart Nova API
# ============================================================================
echo ""
echo "[3/6] Restarting Nova API (for Neutron integration)..."

sudo systemctl restart nova-api

# Wait for Nova API to be ready
MAX_RETRIES=10
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8774/" 2>/dev/null | /usr/bin/grep -qE "200|300|401"; then
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for Nova API... (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 2
done

if systemctl is-active --quiet nova-api; then
    echo "  ✓ Nova API restarted"
else
    echo "  ✗ WARNING: Nova API may not be running properly"
fi

# ============================================================================
# PART 4: Start Neutron services (OVN-based - minimal set)
# ============================================================================
echo ""
echo "[4/6] Starting Neutron services (OVN architecture)..."

# OVN-based Neutron requires only these services on controller:
# - neutron-api: API server (Debian Trixie splits this from rpc-server)
# - neutron-rpc-server: RPC server for internal messaging
# - neutron-ovn-metadata-agent: Metadata service for VMs
#
# NOTE: Debian Trixie uses neutron-api + neutron-rpc-server instead of neutron-server
#       The neutron-server package is a virtual package that installs both.
#
# NOT needed (OVN provides natively):
# - neutron-dhcp-agent (OVN native DHCP)
# - neutron-l3-agent (OVN native L3)
# - neutron-openvswitch-agent (OVN manages OVS)

NEUTRON_SERVICES=(
    "neutron-api"
    "neutron-rpc-server"
    "neutron-ovn-metadata-agent"
)

for SERVICE in "${NEUTRON_SERVICES[@]}"; do
    echo "  Starting $SERVICE..."
    sudo systemctl enable "$SERVICE"
    sudo systemctl restart "$SERVICE"

    # Give service time to start
    sleep 3

    if systemctl is-active --quiet "$SERVICE"; then
        echo "  ✓ $SERVICE started"
    else
        echo "  ✗ $SERVICE failed to start!"
        sudo journalctl -u "$SERVICE" -n 10 --no-pager
    fi
done

# ============================================================================
# PART 5: Restart OVN Services and Verify Integration
# ============================================================================
echo ""
echo "[5/6] Restarting OVN services and verifying integration..."

# LESSON LEARNED (2025-12-20): OVN controller can get into a bad state where
# it runs (high CPU) but stops sending heartbeats to Neutron. This causes
# agents to show "Alive: XXX" and port binding to fail with "dead agent".
# Restarting OVN services after Neutron sync ensures fresh agent registration.

echo "  Restarting OVN services for clean agent registration..."

# Restart OVN controller (part of ovn-host)
sudo systemctl restart ovn-controller
sleep 2
if systemctl is-active --quiet ovn-controller; then
    echo "  ✓ ovn-controller restarted"
else
    echo "  ✗ ovn-controller failed to restart!"
fi

# Restart OVN central services to ensure clean state
sudo systemctl restart ovn-central
sleep 3
if systemctl is-active --quiet ovn-central; then
    echo "  ✓ ovn-central restarted"
else
    echo "  ✗ ovn-central failed to restart!"
fi

# Wait for OVN to stabilize
echo "  Waiting for OVN to stabilize..."
sleep 5

# Check OVN Northbound database connection
echo "  Checking OVN databases..."
if sudo ovn-nbctl show &>/dev/null; then
    echo "  ✓ OVN Northbound database accessible"
else
    echo "  ✗ Cannot access OVN Northbound database!"
fi

if sudo ovn-sbctl show &>/dev/null; then
    echo "  ✓ OVN Southbound database accessible"
else
    echo "  ✗ Cannot access OVN Southbound database!"
fi

# Check chassis registration
CHASSIS_COUNT=$(sudo ovn-sbctl show 2>/dev/null | /usr/bin/grep -c "Chassis" || echo "0")
echo "  OVN Chassis count: ${CHASSIS_COUNT}"

# CRITICAL: Restart neutron-ovn-metadata-agent AFTER OVN is stable
# This ensures the agent registers with fresh heartbeat to Neutron
echo "  Restarting neutron-ovn-metadata-agent for fresh heartbeat registration..."
sudo systemctl restart neutron-ovn-metadata-agent
sleep 3
if systemctl is-active --quiet neutron-ovn-metadata-agent; then
    echo "  ✓ neutron-ovn-metadata-agent restarted"
else
    echo "  ✗ neutron-ovn-metadata-agent failed to restart!"
fi

# Wait for agent to register with Neutron (heartbeat interval is typically 30s)
echo "  Waiting for agent heartbeat registration (up to 60s)..."
MAX_WAIT=60
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Check if any OVN agent shows as alive
    ALIVE_CHECK=$(source ~/admin-openrc && /usr/bin/openstack network agent list -f value -c Alive 2>/dev/null | grep -c "True" || echo "0")
    if [ "$ALIVE_CHECK" -gt 0 ]; then
        echo "  ✓ Agent heartbeat detected ($ALIVE_CHECK agent(s) alive)"
        break
    fi
    WAIT_COUNT=$((WAIT_COUNT + 10))
    echo "    Waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
    sleep 10
done

if [ "$ALIVE_CHECK" -eq 0 ]; then
    echo "  ⚠ WARNING: No agents showing as alive after ${MAX_WAIT}s"
    echo "    This may indicate OVN-Neutron integration issues"
fi

# ============================================================================
# PART 6: Final Verification
# ============================================================================
echo ""
echo "[6/6] Verifying Neutron installation..."

# Wait for services to stabilize
echo "  Waiting for services to stabilize..."
sleep 5

ERRORS=0

# Check all services are running
echo ""
echo "Service Status:"
for SERVICE in "${NEUTRON_SERVICES[@]}"; do
    if systemctl is-active --quiet "$SERVICE"; then
        echo "  ✓ $SERVICE is running"
    else
        echo "  ✗ $SERVICE is NOT running!"
        ERRORS=$((ERRORS + 1))
    fi
done

# Also verify OVN services
for SERVICE in ovn-central ovn-host openvswitch-switch; do
    if systemctl is-active --quiet "$SERVICE"; then
        echo "  ✓ $SERVICE is running"
    else
        echo "  ✗ $SERVICE is NOT running!"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check port 9696 is listening
if sudo ss -tlnp | /usr/bin/grep -q ":9696"; then
    echo "  ✓ Neutron API listening on port 9696"
else
    echo "  ✗ Neutron API NOT listening on port 9696!"
    ERRORS=$((ERRORS + 1))
fi

# Load credentials and check API
source ~/admin-openrc

echo ""
echo "Neutron API Test:"
if /usr/bin/openstack network list &>/dev/null; then
    echo "  ✓ Neutron API responding to CLI"
else
    echo "  ✗ Neutron API not responding!"
    ERRORS=$((ERRORS + 1))
fi

# Note: With OVN, there are no traditional "network agents" like DHCP agent, L3 agent
# OVN handles these functions natively
echo ""
echo "OVN Network Agents:"
if /usr/bin/openstack network agent list &>/dev/null; then
    AGENT_OUTPUT=$(/usr/bin/openstack network agent list -f table 2>/dev/null)
    if [ -n "$AGENT_OUTPUT" ]; then
        echo "$AGENT_OUTPUT"
    else
        echo "  (No legacy agents - OVN handles L2/L3/DHCP natively)"
    fi

    # Check for OVN metadata agent
    if /usr/bin/openstack network agent list -f value -c Binary 2>/dev/null | /usr/bin/grep -q "neutron-ovn-metadata-agent"; then
        echo "  ✓ OVN metadata agent registered"
    else
        echo "  ⚠ OVN metadata agent not yet registered (may take a moment)"
    fi
else
    echo "  ✗ Cannot list network agents!"
    ERRORS=$((ERRORS + 1))
fi

# Show extension list
echo ""
echo "Neutron Extensions (sample):"
/usr/bin/openstack extension list --network -f value -c Alias 2>/dev/null | head -10 | sed 's/^/  - /'
echo "  ... (use 'openstack extension list --network' for full list)"

# Final summary
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Neutron OVN services started successfully ==="
    echo "=========================================="
    echo ""
    echo "Architecture: ML2/OVN (modern SDN)"
    echo ""
    echo "Services running:"
    echo "  - neutron-api (API on port 9696)"
    echo "  - neutron-rpc-server (internal RPC)"
    echo "  - neutron-ovn-metadata-agent (VM metadata)"
    echo "  - ovn-central (OVN databases)"
    echo "  - ovn-host (OVN controller)"
    echo ""
    echo "OVN Native Features (no agents needed):"
    echo "  - Distributed DHCP"
    echo "  - Distributed L3 routing"
    echo "  - Security groups"
    echo "  - Geneve tunneling"
    echo ""
    echo "Quick test commands:"
    echo "  openstack network list"
    echo "  openstack extension list --network"
    echo "  sudo ovn-nbctl show"
    echo "  sudo ovn-sbctl show"
    echo ""
    echo "Next: Run 28-provider-network.sh"
else
    echo "=== Neutron started with $ERRORS error(s) ==="
    echo "=========================================="
    echo ""
    echo "Check logs:"
    echo "  sudo journalctl -u neutron-api -n 50"
    echo "  sudo journalctl -u neutron-rpc-server -n 50"
    echo "  sudo journalctl -u neutron-ovn-metadata-agent -n 50"
    echo "  sudo journalctl -u ovn-central -n 50"
    echo "  sudo tail -50 /var/log/neutron/neutron-api.log"
    exit 1
fi
