#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing ClamAV..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    clamav \
    clamav-daemon

echo "==> Stopping freshclam temporarily..."
sudo systemctl stop clamav-freshclam.service 2>/dev/null || true

echo "==> Updating ClamAV virus database..."
sudo freshclam

echo "==> Enabling ClamAV services..."
sudo systemctl enable clamav-daemon.service
sudo systemctl enable clamav-freshclam.service

echo "==> Starting ClamAV services..."
sudo systemctl start clamav-daemon.service
sudo systemctl start clamav-freshclam.service

echo "==> Verifying services..."
sudo systemctl --no-pager --full status clamav-daemon.service
sudo systemctl --no-pager --full status clamav-freshclam.service

echo
echo "==> ClamAV version:"
clamscan --version

echo
echo "==> ClamAV installation complete."

