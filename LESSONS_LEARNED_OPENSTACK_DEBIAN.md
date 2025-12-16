# Lessons Learned: OpenStack Deployment on Debian

## Overview

This document captures all issues encountered during OpenStack Wallaby deployment on Debian 11 Bullseye, categorizing them by root cause and indicating whether they are resolved in Debian 13 Trixie or require configuration fixes in scripts.

---

## Category 1: Package Version Mismatches (Backports vs Main)

### Issue 1.1: Placement API SQLAlchemy Crash

**Symptom:**
```
sqlalchemy.exc.ArgumentError: FROM expression expected
```
VM scheduling fails with Placement API returning HTTP 500.

**Root Cause:**
- Placement 5.0.1 (from bullseye-wallaby-backports) uses SQLAlchemy 1.4+ style: `sa.select()` without `.select_from()`
- Debian Bullseye ships SQLAlchemy 1.3.22 (main) which requires explicit `.select_from()`
- No newer SQLAlchemy available in Bullseye backports

**Fix Applied (Bullseye):**
Downgraded Placement from 5.0.1 (backports) to 4.0.0 (main):
```bash
sudo apt install -y placement-api/bullseye placement-common/bullseye python3-placement/bullseye
```

**Trixie Status:** ✅ FIXED - Native OpenStack Caracal packages are built against SQLAlchemy 2.x (both from same repo).

**Script Requirement (Trixie):** None - use native packages without backports.

---

### Issue 1.2: Nova-Cinder EndpointNotFound

**Symptom:**
```
keystoneauth1.exceptions.catalog.EndpointNotFound: cinder endpoint not found
```
Nova fails to communicate with Cinder for volume operations.

**Root Cause:**
- Empty `[cinder]` section in `/etc/nova/nova.conf`
- Missing `catalog_info`, `os_region_name`, `auth_url`, etc.

**Fix Applied:**
Added complete `[cinder]` section to Nova configuration:
```ini
[cinder]
os_region_name = RegionOne
catalog_info = volumev3:cinderv3:publicURL
```

**Trixie Status:** ⚠️ CONFIGURATION REQUIRED - Still needs explicit configuration, but Trixie's default templates may have better defaults.

**Script Requirement (Trixie):** Always configure `[cinder]` section explicitly in Nova install script.

---

### Issue 1.3: os-brick disconnect_volume() API Mismatch

**Symptom:**
```
TypeError: disconnect_volume() got an unexpected keyword argument 'force'
```
Volume detachment fails.

**Root Cause:**
- Nova 23.2.2 (Wallaby backports) calls `disconnect_volume(force=True)`
- os-brick version in backports doesn't support the `force` parameter

**Trixie Status:** ✅ FIXED - Nova Caracal and os-brick are from same release, APIs match.

**Script Requirement (Trixie):** None.

---

## Category 2: QEMU/libvirt + Ceph RBD Integration

### Issue 2.1: QEMU RBD Encrypted Secrets Bug

**Symptom:**
```
qemu-system-x86_64: -blockdev {"driver":"rbd"...}: error connecting: Invalid argument
```
VM fails to boot when using RBD for ephemeral disks.

**Root Cause:**
- QEMU 5.2.0 + libvirt 7.0.0 bug in how encrypted secrets are passed to RBD driver
- libvirt passes secret via `-object secret,id=...,data=<encrypted>` 
- QEMU 5.2's RBD driver fails to decrypt/use the secret correctly
- Bug was fixed in QEMU 6.x

**Fix Applied (Bullseye):**
Workaround - changed VM disk backend from RBD to local qcow2:
```bash
sudo crudini --set /etc/nova/nova.conf libvirt images_type qcow2
```
This keeps Glance images and Cinder volumes in Ceph but stores VM ephemeral disks locally.

**Trixie Status:** ✅ FIXED - QEMU 9.x/10.x + libvirt 11.x have this bug fixed.

**Script Requirement (Trixie):** Can safely use `images_type = rbd` for full Ceph integration.

---

### Issue 2.2: AppArmor Blocking Ceph Keyring Access

