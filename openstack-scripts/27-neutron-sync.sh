#!/bin/bash
###############################################################################
# 27-neutron-sync.sh
# Sync Neutron database and start services
# Idempotent - safe to run multiple times
#
# This script:
# - Syncs Neutron database schema
# - Restarts Nova API (for Neutron integration)
# - Starts all Neutron services (OVS-based)
# - Verifies all agents are running
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

echo "=== Step 27: Neutron Database Sync and Service Start ==="

# ============================================================================
# PART 1: Check prerequisites
# ============================================================================
echo ""
echo "[1/5] Checking prerequisites..."

# Check Neutron config exists
if [ ! -f /etc/neutron/neutron.conf ]; then
    echo "  ✗ ERROR: /etc/neutron/neutron.conf not found!"
    echo "  Run 26-neutron-install.sh first."
    exit 1
fi
echo "  ✓ Neutron config exists"

# Check ML2 config exists
if [ ! -f /etc/neutron/plugins/ml2/ml2_conf.ini ]; then
    echo "  ✗ ERROR: ML2 config not found!"
    exit 1
fi
echo "  ✓ ML2 config exists"

# Check OVS agent config exists
if [ ! -f /etc/neutron/plugins/ml2/openvswitch_agent.ini ]; then
    echo "  ✗ ERROR: OVS agent config not found!"
    exit 1
fi
echo "  ✓ OVS agent config exists"

# Check database connectivity
if ! mysql -u neutron -p"${NEUTRON_DB_PASS}" -e "SELECT 1" neutron &>/dev/null; then
    echo "  ✗ ERROR: Cannot connect to Neutron database!"
    exit 1
fi
echo "  ✓ Database connection OK"

# ============================================================================
# PART 2: Sync Neutron database
# ============================================================================
echo ""
echo "[2/5] Syncing Neutron database..."

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
echo "[3/5] Restarting Nova API (for Neutron integration)..."

sudo systemctl restart nova-api

# Wait for Nova API to be ready
MAX_RETRIES=10
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://${CONTROLLER_IP}:8774/" 2>/dev/null | grep -qE "200|300|401"; then
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
# PART 4: Start Neutron services
# ============================================================================
echo ""
echo "[4/5] Starting Neutron services..."

# List of Neutron services (OVS-based, not Linux Bridge)
NEUTRON_SERVICES=(
    "neutron-server"
    "neutron-openvswitch-agent"
    "neutron-dhcp-agent"
    "neutron-metadata-agent"
    "neutron-l3-agent"
)

for SERVICE in "${NEUTRON_SERVICES[@]}"; do
    echo "  Starting $SERVICE..."
    sudo systemctl enable "$SERVICE"
    sudo systemctl restart "$SERVICE"
    
    # Give service time to start
    sleep 2
    
    if systemctl is-active --quiet "$SERVICE"; then
        echo "  ✓ $SERVICE started"
    else
        echo "  ✗ $SERVICE failed to start!"
        sudo journalctl -u "$SERVICE" -n 5 --no-pager
    fi
done

# ============================================================================
# PART 5: Verification
# ============================================================================
echo ""
echo "[5/5] Verifying Neutron installation..."

# Wait for agents to register
echo "  Waiting for agents to register..."
sleep 10

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

# Check port 9696 is listening
if sudo ss -tlnp | grep -q ":9696"; then
    echo "  ✓ Neutron API listening on port 9696"
else
    echo "  ✗ Neutron API NOT listening on port 9696!"
    ERRORS=$((ERRORS + 1))
fi

# Load credentials and check agents
source ~/admin-openrc

echo ""
echo "Neutron Agents:"
if openstack network agent list &>/dev/null; then
    openstack network agent list -f table
    
    # Count alive agents
    AGENT_COUNT=$(openstack network agent list -f value -c Alive | grep -c "True" || echo "0")
    TOTAL_AGENTS=$(openstack network agent list -f value -c Alive | wc -l)
    
    if [ "$AGENT_COUNT" -eq "$TOTAL_AGENTS" ] && [ "$TOTAL_AGENTS" -gt 0 ]; then
        echo "  ✓ All ${AGENT_COUNT} agents are alive"
    else
        echo "  ⚠️  Only ${AGENT_COUNT}/${TOTAL_AGENTS} agents are alive"
    fi
else
    echo "  ✗ Cannot list network agents!"
    ERRORS=$((ERRORS + 1))
fi

# Test Neutron API
echo ""
if openstack network list &>/dev/null; then
    echo "  ✓ Neutron API responding to CLI"
else
    echo "  ✗ Neutron API not responding!"
    ERRORS=$((ERRORS + 1))
fi

# Show extension list
echo ""
echo "Neutron Extensions (sample):"
openstack extension list --network -f value -c Alias 2>/dev/null | head -10 | sed 's/^/  - /'
echo "  ... (use 'openstack extension list --network' for full list)"

# Final summary
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Neutron services started successfully ==="
    echo "=========================================="
    echo ""
    echo "Services running:"
    echo "  - neutron-server (API on port 9696)"
    echo "  - neutron-openvswitch-agent (OVS integration)"
    echo "  - neutron-dhcp-agent (DHCP for VMs)"
    echo "  - neutron-metadata-agent (Metadata for VMs)"
    echo "  - neutron-l3-agent (Routing)"
    echo ""
    echo "Quick test commands:"
    echo "  openstack network agent list"
    echo "  openstack network list"
    echo "  openstack extension list --network"
    echo ""
    echo "Next: Run 28-provider-network.sh"
else
    echo "=== Neutron started with $ERRORS error(s) ==="
    echo "=========================================="
    echo ""
    echo "Check logs:"
    echo "  sudo journalctl -u neutron-server -n 50"
    echo "  sudo journalctl -u neutron-openvswitch-agent -n 50"
    echo "  sudo tail -50 /var/log/neutron/neutron-server.log"
    exit 1
fi
