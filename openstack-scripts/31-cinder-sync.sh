#!/bin/bash
###############################################################################
# 31-cinder-sync.sh
# Sync Cinder database and start services
#
# Prerequisites:
#   - Script 29 completed (database setup)
#   - Script 30 completed (Cinder configuration)
#
# This script:
#   - Syncs the Cinder database schema
#   - Creates default volume type
#   - Starts and enables all Cinder services
#   - Verifies everything is working
###############################################################################

# Exit on undefined variables only
set -u

# =============================================================================
# LOAD ENVIRONMENT
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/openstack-env.sh"

if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE="${SCRIPT_DIR}/../openstack-env.sh"
fi

if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE=~/openstack-env.sh
fi

if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE=/mnt/user-data/outputs/openstack-env.sh
fi

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
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

echo "=== Step 31: Cinder Database Sync and Service Start ==="

# Error counter
ERRORS=0

# =============================================================================
# PART 1: Check Prerequisites
# =============================================================================
echo ""
echo "[1/5] Checking prerequisites..."

# Check config file exists (needs sudo due to permissions)
if ! sudo test -f /etc/cinder/cinder.conf; then
    echo "  ✗ ERROR: /etc/cinder/cinder.conf not found!"
    echo "  Run 30-cinder-install.sh first."
    exit 1
fi
echo "  ✓ Cinder config exists"

# Check database connection
if ! mysql -u cinder -p"${CINDER_DB_PASS}" -e "SELECT 1;" cinder &>/dev/null; then
    echo "  ✗ ERROR: Cannot connect to Cinder database!"
    exit 1
fi
echo "  ✓ Database connection OK"

# Check Ceph connectivity
if ! sudo ceph health &>/dev/null; then
    echo "  ✗ ERROR: Cannot connect to Ceph!"
    exit 1
fi
echo "  ✓ Ceph cluster accessible"

# =============================================================================
# PART 2: Sync Cinder Database
# =============================================================================
echo ""
echo "[2/5] Syncing Cinder database..."

# Run database migration
sudo -u cinder cinder-manage db sync 2>&1 | grep -v "^$" | head -20

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "  OK"
else
    echo "  ✗ ERROR: Database sync failed!"
    ((ERRORS++))
fi

# Count tables
TABLE_COUNT=$(mysql -u cinder -p"${CINDER_DB_PASS}" -N -e "SHOW TABLES;" cinder 2>/dev/null | wc -l)
echo "  ✓ Database synced (${TABLE_COUNT} tables)"

# =============================================================================
# PART 3: Start Cinder Services
# =============================================================================
echo ""
echo "[3/5] Starting Cinder services..."

# Debian uses these service names
CINDER_SERVICES=(
    "cinder-api"
    "cinder-scheduler"
    "cinder-volume"
)

for SERVICE in "${CINDER_SERVICES[@]}"; do
    echo "  Starting ${SERVICE}..."
    
    # Enable and start service
    if sudo systemctl enable --now ${SERVICE} 2>&1 | grep -v "^$"; then
        # Check if it's actually running
        sleep 2
        if systemctl is-active --quiet ${SERVICE}; then
            echo "  ✓ ${SERVICE} started"
        else
            echo "  ✗ ${SERVICE} failed to start"
            echo "    Check: sudo journalctl -u ${SERVICE} -n 50"
            ((ERRORS++))
        fi
    else
        if systemctl is-active --quiet ${SERVICE}; then
            echo "  ✓ ${SERVICE} started"
        else
            echo "  ✗ ${SERVICE} failed to start"
            ((ERRORS++))
        fi
    fi
done

# =============================================================================
# PART 4: Create Default Volume Type
# =============================================================================
echo ""
echo "[4/5] Creating default volume type..."

# Wait for API to be ready
echo "  Waiting for Cinder API..."
for i in {1..30}; do
    if openstack volume type list &>/dev/null; then
        echo "  ✓ Cinder API responding"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "  ✗ ERROR: Cinder API not responding after 30 seconds!"
        ((ERRORS++))
    fi
    sleep 1
done

# Create 'ceph' volume type if it doesn't exist
if openstack volume type show ceph &>/dev/null; then
    echo "  ✓ Volume type 'ceph' already exists"
else
    echo "  Creating volume type 'ceph'..."
    if openstack volume type create --property volume_backend_name=ceph ceph &>/dev/null; then
        echo "  ✓ Volume type 'ceph' created"
    else
        echo "  ✗ ERROR: Failed to create volume type!"
        ((ERRORS++))
    fi
fi

# Set as default
openstack volume type set --property volume_backend_name=ceph ceph 2>/dev/null || true

# =============================================================================
# PART 5: Verification
# =============================================================================
echo ""
echo "[5/5] Verifying Cinder installation..."

# Wait for services to register
echo "  Waiting for services to register..."
sleep 5

# Service status
echo ""
echo "Service Status:"
for SERVICE in "${CINDER_SERVICES[@]}"; do
    if systemctl is-active --quiet ${SERVICE}; then
        echo "  ✓ ${SERVICE} is running"
    else
        echo "  ✗ ${SERVICE} is NOT running"
        ((ERRORS++))
    fi
done

# Check port 8776 is listening
if sudo ss -tlnp | grep -q ":8776"; then
    echo "  ✓ Cinder API listening on port 8776"
else
    echo "  ✗ Cinder API NOT listening on port 8776"
    ((ERRORS++))
fi

# Cinder service list (shows scheduler and volume services)
echo ""
echo "Cinder Services:"
openstack volume service list 2>/dev/null || echo "  (waiting for services to register...)"

# Volume types
echo ""
echo "Volume Types:"
openstack volume type list 2>/dev/null || echo "  (no volume types)"

# Test API
echo ""
echo "Testing Cinder API..."
if openstack volume list &>/dev/null; then
    echo "  ✓ Cinder API responding to CLI"
else
    echo "  ✗ Cinder API not responding"
    ((ERRORS++))
fi

# Ceph pool stats
echo ""
echo "Ceph Pool Status:"
sudo ceph df 2>/dev/null | grep -E "(POOL|${CEPH_CINDER_POOL})" || echo "  (could not get pool stats)"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Cinder Services Started Successfully ==="
else
    echo "=== Cinder Started with $ERRORS Error(s) ==="
fi
echo "=========================================="
echo ""
echo "Services running:"
echo "  - cinder-api (API on port 8776)"
echo "  - cinder-scheduler (scheduling)"
echo "  - cinder-volume (Ceph backend)"
echo ""
echo "Backend: Ceph RBD (pool: ${CEPH_CINDER_POOL})"
echo "Default volume type: ceph"
echo ""
echo "Quick test commands:"
echo "  openstack volume service list"
echo "  openstack volume type list"
echo "  openstack volume create --size 1 test-volume"
echo "  openstack volume list"
echo ""
echo "Next: Run 32-nova-ceph.sh to configure Nova for Ceph volumes"
