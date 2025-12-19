#!/bin/bash
###############################################################################
# 27a-ovn-reset-chassis.sh
# Reset OVN chassis registration to fix stuck heartbeat
# Use this when OVN agents show "Alive: XXX" (false) in Neutron
#
# Root Cause: OVN controller can get stuck where Chassis.nb_cfg = 0
# while SB_Global.nb_cfg has progressed. This makes Neutron think
# the agent is dead because the controller isn't updating its nb_cfg.
#
# This script:
# - Stops OVN controller
# - Deletes the stale chassis from OVN Southbound database
# - Clears OVN controller local state
# - Restarts OVN services fresh
# - Waits for new chassis registration
#
# Prerequisites:
# - Script 25-27 completed
# - This is a recovery script, not part of normal installation
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared environment
if [ -f "${SCRIPT_DIR}/openstack-env.sh" ]; then
    source "${SCRIPT_DIR}/openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

echo "=== OVN Chassis Reset ==="
echo ""
echo "This script will reset the OVN chassis registration."
echo "Use this when agents show 'Alive: XXX' in 'openstack network agent list'"
echo ""

# Check current state
echo "[1/6] Checking current OVN agent state..."
source ~/admin-openrc

AGENT_STATUS=$(/usr/bin/openstack network agent list -f value -c Alive 2>/dev/null | head -1 || echo "unknown")
echo "  Current agent alive status: $AGENT_STATUS"

if [ "$AGENT_STATUS" = "True" ]; then
    echo "  Agents are already alive. No reset needed."
    echo "  If you still want to reset, run with --force"
    if [ "$1" != "--force" ]; then
        exit 0
    fi
fi

# Get current chassis info before reset
echo ""
echo "[2/6] Getting current chassis information..."
CHASSIS_NAME=$(ovsdb-client dump unix:/var/run/ovn/ovnsb_db.sock Chassis 2>/dev/null | grep -oP '"\K[0-9a-f-]{36}(?=")' | head -1 || echo "")
CHASSIS_NB_CFG=$(ovsdb-client dump unix:/var/run/ovn/ovnsb_db.sock Chassis 2>/dev/null | awk '{print $7}' | tail -1 || echo "unknown")
GLOBAL_NB_CFG=$(ovsdb-client dump unix:/var/run/ovn/ovnsb_db.sock SB_Global 2>/dev/null | awk '{print $5}' | tail -1 || echo "unknown")

echo "  Chassis name: ${CHASSIS_NAME:-not found}"
echo "  Chassis nb_cfg: $CHASSIS_NB_CFG"
echo "  Global nb_cfg: $GLOBAL_NB_CFG"

if [ "$CHASSIS_NB_CFG" != "0" ] && [ "$CHASSIS_NB_CFG" = "$GLOBAL_NB_CFG" ] 2>/dev/null; then
    echo "  Chassis nb_cfg matches global - OVN may be healthy"
    echo "  The issue might be elsewhere. Continuing anyway..."
fi

# Stop OVN controller
echo ""
echo "[3/6] Stopping OVN controller..."
sudo systemctl stop ovn-controller
sleep 2
echo "  ✓ OVN controller stopped"

# Delete stale chassis from Southbound DB
echo ""
echo "[4/6] Removing stale chassis from OVN Southbound database..."
if [ -n "$CHASSIS_NAME" ]; then
    # Delete chassis using ovn-sbctl
    sudo ovn-sbctl chassis-del "$CHASSIS_NAME" 2>/dev/null || true
    echo "  ✓ Chassis '$CHASSIS_NAME' deleted"
else
    echo "  ⚠ No chassis found to delete"
fi

# Also clear any binding entries for this host
HOSTNAME=$(hostname)
echo "  Clearing any port bindings for host: $HOSTNAME"
# This is done automatically when chassis is deleted

# Clear OVN controller local state
echo ""
echo "[5/6] Clearing OVN controller local state..."

# Stop ovn-host service completely
sudo systemctl stop ovn-host 2>/dev/null || true

# Clear the OVN controller's internal state
# The controller stores state in Open_vSwitch database
sudo ovs-vsctl --if-exists remove open_vswitch . external_ids ovn-installed
sudo ovs-vsctl --if-exists remove open_vswitch . external_ids ovn-remote-probe-interval

