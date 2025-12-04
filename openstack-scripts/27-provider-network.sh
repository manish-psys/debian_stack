#!/bin/bash
###############################################################################
# 27-provider-network.sh
# Create provider flat network (uses LAN DHCP)
###############################################################################
set -e

# Configuration - EDIT THESE
SUBNET_RANGE="192.168.2.0/24"
GATEWAY="192.168.2.1"
DNS_SERVER="8.8.8.8"

echo "=== Step 27: Provider Network Creation ==="

source ~/admin-openrc

echo "[1/2] Creating provider network..."
openstack network create --external \
    --provider-physical-network physnet1 \
    --provider-network-type flat \
    public

echo "[2/2] Creating provider subnet (no DHCP - uses LAN DHCP)..."
openstack subnet create --network public \
    --subnet-range ${SUBNET_RANGE} \
    --gateway ${GATEWAY} \
    --dns-nameserver ${DNS_SERVER} \
    --no-dhcp \
    public-subnet

echo ""
echo "Network list:"
openstack network list

echo ""
echo "Subnet list:"
openstack subnet list

echo ""
echo "=== Provider network created ==="
echo "VMs on this network will get IPs from your LAN DHCP server."
echo "Next: Run 28-cinder-db.sh"
