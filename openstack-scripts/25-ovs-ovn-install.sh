#!/bin/bash
###############################################################################
# 25-ovs-ovn-install.sh
# Install Open vSwitch (OVS) and Open Virtual Network (OVN)
# Migrate existing Linux bridge to OVS bridge
# Idempotent - safe to run multiple times
#
# This script installs:
# - openvswitch-switch: OVS daemon and utilities
# - ovn-central: OVN northbound/southbound databases (controller node)
# - ovn-host: OVN controller (all nodes including controller)
#
# Network Migration:
# - Detects existing Linux bridge (br-provider)
# - Migrates to OVS bridge with same IP configuration
# - Preserves network connectivity
#
# WARNING: This script will briefly disrupt network connectivity during
#          bridge migration. Run from console/IPMI if possible.
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

echo "=== Step 25: OVS and OVN Installation ==="
echo "Using Controller: ${CONTROLLER_IP}"

# =============================================================================
# Configuration - Auto-detected or set defaults
# =============================================================================
# Bridge name for provider network
PROVIDER_BRIDGE="br-provider"

# Detect physical interface (the one connected to br-provider or with IP)
detect_physical_interface() {
    # First, check if br-provider exists and has a port
    if [ -d "/sys/class/net/${PROVIDER_BRIDGE}/brif" ]; then
        # Linux bridge - get the first interface
        PHYS_IF=$(ls /sys/class/net/${PROVIDER_BRIDGE}/brif/ 2>/dev/null | head -1)
        if [ -n "$PHYS_IF" ]; then
            echo "$PHYS_IF"
            return
        fi
    fi
    
    # Check if it's already an OVS bridge
    if [ -x /usr/bin/ovs-vsctl ]; then
        PHYS_IF=$(sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} 2>/dev/null | /usr/bin/grep -E "^(en|eth)" | head -1)
        if [ -n "$PHYS_IF" ]; then
            echo "$PHYS_IF"
            return
        fi
    fi
    
    # Fallback: find first UP physical interface
    PHYS_IF=$(ip -br link show | /usr/bin/grep -E "^(en|eth)" | /usr/bin/grep "UP" | awk '{print $1}' | head -1)
    if [ -n "$PHYS_IF" ]; then
        echo "$PHYS_IF"
        return
    fi

    # Last resort: first physical interface
    ip -br link show | /usr/bin/grep -E "^(en|eth)" | awk '{print $1}' | head -1
}

PHYSICAL_INTERFACE=$(detect_physical_interface)

echo "Detected physical interface: ${PHYSICAL_INTERFACE:-NOT FOUND}"
echo "Provider bridge: ${PROVIDER_BRIDGE}"

# ============================================================================
# PART 0: Prerequisites Check
# ============================================================================
echo ""
echo "[0/7] Checking prerequisites..."

# Check we have a physical interface
if [ -z "$PHYSICAL_INTERFACE" ]; then
    echo "  ✗ ERROR: No physical interface detected!"
    echo "  Please set PHYSICAL_INTERFACE manually in this script."
    exit 1
fi
echo "  ✓ Physical interface: ${PHYSICAL_INTERFACE}"

# Check interface exists
if [ ! -d "/sys/class/net/${PHYSICAL_INTERFACE}" ]; then
    echo "  ✗ ERROR: Interface ${PHYSICAL_INTERFACE} does not exist!"
    exit 1
fi
echo "  ✓ Interface ${PHYSICAL_INTERFACE} exists"

