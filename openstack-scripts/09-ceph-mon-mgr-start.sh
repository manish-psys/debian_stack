#!/bin/bash
###############################################################################
# 09-ceph-mon-mgr-start.sh
# Start and enable Ceph monitor and manager services
###############################################################################
set -e

# Configuration - EDIT THIS
HOSTNAME="osctl1"

echo "=== Step 9: Start Ceph Monitor and Manager ==="

echo "[1/2] Enabling and starting Ceph monitor..."
sudo systemctl enable --now ceph-mon@${HOSTNAME}

echo "[2/2] Enabling and starting Ceph manager..."
sudo systemctl enable --now ceph-mgr@${HOSTNAME}

echo ""
echo "Waiting for services to start..."
sleep 5

echo ""
echo "Service status:"
sudo systemctl status ceph-mon@${HOSTNAME} --no-pager || true
echo ""
sudo systemctl status ceph-mgr@${HOSTNAME} --no-pager || true

echo ""
echo "=== Ceph MON and MGR started ==="
echo "Next: Run 10-ceph-osd-create.sh"
