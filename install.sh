#!/bin/bash
set -e

echo "Installing ufw-docker-protect (AWS SG style)..."

# 1. Copy CLI tool
if [ ! -f "ufw-docker-protect" ]; then
    echo "Error: ufw-docker-protect script not found in current directory."
    exit 1
fi

cp ufw-docker-protect /usr/local/bin/ufw-docker-protect
chmod +x /usr/local/bin/ufw-docker-protect

# 2. Setup Configuration and State directories
mkdir -p /etc/ufw-docker-protect
mkdir -p /var/lib/ufw-docker-protect/snapshots
mkdir -p /var/log/ufw-docker-protect
touch /var/log/ufw-docker-protect/activity.log

# 3. Copy systemd service
if [ ! -f "ufw-docker-protect.service" ]; then
    echo "Error: ufw-docker-protect.service not found."
    exit 1
fi

cp ufw-docker-protect.service /etc/systemd/system/ufw-docker-protect.service
systemctl daemon-reload

# 4. Trigger Installation Sync
/usr/local/bin/ufw-docker-protect install

echo "Installation complete."
echo "Run 'ufw-docker-protect doctor' to check system health."
echo "Run 'ufw-docker-protect list-rules' to view current allows."
