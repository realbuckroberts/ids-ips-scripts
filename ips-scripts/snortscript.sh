#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo."
  exit 1
fi

echo "=== Step 1: Installing Snort ==="
apt update && apt install snort -y

echo "=== Step 2: Auto-Detecting Network Interface ==="
# Finds the first active, non-loopback network interface
INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -n1)

if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -br link show | grep -v LO | awk '$2=="UP" {print $1}' | head -n1)
fi

if [ -z "$INTERFACE" ]; then
    echo "Could not auto-detect your network interface. Please configure manually."
    exit 1
fi
echo "Detected Active Interface: $INTERFACE"

echo "=== Step 3: Configuring Snort ==="
# Get the local subnet range
SUBNET=$(ip -o -f inet addr show dev "$INTERFACE" | awk '{print $4}' | head -n1)
echo "Detected Local Subnet: $SUBNET"

# Create a clean, basic snort.conf directory if it doesn't exist
mkdir -p /etc/snort/rules
touch /etc/snort/rules/local.rules

# Back up original configuration
if [ -f /etc/snort/snort.conf ]; then
    cp /etc/snort/snort.conf /etc/snort/snort.conf.bak
fi

# Write minimal configuration file
cat << EOF > /etc/snort/snort.conf
# Auto-generated basic Snort configuration
ipvar HOME_NET $SUBNET
ipvar EXTERNAL_NET !\$HOME_NET

var RULE_PATH /etc/snort/rules

# Configure the output log
output alert_fast: stdout

# Include local rules
include \$RULE_PATH/local.rules
EOF

echo "=== Step 4: Creating a Test Rule ==="
# Add a simple rule to detect ICMP (ping) traffic
echo 'alert icmp any any -> $HOME_NET any (msg:"ICMP Ping Detected"; sid:1000001; rev:1;)' > /etc/snort/rules/local.rules

echo "=== Step 5: Creating systemd Service ==="
cat << EOF > /etc/systemd/system/snort.service
[Unit]
Description=Snort IDS Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/snort -q -A fast -i $INTERFACE -c /etc/snort/snort.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "=== Step 6: Starting and Enabling Snort Service ==="
systemctl daemon-reload
systemctl enable snort
systemctl restart snort

echo "=================================================="
echo "Snort setup complete and running as a service!"
echo "Interface: $INTERFACE"
echo "Subnet: $SUBNET"
echo "You can check status using: sudo systemctl status snort"
echo "You can view real-time logs using: sudo journalctl -u snort -f"
echo "=================================================="