# Get current IP configuration (we'll need to preserve this)
CURRENT_IP=$(ip -4 addr show ${PROVIDER_BRIDGE} 2>/dev/null | /usr/bin/grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
if [ -z "$CURRENT_IP" ]; then
    # Maybe IP is on the physical interface directly
    CURRENT_IP=$(ip -4 addr show ${PHYSICAL_INTERFACE} 2>/dev/null | /usr/bin/grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
fi

CURRENT_GW=$(ip route | /usr/bin/grep "^default" | awk '{print $3}' | head -1)

echo "  ✓ Current IP: ${CURRENT_IP:-NOT SET}"
echo "  ✓ Current Gateway: ${CURRENT_GW:-NOT SET}"

# Warn about network disruption
echo ""
echo "  ⚠️  WARNING: Bridge migration may briefly disrupt network!"
echo "  ⚠️  Ensure you have console/IPMI access if running remotely."
echo ""
read -p "  Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "  Cancelled."
    exit 0
fi

# ============================================================================
# PART 1: Install OVS
# ============================================================================
echo ""
echo "[1/7] Installing Open vSwitch..."

if [ -x /usr/bin/ovs-vsctl ]; then
    echo "  ✓ OVS already installed"
    /usr/bin/ovs-vsctl --version | head -1 | sed 's/^/    /'
else
    sudo apt-get update
    sudo apt-get install -y openvswitch-switch openvswitch-common
    echo "  ✓ OVS packages installed"
fi

# Ensure OVS service is running
sudo systemctl enable openvswitch-switch
sudo systemctl start openvswitch-switch

# Wait for OVS to be ready
MAX_RETRIES=10
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if sudo ovs-vsctl show &>/dev/null; then
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for OVS... (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 2
done

if ! sudo ovs-vsctl show &>/dev/null; then
    echo "  ✗ ERROR: OVS failed to start!"
    exit 1
fi
echo "  ✓ OVS service running"

# ============================================================================
# PART 2: Install OVN
# ============================================================================
echo ""
echo "[2/7] Installing OVN..."

# Check if OVN packages are available (Debian Trixie has them in main repos)
if ! apt-cache show ovn-central &>/dev/null; then
    echo "  ✗ ERROR: OVN packages not found!"
    echo "  On Debian Trixie, OVN should be in the main repository."
    exit 1
fi
# No backports needed for Trixie
OVN_INSTALL_OPTS=""

# Install OVN central (controller node only) and host (all nodes)
# LESSON LEARNED (2025-12-20): Check for actual packages, not just ovn-nbctl command
# ovn-nbctl comes from ovn-common which remains after purging ovn-central/ovn-host
OVN_CENTRAL_INSTALLED=$(dpkg -l ovn-central 2>/dev/null | grep -c "^ii" || echo "0")
OVN_HOST_INSTALLED=$(dpkg -l ovn-host 2>/dev/null | grep -c "^ii" || echo "0")

if [ "$OVN_CENTRAL_INSTALLED" -eq 1 ] && [ "$OVN_HOST_INSTALLED" -eq 1 ]; then
    echo "  ✓ OVN packages already installed"
    ovn-nbctl --version 2>/dev/null | head -1 | sed 's/^/    /' || true
else
    echo "  Installing OVN packages..."
    sudo apt-get install -y $OVN_INSTALL_OPTS ovn-central ovn-host
    echo "  ✓ OVN packages installed"
fi

# ============================================================================
# PART 3: Configure OVN
# ============================================================================
echo ""
echo "[3/7] Configuring OVN..."

# Ensure OVN database directory exists with proper permissions
sudo mkdir -p /var/lib/ovn
sudo mkdir -p /var/run/ovn
sudo chmod 755 /var/lib/ovn /var/run/ovn

# Initialize OVN databases if they don't exist
# LESSON LEARNED (2025-12-20): Fresh OVN install needs database initialization
# Without this, OVN services may fail to start or behave erratically
if [ ! -f /var/lib/ovn/ovnnb_db.db ]; then
    echo "  Initializing OVN Northbound database..."
    sudo ovsdb-tool create /var/lib/ovn/ovnnb_db.db /usr/share/ovn/ovn-nb.ovsschema
    echo "  ✓ OVN Northbound database initialized"
fi

if [ ! -f /var/lib/ovn/ovnsb_db.db ]; then
    echo "  Initializing OVN Southbound database..."
    sudo ovsdb-tool create /var/lib/ovn/ovnsb_db.db /usr/share/ovn/ovn-sb.ovsschema
    echo "  ✓ OVN Southbound database initialized"
fi

# Start OVN central services
sudo systemctl enable ovn-central
sudo systemctl start ovn-central

# Wait for OVN northbound DB to be ready
MAX_RETRIES=15
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if sudo ovn-nbctl --no-leader-only show &>/dev/null; then
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for OVN northbound DB... (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "  ✗ ERROR: OVN northbound DB not responding!"
    echo "  Checking OVN central status..."
    sudo systemctl status ovn-central --no-pager -l || true
    exit 1
fi
echo "  ✓ OVN central running"

# Configure OVN to connect to local databases (for AIO setup)
# Use hostname as system-id for consistent chassis naming
SYSTEM_ID=$(hostname)
sudo ovs-vsctl set open . external-ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock
sudo ovs-vsctl set open . external-ids:ovn-encap-type=geneve
sudo ovs-vsctl set open . external-ids:ovn-encap-ip=${CONTROLLER_IP}
sudo ovs-vsctl set open . external-ids:system-id="${SYSTEM_ID}"

# LESSON LEARNED (2025-12-20): Configure OVN controller tuning to prevent high CPU
# ovn-monitor-all=true: Monitor all tables (needed for single node)
# ovn-openflow-probe-interval: Reduce OpenFlow probe frequency
sudo ovs-vsctl set open . external-ids:ovn-monitor-all=true
sudo ovs-vsctl set open . external-ids:ovn-openflow-probe-interval=60

echo "  ✓ OVN external-ids configured (system-id: ${SYSTEM_ID})"

# Start OVN controller (host service)
sudo systemctl enable ovn-host
sudo systemctl start ovn-host

# Wait for OVN controller to register
sleep 3
if systemctl is-active --quiet ovn-controller; then
    echo "  ✓ OVN host service running"
else
    echo "  ✗ WARNING: OVN controller may not be running properly"
    sudo systemctl status ovn-controller --no-pager -l || true
fi

# Verify chassis registration
CHASSIS_CHECK=$(sudo ovn-sbctl show 2>/dev/null | grep -c "Chassis" || echo "0")
if [ "$CHASSIS_CHECK" -gt 0 ]; then
    echo "  ✓ OVN chassis registered"
else
    echo "  ⚠ OVN chassis not yet registered (may take a moment)"
fi

# CRITICAL: Fix OVN socket permissions for Neutron access
# OVN creates sockets with restrictive permissions (root:root 750)
# Neutron services need to connect to these sockets
# Setting 777 allows neutron user to access OVN databases
echo "  Setting OVN socket permissions for Neutron..."
sudo chmod 777 /var/run/ovn/ovnnb_db.sock /var/run/ovn/ovnsb_db.sock 2>/dev/null || true

# Create systemd override to fix permissions after OVN restarts
# This ensures permissions persist across service restarts/reboots
sudo mkdir -p /etc/systemd/system/ovn-central.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/ovn-central.service.d/socket-permissions.conf > /dev/null
[Service]
ExecStartPost=/bin/bash -c 'sleep 2 && chmod 777 /var/run/ovn/ovnnb_db.sock /var/run/ovn/ovnsb_db.sock 2>/dev/null || true'
EOF
sudo systemctl daemon-reload
echo "  ✓ OVN socket permissions set (persistent)"

# ============================================================================
# PART 3.5: Configure OVN Log Rotation
# ============================================================================
echo ""
echo "[3.5/7] Configuring OVN log rotation..."

# LESSON LEARNED (2025-12-20): OVN logs can grow very large (37MB+ compressed, 144MB+
# uncompressed per file) especially when OVN controller is under stress. This can:
# - Fill up /var/log partition
# - Cause high disk I/O
# - Make debugging difficult with massive log files
# Configure aggressive log rotation to keep logs manageable.

LOGROTATE_OVN="/etc/logrotate.d/ovn"

if [ ! -f "$LOGROTATE_OVN" ] || ! grep -q "daily" "$LOGROTATE_OVN" 2>/dev/null; then
    cat <<'EOF' | sudo tee "$LOGROTATE_OVN" > /dev/null
# OVN log rotation - keeps logs manageable
# Generated by 25-ovs-ovn-install.sh

/var/log/ovn/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    size 50M
    postrotate
        # Notify OVN services to reopen logs
        /bin/systemctl kill -s HUP ovn-controller 2>/dev/null || true
        /bin/systemctl kill -s HUP ovn-central 2>/dev/null || true
    endscript
}
EOF
    echo "  ✓ OVN logrotate configured (daily, max 50MB, 7 rotations)"
else
    echo "  ✓ OVN logrotate already configured"
fi

# Also configure OVS log rotation
LOGROTATE_OVS="/etc/logrotate.d/openvswitch"
if [ ! -f "$LOGROTATE_OVS" ] || ! grep -q "size 50M" "$LOGROTATE_OVS" 2>/dev/null; then
    cat <<'EOF' | sudo tee "$LOGROTATE_OVS" > /dev/null
# Open vSwitch log rotation
# Generated by 25-ovs-ovn-install.sh

/var/log/openvswitch/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    size 50M
    postrotate
        /bin/systemctl kill -s HUP openvswitch-switch 2>/dev/null || true
    endscript
}
EOF
    echo "  ✓ OVS logrotate configured"
else
    echo "  ✓ OVS logrotate already configured"
fi

# Run logrotate once to clean up any existing large logs
echo "  Running initial log rotation..."
sudo logrotate -f /etc/logrotate.d/ovn 2>/dev/null || true
sudo logrotate -f /etc/logrotate.d/openvswitch 2>/dev/null || true
echo "  ✓ Initial log rotation complete"

# ============================================================================
# PART 4: Check if bridge migration is needed
# ============================================================================
echo ""
echo "[4/7] Checking bridge configuration..."

MIGRATION_NEEDED=false

# Check if br-provider exists as OVS bridge
if sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE} 2>/dev/null; then
    echo "  ✓ ${PROVIDER_BRIDGE} is already an OVS bridge"
    
    # Check if physical interface is attached
    if sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} | /usr/bin/grep -q "^${PHYSICAL_INTERFACE}$"; then
        echo "  ✓ ${PHYSICAL_INTERFACE} is attached to ${PROVIDER_BRIDGE}"
    else
        echo "  Adding ${PHYSICAL_INTERFACE} to ${PROVIDER_BRIDGE}..."
        sudo ovs-vsctl add-port ${PROVIDER_BRIDGE} ${PHYSICAL_INTERFACE}
        echo "  ✓ ${PHYSICAL_INTERFACE} added to ${PROVIDER_BRIDGE}"
    fi
    
