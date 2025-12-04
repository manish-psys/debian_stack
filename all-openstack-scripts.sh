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
#!/bin/bash
###############################################################################
# 03-networking-bridge.sh
# Configure Linux bridge for OpenStack provider network
###############################################################################
set -e

# Configuration - EDIT THESE
PHYSICAL_NIC="enp1s0"      # Your actual NIC name (check with: ip link)
IP_ADDRESS="192.168.2.9"
NETMASK="255.255.255.0"
GATEWAY="192.168.2.1"

echo "=== Step 3: Network Bridge Configuration ==="

echo "[1/4] Backing up current network config..."
sudo cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)

echo "[2/4] Writing new network configuration..."
cat <<EOF | sudo tee /etc/network/interfaces
auto lo
iface lo inet loopback

# Physical NIC - no IP here
auto ${PHYSICAL_NIC}
iface ${PHYSICAL_NIC} inet manual

# Bridge used by host AND by OpenStack (provider network)
auto br-provider
iface br-provider inet static
    address ${IP_ADDRESS}
    netmask ${NETMASK}
    gateway ${GATEWAY}
    bridge_ports ${PHYSICAL_NIC}
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
EOF

echo "[3/4] Applying network configuration..."
echo "WARNING: This may briefly disconnect your network!"
read -p "Press Enter to continue or Ctrl+C to cancel..."

sudo ifdown ${PHYSICAL_NIC} 2>/dev/null || true
sudo ifup br-provider

echo "[4/4] Verifying network..."
echo ""
echo "Bridge status:"
ip a show br-provider
echo ""
echo "Routes:"
ip r
echo ""
echo "Testing connectivity..."
ping -c2 8.8.8.8 || echo "WARNING: Internet connectivity test failed!"

echo ""
echo "=== Network bridge setup complete ==="
echo "Next: Run 04-openstack-repos.sh"
#!/bin/bash
###############################################################################
# 04-openstack-repos.sh
# Add Debian OpenStack Wallaby backports repository
###############################################################################
set -e

echo "=== Step 4: OpenStack Repository Setup ==="

echo "[1/3] Adding OpenStack backports GPG key..."
curl http://osbpo.debian.net/osbpo/dists/pubkey.gpg | sudo apt-key add -

echo "[2/3] Adding OpenStack Wallaby backports repository..."
cat <<'EOF' | sudo tee /etc/apt/sources.list.d/openstack-bullseye.list
# OpenStack Wallaby backports for bullseye
deb http://osbpo.debian.net/osbpo bullseye-wallaby-backports main
deb http://osbpo.debian.net/osbpo bullseye-wallaby-backports-nochange main
EOF

echo "[3/3] Updating package lists..."
sudo apt update

echo ""
echo "=== OpenStack repository setup complete ==="
echo "You can verify with: apt-cache policy keystone"
echo "Next: Run 05-ceph-install.sh"
#!/bin/bash
###############################################################################
# 05-ceph-install.sh
# Install Ceph packages from Debian repositories
###############################################################################
set -e

echo "=== Step 5: Ceph Installation ==="

echo "[1/1] Installing Ceph packages..."
sudo apt install -y ceph ceph-common ceph-mgr ceph-mon ceph-osd

echo ""
echo "=== Ceph installation complete ==="
echo "Installed version:"
ceph --version
echo ""
echo "Next: Run 06-ceph-disk-prep.sh"
#!/bin/bash
###############################################################################
# 06-ceph-disk-prep.sh
# Prepare disks for Ceph OSDs
###############################################################################
set -e

# Configuration - EDIT THESE
# List your OSD disks (WARNING: ALL DATA WILL BE DESTROYED!)
OSD_DISKS="/dev/sdb /dev/sdc /dev/sdd /dev/sde"

echo "=== Step 6: Ceph Disk Preparation ==="
echo ""
echo "WARNING: This will DESTROY all data on the following disks:"
echo "${OSD_DISKS}"
echo ""

# Show current disk info
echo "Current disk layout:"
lsblk
echo ""

read -p "Are you SURE you want to proceed? Type 'yes' to continue: " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "[1/1] Wiping disks..."
for d in ${OSD_DISKS}; do
    echo "  Wiping ${d}..."
    sudo sgdisk --zap-all "${d}"
    sudo wipefs -a "${d}"
done

echo ""
echo "=== Disk preparation complete ==="
echo "Disks are now ready for Ceph OSD creation."
echo "Next: Run 07-ceph-config.sh"
#!/bin/bash
###############################################################################
# 07-ceph-config.sh
# Create Ceph configuration file
###############################################################################
set -e

# Configuration - EDIT THESE
HOSTNAME="osctl1"
IP_ADDRESS="192.168.2.9"
PUBLIC_NETWORK="192.168.2.0/24"

echo "=== Step 7: Ceph Configuration ==="

echo "[1/2] Creating Ceph directories..."
sudo mkdir -p /etc/ceph
sudo mkdir -p /var/lib/ceph/mon/ceph-${HOSTNAME}

echo "[2/2] Generating FSID and creating ceph.conf..."
FSID=$(uuidgen)