**Symptom:**
```
audit: apparmor="DENIED" operation="open" name="/etc/ceph/ceph.client.cinder.keyring"
```
libvirt/QEMU cannot access Ceph keyring files.

**Root Cause:**
- AppArmor's libvirt-qemu profile doesn't include Ceph keyring paths
- Default profile only allows standard libvirt paths

**Fix Applied:**
Added AppArmor local override:
```bash
cat <<EOF | sudo tee /etc/apparmor.d/local/abstractions/libvirt-qemu
/etc/ceph/** r,
/etc/ceph/ceph.client.*.keyring r,
EOF
sudo systemctl reload apparmor
```

**Trixie Status:** ⚠️ LIKELY STILL NEEDED - AppArmor profiles are distribution-level, may still need customization.

**Script Requirement (Trixie):** Include AppArmor rule addition in Nova-Ceph integration script.

---

### Issue 2.3: Keyring File Permissions (libvirt-qemu user)

**Symptom:**
```
cat: /etc/ceph/ceph.client.cinder.keyring: Permission denied
```
libvirt-qemu user cannot read Ceph keyring.

**Root Cause:**
- Keyring owned by `ceph:cinder` with mode 640
- `libvirt-qemu` user not in `cinder` group
- This is intentional security - principle of least privilege

**Fix Applied:**
```bash
sudo usermod -aG cinder libvirt-qemu
sudo systemctl restart libvirtd
```

**Trixie Status:** ⚠️ STILL NEEDED - This is deployment configuration, not a bug.

**Script Requirement (Trixie):** Add libvirt-qemu to cinder group in Nova-Ceph integration script.

---

## Category 3: Service Configuration Issues

### Issue 3.1: Region Name Inconsistency

**Symptom:**
Various services fail to find endpoints or authenticate.

**Root Cause:**
- Some scripts used `regionOne` (lowercase 'r')
- Others used `RegionOne` (uppercase 'R')
- Keystone is case-sensitive for region names

**Fix Applied:**
Created centralized `openstack-env.sh` sourced by all scripts:
```bash
export OS_REGION_NAME="RegionOne"
```

**Trixie Status:** ⚠️ CONFIGURATION REQUIRED - Same issue will occur without consistent configuration.

**Script Requirement (Trixie):** Always source centralized environment file. Establish region name as `RegionOne` from the start.

---

### Issue 3.2: Database Connection (localhost vs IP)

**Symptom:**
```
OperationalError: (2003, "Can't connect to MySQL server on '192.168.2.9'")
```
Services fail database connection.

**Root Cause:**
- MariaDB configured to listen on localhost/socket only
- Scripts using IP address for connection string
- MariaDB's `skip-networking` or `bind-address = 127.0.0.1` blocks network connections

**Fix Applied:**
Changed all connection strings to use `localhost`:
```ini
connection = mysql+pymysql://service:password@localhost/database
```

**Trixie Status:** ⚠️ CONFIGURATION REQUIRED - Same consideration applies.

**Script Requirement (Trixie):** Use `localhost` for database connections in single-node deployments. For multi-node, configure MariaDB networking explicitly.

---

### Issue 3.3: RabbitMQ User Missing

**Symptom:**
```
AMQP connection refused: user 'openstack' doesn't exist
```
Services fail to connect to message queue.

**Root Cause:**
- RabbitMQ installation script ran but user creation failed silently
- Or user was created with wrong password

**Fix Applied:**
Ensure RabbitMQ user creation in script with verification:
```bash
sudo rabbitmqctl add_user openstack "$RABBIT_PASS" || true
sudo rabbitmqctl set_permissions openstack ".*" ".*" ".*"
# Verify
sudo rabbitmqctl list_users | grep openstack
```

**Trixie Status:** ⚠️ CONFIGURATION REQUIRED

**Script Requirement (Trixie):** 
- Include idempotent RabbitMQ user creation
- Add verification step
- **NEW: Use quorum queues** - OpenStack Caracal requires quorum queues, not classic HA:
```ini
[oslo_messaging_rabbit]
rabbit_quorum_queue = true
```

---

