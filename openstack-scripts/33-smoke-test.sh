#!/bin/bash
###############################################################################
# 33-smoke-test.sh
# Final verification and test VM launch
###############################################################################
set -e

echo "=== Step 33: OpenStack Smoke Test ==="

source ~/admin-openrc

echo "[1/7] Checking all services..."
echo ""
echo "=== Neutron Agents ==="
openstack network agent list
echo ""
echo "=== Nova Services ==="
openstack compute service list
echo ""
echo "=== Cinder Services ==="
openstack volume service list
echo ""

echo "[2/7] Downloading test image (cirros)..."
if ! openstack image show cirros &>/dev/null; then
    wget -q https://download.cirros-cloud.net/0.5.2/cirros-0.5.2-x86_64-disk.img -O /tmp/cirros.img
    openstack image create "cirros" \
        --disk-format qcow2 \
        --container-format bare \
        --file /tmp/cirros.img \
        --public
    rm /tmp/cirros.img
else
    echo "  Cirros image already exists"
fi

echo ""
echo "=== Images ==="
openstack image list

echo "[3/7] Creating flavor..."
if ! openstack flavor show m1.tiny &>/dev/null; then
    openstack flavor create --ram 512 --disk 1 --vcpus 1 m1.tiny
else
    echo "  m1.tiny flavor already exists"
fi

echo ""
echo "=== Flavors ==="
openstack flavor list

echo "[4/7] Creating keypair..."
if ! openstack keypair show mykey &>/dev/null; then
    openstack keypair create --public-key ~/.ssh/id_rsa.pub mykey 2>/dev/null || \
    openstack keypair create mykey > ~/mykey.pem
    chmod 600 ~/mykey.pem 2>/dev/null || true
else
    echo "  mykey keypair already exists"
fi

echo ""
echo "=== Keypairs ==="
openstack keypair list

echo "[5/7] Creating security group rules..."
# Allow ICMP and SSH in default security group
openstack security group rule create --protocol icmp --ingress default 2>/dev/null || true
openstack security group rule create --protocol tcp --dst-port 22 --ingress default 2>/dev/null || true

echo "[6/7] Launching test VM..."
if ! openstack server show test-vm-1 &>/dev/null; then
    openstack server create --image cirros --flavor m1.tiny \
        --network public \
        --key-name mykey \
        test-vm-1
    
    echo "Waiting for VM to become active..."
    sleep 30
else
    echo "  test-vm-1 already exists"
fi

echo ""
echo "=== Server Status ==="
openstack server show test-vm-1

echo ""
echo "[7/7] Getting console URL..."
openstack console url show test-vm-1

echo ""
echo "=========================================="
echo "=== OpenStack Smoke Test Complete ==="
echo "=========================================="
echo ""
echo "Your VM should be running and will get an IP from your LAN DHCP."
echo "Check: openstack server show test-vm-1"
echo ""
echo "Access Horizon at: http://192.168.2.9/horizon"
echo ""
echo "To SSH to the VM (once it has an IP):"
echo "  ssh cirros@<VM_IP>  (password: gocubsgo)"
echo ""