elif [ -d "/sys/class/net/${PROVIDER_BRIDGE}/bridge" ]; then
    echo "  ! ${PROVIDER_BRIDGE} is a Linux bridge - migration needed"
    MIGRATION_NEEDED=true
    
elif [ -d "/sys/class/net/${PROVIDER_BRIDGE}" ]; then
    echo "  ! ${PROVIDER_BRIDGE} exists but is not a bridge - will recreate as OVS"
    MIGRATION_NEEDED=true
    
else
    echo "  ${PROVIDER_BRIDGE} does not exist - will create as OVS bridge"
    MIGRATION_NEEDED=true
fi

# ============================================================================
# PART 5: Migrate Linux bridge to OVS bridge (if needed)
# ============================================================================
echo ""
echo "[5/7] Bridge migration..."

if [ "$MIGRATION_NEEDED" = true ]; then
    echo "  Starting bridge migration..."
    echo "  ⚠️  Network may be briefly interrupted..."
    
    # Save current IP config
    SAVED_IP="$CURRENT_IP"
    SAVED_GW="$CURRENT_GW"
    
    # Step 1: Remove physical interface from Linux bridge
    if [ -d "/sys/class/net/${PROVIDER_BRIDGE}/bridge" ]; then
        echo "  Removing ${PHYSICAL_INTERFACE} from Linux bridge..."
        sudo ip link set ${PHYSICAL_INTERFACE} nomaster 2>/dev/null || true
        
        # Delete Linux bridge
        echo "  Deleting Linux bridge ${PROVIDER_BRIDGE}..."
        sudo ip link set ${PROVIDER_BRIDGE} down 2>/dev/null || true
        sudo brctl delbr ${PROVIDER_BRIDGE} 2>/dev/null || sudo ip link delete ${PROVIDER_BRIDGE} type bridge 2>/dev/null || true
    fi
    
    # Step 2: Create OVS bridge
    echo "  Creating OVS bridge ${PROVIDER_BRIDGE}..."
    sudo ovs-vsctl --may-exist add-br ${PROVIDER_BRIDGE}
    
    # Step 3: Add physical interface to OVS bridge
    echo "  Adding ${PHYSICAL_INTERFACE} to OVS bridge..."
    sudo ovs-vsctl --may-exist add-port ${PROVIDER_BRIDGE} ${PHYSICAL_INTERFACE}
    
    # Step 4: Bring up interfaces
    echo "  Bringing up interfaces..."
    sudo ip link set ${PHYSICAL_INTERFACE} up
    sudo ip link set ${PROVIDER_BRIDGE} up
    
    # Step 5: Restore IP configuration
    if [ -n "$SAVED_IP" ]; then
        echo "  Restoring IP configuration: ${SAVED_IP}..."
        sudo ip addr add ${SAVED_IP} dev ${PROVIDER_BRIDGE} 2>/dev/null || true
    fi
    
    if [ -n "$SAVED_GW" ]; then
        echo "  Restoring default gateway: ${SAVED_GW}..."
        sudo ip route add default via ${SAVED_GW} dev ${PROVIDER_BRIDGE} 2>/dev/null || true
    fi
    
    echo "  ✓ Bridge migration complete"
    
    # Verify connectivity
    sleep 2
    if ping -c 1 -W 2 ${SAVED_GW:-8.8.8.8} &>/dev/null; then
        echo "  ✓ Network connectivity verified"
    else
        echo "  ⚠️  WARNING: Network connectivity check failed!"
        echo "  ⚠️  You may need to manually restore network configuration."
    fi
