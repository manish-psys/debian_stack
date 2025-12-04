#!/bin/bash
###############################################################################
# 26-neutron-sync.sh
# Sync Neutron database and start services
###############################################################################
set -e

echo "=== Step 26: Neutron Database Sync and Service Start ==="

echo "[1/3] Syncing Neutron database..."
sudo -u neutron neutron-db-manage --config-file /etc/neutron/neutron.conf \
    --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head

echo "[2/3] Restarting Nova API (for Neutron integration)..."
sudo systemctl restart nova-api

echo "[3/3] Starting Neutron services..."
sudo systemctl restart neutron-server
sudo systemctl restart neutron-linuxbridge-agent
sudo systemctl restart neutron-dhcp-agent
sudo systemctl restart neutron-metadata-agent

sudo systemctl enable neutron-server
sudo systemctl enable neutron-linuxbridge-agent
sudo systemctl enable neutron-dhcp-agent
sudo systemctl enable neutron-metadata-agent

echo ""
echo "Verifying Neutron agents..."
sleep 5
source ~/admin-openrc
openstack network agent list

echo ""
echo "=== Neutron services started ==="
echo "Next: Run 27-provider-network.sh"
