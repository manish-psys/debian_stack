#!/bin/bash
###############################################################################
# 07-ceph-config.sh
# Create Ceph Reef configuration file
#
# This creates a minimal single-node Ceph cluster configuration suitable
# for all-in-one OpenStack deployments.
###############################################################################
set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

# Configuration
HOSTNAME="${CONTROLLER_HOSTNAME}"
IP_ADDRESS="${CONTROLLER_IP}"
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

# Single-node cluster settings
osd_pool_default_size = 1
osd_pool_default_min_size = 1
osd_crush_chooseleaf_type = 0

# Performance tuning for all-in-one deployment
osd_memory_target = 4294967296
mon_max_pg_per_osd = 300

# Enable RBD, RGW, and CephFS
[client]
rbd_default_features = 1
EOF

echo ""
echo "=== Ceph configuration created ==="
echo "FSID: ${FSID}"
echo ""
cat /etc/ceph/ceph.conf
echo ""
echo "Next: Run 08-ceph-mon-init.sh"