else
    echo "  ✓ No migration needed"
fi

# ============================================================================
# PART 6: Configure OVS bridge for OpenStack
# ============================================================================
echo ""
echo "[6/7] Configuring OVS bridge for OpenStack..."

# Set bridge mapping for Neutron (physnet1 -> br-provider)
sudo ovs-vsctl set open . external-ids:ovn-bridge-mappings=physnet1:${PROVIDER_BRIDGE}
echo "  ✓ Bridge mapping set: physnet1 -> ${PROVIDER_BRIDGE}"

# ============================================================================
# PART 7: Make network configuration persistent
# ============================================================================
echo ""
echo "[7/7] Making configuration persistent..."

# Create/update network interfaces configuration
INTERFACES_FILE="/etc/network/interfaces.d/openstack-bridge"

# Backup existing file if present
if [ -f "$INTERFACES_FILE" ]; then
    sudo cp "$INTERFACES_FILE" "${INTERFACES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

# Get IP without CIDR for gateway config
IP_ADDR=$(echo "$CURRENT_IP" | cut -d'/' -f1)
IP_NETMASK=$(ipcalc -m ${CURRENT_IP} 2>/dev/null | /usr/bin/grep -oP '(?<=NETMASK=).*' || echo "255.255.255.0")

cat <<EOF | sudo tee ${INTERFACES_FILE} > /dev/null
# OpenStack OVS Provider Bridge Configuration
# Generated by 25-ovs-ovn-install.sh on $(date)
# DO NOT EDIT MANUALLY - rerun script to update

