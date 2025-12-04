# OpenStack + Ceph Deployment Guide for Debian 11 (Bullseye)

## Overview

This guide provides 32 sequential bash scripts to deploy a single-node OpenStack Wallaby + Ceph Nautilus cluster on Debian 11 using native Debian packages (no Kolla, no containers).

### Target Architecture

| Component | Details |
|-----------|---------|
| **OS** | Debian 11 (Bullseye) |
| **OpenStack** | Wallaby (from osbpo backports) |
| **Ceph** | Nautilus 14.2 (Debian packages) |
| **Networking** | Linux Bridge with flat provider network |
| **Storage** | Ceph RBD for Glance, Cinder, Nova ephemeral |

### Hardware Requirements

- 1 server (e.g., Dell PowerEdge R620)
- Minimum 16GB RAM (32GB+ recommended)
- 1 NIC (IP: 192.168.2.9/24 - adjust as needed)
- 4 extra disks for Ceph OSDs (e.g., /dev/sdb, /dev/sdc, /dev/sdd, /dev/sde)

---

## Script Reference

### Phase 1: Base System Preparation (Scripts 01-04)

#### 01-base-preparation.sh
**Purpose:** Prepare the base operating system

**What it does:**
- Updates all system packages (`apt full-upgrade`)
- Installs essential tools: vim, tmux, curl, gnupg, bridge-utils, tcpdump, net-tools, git, jq
- Installs and enables chrony for time synchronization (critical for OpenStack + Ceph)

**Prerequisites:** Fresh Debian 11 installation

---

#### 02-hostname-setup.sh
**Purpose:** Configure the server hostname

**What it does:**
- Sets hostname to `osctl1` (configurable)
- Updates `/etc/hostname`
- Adds hostname entry to `/etc/hosts`
- Applies hostname using `hostnamectl`

**Configuration variables:**
```bash
HOSTNAME="osctl1"
IP_ADDRESS="192.168.2.9"
```

**Note:** Re-login after running to see updated prompt.

---

#### 03-networking-bridge.sh
**Purpose:** Create Linux bridge for OpenStack provider network

**What it does:**
- Backs up current `/etc/network/interfaces`
- Creates `br-provider` bridge attached to physical NIC
- Moves host IP to the bridge
- Bridge will be used by both host and OpenStack VMs

**Configuration variables:**
```bash
PHYSICAL_NIC="enp1s0"      # Your actual NIC name
IP_ADDRESS="192.168.2.9"
NETMASK="255.255.255.0"
GATEWAY="192.168.2.1"
```

**Network topology after:**
```
Physical NIC (enp1s0) ──► br-provider (192.168.2.9)
                              │
                              ├── Host access
                              └── OpenStack VMs (provider network)
```

**Warning:** This will briefly disconnect your network. Run from console if possible.

---

#### 04-openstack-repos.sh
**Purpose:** Add Debian OpenStack Wallaby backports repository

**What it does:**
- Adds osbpo.debian.net GPG key
- Adds `bullseye-wallaby-backports` and `bullseye-wallaby-backports-nochange` repos
- Updates apt cache

**Repos added:**
```
deb http://osbpo.debian.net/osbpo bullseye-wallaby-backports main
deb http://osbpo.debian.net/osbpo bullseye-wallaby-backports-nochange main
```

---

### Phase 2: Ceph Storage Cluster (Scripts 05-11)

#### 05-ceph-install.sh
**Purpose:** Install Ceph packages from Debian repositories

**What it does:**
- Installs: ceph, ceph-common, ceph-mgr, ceph-mon, ceph-osd
- Uses Debian bullseye's Ceph Nautilus 14.2

**Packages installed:** ~200MB

---

#### 06-ceph-disk-prep.sh
**Purpose:** Wipe and prepare disks for Ceph OSDs

**What it does:**
- Runs `sgdisk --zap-all` on each OSD disk
- Runs `wipefs -a` to remove filesystem signatures
- Shows current disk layout before proceeding
- Requires confirmation before wiping

**Configuration variables:**
```bash
OSD_DISKS="/dev/sdb /dev/sdc /dev/sdd /dev/sde"
```

**⚠️ WARNING:** This DESTROYS all data on specified disks!

---

#### 07-ceph-config.sh
**Purpose:** Create Ceph configuration file

**What it does:**
- Creates `/etc/ceph` directory
- Creates monitor data directory
- Generates unique cluster FSID using `uuidgen`
- Creates `/etc/ceph/ceph.conf` with:
  - Single monitor configuration
  - Public network definition
  - Cephx authentication enabled
  - Replication size = 1 (lab only!)
  - CRUSH chooseleaf type = 0 (for single node)

