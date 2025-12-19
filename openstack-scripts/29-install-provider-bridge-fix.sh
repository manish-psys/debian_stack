#!/bin/bash
###############################################################################
# 29-install-provider-bridge-fix.sh
# Install systemd service to fix provider bridge connectivity after reboot
#
# Problem:
# OVN sets fail_mode=secure on OVS bridges on every restart. This drops all
# traffic on the provider bridge (br-provider) which carries management traffic
# including SSH. After reboot, SSH becomes unavailable.
#
# Solution:
# This script installs a systemd service that runs after OVN services and
# ensures the provider bridge allows traffic by:
# 1. Removing fail_mode=secure from the bridge
# 2. Adding a NORMAL flow rule to allow all traffic through
#
# This is a one-time installation. After running this script, the fix will
# be applied automatically on every boot.
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Step 29: Install Provider Bridge Boot Fix ==="
echo ""
echo "This installs a systemd service that ensures SSH/management connectivity"
echo "after reboot by fixing OVN's fail_mode=secure on the provider bridge."
echo ""

# =============================================================================
# Step 1: Copy the fix script to /usr/local/bin
# =============================================================================
echo "[1/4] Installing fix script..."

if [ -f "${SCRIPT_DIR}/fix-provider-bridge-boot.sh" ]; then
    sudo cp "${SCRIPT_DIR}/fix-provider-bridge-boot.sh" /usr/local/bin/fix-provider-bridge.sh
    sudo chmod +x /usr/local/bin/fix-provider-bridge.sh
    echo "  ✓ Script installed to /usr/local/bin/fix-provider-bridge.sh"
else
    echo "  ✗ ERROR: fix-provider-bridge-boot.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

# =============================================================================
# Step 2: Install the systemd service
# =============================================================================
echo "[2/4] Installing systemd service..."

if [ -f "${SCRIPT_DIR}/fix-provider-bridge.service" ]; then
    sudo cp "${SCRIPT_DIR}/fix-provider-bridge.service" /etc/systemd/system/
    echo "  ✓ Service file installed to /etc/systemd/system/fix-provider-bridge.service"
else
    echo "  ✗ ERROR: fix-provider-bridge.service not found in ${SCRIPT_DIR}"
    exit 1
fi

# =============================================================================
# Step 3: Enable the service
# =============================================================================
echo "[3/4] Enabling systemd service..."

sudo systemctl daemon-reload
sudo systemctl enable fix-provider-bridge.service
echo "  ✓ Service enabled (will run on boot)"

# =============================================================================
# Step 4: Run the fix now (in case we're already in broken state)
# =============================================================================
echo "[4/4] Running fix now..."

sudo /usr/local/bin/fix-provider-bridge.sh br-provider
echo "  ✓ Fix applied"

# =============================================================================
# Verification
# =============================================================================
echo ""
echo "=== Verification ==="
echo "Bridge fail_mode:"
sudo ovs-vsctl get bridge br-provider fail_mode 2>/dev/null || echo "  (not set - good!)"

echo ""
echo "NORMAL flow rules on br-provider:"
sudo ovs-ofctl dump-flows br-provider 2>/dev/null | grep "actions=NORMAL" || echo "  (none found)"

echo ""
echo "Service status:"
sudo systemctl status fix-provider-bridge.service --no-pager || true

echo ""
echo "=== Installation Complete ==="
echo ""
echo "The provider bridge fix will now be applied automatically after every reboot."
echo "This ensures SSH and management connectivity is maintained even when OVN"
echo "sets fail_mode=secure on the provider bridge."
echo ""