cat <<EOF | sudo tee /etc/ceph/ceph.conf
[global]
fsid = ${FSID}
mon_initial_members = ${HOSTNAME}
mon_host = ${IP_ADDRESS}
public_network = ${PUBLIC_NETWORK}
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx
osd_pool_default_size = 1
osd_pool_default_min_size = 1
osd_crush_chooseleaf_type = 0
EOF

echo ""
echo "=== Ceph configuration created ==="
echo "FSID: ${FSID}"
echo ""
cat /etc/ceph/ceph.conf
echo ""
echo "Next: Run 08-ceph-mon-init.sh"
#!/bin/bash
###############################################################################
# 08-ceph-mon-init.sh
# Initialize Ceph monitor and manager
###############################################################################
set -e

# Configuration - EDIT THESE
HOSTNAME="osctl1"
IP_ADDRESS="192.168.2.9"

echo "=== Step 8: Ceph Monitor Initialization ==="

# Get FSID from ceph.conf
FSID=$(awk '/fsid/ {print $3}' /etc/ceph/ceph.conf)
if [ -z "$FSID" ]; then
    echo "ERROR: Could not find FSID in /etc/ceph/ceph.conf"
    echo "Please run 07-ceph-config.sh first."
    exit 1
fi
echo "Using FSID: ${FSID}"

echo "[1/5] Creating monitor keyring..."
sudo ceph-authtool --create-keyring /etc/ceph/ceph.mon.keyring \
    --gen-key -n mon. --cap mon 'allow *'

echo "[2/5] Creating admin keyring..."
sudo ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring \
    --gen-key -n client.admin --set-uid=0 \
    --cap mon 'allow *' --cap osd 'allow *' \
    --cap mgr 'allow *' --cap mds 'allow *'

echo "[3/5] Importing admin keyring into monitor keyring..."
sudo ceph-authtool /etc/ceph/ceph.mon.keyring \
    --import-keyring /etc/ceph/ceph.client.admin.keyring

echo "[4/5] Creating monmap..."
sudo monmaptool --create --add ${HOSTNAME} ${IP_ADDRESS}:6789 \
    --fsid "${FSID}" /tmp/monmap

echo "[5/5] Initializing monitor..."
sudo -u ceph ceph-mon --mkfs -i ${HOSTNAME} \
    --monmap /tmp/monmap \
    --keyring /etc/ceph/ceph.mon.keyring

echo ""
echo "=== Ceph monitor initialized ==="
echo "Next: Run 09-ceph-mon-mgr-start.sh"
#!/bin/bash
###############################################################################
# 09-ceph-mon-mgr-start.sh
# Start and enable Ceph monitor and manager services
###############################################################################
set -e

# Configuration - EDIT THIS
HOSTNAME="osctl1"

echo "=== Step 9: Start Ceph Monitor and Manager ==="

echo "[1/2] Enabling and starting Ceph monitor..."
sudo systemctl enable --now ceph-mon@${HOSTNAME}

echo "[2/2] Enabling and starting Ceph manager..."
sudo systemctl enable --now ceph-mgr@${HOSTNAME}

echo ""
echo "Waiting for services to start..."
sleep 5

echo ""
echo "Service status:"
sudo systemctl status ceph-mon@${HOSTNAME} --no-pager || true
echo ""
sudo systemctl status ceph-mgr@${HOSTNAME} --no-pager || true

echo ""
echo "=== Ceph MON and MGR started ==="
echo "Next: Run 10-ceph-osd-create.sh"
#!/bin/bash
###############################################################################
# 10-ceph-osd-create.sh
# Create Ceph OSDs on prepared disks
###############################################################################
set -e

# Configuration - EDIT THESE
# Disk device names (without /dev/ prefix)
OSD_DISKS="sdb sdc sdd sde"

echo "=== Step 10: Create Ceph OSDs ==="

echo "[1/2] Creating OSDs..."
for d in ${OSD_DISKS}; do
    echo "  Creating OSD on /dev/${d}..."
    sudo ceph-volume lvm create --data /dev/${d}
done

echo "[2/2] Verifying Ceph cluster..."
echo ""
echo "Ceph status:"
sudo ceph -s
echo ""
echo "OSD tree:"
sudo ceph osd tree

echo ""
echo "=== Ceph OSDs created ==="
echo "If HEALTH_OK and all OSDs are up,in - Ceph is ready!"
echo "Next: Run 11-ceph-pools.sh"
#!/bin/bash
###############################################################################
# 11-ceph-pools.sh
# Create Ceph pools for OpenStack services
###############################################################################
set -e

echo "=== Step 11: Create Ceph Pools for OpenStack ==="

echo "[1/3] Creating pools..."
sudo ceph osd pool create volumes 64
sudo ceph osd pool create images 64
sudo ceph osd pool create backups 32
sudo ceph osd pool create vms 32

echo "[2/3] Setting replication size to 1 (LAB ONLY!)..."
for p in volumes images backups vms; do
    sudo ceph osd pool set $p size 1
done

echo "[3/3] Creating Cinder client for OpenStack..."
sudo ceph auth get-or-create client.cinder \
    mon 'allow r' \
    osd 'allow class-read object_prefix rbd_children, allow rwx pool=volumes, allow rwx pool=images, allow rwx pool=backups, allow rwx pool=vms' \
    | sudo tee /etc/ceph/ceph.client.cinder.keyring

