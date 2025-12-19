#!/bin/bash
###############################################################################
# 00-admin-setup.sh
# Setup administrator user groups for OpenStack management
# Idempotent - safe to run multiple times
#
# This script adds the current user (or specified user) to groups required for:
# - Reading OpenStack service logs (/var/log/nova, /var/log/neutron, etc.)
# - Managing libvirt/KVM virtual machines
# - Accessing OpenStack service configurations
# - Full system administration capabilities
#
# Run this ONCE after initial system setup, then log out and back in.
###############################################################################

set -e

# Default to current user if not specified
TARGET_USER="${1:-$(whoami)}"

echo "=== OpenStack Administrator Setup ==="
echo "Setting up user: ${TARGET_USER}"
echo ""

# Check if running as root or with sudo
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Usage: sudo $0 [username]"
    exit 1
fi

# Groups required for OpenStack administration
ADMIN_GROUPS=(
    "adm"           # System logs access (/var/log/*)
    "libvirt"       # Libvirt/KVM management
    "kvm"           # KVM hypervisor access
    "disk"          # Disk device access (for Ceph, LVM)
    "nova"          # Nova service files access
    "neutron"       # Neutron service files access
    "cinder"        # Cinder service files access
    "glance"        # Glance service files access
    "keystone"      # Keystone service files access
)

echo "[1/3] Adding user to administrative groups..."

for GROUP in "${ADMIN_GROUPS[@]}"; do
    if getent group "$GROUP" > /dev/null 2>&1; then
        if id -nG "$TARGET_USER" | grep -qw "$GROUP"; then
            echo "  ✓ $TARGET_USER already in group: $GROUP"
        else
            usermod -aG "$GROUP" "$TARGET_USER"
            echo "  ✓ Added $TARGET_USER to group: $GROUP"
        fi
    else
        echo "  - Group '$GROUP' does not exist (service may not be installed)"
    fi
done

echo ""
echo "[2/3] Configuring sudo access..."

# Create sudoers.d file for OpenStack admin
SUDOERS_FILE="/etc/sudoers.d/openstack-admin"
if [ ! -f "$SUDOERS_FILE" ]; then
    cat > "$SUDOERS_FILE" << EOF
# OpenStack Administrator sudo rules
# Created by 00-admin-setup.sh

# Allow OpenStack service management without password
${TARGET_USER} ALL=(ALL) NOPASSWD: /bin/systemctl start *
${TARGET_USER} ALL=(ALL) NOPASSWD: /bin/systemctl stop *
${TARGET_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart *
${TARGET_USER} ALL=(ALL) NOPASSWD: /bin/systemctl reload *
${TARGET_USER} ALL=(ALL) NOPASSWD: /bin/systemctl status *
${TARGET_USER} ALL=(ALL) NOPASSWD: /bin/systemctl enable *
${TARGET_USER} ALL=(ALL) NOPASSWD: /bin/systemctl disable *

# Allow journalctl access
${TARGET_USER} ALL=(ALL) NOPASSWD: /bin/journalctl *

# Allow crudini for config management
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/crudini *

# Allow OpenStack management commands
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/nova-manage *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/neutron-db-manage *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/glance-manage *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/cinder-manage *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/keystone-manage *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/placement-manage *

# Allow OVS/OVN management
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/ovs-vsctl *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/ovs-ofctl *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/ovn-nbctl *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/ovn-sbctl *

# Allow Ceph management
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/ceph *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/rbd *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/rados *

# Allow RabbitMQ management
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/rabbitmqctl *

# Allow MySQL access
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/mysql *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/mysqldump *

# Allow Apache management
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/apache2ctl *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/a2ensite *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/a2dissite *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/a2enmod *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/a2dismod *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/a2enconf *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/a2disconf *

# Allow apt operations for package management
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/apt *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/apt-get *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/dpkg *

# Allow log viewing
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/tail *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/cat /var/log/*
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/less /var/log/*

# Allow libvirt management
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/virsh *

# Allow network diagnostics
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/ss *
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/ss *
EOF
    chmod 440 "$SUDOERS_FILE"
    echo "  ✓ Created $SUDOERS_FILE"
else
    echo "  ✓ $SUDOERS_FILE already exists"
fi

# Validate sudoers syntax
if visudo -c -f "$SUDOERS_FILE" > /dev/null 2>&1; then
    echo "  ✓ Sudoers syntax validated"
else
    echo "  ✗ ERROR: Invalid sudoers syntax!"
    rm -f "$SUDOERS_FILE"
    exit 1
fi

echo ""
echo "[3/3] Setting log directory permissions..."

# Make log directories readable by adm group
LOG_DIRS=(
    "/var/log/nova"
    "/var/log/neutron"
    "/var/log/glance"
    "/var/log/cinder"
    "/var/log/keystone"
    "/var/log/apache2"
    "/var/log/ovn"
)

for DIR in "${LOG_DIRS[@]}"; do
    if [ -d "$DIR" ]; then
        # Ensure adm group can read logs
        chmod g+rx "$DIR" 2>/dev/null || true
        # Set group to adm if not already
        chgrp adm "$DIR" 2>/dev/null || true
        # Ensure files are readable
        find "$DIR" -type f -exec chmod g+r {} \; 2>/dev/null || true
        echo "  ✓ $DIR permissions updated"
    fi
done

echo ""
echo "=========================================="
echo "=== Administrator Setup Complete ==="
echo "=========================================="
echo ""
echo "User '${TARGET_USER}' now has access to:"
echo "  - OpenStack service logs (via adm group)"
echo "  - Libvirt/KVM management (via libvirt, kvm groups)"
echo "  - OpenStack service config files"
echo "  - Passwordless sudo for common admin tasks"
echo ""
echo "IMPORTANT: Log out and log back in for group changes to take effect!"
echo ""
echo "Quick verification after re-login:"
echo "  groups                              # Should show new groups"
echo "  sudo journalctl -u nova-compute -n 5  # Should work without password"
echo "  cat /var/log/nova/nova-compute.log    # Should be readable"
