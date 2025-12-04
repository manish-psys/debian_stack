#!/bin/bash
###############################################################################
# 02-hostname-setup.sh
# Configure hostname for OpenStack node
###############################################################################
set -e

# Configuration - EDIT THESE
HOSTNAME="osctl1"
IP_ADDRESS="192.168.2.9"

echo "=== Step 2: Hostname Setup ==="

echo "[1/3] Setting hostname to ${HOSTNAME}..."
echo "${HOSTNAME}" | sudo tee /etc/hostname

echo "[2/3] Updating /etc/hosts..."
sudo sed -i "/${IP_ADDRESS}/d" /etc/hosts
echo "${IP_ADDRESS}  ${HOSTNAME}" | sudo tee -a /etc/hosts

echo "[3/3] Applying hostname..."
sudo hostnamectl set-hostname ${HOSTNAME}

echo ""
echo "=== Hostname setup complete ==="
echo "Current hostname: $(hostname)"
echo ""
echo "NOTE: Re-login to see correct prompt."
echo "Next: Run 03-networking-bridge.sh"
