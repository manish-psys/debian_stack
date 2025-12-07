#!/bin/bash
###############################################################################
# 29-cinder-db.sh
# Create Cinder database and Keystone entities for Block Storage service
# 
# Prerequisites:
#   - MariaDB running (script 13)
#   - Keystone configured (script 15-16)
#   - admin-openrc available
#
# This script creates:
#   - MySQL database 'cinder'
#   - MySQL user 'cinder'
#   - Keystone user 'cinder'
#   - Keystone service 'cinderv3' (volumev3)
#   - Keystone endpoints (public, internal, admin)
###############################################################################

# Exit on undefined variables only - we handle errors manually
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
    echo "Please ensure the environment file exists."
    exit 1
fi

echo "=== Step 29: Cinder Database and Keystone Setup ==="
echo "Using Controller: ${CONTROLLER_IP}"
echo "Using Region: ${REGION_NAME}"
echo ""

# Error counter
ERRORS=0

# =============================================================================
# PART 1: Check Prerequisites
# =============================================================================
echo "[1/5] Checking prerequisites..."

# Check if MariaDB is running
if ! systemctl is-active --quiet mariadb; then
    echo "  ✗ ERROR: MariaDB is not running!"
    exit 1
fi
echo "  ✓ MariaDB is running"

# Check if Keystone is available
if [ ! -f ~/admin-openrc ]; then
    echo "  ✗ ERROR: admin-openrc not found!"
    echo "  Run Keystone setup scripts first."
    exit 1
fi
echo "  ✓ admin-openrc exists"

# Source admin credentials
source ~/admin-openrc

# Test Keystone connectivity
if ! openstack token issue &>/dev/null; then
    echo "  ✗ ERROR: Cannot connect to Keystone!"
    exit 1
fi
echo "  ✓ Keystone is accessible"

# Check RabbitMQ
if ! systemctl is-active --quiet rabbitmq-server; then
    echo "  ✗ ERROR: RabbitMQ is not running!"
    exit 1
fi
echo "  ✓ RabbitMQ is running"

# =============================================================================
# PART 2: Create Cinder Database
# =============================================================================
echo ""
echo "[2/5] Creating Cinder database..."

# Check if database already exists
DB_EXISTS=$(sudo mysql -u root -e "SHOW DATABASES LIKE 'cinder';" 2>/dev/null | grep -c cinder || true)

if [ "$DB_EXISTS" -gt 0 ]; then
    echo "  ✓ Database 'cinder' already exists"
else
    echo "  Creating database 'cinder'..."
    sudo mysql -u root <<EOF
CREATE DATABASE cinder;
EOF
    if [ $? -eq 0 ]; then
        echo "  ✓ Database 'cinder' created"
    else
        echo "  ✗ ERROR: Failed to create database!"
        ((ERRORS++))
    fi
fi

# Create/update MySQL user
echo "  Configuring MySQL user 'cinder'..."
sudo mysql -u root <<EOF
CREATE USER IF NOT EXISTS 'cinder'@'localhost' IDENTIFIED BY '${CINDER_DB_PASS}';
CREATE USER IF NOT EXISTS 'cinder'@'%' IDENTIFIED BY '${CINDER_DB_PASS}';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%';
ALTER USER 'cinder'@'localhost' IDENTIFIED BY '${CINDER_DB_PASS}';
ALTER USER 'cinder'@'%' IDENTIFIED BY '${CINDER_DB_PASS}';
FLUSH PRIVILEGES;
EOF

if [ $? -eq 0 ]; then
    echo "  ✓ MySQL user 'cinder' configured"
else
    echo "  ✗ ERROR: Failed to configure MySQL user!"
    ((ERRORS++))
fi

# Test database connection
echo "  Testing database connection..."
if mysql -u cinder -p"${CINDER_DB_PASS}" -e "SELECT 1;" cinder &>/dev/null; then
    echo "  ✓ Database connection successful"
else
    echo "  ✗ ERROR: Cannot connect to database as 'cinder' user!"
    ((ERRORS++))
fi

# =============================================================================
# PART 3: Create Keystone User
# =============================================================================
echo ""
echo "[3/5] Creating Keystone user 'cinder'..."

# Check if user already exists
if openstack user show cinder &>/dev/null; then
    echo "  ✓ User 'cinder' already exists"