**Configuration variables:**
```bash
HOSTNAME="osctl1"
IP_ADDRESS="192.168.2.9"
PUBLIC_NETWORK="192.168.2.0/24"
```

---

#### 08-ceph-mon-init.sh
**Purpose:** Initialize Ceph monitor

**What it does:**
1. Creates monitor keyring with `mon.` key
2. Creates admin keyring with `client.admin` key (full permissions)
3. Imports admin keyring into monitor keyring
4. Creates monmap with initial monitor
5. Initializes monitor with `ceph-mon --mkfs`

**Files created:**
- `/etc/ceph/ceph.mon.keyring`
- `/etc/ceph/ceph.client.admin.keyring`
- `/tmp/monmap`

---

#### 09-ceph-mon-mgr-start.sh
**Purpose:** Start Ceph monitor and manager services

**What it does:**
- Enables and starts `ceph-mon@osctl1`
- Enables and starts `ceph-mgr@osctl1`
- Shows service status

**Services started:**
- `ceph-mon@osctl1.service`
- `ceph-mgr@osctl1.service`

---

#### 10-ceph-osd-create.sh
**Purpose:** Create Ceph OSDs on prepared disks

**What it does:**
- Runs `ceph-volume lvm create --data /dev/sdX` for each disk
- Each disk becomes one OSD
- Shows cluster status and OSD tree after creation

**Configuration variables:**
```bash
OSD_DISKS="sdb sdc sdd sde"
```

**Expected output:** 4 OSDs, all `up` and `in`, HEALTH_OK

---

#### 11-ceph-pools.sh
**Purpose:** Create Ceph pools for OpenStack services

**What it does:**
- Creates pools: `volumes` (64 PGs), `images` (64 PGs), `backups` (32 PGs), `vms` (32 PGs)
- Sets replication size to 1 for all pools (lab only!)
- Creates `client.cinder` Ceph user with appropriate permissions
- Saves keyring to `/etc/ceph/ceph.client.cinder.keyring`

**Pools and their purpose:**
| Pool | Used by | Purpose |
|------|---------|---------|
| volumes | Cinder | Block storage volumes |
| images | Glance | VM images |
| backups | Cinder | Volume backups |
| vms | Nova | Ephemeral disks |

---

### Phase 3: OpenStack Base Services (Scripts 12-16)

#### 12-openstack-base.sh
**Purpose:** Install OpenStack infrastructure dependencies

**What it does:**
- Installs python3-openstackclient (CLI tools)
- Installs MariaDB server
- Installs RabbitMQ server (message queue)
- Installs Memcached (caching)
- Installs etcd server
- Enables and starts all services

---

#### 13-mariadb-config.sh
**Purpose:** Configure and secure MariaDB

**What it does:**
- Creates OpenStack-optimized MariaDB config:
  - Binds to 127.0.0.1
  - Sets InnoDB as default engine
  - Enables innodb_file_per_table
  - Sets max_connections = 4096
  - Sets UTF-8 character set
- Restarts MariaDB
- Runs `mysql_secure_installation` (interactive)

**Interactive prompts:**
- Set root password
- Remove anonymous users
- Disallow remote root login
- Remove test database
- Reload privileges

---

#### 14-keystone-db.sh
**Purpose:** Create Keystone database

**What it does:**
- Creates `keystone` database in MariaDB
- Creates `keystone` user with full privileges
- Grants access from localhost and any host

**Configuration variables:**
```bash
KEYSTONE_DB_PASS="keystonedbpass"  # CHANGE THIS!
```

---

#### 15-keystone-install.sh
**Purpose:** Install and configure Keystone (Identity service)

**What it does:**
- Installs keystone, apache2, libapache2-mod-wsgi-py3
- Configures database connection
- Sets Fernet token provider
- Syncs database schema
- Sets up Fernet keys
- Bootstraps Keystone with admin user and endpoints
- Configures Apache ServerName
- Restarts Apache

**Configuration variables:**
```bash
KEYSTONE_DB_PASS="keystonedbpass"
ADMIN_PASS="adminpass"           # CHANGE THIS!
IP_ADDRESS="192.168.2.9"
```

**Endpoints created:**
- Public: http://192.168.2.9:5000/v3/
- Internal: http://192.168.2.9:5000/v3/
- Admin: http://192.168.2.9:5000/v3/

---

#### 16-keystone-openrc.sh
**Purpose:** Create admin credentials file

**What it does:**
- Creates `~/admin-openrc` file with environment variables
- Tests Keystone by issuing a token

**File created:** `~/admin-openrc`
```bash
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=adminpass
export OS_AUTH_URL=http://192.168.2.9:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
```

