#!/bin/bash
###############################################################################
# 34-smoke-test-cleanup.sh
# Cleanup script for smoke test resources
# Idempotent - safe to run multiple times
#
# This script:
# - Deletes all smoketest VMs (any status)
# - Deletes all smoketest volumes
# - Cleans up orphaned ports
# - Optionally removes persistent resources (keypair, image, flavor)
#
# Usage:
#   ./34-smoke-test-cleanup.sh          # Clean VMs and volumes only
#   ./34-smoke-test-cleanup.sh --all    # Clean everything including image/flavor
###############################################################################
set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/openstack-env.sh" ]; then
    source "$SCRIPT_DIR/openstack-env.sh"
elif [ -f "./openstack-env.sh" ]; then
    source "./openstack-env.sh"
else
    echo "ERROR: openstack-env.sh not found!"
    exit 1
fi

# Source admin credentials
if [ -f ~/admin-openrc ]; then
    source ~/admin-openrc
else
    echo "ERROR: ~/admin-openrc not found!"
    exit 1
fi

echo "=========================================="
echo "=== Smoke Test Cleanup ==="
echo "=========================================="
echo ""

# Parse arguments
CLEAN_ALL=false
if [ "$1" = "--all" ] || [ "$1" = "-a" ]; then
    CLEAN_ALL=true
    echo "Mode: Full cleanup (including persistent resources)"
else
    echo "Mode: Standard cleanup (VMs and volumes only)"
    echo "      Use --all to also remove image, flavor, keypair"
fi
echo ""

ERRORS=0

###############################################################################
# Phase 1: Delete smoketest VMs
###############################################################################
echo "[1/5] Cleaning up smoketest VMs..."

# Find all smoketest VMs (any status)
SMOKETEST_VMS=$(openstack server list --all-projects -f value -c ID -c Name 2>/dev/null | grep "smoketest-vm" | awk '{print $1}' || true)

if [ -n "$SMOKETEST_VMS" ]; then
    VM_COUNT=$(echo "$SMOKETEST_VMS" | wc -w)
    echo "  Found $VM_COUNT smoketest VM(s) to delete"

    for VM_ID in $SMOKETEST_VMS; do
        VM_NAME=$(openstack server show "$VM_ID" -f value -c name 2>/dev/null || echo "$VM_ID")
        VM_STATUS=$(openstack server show "$VM_ID" -f value -c status 2>/dev/null || echo "UNKNOWN")

        echo "  Deleting VM: $VM_NAME (status: $VM_STATUS)..."

        # Force delete handles VMs in ERROR state
        if openstack server delete --force "$VM_ID" 2>/dev/null; then
            echo "    Deleted"
        else
            echo "    Warning: Delete command failed (may already be deleted)"
        fi
    done

    # Wait for VMs to be fully deleted
    echo "  Waiting for VMs to be fully deleted..."
    for i in {1..30}; do
        REMAINING=$(openstack server list --all-projects -f value -c Name 2>/dev/null | grep -c "smoketest-vm" || true)
        if [ "$REMAINING" -eq 0 ]; then
            break
        fi
        sleep 2
    done

    REMAINING=$(openstack server list --all-projects -f value -c Name 2>/dev/null | grep -c "smoketest-vm" || true)
    if [ "$REMAINING" -eq 0 ]; then
        echo "  All smoketest VMs deleted"
    else
        echo "  Warning: $REMAINING VM(s) still present"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "  No smoketest VMs found"
fi

###############################################################################
# Phase 2: Delete smoketest volumes
###############################################################################
echo ""
echo "[2/5] Cleaning up smoketest volumes..."

# Find all smoketest volumes
SMOKETEST_VOLS=$(openstack volume list --all-projects -f value -c ID -c Name 2>/dev/null | grep "smoketest-vol" | awk '{print $1}' || true)

