#!/bin/bash
###############################################################################
# openstack-env.sh
# Shared environment variables for OpenStack deployment on Debian 13 (Trixie)
# SOURCE THIS FILE IN ALL DEPLOYMENT SCRIPTS
#
# =============================================================================
# DEPLOYED PACKAGE VERSIONS (Verified on 2025-12-12)
# =============================================================================
# These are the actual package versions available in Debian Trixie repositories
# as verified by script 04-openstack-repos.sh
#
# OpenStack Components:
# - Keystone: 2:27.0.0-3+deb13u1 (2024.1 Caracal with security updates)
# - Nova: 2:31.0.0-6+deb13u1 (2024.2 Dalmatian with updates)
# - Neutron: 2:26.0.0-9 (2024.1 Caracal)
# - Glance: 2:30.0.0-3 (2024.2 Dalmatian)
# - Cinder: 2:26.0.0-2 (2024.1 Caracal)
# - Placement: (included with Nova)
#
# Storage & Networking:
# - Ceph: 18.2.7+ds-1 (Reef LTS)
# - Open vSwitch: 3.5.0-1+b1
# - OVN Central: 25.03.0-1
#
# =============================================================================
# DOCUMENTATION REFERENCES
# =============================================================================
# OpenStack Caracal (2024.1): https://docs.openstack.org/2024.1/
# OpenStack Dalmatian (2024.2): https://docs.openstack.org/2024.2/
# Ceph Reef: https://docs.ceph.com/en/reef/
# OVN: https://www.ovn.org/en/
# Debian OpenStack: https://wiki.debian.org/OpenStack
#
# Release Notes:
# - Caracal: https://releases.openstack.org/caracal/
# - Dalmatian: https://releases.openstack.org/dalmatian/
# - Ceph Reef: https://docs.ceph.com/en/reef/releases/reef/
###############################################################################

# =============================================================================
# NETWORK CONFIGURATION
# =============================================================================
export CONTROLLER_IP="192.168.2.9"
export CONTROLLER_HOSTNAME="osctl1"

# =============================================================================
# REGION CONFIGURATION (Critical for service discovery)
# =============================================================================
# OpenStack default is "RegionOne" - DO NOT CHANGE unless you have a reason
# This MUST match what was used in Keystone bootstrap (script 15)
export REGION_NAME="RegionOne"

# =============================================================================
# DATABASE PASSWORDS
# Use simple passwords without special characters to avoid URL encoding issues
# =============================================================================
export MYSQL_ROOT_PASS=""  # Debian uses unix_socket auth, no password needed for root

# Service database passwords
export KEYSTONE_DB_PASS="keystonepass123"
export GLANCE_DB_PASS="glancepass123"
export PLACEMENT_DB_PASS="placementpass123"
export NOVA_DB_PASS="novapass123"
export NEUTRON_DB_PASS="neutronpass123"
export CINDER_DB_PASS="cinderpass123"

# =============================================================================
# KEYSTONE SERVICE USER PASSWORDS
# These are for service accounts that authenticate with Keystone
# =============================================================================
export ADMIN_PASS="keystonepass123"
export GLANCE_PASS="glancepass123"
export PLACEMENT_PASS="placementpass123"
export NOVA_PASS="novapass123"
export NEUTRON_PASS="neutronpass123"
export CINDER_PASS="cinderpass123"

# =============================================================================
# RABBITMQ CONFIGURATION
# =============================================================================
export RABBIT_USER="openstack"
export RABBIT_PASS="rabbitpass123"

# =============================================================================
# MEMCACHED CONFIGURATION
# =============================================================================
# Memcached listens on controller IP to allow multi-node access
export MEMCACHED_SERVERS="${CONTROLLER_IP}:11211"

# =============================================================================
# ETCD CONFIGURATION
# =============================================================================
export ETCD_SERVERS="http://${CONTROLLER_IP}:2379"

# =============================================================================
# METADATA / NEUTRON SHARED SECRET
# =============================================================================
export METADATA_SECRET="metadatasecret123"

# =============================================================================
# OVN CONFIGURATION
# =============================================================================
# FIX: OVN_NB_DB was incorrectly pointing to ovnsb_db.sock (copy-paste error)
export OVN_NB_DB="unix:/var/run/ovn/ovnnb_db.sock"
export OVN_SB_DB="unix:/var/run/ovn/ovnsb_db.sock"
export PROVIDER_NETWORK_NAME="physnet1"
export PROVIDER_BRIDGE_NAME="br-provider"