**Usage:** `source ~/admin-openrc` before running OpenStack commands

---

### Phase 4: Glance Image Service (Scripts 17-18)

#### 17-glance-db.sh
**Purpose:** Create Glance database and Keystone entities

**What it does:**
- Creates `glance` database
- Creates `glance` Keystone user
- Assigns admin role to glance user
- Creates `image` service
- Creates public/internal/admin endpoints

**Configuration variables:**
```bash
GLANCE_DB_PASS="glancedbpass"    # CHANGE THIS!
GLANCE_PASS="glancepass"         # CHANGE THIS!
```

---

#### 18-glance-install.sh
**Purpose:** Install and configure Glance with Ceph backend

**What it does:**
- Installs glance package
- Configures database connection
- Configures Keystone authentication
- Configures Ceph RBD backend:
  - Store: rbd
  - Pool: images
  - User: cinder
- Copies Ceph keyring for Glance
- Syncs database and starts service

**Storage backend:**
```ini
[glance_store]
stores = rbd
default_store = rbd
rbd_store_pool = images
rbd_store_user = cinder
```

---

### Phase 5: Placement Service (Scripts 19-20)

#### 19-placement-db.sh
**Purpose:** Create Placement database and Keystone entities

**What it does:**
- Creates `placement` database
- Creates `placement` Keystone user
- Creates `placement` service
- Creates endpoints on port 8778

**Configuration variables:**
```bash
PLACEMENT_DB_PASS="placementdbpass"
PLACEMENT_PASS="placementpass"
```

---

#### 20-placement-install.sh
**Purpose:** Install and configure Placement API

**What it does:**
- Installs placement-api package
- Configures database connection
- Configures Keystone authentication
- Syncs database
- Restarts Apache (Placement runs under Apache)

**Purpose of Placement:** Tracks resource inventory and usage across compute nodes. Required by Nova scheduler.

---

### Phase 6: Nova Compute Service (Scripts 21-23)

#### 21-nova-db.sh
**Purpose:** Create Nova databases and Keystone entities

**What it does:**
- Creates three databases: `nova_api`, `nova`, `nova_cell0`
- Creates `nova` Keystone user
- Creates `compute` service
- Creates endpoints on port 8774

**Configuration variables:**
```bash
NOVA_DB_PASS="novadbpass"
NOVA_PASS="novapass"
```

---

#### 22-nova-install.sh
**Purpose:** Install and configure Nova (controller + compute)

**What it does:**
- Installs: nova-api, nova-conductor, nova-scheduler, nova-novncproxy, nova-compute
- Configures:
  - Database connections (api_database, database)
  - RabbitMQ transport
  - Keystone authentication
  - VNC proxy (port 6080)
  - Glance API server
  - Placement integration
  - Neutron integration (use_neutron=true)
- Syncs databases
- Maps cell0 and creates cell1
- Starts all Nova services

**Configuration variables:**
```bash
NOVA_DB_PASS="novadbpass"
NOVA_PASS="novapass"
PLACEMENT_PASS="placementpass"
RABBIT_PASS="guest"
IP_ADDRESS="192.168.2.9"
```

**Services started:**
- nova-api
- nova-conductor
- nova-scheduler
- nova-novncproxy
- nova-compute

---

#### 23-nova-discover.sh
**Purpose:** Discover compute hosts

**What it does:**
- Runs `nova-manage cell_v2 discover_hosts`
- Lists compute services
- Lists hypervisors

**Run after:** Nova services have started (wait a few seconds)

---

### Phase 7: Neutron Networking Service (Scripts 24-27)

#### 24-neutron-db.sh
**Purpose:** Create Neutron database and Keystone entities

**What it does:**
- Creates `neutron` database
- Creates `neutron` Keystone user
- Creates `network` service
- Creates endpoints on port 9696

**Configuration variables:**
```bash
NEUTRON_DB_PASS="neutrondbpass"
NEUTRON_PASS="neutronpass"
```

---

#### 25-neutron-install.sh
**Purpose:** Install and configure Neutron with Linux Bridge

**What it does:**
- Installs: neutron-server, neutron-plugin-ml2, neutron-linuxbridge-agent, neutron-dhcp-agent, neutron-metadata-agent
- Configures neutron.conf:
  - ML2 core plugin
  - RabbitMQ transport
  - Keystone authentication
  - Nova notifications
- Configures ML2 plugin:
  - Type driver: flat
  - Mechanism driver: linuxbridge
  - Physical network: physnet1
- Configures Linux Bridge agent:
  - Maps physnet1 to br-provider
  - Disables VXLAN
  - Enables security groups with iptables