if [ -n "$SMOKETEST_VOLS" ]; then
    VOL_COUNT=$(echo "$SMOKETEST_VOLS" | wc -w)
    echo "  Found $VOL_COUNT smoketest volume(s) to delete"

    for VOL_ID in $SMOKETEST_VOLS; do
        VOL_NAME=$(openstack volume show "$VOL_ID" -f value -c name 2>/dev/null || echo "$VOL_ID")
        VOL_STATUS=$(openstack volume show "$VOL_ID" -f value -c status 2>/dev/null || echo "UNKNOWN")

        echo "  Deleting volume: $VOL_NAME (status: $VOL_STATUS)..."

        # Detach first if in-use
        if [ "$VOL_STATUS" = "in-use" ]; then
            echo "    Volume is in-use, attempting to detach..."
            # Get attachment info
            ATTACHED_TO=$(openstack volume show "$VOL_ID" -f value -c attachments 2>/dev/null || true)
            if [ -n "$ATTACHED_TO" ]; then
                # Try force detach
                openstack volume set --state available "$VOL_ID" 2>/dev/null || true
            fi
            sleep 2
        fi

        # Force delete for volumes in error state
        if [ "$VOL_STATUS" = "error" ] || [ "$VOL_STATUS" = "error_deleting" ]; then
            openstack volume set --state available "$VOL_ID" 2>/dev/null || true
            sleep 1
        fi

        if openstack volume delete --force "$VOL_ID" 2>/dev/null; then
            echo "    Deleted"
        else
            echo "    Warning: Delete command failed"
        fi
    done

    # Wait for volumes to be deleted
    echo "  Waiting for volumes to be fully deleted..."
    for i in {1..30}; do
        REMAINING=$(openstack volume list --all-projects -f value -c Name 2>/dev/null | grep -c "smoketest-vol" || true)
        if [ "$REMAINING" -eq 0 ]; then
            break
        fi
        sleep 2
    done

    REMAINING=$(openstack volume list --all-projects -f value -c Name 2>/dev/null | grep -c "smoketest-vol" || true)
    if [ "$REMAINING" -eq 0 ]; then
        echo "  All smoketest volumes deleted"
    else
        echo "  Warning: $REMAINING volume(s) still present"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "  No smoketest volumes found"
fi

###############################################################################
# Phase 3: Clean up orphaned ports
###############################################################################
echo ""
echo "[3/5] Cleaning up orphaned ports..."

# Find ports with no device owner (orphaned)
ORPHAN_PORTS=$(openstack port list --device-owner "" -f value -c ID 2>/dev/null || true)

if [ -n "$ORPHAN_PORTS" ]; then
    PORT_COUNT=$(echo "$ORPHAN_PORTS" | wc -w)
    echo "  Found $PORT_COUNT orphaned port(s)"

    for PORT_ID in $ORPHAN_PORTS; do
        echo "  Deleting orphaned port: $PORT_ID..."
        if openstack port delete "$PORT_ID" 2>/dev/null; then
            echo "    Deleted"
        else
            echo "    Warning: Could not delete (may be in use)"
        fi
    done
else
    echo "  No orphaned ports found"
fi

###############################################################################
# Phase 4: Clean up smoketest keypair
###############################################################################
echo ""
echo "[4/5] Cleaning up keypair..."

if [ "$CLEAN_ALL" = true ]; then
    if openstack keypair show smoketest-key &>/dev/null; then
        openstack keypair delete smoketest-key
        echo "  Keypair 'smoketest-key' deleted"
    else
        echo "  Keypair 'smoketest-key' not found"
    fi

    # Remove local key file
    if [ -f ~/smoketest-key.pem ]; then
        rm -f ~/smoketest-key.pem
        echo "  Local key file ~/smoketest-key.pem removed"
    fi
else
    echo "  Skipping (use --all to remove)"
fi

###############################################################################
# Phase 5: Clean up persistent resources (image, flavor)
###############################################################################
echo ""
echo "[5/5] Cleaning up persistent resources..."

if [ "$CLEAN_ALL" = true ]; then
    # Delete cirros image
    if openstack image show cirros &>/dev/null; then
        openstack image delete cirros
        echo "  Image 'cirros' deleted"
    else
        echo "  Image 'cirros' not found"
    fi

    # Delete m1.tiny flavor
    if openstack flavor show m1.tiny &>/dev/null; then
        openstack flavor delete m1.tiny
        echo "  Flavor 'm1.tiny' deleted"
    else
        echo "  Flavor 'm1.tiny' not found"
    fi
else
    echo "  Skipping (use --all to remove image and flavor)"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Cleanup Complete ==="
else
    echo "=== Cleanup Complete (with $ERRORS warning(s)) ==="
fi
echo "=========================================="
echo ""

# Show current state
echo "Current state:"
echo ""
echo "Servers:"
openstack server list --all-projects -f table 2>/dev/null || echo "  (none or error)"
echo ""
echo "Volumes:"
openstack volume list --all-projects -f table 2>/dev/null || echo "  (none or error)"
echo ""

if [ "$CLEAN_ALL" = false ]; then
    echo "Note: Persistent resources preserved (keypair, image, flavor)"
    echo "      Run with --all to remove these as well"
fi