sudo chmod 600 /etc/ceph/ceph.client.cinder.keyring

echo ""
echo "Pool list:"
sudo ceph osd pool ls detail

echo ""
echo "=== Ceph pools created ==="
echo "Keyring saved to: /etc/ceph/ceph.client.cinder.keyring"
echo "Next: Run 12-openstack-base.sh"
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
#!/bin/bash
###############################################################################
# 13-mariadb-config.sh
# Configure MariaDB for OpenStack
###############################################################################
set -e

echo "=== Step 13: MariaDB Configuration ==="

echo "[1/3] Creating OpenStack MariaDB config..."
cat <<'EOF' | sudo tee /etc/mysql/mariadb.conf.d/99-openstack.cnf
[mysqld]
bind-address = 127.0.0.1

default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF

echo "[2/3] Restarting MariaDB..."
sudo systemctl restart mariadb

echo "[3/3] Running mysql_secure_installation..."
echo ""
echo "Follow the prompts to secure MariaDB:"
echo "  - Set root password"
echo "  - Remove anonymous users"
echo "  - Disallow root login remotely"
echo "  - Remove test database"
echo "  - Reload privilege tables"
echo ""
sudo mysql_secure_installation

echo ""
echo "=== MariaDB configured ==="
echo "Next: Run 14-keystone-db.sh"
#!/bin/bash
###############################################################################
# 14-keystone-db.sh
# Create Keystone database and user
###############################################################################
set -e

# Configuration - EDIT THESE
KEYSTONE_DB_PASS="keystonedbpass"  # Change this!

echo "=== Step 14: Keystone Database Setup ==="

echo "Enter MariaDB root password when prompted..."

sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${KEYSTONE_DB_PASS}';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${KEYSTONE_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo ""
echo "=== Keystone database created ==="
echo "Database: keystone"
echo "User: keystone"
echo "Password: ${KEYSTONE_DB_PASS}"
echo ""
echo "IMPORTANT: Save this password securely!"
echo "Next: Run 15-keystone-install.sh"
#!/bin/bash
###############################################################################
# 15-keystone-install.sh
# Install and configure Keystone (Identity service)
###############################################################################
set -e

# Configuration - EDIT THESE
KEYSTONE_DB_PASS="keystonedbpass"  # Must match 14-keystone-db.sh
ADMIN_PASS="adminpass"             # Admin user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 15: Keystone Installation ==="

echo "[1/6] Installing Keystone packages..."
sudo apt -t bullseye-wallaby-backports install -y keystone \
    apache2 libapache2-mod-wsgi-py3

echo "[2/6] Configuring Keystone..."
sudo cp /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig

# Update database connection
sudo crudini --set /etc/keystone/keystone.conf database connection \
    "mysql+pymysql://keystone:${KEYSTONE_DB_PASS}@localhost/keystone"

# Configure token provider
sudo crudini --set /etc/keystone/keystone.conf token provider fernet

echo "[3/6] Syncing Keystone database..."
sudo -u keystone keystone-manage db_sync

echo "[4/6] Initializing Fernet keys..."
sudo keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
sudo keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

echo "[5/6] Bootstrapping Keystone..."
sudo keystone-manage bootstrap --bootstrap-password ${ADMIN_PASS} \
    --bootstrap-admin-url http://${IP_ADDRESS}:5000/v3/ \
    --bootstrap-internal-url http://${IP_ADDRESS}:5000/v3/ \
    --bootstrap-public-url http://${IP_ADDRESS}:5000/v3/ \
    --bootstrap-region-id RegionOne

echo "[6/6] Configuring Apache..."
# Set ServerName
echo "ServerName ${IP_ADDRESS}" | sudo tee /etc/apache2/conf-available/servername.conf
sudo a2enconf servername

# Restart Apache
sudo systemctl restart apache2

echo ""
echo "=== Keystone installed ==="
echo "Admin password: ${ADMIN_PASS}"
echo ""
echo "IMPORTANT: Save this password securely!"
echo "Next: Run 16-keystone-openrc.sh"
#!/bin/bash
###############################################################################
# 16-keystone-openrc.sh
# Create OpenStack admin credentials file
###############################################################################
set -e

# Configuration - EDIT THESE
ADMIN_PASS="adminpass"    # Must match 15-keystone-install.sh
IP_ADDRESS="192.168.2.9"

echo "=== Step 16: Create Admin Credentials File ==="

echo "[1/2] Creating admin-openrc..."
cat <<EOF > ~/admin-openrc
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_AUTH_URL=http://${IP_ADDRESS}:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

chmod 600 ~/admin-openrc

echo "[2/2] Testing Keystone..."
source ~/admin-openrc
openstack token issue

echo ""
echo "=== Admin credentials created ==="
echo "File: ~/admin-openrc"
echo ""
echo "To use OpenStack CLI, run: source ~/admin-openrc"
echo "Next: Run 17-glance-db.sh"
#!/bin/bash
###############################################################################
# 17-glance-db.sh
# Create Glance database and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
GLANCE_DB_PASS="glancedbpass"    # Change this!
GLANCE_PASS="glancepass"         # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 17: Glance Database and Keystone Setup ==="

