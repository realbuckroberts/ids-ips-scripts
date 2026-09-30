#!/bin/bash

# Ensure the script is run with sudo/root privileges
if [ "$EUID" -ne 0 ]; then
  echo "❌ Error: Please run this script with sudo."
  exit 1
fi

echo "🔍 Checking for active apt or dpkg processes..."
# Find PIDs holding the locks
PIDS=$(lsof -t /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null)

if [ -not -z "$PIDS" ]; then
    echo "⚠️ Found active processes holding the lock: $PIDS"
    echo "🛑 Terminating stuck package manager processes..."
    kill -9 $PIDS
    sleep 2
else
    echo "✅ No active package manager processes found."
fi

echo "🧹 Removing stale lock files..."
rm -f /var/lib/dpkg/lock
rm -f /var/lib/dpkg/lock-frontend
rm -f /var/cache/apt/archives/lock
rm -f /var/lib/apt/lists/lock

echo "🛠️ Repairing interrupted package installations..."
dpkg --configure -a
apt-get install -f -y

echo "🔄 Updating package lists to verify fix..."
apt-get update

echo "🎉 Done! Your package manager should now be unfucked."

