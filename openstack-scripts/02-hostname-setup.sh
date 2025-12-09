#!/bin/bash
###############################################################################
# 02-hostname-setup.sh
# Configure hostname for OpenStack controller node
#
# This sets the system hostname and updates /etc/hosts for proper
# name resolution required by OpenStack services.
###############################################################################
set -e

# Source environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack-env.sh"

# Configuration from environment
HOSTNAME="${CONTROLLER_HOSTNAME}"
IP_ADDRESS="${CONTROLLER_IP}"

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
