#!/bin/bash
###############################################################################
# 09-ceph-mon-mgr-start.sh
# Start and enable Ceph monitor and manager services (Improved & Idempotent)
###############################################################################
set -e

# Configuration - EDIT THIS
HOSTNAME="osctl1"

echo "=== Step 9: Start Ceph Monitor and Manager ==="

# ============================================================================
# PART 1: Ceph Monitor
# ============================================================================
echo "[1/4] Enabling and starting Ceph monitor..."
sudo systemctl enable ceph-mon@${HOSTNAME} 2>/dev/null || true
sudo systemctl start ceph-mon@${HOSTNAME}

# Wait for monitor to be ready
echo "  Waiting for monitor to be ready..."
sleep 3

# Verify monitor is running
if ! sudo systemctl is-active --quiet ceph-mon@${HOSTNAME}; then
    echo "ERROR: Ceph monitor failed to start!"
    sudo systemctl status ceph-mon@${HOSTNAME} --no-pager
    exit 1
fi
echo "  ✓ Ceph monitor is running"

# ============================================================================
# PART 2: Create MGR keyring (if not exists)
# ============================================================================
echo "[2/4] Setting up Ceph manager keyring..."
MGR_DIR="/var/lib/ceph/mgr/ceph-${HOSTNAME}"
MGR_KEYRING="${MGR_DIR}/keyring"

if [ -f "${MGR_KEYRING}" ]; then
    echo "  ✓ MGR keyring already exists, skipping creation"
else
    echo "  Creating MGR directory and keyring..."
    sudo mkdir -p "${MGR_DIR}"
    
    # Create mgr keyring using ceph auth
    sudo ceph auth get-or-create mgr.${HOSTNAME} \
        mon 'allow profile mgr' \
        osd 'allow *' \
        mds 'allow *' \
        -o "${MGR_KEYRING}"
    
    # Set correct ownership
    sudo chown -R ceph:ceph "${MGR_DIR}"
    echo "  ✓ MGR keyring created"
fi

# ============================================================================
# PART 3: Start Ceph Manager
# ============================================================================
echo "[3/4] Enabling and starting Ceph manager..."
sudo systemctl enable ceph-mgr@${HOSTNAME} 2>/dev/null || true
sudo systemctl restart ceph-mgr@${HOSTNAME}

# Wait for manager to be ready
echo "  Waiting for manager to be ready..."
sleep 5

# Verify manager is running
if ! sudo systemctl is-active --quiet ceph-mgr@${HOSTNAME}; then
    echo "ERROR: Ceph manager failed to start!"
    sudo systemctl status ceph-mgr@${HOSTNAME} --no-pager
    sudo journalctl -u ceph-mgr@${HOSTNAME} --no-pager -n 20
    exit 1
fi
echo "  ✓ Ceph manager is running"

# ============================================================================
# PART 4: Verify Ceph Cluster Status
# ============================================================================
echo "[4/4] Verifying Ceph cluster status..."
echo ""
sudo ceph -s

echo ""
echo "Service status:"
echo "---------------"
systemctl is-active ceph-mon@${HOSTNAME} && echo "ceph-mon@${HOSTNAME}: active" || echo "ceph-mon@${HOSTNAME}: inactive"
systemctl is-active ceph-mgr@${HOSTNAME} && echo "ceph-mgr@${HOSTNAME}: active" || echo "ceph-mgr@${HOSTNAME}: inactive"

echo ""
echo "=== Ceph MON and MGR started successfully ==="
echo "Next: Run 10-ceph-osd-create.sh"