echo "[1/3] Creating Glance database..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '${GLANCE_DB_PASS}';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '${GLANCE_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Glance Keystone entities..."
openstack user create --domain default --password ${GLANCE_PASS} glance
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image" image
openstack endpoint create --region RegionOne image public http://${IP_ADDRESS}:9292
openstack endpoint create --region RegionOne image internal http://${IP_ADDRESS}:9292
openstack endpoint create --region RegionOne image admin http://${IP_ADDRESS}:9292

echo ""
echo "=== Glance database and Keystone entities created ==="
echo "DB Password: ${GLANCE_DB_PASS}"
echo "Keystone Password: ${GLANCE_PASS}"
echo ""
echo "IMPORTANT: Save these passwords securely!"
echo "Next: Run 18-glance-install.sh"
#!/bin/bash
###############################################################################
# 18-glance-install.sh
# Install and configure Glance (Image service) with Ceph backend
###############################################################################
set -e

# Configuration - EDIT THESE
GLANCE_DB_PASS="glancedbpass"    # Must match 17-glance-db.sh
GLANCE_PASS="glancepass"         # Must match 17-glance-db.sh
IP_ADDRESS="192.168.2.9"

echo "=== Step 18: Glance Installation ==="

echo "[1/5] Installing Glance..."
sudo apt -t bullseye-wallaby-backports install -y glance

echo "[2/5] Backing up original config..."
sudo cp /etc/glance/glance-api.conf /etc/glance/glance-api.conf.orig

echo "[3/5] Configuring Glance..."
# Database
sudo crudini --set /etc/glance/glance-api.conf database connection \
    "mysql+pymysql://glance:${GLANCE_DB_PASS}@localhost/glance"

# Keystone auth
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken www_authenticate_uri "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken username "glance"
sudo crudini --set /etc/glance/glance-api.conf keystone_authtoken password "${GLANCE_PASS}"

# Paste deploy
sudo crudini --set /etc/glance/glance-api.conf paste_deploy flavor "keystone"

# Ceph backend
sudo crudini --set /etc/glance/glance-api.conf glance_store stores "rbd"
sudo crudini --set /etc/glance/glance-api.conf glance_store default_store "rbd"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_pool "images"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_user "cinder"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_ceph_conf "/etc/ceph/ceph.conf"
sudo crudini --set /etc/glance/glance-api.conf glance_store rbd_store_chunk_size "8"

echo "[4/5] Setting up Ceph keyring for Glance..."
sudo cp /etc/ceph/ceph.client.cinder.keyring /etc/ceph/ceph.client.cinder.keyring.glance
sudo chown glance:glance /etc/ceph/ceph.client.cinder.keyring.glance

echo "[5/5] Syncing database and restarting..."
sudo -u glance glance-manage db_sync
sudo systemctl restart glance-api
sudo systemctl enable glance-api

echo ""
echo "Testing Glance..."
source ~/admin-openrc
openstack image list

echo ""
echo "=== Glance installed and configured ==="
echo "Next: Run 19-placement-db.sh"
#!/bin/bash
###############################################################################
# 19-placement-db.sh
# Create Placement database and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
PLACEMENT_DB_PASS="placementdbpass"    # Change this!
PLACEMENT_PASS="placementpass"          # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 19: Placement Database and Keystone Setup ==="

echo "[1/3] Creating Placement database..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS placement;
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost' IDENTIFIED BY '${PLACEMENT_DB_PASS}';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%' IDENTIFIED BY '${PLACEMENT_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Placement Keystone entities..."
openstack user create --domain default --password ${PLACEMENT_PASS} placement
openstack role add --project service --user placement admin
openstack service create --name placement --description "Placement API" placement
openstack endpoint create --region RegionOne placement public http://${IP_ADDRESS}:8778
openstack endpoint create --region RegionOne placement internal http://${IP_ADDRESS}:8778
openstack endpoint create --region RegionOne placement admin http://${IP_ADDRESS}:8778

echo ""
echo "=== Placement database and Keystone entities created ==="
echo "DB Password: ${PLACEMENT_DB_PASS}"
echo "Keystone Password: ${PLACEMENT_PASS}"
echo ""
echo "Next: Run 20-placement-install.sh"
#!/bin/bash
###############################################################################
# 20-placement-install.sh
# Install and configure Placement service
###############################################################################
set -e

# Configuration - EDIT THESE
PLACEMENT_DB_PASS="placementdbpass"    # Must match 19-placement-db.sh
PLACEMENT_PASS="placementpass"          # Must match 19-placement-db.sh
IP_ADDRESS="192.168.2.9"

echo "=== Step 20: Placement Installation ==="

echo "[1/4] Installing Placement..."
sudo apt -t bullseye-wallaby-backports install -y placement-api

echo "[2/4] Configuring Placement..."
sudo cp /etc/placement/placement.conf /etc/placement/placement.conf.orig

# Database
sudo crudini --set /etc/placement/placement.conf placement_database connection \
    "mysql+pymysql://placement:${PLACEMENT_DB_PASS}@localhost/placement"