# Physical interface - no IP, member of OVS bridge
auto ${PHYSICAL_INTERFACE}
iface ${PHYSICAL_INTERFACE} inet manual
    ovs_bridge ${PROVIDER_BRIDGE}
    ovs_type OVSPort

# OVS Provider Bridge
auto ${PROVIDER_BRIDGE}
iface ${PROVIDER_BRIDGE} inet static
    address ${IP_ADDR}
    netmask ${IP_NETMASK}
    gateway ${CURRENT_GW}
    ovs_type OVSBridge
    ovs_ports ${PHYSICAL_INTERFACE}
EOF

echo "  ✓ Network configuration saved to ${INTERFACES_FILE}"

# Ensure main interfaces file sources the directory
if ! /usr/bin/grep -q "source /etc/network/interfaces.d" /etc/network/interfaces 2>/dev/null; then
    echo "source /etc/network/interfaces.d/*" | sudo tee -a /etc/network/interfaces > /dev/null
    echo "  ✓ Added interfaces.d sourcing to /etc/network/interfaces"
fi

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "=== Verification ==="
echo ""

ERRORS=0

# Check OVS service
if systemctl is-active --quiet openvswitch-switch; then
    echo "  ✓ openvswitch-switch is running"
else
    echo "  ✗ openvswitch-switch is NOT running!"
    ERRORS=$((ERRORS + 1))
