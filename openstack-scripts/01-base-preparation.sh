#!/bin/bash
###############################################################################
# 01-base-preparation.sh
# Base OS preparation for OpenStack + Ceph on Debian 11 (bullseye)
###############################################################################
set -e

echo "=== Step 1: Base OS Preparation ==="

echo "[1/3] Updating system packages..."
sudo apt update
sudo apt full-upgrade -y

echo "[2/3] Installing essential tools..."
sudo apt install -y vim tmux curl gnupg bridge-utils tcpdump net-tools \
                    chrony git jq

echo "[3/3] Enabling and starting time sync (chrony)..."
sudo systemctl enable --now chrony

echo ""
echo "=== Base preparation complete ==="
echo "Next: Run 02-hostname-setup.sh"
