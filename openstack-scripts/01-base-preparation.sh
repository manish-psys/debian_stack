#!/bin/bash
###############################################################################
# 01-base-preparation.sh
# Base OS preparation for OpenStack + Ceph on Debian 13 (Trixie)
#
# This script prepares a fresh Debian Trixie system for OpenStack deployment
# by updating packages and installing essential system tools.
#
# Prerequisites: Fresh Debian 13.2 (Trixie) installation
###############################################################################
set -e

echo "=== Step 1: Base OS Preparation for Debian Trixie ==="

echo "[1/4] Verifying Debian version..."
if ! grep -q "trixie" /etc/os-release; then
    echo "  ✗ ERROR: This script requires Debian 13 (Trixie)"
    echo "  Current version:"
    cat /etc/os-release | grep VERSION_CODENAME
    exit 1
fi
echo "  ✓ Debian Trixie detected"

echo "[2/4] Updating system packages..."
sudo apt update
sudo apt full-upgrade -y

echo "[3/4] Installing essential tools..."
# Core utilities for OpenStack deployment
sudo apt install -y \
    vim \
    tmux \
    curl \
    wget \
    gnupg \
    bridge-utils \
    vlan \
    tcpdump \
    net-tools \
    iproute2 \
    chrony \
    git \
    jq \
    python3-pip \
    python3-openstackclient \
    crudini \
    qemu-utils

echo "[4/4] Enabling and starting time sync (chrony)..."
sudo systemctl enable --now chrony
sudo systemctl status chrony --no-pager | head -5

echo ""
echo "=== Verification ==="
echo "  ✓ Debian version: $(cat /etc/os-release | grep VERSION= | head -1)"
echo "  ✓ Chrony status: $(systemctl is-active chrony)"
echo "  ✓ Python3 version: $(python3 --version)"
echo "  ✓ OpenStack CLI: $(openstack --version 2>/dev/null || echo 'will be configured later')"

echo ""
echo "=== Base preparation complete ==="
echo "Next: Run 02-hostname-setup.sh"
