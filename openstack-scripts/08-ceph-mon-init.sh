#!/bin/bash
###############################################################################
# 08-ceph-mon-init.sh
# Initialize Ceph monitor for Ceph Reef
#
# This script creates the initial monitor (MON) which is the cluster
# coordinator. The MON maintains the cluster map and handles authentication.
###############################################################################
set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

# Configuration from environment
HOSTNAME="${CONTROLLER_HOSTNAME}"
IP_ADDRESS="${CONTROLLER_IP}"

echo "=== Step 8: Ceph Monitor Initialization ==="
echo "Hostname: ${HOSTNAME}"
echo "IP: ${IP_ADDRESS}"

# Get FSID from ceph.conf
FSID=$(awk '/fsid/ {print $3}' /etc/ceph/ceph.conf)
if [ -z "$FSID" ]; then
    echo "ERROR: Could not find FSID in /etc/ceph/ceph.conf"
    echo "Please run 07-ceph-config.sh first."
    exit 1
fi
echo "Using FSID: ${FSID}"

echo "[1/5] Creating monitor keyring..."
sudo ceph-authtool --create-keyring /etc/ceph/ceph.mon.keyring \
    --gen-key -n mon. --cap mon 'allow *'

echo "[2/5] Creating admin keyring..."
sudo ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring \
    --gen-key -n client.admin \
    --cap mon 'allow *' --cap osd 'allow *' \
    --cap mgr 'allow *' --cap mds 'allow *'

echo "[3/5] Importing admin keyring into monitor keyring..."
sudo ceph-authtool /etc/ceph/ceph.mon.keyring \
    --import-keyring /etc/ceph/ceph.client.admin.keyring

echo "[4/5] Creating monmap..."
sudo monmaptool --create --add ${HOSTNAME} ${IP_ADDRESS}:6789 \
    --fsid "${FSID}" /tmp/monmap

echo "[5/5] Initializing monitor..."
sudo mkdir -p /var/lib/ceph/mon/ceph-${HOSTNAME}
sudo ceph-mon --mkfs -i ${HOSTNAME} \
    --monmap /tmp/monmap \
    --keyring /etc/ceph/ceph.mon.keyring
sudo chown -R ceph:ceph /var/lib/ceph/mon/ceph-${HOSTNAME}

echo ""
echo "=== Ceph monitor initialized ==="
echo "Next: Run 09-ceph-mon-mgr-start.sh"