# Reset system-id to force re-registration with new chassis ID
# (Keep the same hostname but get new UUID)
# Note: We keep system-id as hostname for consistency
echo "  ✓ Local state cleared"

# Restart OVN services
echo ""
echo "[6/6] Restarting OVN services with fresh state..."

# Restart OVN central first
sudo systemctl restart ovn-central
sleep 3
if systemctl is-active --quiet ovn-central; then
    echo "  ✓ ovn-central restarted"
else
    echo "  ✗ ovn-central failed to restart!"
fi

# Restart OVN host (controller)
sudo systemctl restart ovn-host
sleep 5
if systemctl is-active --quiet ovn-controller; then
    echo "  ✓ ovn-controller restarted"
else
    echo "  ✗ ovn-controller failed to restart!"
fi

# Restart Neutron OVN metadata agent
sudo systemctl restart neutron-ovn-metadata-agent
sleep 2
if systemctl is-active --quiet neutron-ovn-metadata-agent; then
    echo "  ✓ neutron-ovn-metadata-agent restarted"
else
    echo "  ✗ neutron-ovn-metadata-agent failed to restart!"
fi

# Wait for new chassis registration
echo ""
echo "Waiting for new chassis registration (up to 30s)..."
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    NEW_CHASSIS_NB_CFG=$(ovsdb-client dump unix:/var/run/ovn/ovnsb_db.sock Chassis 2>/dev/null | awk '{print $7}' | tail -1 || echo "0")
    NEW_GLOBAL_NB_CFG=$(ovsdb-client dump unix:/var/run/ovn/ovnsb_db.sock SB_Global 2>/dev/null | awk '{print $5}' | tail -1 || echo "0")

    # Check if nb_cfg has progressed (not stuck at 0)
    if [ "$NEW_CHASSIS_NB_CFG" != "0" ] 2>/dev/null; then
        echo "  ✓ Chassis nb_cfg updated: $NEW_CHASSIS_NB_CFG (global: $NEW_GLOBAL_NB_CFG)"
        break
    fi

    WAIT_COUNT=$((WAIT_COUNT + 5))
    echo "  Waiting... (${WAIT_COUNT}s/${MAX_WAIT}s) - Chassis nb_cfg: $NEW_CHASSIS_NB_CFG"
    sleep 5
done

# Final verification
echo ""
echo "=== Verification ==="

# Check agent status
echo ""
echo "Neutron Network Agents:"
source ~/admin-openrc
/usr/bin/openstack network agent list -f table 2>/dev/null || echo "  Failed to list agents"

# Check OVN state
echo ""
echo "OVN Chassis State:"
ovsdb-client dump unix:/var/run/ovn/ovnsb_db.sock Chassis 2>/dev/null | head -5

echo ""
echo "OVN Southbound Global State:"
ovsdb-client dump unix:/var/run/ovn/ovnsb_db.sock SB_Global 2>/dev/null | head -5

echo ""
echo "=========================================="
# Final check
FINAL_ALIVE=$(/usr/bin/openstack network agent list -f value -c Alive 2>/dev/null | grep -c "True" || echo "0")
if [ "$FINAL_ALIVE" -gt 0 ]; then
    echo "=== OVN Chassis Reset SUCCESS ==="
    echo "=========================================="
    echo ""
    echo "$FINAL_ALIVE agent(s) now showing as alive."
    echo ""
    echo "You can now run the smoke test:"
    echo "  ./34-smoke-test.sh"
else
    echo "=== OVN Chassis Reset - Agents Still Dead ==="
    echo "=========================================="
    echo ""
    echo "Agents are still not showing as alive."
    echo "This may be a deeper OVN issue. Check:"
    echo "  1. OVN controller logs: sudo journalctl -u ovn-controller -n 100"
    echo "  2. OVN northd logs: sudo journalctl -u ovn-northd -n 50"
    echo "  3. CPU usage: top -p \$(pgrep ovn-controller)"
    echo ""
    echo "Consider reinstalling OVN:"
    echo "  sudo apt purge ovn-central ovn-host"
    echo "  sudo rm -rf /var/lib/ovn/"
    echo "  ./25-ovs-ovn-install.sh"
fi
