#!/bin/bash
###############################################################################
# 11-ceph-pools.sh
# Create Ceph pools for OpenStack services
###############################################################################
set -e

echo "=== Step 11: Create Ceph Pools for OpenStack ==="

echo "[1/3] Creating pools..."
sudo ceph osd pool create volumes 64
sudo ceph osd pool create images 64
sudo ceph osd pool create backups 32
sudo ceph osd pool create vms 32

echo "[2/3] Setting replication size to 1 (LAB ONLY!)..."
for p in volumes images backups vms; do
    sudo ceph osd pool set $p size 1
done

echo "[3/3] Creating Cinder client for OpenStack..."
sudo ceph auth get-or-create client.cinder \
    mon 'allow r' \
    osd 'allow class-read object_prefix rbd_children, allow rwx pool=volumes, allow rwx pool=images, allow rwx pool=backups, allow rwx pool=vms' \
    | sudo tee /etc/ceph/ceph.client.cinder.keyring

sudo chmod 600 /etc/ceph/ceph.client.cinder.keyring

echo ""
echo "Pool list:"
sudo ceph osd pool ls detail

echo ""
echo "=== Ceph pools created ==="
echo "Keyring saved to: /etc/ceph/ceph.client.cinder.keyring"
echo "Next: Run 12-openstack-base.sh"
