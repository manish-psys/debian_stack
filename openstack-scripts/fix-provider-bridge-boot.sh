#!/bin/bash
###############################################################################
# fix-provider-bridge-boot.sh
# Ensures provider bridge allows traffic after OVN services start
#
# Problem:
# OVN sets fail_mode=secure on OVS bridges, which drops all traffic unless
# explicit OpenFlow rules exist. For the provider bridge that carries
# management traffic (SSH, API access), this breaks connectivity.
#
# Solution:
# This script removes fail_mode=secure and adds a NORMAL flow rule to allow
# all traffic through the provider bridge.
#
# Installation:
# 1. Copy this script to /usr/local/bin/fix-provider-bridge.sh
# 2. Create systemd service to run after OVN services
###############################################################################

PROVIDER_BRIDGE="${1:-br-provider}"
LOG_TAG="fix-provider-bridge"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$1"
}

# Wait for OVS to be ready
wait_for_ovs() {
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if ovs-vsctl show &>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    return 1
}

# Main function
main() {
    log "Starting provider bridge connectivity fix for ${PROVIDER_BRIDGE}"

    # Wait for OVS to be available
    if ! wait_for_ovs; then
        log "ERROR: OVS not available after 30 seconds"
        exit 1
    fi

    # Check if bridge exists
    if ! ovs-vsctl br-exists "${PROVIDER_BRIDGE}"; then
        log "WARNING: Bridge ${PROVIDER_BRIDGE} does not exist yet, skipping"
        exit 0
    fi

    # Remove fail_mode: secure if set
    # OVN sets this automatically, but for provider bridge we need traffic to flow
    if ovs-vsctl get bridge "${PROVIDER_BRIDGE}" fail_mode 2>/dev/null | grep -q "secure"; then
        ovs-vsctl remove bridge "${PROVIDER_BRIDGE}" fail_mode secure 2>/dev/null || true
        log "Removed fail_mode=secure from ${PROVIDER_BRIDGE}"
    fi

    # Add default NORMAL flow rule to allow all traffic through
    # Priority 0 means it's the fallback rule
    ovs-ofctl add-flow "${PROVIDER_BRIDGE}" "priority=0,actions=NORMAL" 2>/dev/null || true
    log "Added NORMAL flow rule to ${PROVIDER_BRIDGE}"

    # Verify the fix
    local fail_mode=$(ovs-vsctl get bridge "${PROVIDER_BRIDGE}" fail_mode 2>/dev/null || echo "[]")
    local flow_count=$(ovs-ofctl dump-flows "${PROVIDER_BRIDGE}" 2>/dev/null | grep -c "actions=NORMAL" || echo "0")

    log "Verification: fail_mode=${fail_mode}, NORMAL flows=${flow_count}"
    log "Provider bridge connectivity fix completed"
}

main "$@"
