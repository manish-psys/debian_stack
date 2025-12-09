#!/bin/bash
###############################################################################
# 05-ceph-install.sh
# Install Ceph Reef (18.2.7) packages from Debian Trixie repositories
#
# Ceph Reef is an LTS release providing:
# - RBD (RADOS Block Device) for VM volumes
# - RGW (RADOS Gateway) for S3-compatible object storage
# - CephFS for shared filesystem storage
###############################################################################
set -e

echo "=== Step 5: Ceph Reef Installation ==="

echo "[1/2] Installing Ceph packages..."
sudo apt install -y \
    ceph \
    ceph-common \
    ceph-mgr \
    ceph-mon \
    ceph-osd \
    ceph-mds \
    radosgw \
    python3-ceph-argparse \
    python3-cephfs \
    python3-rados \
    python3-rbd

echo "[2/2] Installing additional tools..."
sudo apt install -y gdisk parted

echo ""
echo "=== Ceph installation complete ==="
echo "Installed version:"
ceph --version
echo ""
echo "Next: Run 06-ceph-disk-prep.sh"
