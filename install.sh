#!/bin/bash
set -e

echo "Installing ufw-docker-protect (AWS SG style)..."

# 1. Setup Python Virtual Environment for Dependencies
echo "Constructing native Virtual Environment avoiding system conflicts..."
mkdir -p /opt/ufw-docker-protect
apt-get update && apt-get install -y python3-venv || true
python3 -m venv /opt/ufw-docker-protect/venv
/opt/ufw-docker-protect/venv/bin/pip install rich prompt_toolkit

# 2. Deploy Script
echo "Deploying script with venv bindings..."
sed 's|^#!/usr/bin/env python3|#!/opt/ufw-docker-protect/venv/bin/python3|' ufw-docker-protect > /usr/local/bin/ufw-docker-protect
chmod +x /usr/local/bin/ufw-docker-protect

# 3. Setup Configuration and State directories
mkdir -p /etc/ufw-docker-protect
mkdir -p /var/lib/ufw-docker-protect/snapshots
mkdir -p /var/log/ufw-docker-protect
touch /var/log/ufw-docker-protect/activity.log

# 4. Setup Systemd Service
if [ ! -f "ufw-docker-protect.service" ]; then
    echo "ufw-docker-protect.service not found in the current directory."
    exit 1
fi
cp ufw-docker-protect.service /etc/systemd/system/ufw-docker-protect.service
systemctl daemon-reload

# 5. Initialize Configurations
echo "Initializing structural configurations..."

# 6. Trigger Installation Sync
/usr/local/bin/ufw-docker-protect install

echo "Installation complete."
echo "Run 'ufw-docker-protect doctor' to check system health."
echo "Run 'ufw-docker-protect' directly for the Interactive TUI Console."