# API
sudo crudini --set /etc/placement/placement.conf api auth_strategy "keystone"

# Keystone auth
sudo crudini --set /etc/placement/placement.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000/v3"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken username "placement"
sudo crudini --set /etc/placement/placement.conf keystone_authtoken password "${PLACEMENT_PASS}"

echo "[3/4] Syncing database..."
sudo -u placement placement-manage db sync

echo "[4/4] Restarting Apache..."
sudo systemctl restart apache2

echo ""
echo "Testing Placement..."
source ~/admin-openrc
openstack --os-placement-api-version 1.2 resource class list --sort-column name | head -20

echo ""
echo "=== Placement installed ==="
echo "Next: Run 21-nova-db.sh"
#!/bin/bash
###############################################################################
# 21-nova-db.sh
# Create Nova databases and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
NOVA_DB_PASS="novadbpass"    # Change this!
NOVA_PASS="novapass"          # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 21: Nova Database and Keystone Setup ==="

echo "[1/3] Creating Nova databases..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS nova_api;
CREATE DATABASE IF NOT EXISTS nova;
CREATE DATABASE IF NOT EXISTS nova_cell0;

GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_DB_PASS}';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Nova Keystone entities..."
openstack user create --domain default --password ${NOVA_PASS} nova
openstack role add --project service --user nova admin
openstack service create --name nova --description "OpenStack Compute" compute
openstack endpoint create --region RegionOne compute public http://${IP_ADDRESS}:8774/v2.1
openstack endpoint create --region RegionOne compute internal http://${IP_ADDRESS}:8774/v2.1
openstack endpoint create --region RegionOne compute admin http://${IP_ADDRESS}:8774/v2.1

echo ""
echo "=== Nova databases and Keystone entities created ==="
echo "DB Password: ${NOVA_DB_PASS}"
echo "Keystone Password: ${NOVA_PASS}"
echo ""
echo "Next: Run 22-nova-install.sh"
#!/bin/bash
###############################################################################
# 22-nova-install.sh
# Install and configure Nova (Compute service)
###############################################################################
set -e

# Configuration - EDIT THESE
NOVA_DB_PASS="novadbpass"        # Must match 21-nova-db.sh
NOVA_PASS="novapass"              # Must match 21-nova-db.sh
PLACEMENT_PASS="placementpass"    # Must match 19-placement-db.sh
RABBIT_PASS="guest"               # RabbitMQ password (default is guest)
IP_ADDRESS="192.168.2.9"

echo "=== Step 22: Nova Installation ==="

echo "[1/5] Installing Nova packages..."
sudo apt -t bullseye-wallaby-backports install -y \
    nova-api nova-conductor nova-scheduler nova-novncproxy \
    nova-compute

echo "[2/5] Backing up original config..."
sudo cp /etc/nova/nova.conf /etc/nova/nova.conf.orig

echo "[3/5] Configuring Nova..."
# Default section
sudo crudini --set /etc/nova/nova.conf DEFAULT my_ip "${IP_ADDRESS}"
sudo crudini --set /etc/nova/nova.conf DEFAULT transport_url "rabbit://guest:${RABBIT_PASS}@localhost:5672/"
sudo crudini --set /etc/nova/nova.conf DEFAULT use_neutron "true"
sudo crudini --set /etc/nova/nova.conf DEFAULT firewall_driver "nova.virt.firewall.NoopFirewallDriver"

# API database
sudo crudini --set /etc/nova/nova.conf api_database connection \
    "mysql+pymysql://nova:${NOVA_DB_PASS}@localhost/nova_api"

# Database
sudo crudini --set /etc/nova/nova.conf database connection \
    "mysql+pymysql://nova:${NOVA_DB_PASS}@localhost/nova"

# API
sudo crudini --set /etc/nova/nova.conf api auth_strategy "keystone"

# Keystone auth
sudo crudini --set /etc/nova/nova.conf keystone_authtoken www_authenticate_uri "http://${IP_ADDRESS}:5000/"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000/"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken username "nova"
sudo crudini --set /etc/nova/nova.conf keystone_authtoken password "${NOVA_PASS}"

# VNC
sudo crudini --set /etc/nova/nova.conf vnc enabled "true"
sudo crudini --set /etc/nova/nova.conf vnc server_listen "${IP_ADDRESS}"
sudo crudini --set /etc/nova/nova.conf vnc server_proxyclient_address "${IP_ADDRESS}"
sudo crudini --set /etc/nova/nova.conf vnc novncproxy_base_url "http://${IP_ADDRESS}:6080/vnc_auto.html"

# Glance
sudo crudini --set /etc/nova/nova.conf glance api_servers "http://${IP_ADDRESS}:9292"

# Oslo concurrency
sudo crudini --set /etc/nova/nova.conf oslo_concurrency lock_path "/var/lib/nova/tmp"

# Placement
sudo crudini --set /etc/nova/nova.conf placement region_name "RegionOne"
sudo crudini --set /etc/nova/nova.conf placement project_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf placement project_name "service"
sudo crudini --set /etc/nova/nova.conf placement auth_type "password"
sudo crudini --set /etc/nova/nova.conf placement user_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf placement auth_url "http://${IP_ADDRESS}:5000/v3"
sudo crudini --set /etc/nova/nova.conf placement username "placement"
sudo crudini --set /etc/nova/nova.conf placement password "${PLACEMENT_PASS}"