else
    echo "  Creating user 'cinder'..."
    if openstack user create --domain default --password "${CINDER_PASS}" cinder &>/dev/null; then
        echo "  ✓ User 'cinder' created"
    else
        echo "  ✗ ERROR: Failed to create user!"
        ((ERRORS++))
    fi
fi

# Add admin role to cinder user
echo "  Adding 'admin' role to 'cinder' user..."
if openstack role add --project service --user cinder admin 2>/dev/null; then
    echo "  ✓ Role 'admin' added to user 'cinder'"
else
    # Role might already be assigned
    echo "  ✓ Role 'admin' already assigned (or added)"
fi

# =============================================================================
# PART 4: Create Cinder Service and Endpoints
# =============================================================================
echo ""
echo "[4/5] Creating Cinder service and endpoints..."

# Cinder v3 API (volumev3) - this is the current standard
# Note: Cinder v2 is deprecated, we only create v3

# Check if service exists
if openstack service show cinderv3 &>/dev/null; then
    echo "  ✓ Service 'cinderv3' already exists"
else
    echo "  Creating service 'cinderv3'..."
    if openstack service create --name cinderv3 \
        --description "OpenStack Block Storage v3" volumev3 &>/dev/null; then
        echo "  ✓ Service 'cinderv3' created"
    else
        echo "  ✗ ERROR: Failed to create service!"
        ((ERRORS++))
    fi
fi

# Create endpoints
# Cinder v3 uses /v3/%(project_id)s path
CINDER_URL="http://${CONTROLLER_IP}:8776/v3/%(project_id)s"

EXISTING_ENDPOINTS=$(openstack endpoint list --service cinderv3 -f value -c Interface 2>/dev/null || true)

for INTERFACE in public internal admin; do
    if echo "$EXISTING_ENDPOINTS" | grep -q "^${INTERFACE}$"; then
        echo "  ✓ ${INTERFACE} endpoint already exists"
    else
        echo "  Creating ${INTERFACE} endpoint..."
        if openstack endpoint create --region "${REGION_NAME}" \
            volumev3 ${INTERFACE} "${CINDER_URL}" &>/dev/null; then
            echo "  ✓ ${INTERFACE} endpoint created"
        else
            echo "  ✗ ERROR: Failed to create ${INTERFACE} endpoint!"
            ((ERRORS++))
        fi
    fi
done

# =============================================================================
# PART 5: Verification
# =============================================================================
echo ""
echo "[5/5] Verifying Cinder setup..."

# Verify database
echo ""
echo "Database verification:"
TABLES=$(mysql -u cinder -p"${CINDER_DB_PASS}" -N -e "SHOW TABLES;" cinder 2>/dev/null | wc -l)
echo "  Tables in 'cinder' database: ${TABLES} (will be populated after db sync)"

# Verify Keystone user
echo ""
echo "Keystone user:"
openstack user show cinder -f table -c name -c domain_id -c enabled 2>/dev/null || echo "  ✗ User not found"

# Verify service
echo ""
echo "Cinder service:"
openstack service show cinderv3 -f table -c name -c type -c enabled 2>/dev/null || echo "  ✗ Service not found"

# Verify endpoints
echo ""
echo "Cinder endpoints:"
openstack endpoint list --service cinderv3 -f table -c "Service Name" -c "Service Type" -c Interface -c URL 2>/dev/null || echo "  ✗ No endpoints found"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "=== Cinder DB Setup Completed Successfully ==="
else
    echo "=== Cinder DB Setup Completed with $ERRORS Error(s) ==="
fi
echo "=========================================="
echo ""
echo "Configuration summary:"
echo "  Database: cinder"
echo "  DB User: cinder"
echo "  DB Password: ${CINDER_DB_PASS}"
echo "  Keystone User: cinder"
echo "  Keystone Password: ${CINDER_PASS}"
echo "  Service: cinderv3 (volumev3)"
echo "  API Port: 8776"
echo ""
echo "Credentials stored in: openstack-env.sh"
echo "  CINDER_DB_PASS=${CINDER_DB_PASS}"
echo "  CINDER_PASS=${CINDER_PASS}"
echo ""
echo "Next: Run 30-cinder-install.sh"
