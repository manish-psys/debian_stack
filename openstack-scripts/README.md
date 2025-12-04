# OpenStack + Ceph Deployment Scripts for Debian 11 (Bullseye)

Single-node OpenStack Wallaby + Ceph Nautilus deployment using Debian packages.

## Prerequisites

- Debian 11 (bullseye) fresh install
- 4 extra disks for Ceph OSDs (e.g., /dev/sdb, /dev/sdc, /dev/sdd, /dev/sde)
- Single NIC with IP 192.168.2.9/24 (adjust in scripts as needed)
- Root/sudo access

## Configuration

**Before running**, edit the configuration variables at the top of each script:
- IP addresses
- Disk device names  
- Passwords (IMPORTANT: change all default passwords!)
- NIC name
- Timezone

## Script Order

| # | Script | Description |
|---|--------|-------------|
| 01 | base-preparation.sh | Update system, install base tools |
| 02 | hostname-setup.sh | Configure hostname |
| 03 | networking-bridge.sh | Create br-provider bridge |
| 04 | openstack-repos.sh | Add OpenStack Wallaby repos |
| 05 | ceph-install.sh | Install Ceph packages |
| 06 | ceph-disk-prep.sh | Wipe OSD disks |
| 07 | ceph-config.sh | Create ceph.conf |
| 08 | ceph-mon-init.sh | Initialize Ceph monitor |
| 09 | ceph-mon-mgr-start.sh | Start MON and MGR |
| 10 | ceph-osd-create.sh | Create OSDs |
| 11 | ceph-pools.sh | Create OpenStack pools |
| 12 | openstack-base.sh | Install MariaDB, RabbitMQ, etc. |
| 13 | mariadb-config.sh | Secure MariaDB |
| 14 | keystone-db.sh | Create Keystone database |
| 15 | keystone-install.sh | Install Keystone |
| 16 | keystone-openrc.sh | Create admin credentials |
| 17 | glance-db.sh | Create Glance database |
| 18 | glance-install.sh | Install Glance with Ceph |
| 19 | placement-db.sh | Create Placement database |
| 20 | placement-install.sh | Install Placement |
| 21 | nova-db.sh | Create Nova databases |
| 22 | nova-install.sh | Install Nova |
| 23 | nova-discover.sh | Discover compute hosts |
| 24 | neutron-db.sh | Create Neutron database |
| 25 | neutron-install.sh | Install Neutron (Linux Bridge) |
| 26 | neutron-sync.sh | Sync DB and start services |
| 27 | provider-network.sh | Create flat provider network |
| 28 | cinder-db.sh | Create Cinder database |
| 29 | cinder-install.sh | Install Cinder with Ceph |
| 30 | nova-ceph.sh | Configure Nova for Ceph |
| 31 | horizon.sh | Install Horizon dashboard |
| 32 | smoke-test.sh | Launch test VM |

## Usage

```bash
# Make all scripts executable
chmod +x *.sh

# Run in order
./01-base-preparation.sh
./02-hostname-setup.sh
# ... continue through all scripts ...
./32-smoke-test.sh
```

## Notes

- This is a LAB/POC setup with single-node Ceph (replication=1)
- Provider network uses your LAN DHCP for VM IPs
- All services run on one node (no HA)
- Review and change all passwords before deploying!

## Troubleshooting

Check service status:
```bash
systemctl status ceph-mon@osctl1
systemctl status ceph-mgr@osctl1
systemctl status nova-api
systemctl status neutron-server
```

Check logs:
```bash
journalctl -u nova-api -f
journalctl -u neutron-server -f
tail -f /var/log/ceph/ceph.log
```

Verify Ceph:
```bash
ceph -s
ceph osd tree
```

Verify OpenStack:
```bash
source ~/admin-openrc
openstack service list
openstack endpoint list
openstack network agent list
openstack compute service list
```