echo "[4/5] Syncing databases..."
sudo -u nova nova-manage api_db sync
sudo -u nova nova-manage cell_v2 map_cell0
sudo -u nova nova-manage cell_v2 create_cell --name=cell1 --verbose || true
sudo -u nova nova-manage db sync
sudo -u nova nova-manage cell_v2 list_cells

echo "[5/5] Starting Nova services..."
sudo systemctl restart nova-api nova-scheduler nova-conductor nova-novncproxy nova-compute
sudo systemctl enable nova-api nova-scheduler nova-conductor nova-novncproxy nova-compute

echo ""
echo "=== Nova installed ==="
echo "Next: Run 23-nova-discover.sh (after a few seconds for services to start)"
#!/bin/bash
###############################################################################
# 23-nova-discover.sh
# Discover compute hosts and verify Nova
###############################################################################
set -e

echo "=== Step 23: Nova Compute Discovery ==="

echo "[1/2] Discovering compute hosts..."
sudo -u nova nova-manage cell_v2 discover_hosts --verbose

echo "[2/2] Verifying Nova services..."
source ~/admin-openrc

echo ""
echo "Compute services:"
openstack compute service list

echo ""
echo "Hypervisor list:"
openstack hypervisor list

echo ""
echo "=== Nova compute discovery complete ==="
echo "Next: Run 24-neutron-db.sh"
#!/bin/bash
###############################################################################
# 24-neutron-db.sh
# Create Neutron database and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
NEUTRON_DB_PASS="neutrondbpass"    # Change this!
NEUTRON_PASS="neutronpass"          # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 24: Neutron Database and Keystone Setup ==="

echo "[1/3] Creating Neutron database..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS neutron;
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '${NEUTRON_DB_PASS}';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '${NEUTRON_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Neutron Keystone entities..."
openstack user create --domain default --password ${NEUTRON_PASS} neutron
openstack role add --project service --user neutron admin
openstack service create --name neutron --description "OpenStack Networking" network
openstack endpoint create --region RegionOne network public http://${IP_ADDRESS}:9696
openstack endpoint create --region RegionOne network internal http://${IP_ADDRESS}:9696
openstack endpoint create --region RegionOne network admin http://${IP_ADDRESS}:9696

echo ""
echo "=== Neutron database and Keystone entities created ==="
echo "DB Password: ${NEUTRON_DB_PASS}"
echo "Keystone Password: ${NEUTRON_PASS}"
echo ""
echo "Next: Run 25-neutron-install.sh"
#!/bin/bash
###############################################################################
# 25-neutron-install.sh
# Install and configure Neutron (Networking service) with Linux Bridge
###############################################################################
set -e

# Configuration - EDIT THESE
NEUTRON_DB_PASS="neutrondbpass"    # Must match 24-neutron-db.sh
NEUTRON_PASS="neutronpass"          # Must match 24-neutron-db.sh
NOVA_PASS="novapass"                # Must match 21-nova-db.sh
RABBIT_PASS="guest"
IP_ADDRESS="192.168.2.9"
METADATA_SECRET="metadatasecret"    # Shared secret for metadata - Change this!

echo "=== Step 25: Neutron Installation ==="

echo "[1/7] Installing Neutron packages..."
sudo apt -t bullseye-wallaby-backports install -y \
    neutron-server neutron-plugin-ml2 \
    neutron-linuxbridge-agent neutron-dhcp-agent \
    neutron-metadata-agent

echo "[2/7] Backing up original configs..."
sudo cp /etc/neutron/neutron.conf /etc/neutron/neutron.conf.orig
sudo cp /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugins/ml2/ml2_conf.ini.orig
sudo cp /etc/neutron/plugins/ml2/linuxbridge_agent.ini /etc/neutron/plugins/ml2/linuxbridge_agent.ini.orig

echo "[3/7] Configuring neutron.conf..."
# Database
sudo crudini --set /etc/neutron/neutron.conf database connection \
    "mysql+pymysql://neutron:${NEUTRON_DB_PASS}@localhost/neutron"

# Default
sudo crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin "ml2"
sudo crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins ""
sudo crudini --set /etc/neutron/neutron.conf DEFAULT transport_url "rabbit://guest:${RABBIT_PASS}@localhost:5672/"
sudo crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy "keystone"
sudo crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes "true"
sudo crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes "true"

# Keystone auth
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken www_authenticate_uri "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken username "neutron"
sudo crudini --set /etc/neutron/neutron.conf keystone_authtoken password "${NEUTRON_PASS}"

# Nova notifications
sudo crudini --set /etc/neutron/neutron.conf nova auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/neutron/neutron.conf nova auth_type "password"
sudo crudini --set /etc/neutron/neutron.conf nova project_domain_name "Default"
sudo crudini --set /etc/neutron/neutron.conf nova user_domain_name "Default"
sudo crudini --set /etc/neutron/neutron.conf nova region_name "RegionOne"
sudo crudini --set /etc/neutron/neutron.conf nova project_name "service"
sudo crudini --set /etc/neutron/neutron.conf nova username "nova"
sudo crudini --set /etc/neutron/neutron.conf nova password "${NOVA_PASS}"

