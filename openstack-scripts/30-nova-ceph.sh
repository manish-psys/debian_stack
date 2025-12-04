#!/bin/bash
###############################################################################
# 30-nova-ceph.sh
# Configure Nova to use Ceph for ephemeral disks
###############################################################################
set -e

echo "=== Step 30: Nova + Ceph Configuration ==="

echo "[1/3] Creating libvirt secret for Ceph..."

# Create secret XML
cat <<'EOF' > /tmp/secret.xml
<secret ephemeral='no' private='no'>
  <usage type='ceph'>
    <name>client.cinder secret</name>
  </usage>
</secret>
EOF

# Define secret and get UUID
SECRET_UUID=$(sudo virsh secret-define --file /tmp/secret.xml 2>/dev/null | awk '{print $2}' | tr -d '"')

if [ -z "$SECRET_UUID" ]; then
    # Secret might already exist, try to get it
    SECRET_UUID=$(sudo virsh secret-list | grep "client.cinder" | awk '{print $1}')
fi

echo "Secret UUID: ${SECRET_UUID}"

echo "[2/3] Setting secret value..."
KEY=$(sudo ceph auth get-key client.cinder)
sudo virsh secret-set-value --secret "${SECRET_UUID}" --base64 "$(echo -n "${KEY}" | base64)"

echo "[3/3] Configuring Nova libvirt for Ceph..."
sudo crudini --set /etc/nova/nova.conf libvirt images_type "rbd"
sudo crudini --set /etc/nova/nova.conf libvirt images_rbd_pool "vms"
sudo crudini --set /etc/nova/nova.conf libvirt images_rbd_ceph_conf "/etc/ceph/ceph.conf"
sudo crudini --set /etc/nova/nova.conf libvirt rbd_user "cinder"
sudo crudini --set /etc/nova/nova.conf libvirt rbd_secret_uuid "${SECRET_UUID}"

# Also set this for Cinder
sudo crudini --set /etc/cinder/cinder.conf ceph rbd_secret_uuid "${SECRET_UUID}"

echo "Restarting Nova and Cinder..."
sudo systemctl restart nova-compute
sudo systemctl restart cinder-volume

echo ""
echo "=== Nova configured to use Ceph ==="
echo "Secret UUID: ${SECRET_UUID}"
echo ""
echo "Next: Run 31-horizon.sh"