- Configures metadata agent with shared secret
- Updates Nova to use Neutron

**Configuration variables:**
```bash
NEUTRON_DB_PASS="neutrondbpass"
NEUTRON_PASS="neutronpass"
NOVA_PASS="novapass"
METADATA_SECRET="metadatasecret"  # CHANGE THIS!
```

---

#### 26-neutron-sync.sh
**Purpose:** Sync Neutron database and start services

**What it does:**
- Runs `neutron-db-manage upgrade head`
- Restarts nova-api
- Starts and enables all Neutron agents
- Verifies agents are running

**Services started:**
- neutron-server
- neutron-linuxbridge-agent
- neutron-dhcp-agent
- neutron-metadata-agent

---

#### 27-provider-network.sh
**Purpose:** Create flat provider network

**What it does:**
- Creates external network `public` mapped to physnet1
- Creates subnet `public-subnet` with:
  - Range: 192.168.2.0/24
  - Gateway: 192.168.2.1
  - DNS: 8.8.8.8
  - **No DHCP** (VMs use your LAN DHCP)

**Configuration variables:**
```bash
SUBNET_RANGE="192.168.2.0/24"
GATEWAY="192.168.2.1"
DNS_SERVER="8.8.8.8"
```

**Important:** VMs on this network get IPs from your existing LAN DHCP server, not from Neutron.

---

### Phase 8: Cinder Block Storage (Scripts 28-29)

#### 28-cinder-db.sh
**Purpose:** Create Cinder database and Keystone entities

**What it does:**
- Creates `cinder` database
- Creates `cinder` Keystone user
- Creates `volumev3` service
- Creates endpoints on port 8776

**Configuration variables:**
```bash
CINDER_DB_PASS="cinderdbpass"
CINDER_PASS="cinderpass"
```

---

#### 29-cinder-install.sh
**Purpose:** Install and configure Cinder with Ceph backend

**What it does:**
- Installs: cinder-api, cinder-scheduler, cinder-volume
- Configures:
  - Database connection
  - RabbitMQ transport
  - Keystone authentication
  - Glance API server
- Configures Ceph backend:
  - Driver: cinder.volume.drivers.rbd.RBDDriver
  - Pool: volumes
  - User: cinder
- Copies Ceph keyring for Cinder
- Syncs database and starts services

**Services started:**
- cinder-api
- cinder-scheduler
- cinder-volume

---

### Phase 9: Integration and Dashboard (Scripts 30-32)

#### 30-nova-ceph.sh
**Purpose:** Configure Nova to use Ceph for ephemeral disks

**What it does:**
- Creates libvirt secret for Ceph authentication
- Sets secret value with Ceph key
- Configures Nova libvirt section:
  - images_type = rbd
  - images_rbd_pool = vms
  - rbd_user = cinder
  - rbd_secret_uuid = <generated UUID>
- Updates Cinder with same secret UUID
- Restarts Nova compute and Cinder volume

**Result:** VM ephemeral disks stored in Ceph `vms` pool

---

#### 31-horizon.sh
**Purpose:** Install Horizon dashboard

**What it does:**
- Installs openstack-dashboard package
- Configures local_settings.py:
  - OPENSTACK_HOST
  - ALLOWED_HOSTS = ['*']
  - TIME_ZONE
  - Memcached session backend
  - Keystone v3 API
- Restarts Apache

**Configuration variables:**
```bash
IP_ADDRESS="192.168.2.9"
TIME_ZONE="UTC"
```

**Access:** http://192.168.2.9/horizon

---

#### 32-smoke-test.sh
**Purpose:** Verify deployment and launch test VM

**What it does:**
1. Checks all service status (Neutron, Nova, Cinder)
2. Downloads and uploads cirros test image
3. Creates m1.tiny flavor (512MB RAM, 1 vCPU, 1GB disk)
4. Creates SSH keypair
5. Adds security group rules (ICMP, SSH)
6. Launches test VM `test-vm-1` on provider network
7. Shows VM status and console URL

**Test VM details:**
- Image: cirros
- Flavor: m1.tiny
- Network: public (provider)
- Default cirros credentials: `cirros` / `gocubsgo`

---

## Password Reference

**⚠️ CHANGE ALL PASSWORDS BEFORE DEPLOYMENT!**