# Oslo concurrency
sudo crudini --set /etc/neutron/neutron.conf oslo_concurrency lock_path "/var/lib/neutron/tmp"

echo "[4/7] Configuring ML2 plugin..."
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers "flat"
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types "flat"
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers "linuxbridge"
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 extension_drivers "port_security"
sudo crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks "physnet1"

echo "[5/7] Configuring Linux Bridge agent..."
sudo crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini linux_bridge physical_interface_mappings "physnet1:br-provider"
sudo crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan enable_vxlan "false"
sudo crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup enable_security_group "true"
sudo crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup firewall_driver "iptables"

echo "[6/7] Configuring Metadata agent..."
sudo crudini --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_host "${IP_ADDRESS}"
sudo crudini --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret "${METADATA_SECRET}"

echo "[7/7] Updating Nova to use Neutron..."
sudo crudini --set /etc/nova/nova.conf neutron auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/nova/nova.conf neutron auth_type "password"
sudo crudini --set /etc/nova/nova.conf neutron project_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf neutron user_domain_name "Default"
sudo crudini --set /etc/nova/nova.conf neutron region_name "RegionOne"
sudo crudini --set /etc/nova/nova.conf neutron project_name "service"
sudo crudini --set /etc/nova/nova.conf neutron username "neutron"
sudo crudini --set /etc/nova/nova.conf neutron password "${NEUTRON_PASS}"
sudo crudini --set /etc/nova/nova.conf neutron service_metadata_proxy "true"
sudo crudini --set /etc/nova/nova.conf neutron metadata_proxy_shared_secret "${METADATA_SECRET}"

echo ""
echo "=== Neutron configuration complete ==="
echo "Metadata secret: ${METADATA_SECRET}"
echo ""
echo "Next: Run 26-neutron-sync.sh"
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
#!/bin/bash
###############################################################################
# 27-provider-network.sh
# Create provider flat network (uses LAN DHCP)
###############################################################################
set -e

# Configuration - EDIT THESE
SUBNET_RANGE="192.168.2.0/24"
GATEWAY="192.168.2.1"
DNS_SERVER="8.8.8.8"

echo "=== Step 27: Provider Network Creation ==="

source ~/admin-openrc

echo "[1/2] Creating provider network..."
openstack network create --external \
    --provider-physical-network physnet1 \
    --provider-network-type flat \
    public

echo "[2/2] Creating provider subnet (no DHCP - uses LAN DHCP)..."
openstack subnet create --network public \
    --subnet-range ${SUBNET_RANGE} \
    --gateway ${GATEWAY} \
    --dns-nameserver ${DNS_SERVER} \
    --no-dhcp \
    public-subnet

echo ""
echo "Network list:"
openstack network list

echo ""
echo "Subnet list:"
openstack subnet list

echo ""
echo "=== Provider network created ==="
echo "VMs on this network will get IPs from your LAN DHCP server."
echo "Next: Run 28-cinder-db.sh"
#!/bin/bash
###############################################################################
# 28-cinder-db.sh
# Create Cinder database and Keystone entities
###############################################################################
set -e

# Configuration - EDIT THESE
CINDER_DB_PASS="cinderdbpass"    # Change this!
CINDER_PASS="cinderpass"          # Keystone user password - Change this!
IP_ADDRESS="192.168.2.9"

echo "=== Step 28: Cinder Database and Keystone Setup ==="

echo "[1/3] Creating Cinder database..."
echo "Enter MariaDB root password when prompted..."
sudo mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS cinder;
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '${CINDER_DB_PASS}';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '${CINDER_DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "[2/3] Loading OpenStack credentials..."
source ~/admin-openrc

echo "[3/3] Creating Cinder Keystone entities..."
openstack user create --domain default --password ${CINDER_PASS} cinder
openstack role add --project service --user cinder admin

# Cinder v3 service
openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3
openstack endpoint create --region RegionOne volumev3 public http://${IP_ADDRESS}:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 internal http://${IP_ADDRESS}:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 admin http://${IP_ADDRESS}:8776/v3/%\(project_id\)s

echo ""
echo "=== Cinder database and Keystone entities created ==="
echo "DB Password: ${CINDER_DB_PASS}"
echo "Keystone Password: ${CINDER_PASS}"
echo ""
echo "Next: Run 29-cinder-install.sh"
#!/bin/bash
###############################################################################
# 29-cinder-install.sh
# Install and configure Cinder (Block Storage) with Ceph backend
###############################################################################
set -e

# Configuration - EDIT THESE
CINDER_DB_PASS="cinderdbpass"    # Must match 28-cinder-db.sh
CINDER_PASS="cinderpass"          # Must match 28-cinder-db.sh
RABBIT_PASS="guest"
IP_ADDRESS="192.168.2.9"

echo "=== Step 29: Cinder Installation ==="