fi

# Check OVN central
if systemctl is-active --quiet ovn-central; then
    echo "  ✓ ovn-central is running"
else
    echo "  ✗ ovn-central is NOT running!"
    ERRORS=$((ERRORS + 1))
fi

# Check OVN host/controller
if systemctl is-active --quiet ovn-host; then
    echo "  ✓ ovn-host is running"
else
    echo "  ✗ ovn-host is NOT running!"
    ERRORS=$((ERRORS + 1))
fi

# Check OVS bridge exists
if sudo ovs-vsctl br-exists ${PROVIDER_BRIDGE}; then
    echo "  ✓ OVS bridge ${PROVIDER_BRIDGE} exists"
else
    echo "  ✗ OVS bridge ${PROVIDER_BRIDGE} NOT found!"
    ERRORS=$((ERRORS + 1))
fi

# Check physical interface is attached
if sudo ovs-vsctl list-ports ${PROVIDER_BRIDGE} | /usr/bin/grep -q "^${PHYSICAL_INTERFACE}$"; then
    echo "  ✓ ${PHYSICAL_INTERFACE} attached to ${PROVIDER_BRIDGE}"
else
    echo "  ✗ ${PHYSICAL_INTERFACE} NOT attached to ${PROVIDER_BRIDGE}!"
    ERRORS=$((ERRORS + 1))
fi

# Check IP is assigned
if ip addr show ${PROVIDER_BRIDGE} | /usr/bin/grep -q "inet "; then
    echo "  ✓ IP address configured on ${PROVIDER_BRIDGE}"
else
    echo "  ✗ No IP address on ${PROVIDER_BRIDGE}!"
    ERRORS=$((ERRORS + 1))
fi

# Check network connectivity
if ping -c 1 -W 2 ${CURRENT_GW:-8.8.8.8} &>/dev/null; then
    echo "  ✓ Network connectivity OK"
else
    echo "  ✗ Network connectivity FAILED!"
    ERRORS=$((ERRORS + 1))
fi

# Show OVS configuration
echo ""
echo "OVS Bridge Configuration:"
sudo ovs-vsctl show | head -20

echo ""
echo "OVN External IDs:"
sudo ovs-vsctl get open . external-ids | tr ',' '\n' | sed 's/^/  /'

# Final summary
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== OVS/OVN installation complete ==="
    echo "=========================================="
    echo ""
    echo "Components installed:"
    echo "  - Open vSwitch (openvswitch-switch)"
    echo "  - OVN Central (ovn-central)"
    echo "  - OVN Host (ovn-host)"
    echo ""
    echo "Bridge configuration:"
    echo "  - Provider bridge: ${PROVIDER_BRIDGE} (OVS)"
    echo "  - Physical interface: ${PHYSICAL_INTERFACE}"
    echo "  - IP: ${CURRENT_IP}"
    echo "  - Gateway: ${CURRENT_GW}"
    echo ""
    echo "OVN mapping: physnet1 -> ${PROVIDER_BRIDGE}"
    echo ""
    echo "Next: Run 26-neutron-install.sh"
else
    echo "=== Installation completed with $ERRORS error(s) ==="
    echo "=========================================="
    echo ""
    echo "Please check the errors above and verify network connectivity."
    echo "If network is down, you may need to manually restore configuration."
    exit 1
fi
