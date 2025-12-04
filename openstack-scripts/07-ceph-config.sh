#!/bin/bash
###############################################################################
# 07-ceph-config.sh
# Create Ceph configuration file
###############################################################################
set -e

# Configuration - EDIT THESE
HOSTNAME="osctl1"
IP_ADDRESS="192.168.2.9"
PUBLIC_NETWORK="192.168.2.0/24"

echo "=== Step 7: Ceph Configuration ==="

echo "[1/2] Creating Ceph directories..."
sudo mkdir -p /etc/ceph
sudo mkdir -p /var/lib/ceph/mon/ceph-${HOSTNAME}

echo "[2/2] Generating FSID and creating ceph.conf..."
FSID=$(uuidgen)

cat <<EOF | sudo tee /etc/ceph/ceph.conf
[global]
fsid = ${FSID}
mon_initial_members = ${HOSTNAME}
mon_host = ${IP_ADDRESS}
public_network = ${PUBLIC_NETWORK}
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx
osd_pool_default_size = 1
osd_pool_default_min_size = 1
osd_crush_chooseleaf_type = 0
EOF

echo ""
echo "=== Ceph configuration created ==="
echo "FSID: ${FSID}"
echo ""
cat /etc/ceph/ceph.conf
echo ""
echo "Next: Run 08-ceph-mon-init.sh"
