#!/bin/bash
###############################################################################
# 05-ceph-install.sh
# Install Ceph packages from Debian repositories
###############################################################################
set -e

echo "=== Step 5: Ceph Installation ==="

echo "[1/1] Installing Ceph packages..."
sudo apt install -y ceph ceph-common ceph-mgr ceph-mon ceph-osd

echo ""
echo "=== Ceph installation complete ==="
echo "Installed version:"
ceph --version
echo ""
echo "Next: Run 06-ceph-disk-prep.sh"
