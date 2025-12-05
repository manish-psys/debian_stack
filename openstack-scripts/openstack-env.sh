#!/bin/bash
###############################################################################
# openstack-env.sh
# Shared environment variables for OpenStack deployment
# SOURCE THIS FILE IN ALL DEPLOYMENT SCRIPTS
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
export MYSQL_ROOT_PASS=""  # Set during mysql_secure_installation (script 13)

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
# METADATA / NEUTRON SHARED SECRET
# =============================================================================
export METADATA_SECRET="metadatasecret123"

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
    sudo crudini --set "$CONFIG_FILE" keystone_authtoken memcached_servers "localhost:11211"
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
# =============================================================================
create_service_endpoints() {
    local SERVICE_NAME="$1"
    local SERVICE_TYPE="$2"
    local DESCRIPTION="$3"
    local PORT="$4"
    local PATH="${5:-}"  # Optional path suffix
    
    local BASE_URL="http://${CONTROLLER_IP}:${PORT}${PATH}"
    
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
# VALIDATION
# =============================================================================
echo "OpenStack environment loaded:"
echo "  Controller IP: $CONTROLLER_IP"
echo "  Region: $REGION_NAME"
