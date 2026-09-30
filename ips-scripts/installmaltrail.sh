#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Maltrail unattended installer
# Ubuntu 24.04
# ============================================================

export DEBIAN_FRONTEND=noninteractive

MALTRAIL_INSTALLER_URL="https://raw.githubusercontent.com/stamparm/maltrail/master/install.sh"
INSTALLER="/tmp/maltrail-install.sh"

log() {
    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    fail "Run this script as root: sudo $0"
fi

# ------------------------------------------------------------
# Verify Ubuntu
# ------------------------------------------------------------

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    fail "This script requires Ubuntu."
fi

if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    log "WARNING: This script was designed for Ubuntu 24.04."
    log "Detected: ${PRETTY_NAME:-unknown}"
fi

log "Installing prerequisites..."

# ------------------------------------------------------------
# Packages
# ------------------------------------------------------------

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    git \
    python3 \
    python3-pip \
    libpcap-dev

# ------------------------------------------------------------
# Download official Maltrail installer
# ------------------------------------------------------------

log "Downloading Maltrail installer..."

curl -fsSL \
    "${MALTRAIL_INSTALLER_URL}" \
    -o "${INSTALLER}"

chmod 700 "${INSTALLER}"

# ------------------------------------------------------------
# Run official installer
# ------------------------------------------------------------

log "Running Maltrail installer..."

bash "${INSTALLER}"

# ------------------------------------------------------------
# Reload systemd
# ------------------------------------------------------------

log "Reloading systemd..."

systemctl daemon-reload

# ------------------------------------------------------------
# Enable services
# ------------------------------------------------------------

log "Enabling Maltrail services..."

systemctl enable maltrail-sensor.service 2>/dev/null || true
systemctl enable maltrail-server.service 2>/dev/null || true

# ------------------------------------------------------------
# Start services
# ------------------------------------------------------------

log "Starting Maltrail services..."

systemctl restart maltrail-server.service 2>/dev/null || true
systemctl restart maltrail-sensor.service 2>/dev/null || true

# ------------------------------------------------------------
# Give services a moment to start
# ------------------------------------------------------------

sleep 3

# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

log "Checking Maltrail services..."

SENSOR_STATUS="inactive"
SERVER_STATUS="inactive"

if systemctl is-active --quiet maltrail-sensor.service; then
    SENSOR_STATUS="active"
fi

if systemctl is-active --quiet maltrail-server.service; then
    SERVER_STATUS="active"
fi

echo
echo "============================================================"
echo " Maltrail installation complete"
echo "============================================================"
echo
echo "Sensor : ${SENSOR_STATUS}"
echo "Server : ${SERVER_STATUS}"
echo

# ------------------------------------------------------------
# Display useful information
# ------------------------------------------------------------

if command -v ip >/dev/null 2>&1; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
else
    SERVER_IP="<SERVER-IP>"
fi

echo "Web interface:"
echo "  http://${SERVER_IP}:8338/"
echo
echo "Sensor status:"
echo "  systemctl status maltrail-sensor"
echo
echo "Server status:"
echo "  systemctl status maltrail-server"
echo
echo "Sensor logs:"
echo "  journalctl -u maltrail-sensor -f"
echo
echo "Server logs:"
echo "  journalctl -u maltrail-server -f"
echo

# ------------------------------------------------------------
# Fail installation if services did not start
# ------------------------------------------------------------

if [[ "${SENSOR_STATUS}" != "active" || "${SERVER_STATUS}" != "active" ]]; then
    echo "WARNING: One or more Maltrail services are not running."
    echo
    echo "Recent sensor log:"
    journalctl -u maltrail-sensor --no-pager -n 20 2>/dev/null || true
    echo
    echo "Recent server log:"
    journalctl -u maltrail-server --no-pager -n 20 2>/dev/null || true
    exit 1
fi

echo "Maltrail is running successfully."