| Service | Variable | Default | Used in Scripts |
|---------|----------|---------|-----------------|
| MariaDB root | (set interactively) | - | 13 |
| Keystone DB | KEYSTONE_DB_PASS | keystonedbpass | 14, 15 |
| Admin user | ADMIN_PASS | adminpass | 15, 16 |
| Glance DB | GLANCE_DB_PASS | glancedbpass | 17, 18 |
| Glance user | GLANCE_PASS | glancepass | 17, 18 |
| Placement DB | PLACEMENT_DB_PASS | placementdbpass | 19, 20 |
| Placement user | PLACEMENT_PASS | placementpass | 19, 20, 22 |
| Nova DB | NOVA_DB_PASS | novadbpass | 21, 22 |
| Nova user | NOVA_PASS | novapass | 21, 22, 25 |
| Neutron DB | NEUTRON_DB_PASS | neutrondbpass | 24, 25 |
| Neutron user | NEUTRON_PASS | neutronpass | 24, 25 |
| Metadata | METADATA_SECRET | metadatasecret | 25 |
| Cinder DB | CINDER_DB_PASS | cinderdbpass | 28, 29 |
| Cinder user | CINDER_PASS | cinderpass | 28, 29 |
| RabbitMQ | RABBIT_PASS | guest | 22, 25, 29 |

---

## Troubleshooting

### Check Service Status

```bash
# Ceph
sudo ceph -s
sudo ceph osd tree
systemctl status ceph-mon@osctl1
systemctl status ceph-mgr@osctl1

# OpenStack
source ~/admin-openrc
openstack service list
openstack endpoint list
openstack network agent list
openstack compute service list
openstack volume service list
```

### View Logs

```bash
# Ceph
tail -f /var/log/ceph/ceph.log

# OpenStack services
journalctl -u nova-api -f
journalctl -u nova-compute -f
journalctl -u neutron-server -f
journalctl -u cinder-volume -f

# Apache (Keystone, Placement, Horizon)
tail -f /var/log/apache2/error.log
```

### Common Issues

**Ceph HEALTH_WARN: too few PGs**
```bash
# Increase PGs (must be power of 2)
sudo ceph osd pool set volumes pg_num 128
```

**Nova compute not discovered**
```bash
sudo -u nova nova-manage cell_v2 discover_hosts --verbose
```

**Neutron agent not running**
```bash
sudo systemctl restart neutron-linuxbridge-agent
sudo systemctl status neutron-linuxbridge-agent
```

**VM not getting IP from DHCP**
- Check your LAN DHCP server is running
- Verify br-provider bridge includes physical NIC
- Check security group allows DHCP (port 67-68 UDP)

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     Dell PowerEdge R620                         │
│                        (osctl1)                                 │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │  Keystone   │  │   Glance    │  │  Placement  │             │
│  │  (Identity) │  │  (Images)   │  │    (API)    │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │    Nova     │  │   Neutron   │  │   Cinder    │             │
│  │  (Compute)  │  │ (Networking)│  │  (Volumes)  │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
│                                                                 │
│  ┌─────────────────────────────────────────────────┐           │
│  │              Ceph Cluster (Single Node)          │           │
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐               │           │
│  │  │OSD 0│ │OSD 1│ │OSD 2│ │OSD 3│  MON + MGR    │           │
│  │  │sdb  │ │sdc  │ │sdd  │ │sde  │               │           │
│  │  └─────┘ └─────┘ └─────┘ └─────┘               │           │
│  └─────────────────────────────────────────────────┘           │
│                                                                 │
│  ┌─────────────────────────────────────────────────┐           │
│  │                br-provider                       │           │
│  │         (Linux Bridge - 192.168.2.9)            │           │
│  │    ┌──────┐  ┌──────┐  ┌──────┐                 │           │
│  │    │ VM 1 │  │ VM 2 │  │ VM 3 │  ...           │           │
│  │    └──────┘  └──────┘  └──────┘                 │           │
│  └───────────────────┬─────────────────────────────┘           │
└──────────────────────┼──────────────────────────────────────────┘
                       │
                       ▼
              Physical NIC (enp1s0)
                       │
                       ▼
           LAN (192.168.2.0/24)
           DHCP Server, Gateway
```

---

## Next Steps (Production Considerations)

1. **Add more nodes** for HA:
   - 3+ Ceph MONs on separate hosts
   - 3+ OpenStack controllers with HAProxy/Keepalived
   - Separate compute nodes

2. **Increase Ceph replication:**
   ```bash
   sudo ceph osd pool set volumes size 3
   sudo ceph osd pool set images size 3
   ```

3. **Separate networks:**
   - Management network
   - Storage network (Ceph)
   - Provider/tenant networks

4. **Enable additional services:**
   - Heat (Orchestration)
   - Swift (Object Storage)
   - Octavia (Load Balancing)

5. **Security hardening:**
   - TLS for all endpoints
   - Firewall rules
   - Regular updates