### Issue 3.4: Placement Service Mode (uwsgi vs Apache)

**Symptom:**
Placement configuration expected Apache but Debian package uses uwsgi.

**Root Cause:**
- Debian packages Placement with uwsgi service (port 8778)
- Many guides assume Apache mod_wsgi
- Different configuration approaches

**Observation:**
Debian's uwsgi approach works fine - just configure `/etc/placement/placement.conf` correctly.

**Trixie Status:** ℹ️ INFO ONLY - Be aware of service mode, may vary.

**Script Requirement (Trixie):** Check how Placement is deployed and configure accordingly. Verify with `systemctl status placement-api`.

---

## Category 4: Horizon Dashboard Issues

### Issue 4.1: WEBROOT Configuration Mismatch

**Symptom:**
HTTP 404 for static files, CSS/JS not loading.

**Root Cause:**
- Apache configured with `/horizon` URL prefix
- Horizon `WEBROOT` setting didn't match
- Static files referenced wrong paths

**Fix Applied:**
```python
# /etc/openstack-dashboard/local_settings.py
WEBROOT = '/horizon/'
LOGIN_URL = '/horizon/auth/login/'
LOGOUT_URL = '/horizon/auth/logout/'
LOGIN_REDIRECT_URL = '/horizon/'
```

**Trixie Status:** ⚠️ CONFIGURATION REQUIRED

**Script Requirement (Trixie):** Set WEBROOT and related URLs consistently.

---

### Issue 4.2: COMPRESS_OFFLINE Setting

**Symptom:**
```
TemplateSyntaxError: Invalid block tag 'compress'
```
Horizon throws template errors.

**Root Cause:**
- `COMPRESS_OFFLINE = True` requires pre-compressed assets
- If compression wasn't run, templates fail
- Or Django Compressor not properly configured

**Fix Applied:**
```python
COMPRESS_OFFLINE = False  # For development/testing
# OR run:
# sudo python3 /usr/share/openstack-dashboard/manage.py compress
```

**Trixie Status:** ⚠️ CONFIGURATION REQUIRED

**Script Requirement (Trixie):** Either set `COMPRESS_OFFLINE = False` or run compression command in script.

---

### Issue 4.3: Static Files Permissions

**Symptom:**
HTTP 500 errors, permission denied in logs.

**Root Cause:**
- Apache (www-data) cannot read static files
- Files owned by root or wrong permissions

**Fix Applied:**
```bash
sudo chown -R horizon:horizon /var/lib/openstack-dashboard/static/
sudo chmod -R 755 /var/lib/openstack-dashboard/static/
```

**Trixie Status:** ⚠️ CONFIGURATION REQUIRED

**Script Requirement (Trixie):** Set correct ownership and permissions after collectstatic.

---

## Category 5: Ceph-Specific Issues

### Issue 5.1: Ceph Secret UUID Mismatch

**Symptom:**
Nova and Cinder use different UUIDs for same Ceph secret.

**Root Cause:**
- Multiple scripts each generating their own UUIDs
- No coordination between Nova and Cinder configuration

**Fix Applied:**
Generate UUID once, use everywhere:
```bash
# In openstack-env.sh
export CEPH_SECRET_UUID="9169941e-2765-462a-a60c-893464845005"
```
Use this in both `/etc/nova/nova.conf` and `/etc/cinder/cinder.conf`.

**Trixie Status:** ⚠️ CONFIGURATION REQUIRED

**Script Requirement (Trixie):** Generate Ceph secret UUID in environment file, reference in all scripts.

---

### Issue 5.2: Pool Replication Size for Single Node

**Symptom:**
```
HEALTH_WARN: 1 pg undersized
```
Ceph warns about replication.

**Root Cause:**
- Default replication size is 3
- Single node can't replicate across multiple hosts

**Fix Applied:**
```bash
# For LAB/single-node only
ceph osd pool set volumes size 1
ceph osd pool set images size 1
ceph osd pool set vms size 1
```

**Trixie Status:** ⚠️ CONFIGURATION REQUIRED (lab only)

**Script Requirement (Trixie):** For lab deployments, set appropriate pool size. For production, use size 3 with multiple nodes.