# =============================================================================
# CEPH CONFIGURATION
# =============================================================================
export CEPH_GLANCE_POOL="images"
export CEPH_CINDER_POOL="volumes"
export CEPH_NOVA_POOL="vms"

# =============================================================================
# API ENDPOINTS (derived from CONTROLLER_IP)
# =============================================================================
export KEYSTONE_AUTH_URL="http://${CONTROLLER_IP}:5000"
export KEYSTONE_AUTH_URL_V3="http://${CONTROLLER_IP}:5000/v3"
export GLANCE_API_URL="http://${CONTROLLER_IP}:9292"
export PLACEMENT_API_URL="http://${CONTROLLER_IP}:8778"
export NOVA_API_URL="http://${CONTROLLER_IP}:8774/v2.1"
export NEUTRON_API_URL="http://${CONTROLLER_IP}:9696"
export CINDER_API_URL="http://${CONTROLLER_IP}:8776"

# =============================================================================
# HELPER FUNCTION: Configure keystone_authtoken section for any service
# Usage: configure_keystone_authtoken <config_file> <service_user> <service_pass>
# =============================================================================
configure_keystone_authtoken() {
    local CONFIG_FILE="$1"
    local SERVICE_USER="$2"
    local SERVICE_PASS="$3"
    
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken www_authenticate_uri "$KEYSTONE_AUTH_URL"
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken auth_url "$KEYSTONE_AUTH_URL"
    # FIX: Use MEMCACHED_SERVERS variable instead of hardcoded localhost
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken memcached_servers "$MEMCACHED_SERVERS"
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken auth_type "password"
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken project_domain_name "Default"
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken user_domain_name "Default"
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken project_name "service"
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken username "$SERVICE_USER"
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken password "$SERVICE_PASS"
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken region_name "$REGION_NAME"
}

# =============================================================================
# HELPER FUNCTION: Create service endpoints in Keystone
# Usage: create_service_endpoints <service_name> <service_type> <description> <port> [path]
# NOTE: Caller must have sourced admin-openrc before calling this function
# =============================================================================
create_service_endpoints() {
    local SERVICE_NAME="$1"
    local SERVICE_TYPE="$2"
    local DESCRIPTION="$3"
    local PORT="$4"
    local PATH="${5:-}"  # Optional path suffix
    
    local BASE_URL="http://${CONTROLLER_IP}:${PORT}${PATH}"
    
    # Ensure we have OpenStack credentials
    if [ -z "$OS_AUTH_URL" ]; then
        if [ -f ~/admin-openrc ]; then
            source ~/admin-openrc
        else
            echo "  ✗ ERROR: admin-openrc not found and OS_AUTH_URL not set!"
            return 1
        fi
    fi
    
    # Verify openstack command is available
    if ! command -v openstack &>/dev/null; then
        echo "  ✗ ERROR: openstack command not found!"
        return 1
    fi
    
    # Create service if not exists
    if ! openstack service show "$SERVICE_NAME" &>/dev/null; then
        openstack service create --name "$SERVICE_NAME" --description "$DESCRIPTION" "$SERVICE_TYPE"
        echo "  ✓ Service '$SERVICE_NAME' created"
    else
        echo "  ✓ Service '$SERVICE_NAME' already exists"
    fi
    
    # Create endpoints if not exist
    local EXISTING=$(openstack endpoint list --service "$SERVICE_NAME" -f value -c Interface 2>/dev/null || true)
    
    for INTERFACE in public internal admin; do
        if ! echo "$EXISTING" | grep -q "$INTERFACE"; then
            openstack endpoint create --region "$REGION_NAME" "$SERVICE_TYPE" "$INTERFACE" "$BASE_URL"
            echo "  ✓ $INTERFACE endpoint created"
        else
            echo "  ✓ $INTERFACE endpoint already exists"
        fi
    done
}

# =============================================================================
# HELPER FUNCTION: Create database and user for OpenStack service
# Usage: create_service_database <db_name> <db_user> <db_pass>
# =============================================================================
create_service_database() {
    local DB_NAME="$1"
    local DB_USER="$2"
    local DB_PASS="$3"
    
    # Create database if not exists
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
    
    # Create user and grant privileges (idempotent)
    sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';"
    sudo mysql -e "FLUSH PRIVILEGES;"
    
    echo "  ✓ Database '${DB_NAME}' and user '${DB_USER}' configured"
}

# =============================================================================
# VALIDATION
# =============================================================================
echo "OpenStack environment loaded:"
echo "  Controller IP: $CONTROLLER_IP"
echo "  Region: $REGION_NAME"
