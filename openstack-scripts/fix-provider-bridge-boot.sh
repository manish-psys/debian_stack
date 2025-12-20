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
# all traffic through the provider bridge. In daemon mode, it runs continuously
# to counter OVN's periodic re-application of fail_mode=secure.
#
# Usage:
#   fix-provider-bridge.sh [bridge_name] [--daemon]
#
# Installation:
# 1. Copy this script to /usr/local/bin/fix-provider-bridge.sh
# 2. Create systemd service to run after OVN services
###############################################################################

PROVIDER_BRIDGE="${1:-br-provider}"
DAEMON_MODE=false
CHECK_INTERVAL=30  # Check every 30 seconds in daemon mode

# Check for --daemon flag
for arg in "$@"; do
    if [ "$arg" = "--daemon" ]; then
        DAEMON_MODE=true
    fi
done

LOG_TAG="fix-provider-bridge"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
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

# Apply the fix
apply_fix() {
    local changed=false

    # Check if bridge exists
    if ! ovs-vsctl br-exists "${PROVIDER_BRIDGE}" 2>/dev/null; then
        return 1
    fi

    # Remove fail_mode: secure if set
    if ovs-vsctl get bridge "${PROVIDER_BRIDGE}" fail_mode 2>/dev/null | grep -q "secure"; then
        ovs-vsctl remove bridge "${PROVIDER_BRIDGE}" fail_mode secure 2>/dev/null || true
        log "Removed fail_mode=secure from ${PROVIDER_BRIDGE}"
        changed=true
    fi

    # Check if NORMAL flow rule exists, add if not
    if ! ovs-ofctl dump-flows "${PROVIDER_BRIDGE}" 2>/dev/null | grep -q "priority=0.*actions=NORMAL"; then
        ovs-ofctl add-flow "${PROVIDER_BRIDGE}" "priority=0,actions=NORMAL" 2>/dev/null || true
        log "Added NORMAL flow rule to ${PROVIDER_BRIDGE}"
        changed=true
    fi

    if [ "$changed" = true ]; then
        log "Fix applied to ${PROVIDER_BRIDGE}"
    fi

    return 0
}

# Main function
main() {
    log "Starting provider bridge connectivity fix for ${PROVIDER_BRIDGE}"

    if [ "$DAEMON_MODE" = true ]; then
        log "Running in daemon mode (checking every ${CHECK_INTERVAL}s)"
    fi

    # Wait for OVS to be available
    if ! wait_for_ovs; then
        log "ERROR: OVS not available after 30 seconds"
        exit 1
    fi

    # Initial fix
    apply_fix

    # If daemon mode, keep checking periodically
    if [ "$DAEMON_MODE" = true ]; then
        while true; do
            sleep ${CHECK_INTERVAL}
            apply_fix
        done
    else
        log "Provider bridge connectivity fix completed (one-shot mode)"
    fi
}

main "$@"
