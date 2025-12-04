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
