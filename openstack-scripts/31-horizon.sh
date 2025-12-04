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
