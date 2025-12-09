# OpenStack + Ceph Deployment on Debian 13.2 (Trixie)

## System Overview

**Hardware Specifications:**
- Server: Dell PowerEdge R620
- CPU: 2x Intel Xeon E5-2696 v2 @ 2.50GHz (48 cores total)
- RAM: 128 GB
- Storage:
  - sda: 1.8TB (OS - Debian 13.2 Trixie)
  - sdb: 1.8TB (Ceph OSD)
  - sdc: 1.8TB (Ceph OSD)
  - sdd: 931GB (Ceph OSD)
  - sde: 1.8TB (Ceph OSD)
  - **Total Ceph Storage: ~7.1TB raw**
- Network: eno1 (192.168.2.9/24) - Provider network

## OpenStack Components (Native Debian Trixie Packages)

### Core Services
- **Keystone 27.0.0** (Identity - Caracal release)
- **Nova 31.0.0** (Compute - Dalmatian release)
- **Neutron 26.0.0** (Networking - Caracal release)
- **Glance 28.0.0** (Image - Caracal release)
- **Cinder 24.0.0** (Block Storage - Caracal release)
- **Placement 11.0.0** (Resource tracking - Caracal release)
- **Horizon** (Dashboard)

### Storage Backend
- **Ceph 18.2.7 (Reef LTS)** providing:
  - **RBD**: Block storage for VM volumes (Cinder)
  - **RGW**: S3-compatible object storage
  - **CephFS**: Shared filesystem storage
  - **Images**: Glance image storage

### Networking
- **Open vSwitch 3.5.0**
- **OVN 25.03.0** (SDN controller)
- **Provider Network**: Direct L2 connectivity on 192.168.2.0/24

## Deployment Architecture

This is an **all-in-one** deployment where a single server runs:
- OpenStack Controller (all API services)
- OpenStack Compute (hypervisor)
- Ceph MON + MGR + OSD (storage cluster)
- OVN Central (SDN controller)
- OVS (virtual switching)

## Key Advantages of Debian Trixie

1. **Native OpenStack Packages**: No backports needed - everything in main repos
2. **Latest Stable Versions**: Caracal/Dalmatian releases with modern features
3. **Ceph Reef LTS**: Long-term support with excellent stability
4. **Modern OVN/OVS**: Latest SDN features and performance improvements
5. **Debian Quality**: Rock-solid stability and security updates

## Deployment Status

### ✅ Updated Scripts for Trixie
- [`01-base-preparation.sh`](openstack-scripts/01-base-preparation.sh) - System prep with Trixie verification
- [`04-openstack-repos.sh`](openstack-scripts/04-openstack-repos.sh) - Native repo configuration
- [`05-ceph-install.sh`](openstack-scripts/05-ceph-install.sh) - Ceph Reef with RGW/CephFS
- [`07-ceph-config.sh`](openstack-scripts/07-ceph-config.sh) - Optimized for all-in-one
- [`openstack-env.sh`](openstack-scripts/openstack-env.sh) - Updated with Trixie versions

### 📋 Scripts Ready to Use (Compatible with Trixie)
All remaining scripts (02-03, 06, 08-34) are compatible with Debian Trixie as they:
- Use generic Debian commands
- Source the updated environment file
- Follow idempotent patterns
- Include proper verification steps

## Pre-Deployment Checklist

### ✅ System Requirements Met
- [x] Debian 13.2 (Trixie) installed
- [x] 128GB RAM (excellent for all-in-one)
- [x] 48 CPU cores (plenty for compute)
- [x] 7.1TB storage for Ceph
- [x] Network connectivity (192.168.2.9/24)
- [x] Root/sudo access

### ⚠️ Before Starting Deployment

1. **Backup Important Data**: The Ceph disk prep script will DESTROY all data on sdb/sdc/sdd/sde
2. **Network Planning**: Confirm 192.168.2.0/24 is your provider network
3. **Hostname**: Verify hostname is set correctly (currently: psplstack)
4. **Time Sync**: Ensure system time is accurate (critical for Ceph)

## Deployment Steps

### Phase 1: Base System (Scripts 01-04)
```bash
cd ~/git_repos/padmini/ppcs/debian_stack/openstack-scripts

# 1. Base preparation
sudo ./01-base-preparation.sh

# 2. Hostname setup (verify CONTROLLER_HOSTNAME in openstack-env.sh first)
sudo ./02-hostname-setup.sh

# 3. Network bridge setup
sudo ./03-networking-bridge.sh

# 4. Repository configuration
sudo ./04-openstack-repos.sh
```