echo "[1/5] Installing Cinder packages..."
sudo apt -t bullseye-wallaby-backports install -y \
    cinder-api cinder-scheduler cinder-volume

echo "[2/5] Backing up original config..."
sudo cp /etc/cinder/cinder.conf /etc/cinder/cinder.conf.orig

echo "[3/5] Configuring Cinder..."
# Database
sudo crudini --set /etc/cinder/cinder.conf database connection \
    "mysql+pymysql://cinder:${CINDER_DB_PASS}@localhost/cinder"

# Default
sudo crudini --set /etc/cinder/cinder.conf DEFAULT transport_url "rabbit://guest:${RABBIT_PASS}@localhost:5672/"
sudo crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy "keystone"
sudo crudini --set /etc/cinder/cinder.conf DEFAULT my_ip "${IP_ADDRESS}"
sudo crudini --set /etc/cinder/cinder.conf DEFAULT enabled_backends "ceph"
sudo crudini --set /etc/cinder/cinder.conf DEFAULT glance_api_servers "http://${IP_ADDRESS}:9292"

# Keystone auth
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken www_authenticate_uri "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_url "http://${IP_ADDRESS}:5000"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken memcached_servers "localhost:11211"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_type "password"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken project_domain_name "Default"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken user_domain_name "Default"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken project_name "service"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken username "cinder"
sudo crudini --set /etc/cinder/cinder.conf keystone_authtoken password "${CINDER_PASS}"

# Oslo concurrency
sudo crudini --set /etc/cinder/cinder.conf oslo_concurrency lock_path "/var/lib/cinder/tmp"

# Ceph backend
sudo crudini --set /etc/cinder/cinder.conf ceph volume_driver "cinder.volume.drivers.rbd.RBDDriver"
sudo crudini --set /etc/cinder/cinder.conf ceph rbd_pool "volumes"
sudo crudini --set /etc/cinder/cinder.conf ceph rbd_ceph_conf "/etc/ceph/ceph.conf"
sudo crudini --set /etc/cinder/cinder.conf ceph rbd_user "cinder"
sudo crudini --set /etc/cinder/cinder.conf ceph volume_backend_name "ceph"

echo "[4/5] Setting up Ceph keyring for Cinder..."
sudo cp /etc/ceph/ceph.client.cinder.keyring /etc/ceph/ceph.client.cinder.keyring.cinder
sudo chown cinder:cinder /etc/ceph/ceph.client.cinder.keyring.cinder

echo "[5/5] Syncing database and starting services..."
sudo -u cinder cinder-manage db sync

sudo systemctl restart cinder-api cinder-scheduler cinder-volume
sudo systemctl enable cinder-api cinder-scheduler cinder-volume

echo ""
echo "Verifying Cinder..."
sleep 3
source ~/admin-openrc
openstack volume service list

echo ""
echo "=== Cinder installed ==="
echo "Next: Run 30-nova-ceph.sh"
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
#!/bin/bash
###############################################################################
# 31-horizon.sh
# Install and configure Horizon (Dashboard)
###############################################################################
set -e

# Configuration - EDIT THESE
IP_ADDRESS="192.168.2.9"
TIME_ZONE="UTC"    # Change to your timezone, e.g., "America/New_York"

echo "=== Step 31: Horizon Installation ==="

echo "[1/3] Installing Horizon..."
sudo apt install -y openstack-dashboard

echo "[2/3] Configuring Horizon..."
# Backup original
sudo cp /etc/openstack-dashboard/local_settings.py /etc/openstack-dashboard/local_settings.py.orig

# Configure settings
sudo sed -i "s/OPENSTACK_HOST = .*/OPENSTACK_HOST = \"${IP_ADDRESS}\"/" \
    /etc/openstack-dashboard/local_settings.py

sudo sed -i "s/ALLOWED_HOSTS = .*/ALLOWED_HOSTS = ['*']/" \
    /etc/openstack-dashboard/local_settings.py

sudo sed -i "s/TIME_ZONE = .*/TIME_ZONE = \"${TIME_ZONE}\"/" \
    /etc/openstack-dashboard/local_settings.py

# Ensure memcached is configured
cat <<'EOF' | sudo tee -a /etc/openstack-dashboard/local_settings.py

# Session engine
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
        'LOCATION': '127.0.0.1:11211',
    },
}

# Keystone API version
OPENSTACK_KEYSTONE_URL = "http://${IP_ADDRESS}:5000/v3"
OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = "Default"

# API versions
OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "image": 2,
    "volume": 3,
}
EOF

# Replace placeholder
sudo sed -i "s/\${IP_ADDRESS}/${IP_ADDRESS}/g" /etc/openstack-dashboard/local_settings.py

echo "[3/3] Restarting Apache..."
sudo systemctl restart apache2

echo ""
echo "=== Horizon installed ==="
echo ""
echo "Access the dashboard at: http://${IP_ADDRESS}/horizon"
echo "Login with: admin / <your_admin_password>"
echo ""
echo "Next: Run 32-smoke-test.sh"
#!/bin/bash
###############################################################################
# 32-smoke-test.sh
# Final verification and test VM launch
###############################################################################
set -e

echo "=== Step 32: OpenStack Smoke Test ==="

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
