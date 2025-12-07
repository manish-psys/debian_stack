#!/bin/bash
###############################################################################
# 28-provider-network-cleanup.sh
# Remove provider network and subnet
# WARNING: This will disconnect any VMs using this network!
###############################################################################

set -u

# Network names (must match 28-provider-network.sh)
PROVIDER_NET_NAME="provider-net"
PROVIDER_SUBNET_NAME="provider-subnet"

echo "=== Cleanup: Provider Network ==="
echo ""
echo "WARNING: This will delete the provider network and subnet!"
echo "Any VMs using this network will lose connectivity!"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Source admin credentials
if [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
else
    echo "ERROR: ~/admin-openrc not found!"
    exit 1
fi

echo ""
echo "[1/3] Checking for ports using this network..."
PORTS=$(openstack port list --network "${PROVIDER_NET_NAME}" -f value -c ID 2>/dev/null || true)
if [ -n "$PORTS" ]; then
    echo "  Found ports on this network:"
    openstack port list --network "${PROVIDER_NET_NAME}"
    echo ""
    read -p "Delete these ports? (yes/no): " DELETE_PORTS
    if [ "$DELETE_PORTS" = "yes" ]; then
        for PORT in $PORTS; do
            echo "  Deleting port $PORT..."
            openstack port delete "$PORT" 2>/dev/null || true
        done
        echo "  ✓ Ports deleted"
    else
        echo "  Cannot delete network with active ports."
        exit 1
    fi
else
    echo "  ✓ No ports found"
fi

echo ""
echo "[2/3] Deleting subnet..."
if openstack subnet show "${PROVIDER_SUBNET_NAME}" &>/dev/null; then
    if openstack subnet delete "${PROVIDER_SUBNET_NAME}"; then
        echo "  ✓ Subnet '${PROVIDER_SUBNET_NAME}' deleted"
    else
        echo "  ✗ Failed to delete subnet"
    fi
else
    echo "  ✓ Subnet '${PROVIDER_SUBNET_NAME}' not found (already deleted)"
fi

echo ""
echo "[3/3] Deleting network..."
if openstack network show "${PROVIDER_NET_NAME}" &>/dev/null; then
    if openstack network delete "${PROVIDER_NET_NAME}"; then
        echo "  ✓ Network '${PROVIDER_NET_NAME}' deleted"
    else
        echo "  ✗ Failed to delete network"
    fi
else
    echo "  ✓ Network '${PROVIDER_NET_NAME}' not found (already deleted)"
fi

echo ""
echo "=== Provider Network Cleanup Complete ==="
echo ""
echo "Verify with:"
echo "  openstack network list"
echo "  openstack subnet list"