### Phase 2: Ceph Storage (Scripts 05-11)
```bash
# 5. Install Ceph packages
sudo ./05-ceph-install.sh

# 6. Prepare disks (WARNING: DESTROYS DATA!)
sudo ./06-ceph-disk-prep.sh

# 7. Create Ceph configuration
sudo ./07-ceph-config.sh

# 8. Initialize Ceph monitor
sudo ./08-ceph-mon-init.sh

# 9. Start MON and MGR
sudo ./09-ceph-mon-mgr-start.sh

# 10. Create OSDs
sudo ./10-ceph-osd-create.sh

# 11. Create storage pools
sudo ./11-ceph-pools.sh
```

### Phase 3: OpenStack Core (Scripts 12-16)
```bash
# 12. Install base OpenStack packages
sudo ./12-openstack-base.sh

# 13. Configure MariaDB
sudo ./13-mariadb-config.sh

# 14. Create Keystone database
sudo ./14-keystone-db.sh

# 15. Install and configure Keystone
sudo ./15-keystone-install.sh

# 16. Create OpenStack credentials file
sudo ./16-keystone-openrc.sh
```

### Phase 4: OpenStack Services (Scripts 17-31)
```bash
# Glance (Image Service)
sudo ./17-glance-db.sh
sudo ./18-glance-install.sh

# Placement (Resource Tracking)
sudo ./19-placement-db.sh
sudo ./20-placement-install.sh

# Nova (Compute)
sudo ./21-nova-db.sh
sudo ./22-nova-install.sh
sudo ./23-nova-discover.sh

# Neutron (Networking)
sudo ./24-neutron-db.sh
sudo ./25-ovs-ovn-install.sh
sudo ./26-neutron-install.sh
sudo ./27-neutron-sync.sh
sudo ./28-provider-network.sh

# Cinder (Block Storage)
sudo ./29-cinder-db.sh
sudo ./30-cinder-install.sh
sudo ./31-cinder-sync.sh
```

### Phase 5: Integration & UI (Scripts 32-34)
```bash
# Nova-Ceph integration
sudo ./32-nova-ceph.sh

# Horizon dashboard
sudo ./33-horizon-install.sh

# Smoke test
sudo ./34-smoke-test.sh
```

## Expected Deployment Time

- **Phase 1** (Base): ~10 minutes
- **Phase 2** (Ceph): ~20 minutes
- **Phase 3** (Core): ~15 minutes
- **Phase 4** (Services): ~30 minutes
- **Phase 5** (Integration): ~10 minutes
- **Total**: ~85 minutes (1.5 hours)

## Post-Deployment Features

### Storage Capabilities
1. **Block Storage (Cinder + RBD)**
   - Persistent volumes for VMs
   - Snapshots and clones
   - Volume migration

2. **Object Storage (RGW)**
   - S3-compatible API
   - Multi-tenant support
   - Bucket management

3. **Shared Filesystem (CephFS)**
   - POSIX-compliant filesystem
   - Multiple clients
   - Snapshots

### Networking Features
1. **Provider Networks**
   - Direct L2 connectivity
   - VLAN support
   - External network access

2. **OVN/OVS SDN**
   - Virtual networks
   - Security groups
   - Floating IPs
   - Load balancing
   - VPN as a Service

### Compute Features
1. **KVM Hypervisor**
   - Hardware virtualization
   - Live migration
   - CPU/memory overcommit

2. **Instance Management**
   - Multiple flavors
   - Custom images
   - Metadata service
   - Console access

## Monitoring & Management

### Access Points
- **Horizon Dashboard**: http://192.168.2.9/horizon
- **Keystone API**: http://192.168.2.9:5000
- **Nova API**: http://192.168.2.9:8774
- **Neutron API**: http://192.168.2.9:9696
- **Glance API**: http://192.168.2.9:9292
- **Cinder API**: http://192.168.2.9:8776

### CLI Access
```bash
source ~/admin-openrc
openstack server list
openstack network list
openstack volume list
ceph status
ceph df
```

## Troubleshooting

### Common Issues
1. **Time Sync**: Ceph requires accurate time - check `chronyc tracking`
2. **Network**: Verify provider network connectivity
3. **Logs**: Check `/var/log/ceph/` and `/var/log/<service>/`
4. **Services**: Use `systemctl status <service>` to check status

### Getting Help
- Debian OpenStack: https://wiki.debian.org/OpenStack
- Ceph Documentation: https://docs.ceph.com/
- OpenStack Docs: https://docs.openstack.org/

## Next Steps

You are now ready to begin deployment! Start with:

```bash
cd ~/git_repos/padmini/ppcs/debian_stack/openstack-scripts
sudo ./01-base-preparation.sh
```

The script will guide you through each step and indicate which script to run next.