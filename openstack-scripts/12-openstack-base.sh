#!/bin/bash
###############################################################################
# 12-openstack-base.sh
# Install OpenStack base dependencies (MariaDB, RabbitMQ, Memcached, etcd)
###############################################################################
set -e

echo "=== Step 12: OpenStack Base Dependencies ==="

echo "[1/2] Installing packages..."
sudo apt install -y python3-openstackclient \
                    mariadb-server \
                    rabbitmq-server \
                    memcached python3-memcache \
                    etcd-server

echo "[2/2] Starting services..."
sudo systemctl enable --now mariadb
sudo systemctl enable --now rabbitmq-server
sudo systemctl enable --now memcached
sudo systemctl enable --now etcd

echo ""
echo "Service status:"
for svc in mariadb rabbitmq-server memcached etcd; do
    echo "  ${svc}: $(systemctl is-active ${svc})"
done

echo ""
echo "=== Base dependencies installed ==="
echo "Next: Run 13-mariadb-config.sh"