---

## Category 6: Idempotency Issues

### Issue 6.1: Duplicate Configuration Entries

**Symptom:**
Configuration files have duplicate entries causing unpredictable behavior.

**Root Cause:**
- Scripts using `echo >>` to append configuration
- Running script multiple times creates duplicates

**Fix Applied:**
Use `crudini` for all configuration:
```bash
sudo crudini --set /etc/nova/nova.conf libvirt images_type rbd
```

**Trixie Status:** ⚠️ SCRIPT DESIGN REQUIRED

**Script Requirement (Trixie):** Always use crudini or similar idempotent config tools.

---

### Issue 6.2: Resource Creation Without Existence Check

**Symptom:**
Script fails on re-run because resource already exists.

**Root Cause:**
- No check before creating users, endpoints, pools, etc.

**Fix Applied:**
Add existence checks:
```bash
# Check before creating
if ! openstack user show glance &>/dev/null; then
    openstack user create --password "$GLANCE_PASS" glance
fi
```

**Trixie Status:** ⚠️ SCRIPT DESIGN REQUIRED

**Script Requirement (Trixie):** All scripts must be idempotent with existence checks.

---

## Summary: Trixie Script Requirements Checklist

### Automatically Fixed (No action needed):
- [ ] Placement + SQLAlchemy compatibility
- [ ] QEMU/libvirt RBD encrypted secrets bug
- [ ] os-brick API compatibility

### Configuration Required (Add to scripts):
- [ ] `[cinder]` section in nova.conf with explicit settings
- [ ] AppArmor rules for Ceph keyring access
- [ ] Add libvirt-qemu user to cinder group
- [ ] Centralized region name (`RegionOne`)
- [ ] Database connection using `localhost` (single-node) or explicit network config (multi-node)
- [ ] RabbitMQ user creation with verification
- [ ] **Quorum queues for RabbitMQ** (new Caracal requirement)
- [ ] Horizon WEBROOT and related settings
- [ ] Horizon COMPRESS_OFFLINE setting
- [ ] Horizon static files permissions
- [ ] Single Ceph secret UUID used everywhere
- [ ] Appropriate Ceph pool replication size

### Script Design Requirements:
- [ ] Use `crudini` for all configuration changes
- [ ] Include existence checks before resource creation
- [ ] Source centralized environment file
- [ ] Include verification steps at end of each script
- [ ] Use `set -e` for fail-fast behavior

---

## New Considerations for Trixie

### RabbitMQ Quorum Queues
OpenStack Caracal deprecates classic HA (mirrored) queues in favor of quorum queues.
**IMPORTANT**: This applies ONLY to HA deployments with a RabbitMQ cluster (3+ nodes).

For **single-node deployments**: Do NOT enable quorum queues. They require Raft
consensus across multiple RabbitMQ nodes. Enabling on single-node causes services
to fail with "State: down", "Updated At: None", and zombie worker processes.

```ini
# For HA deployments with RabbitMQ cluster ONLY:
[oslo_messaging_rabbit]
rabbit_quorum_queue = true

# For single-node deployments: leave unset (use standard queues)
```

### Ceph Reef (18.x) Changes
- Monitor protocol: msgr2 preferred
- New health warnings format
- OSD deployment may differ slightly

### MariaDB 11.8
- Default authentication may differ
- Check `mysql_native_password` vs `caching_sha2_password`

### Python 3.13
- Some older OpenStack plugins may have compatibility issues
- Test thoroughly

---

## Reference: Version Matrix

| Component | Debian 11 Bullseye | Debian 13 Trixie |
|-----------|-------------------|------------------|
| OpenStack | Wallaby (backports) | Caracal (native) |
| Python | 3.9 | 3.13 |
| SQLAlchemy | 1.3.22 | 2.x |
| QEMU | 5.2 | 9.x/10.x |
| libvirt | 7.0 | 11.x |
| Ceph | Nautilus 14.2 | Reef 18.x |
| MariaDB | 10.5 | 11.8 |
| Kernel | 5.10 | 6.12 |
