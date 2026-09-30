#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Zeek systemd service setup
#
# Usage:
#   sudo ./setup-zeek-service.sh
#
# Or specify interface as argument 2:
#   sudo ./setup-zeek-service.sh anything eno1
#
# Argument 2 = network interface (optional)
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this script with sudo."
    exit 1
fi

SERVICE_NAME="zeek"

ZEEK_PREFIX="/opt/zeek"
ZEEK_BIN="${ZEEK_PREFIX}/bin"
ZEEK="${ZEEK_BIN}/zeek"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="/etc/default/${SERVICE_NAME}"
OFFLOAD_SERVICE="/etc/systemd/system/zeek-disable-offloading.service"

LOG_DIR="${ZEEK_PREFIX}/var/logs/zeek"

# ------------------------------------------------------------
# Determine network interface
# ------------------------------------------------------------

if [[ -n "${2:-}" ]]; then

    INTERFACE="$2"
    echo "[+] Using interface from argument 2: ${INTERFACE}"

else

    echo "[+] No interface supplied. Detecting default Ethernet adapter..."

    INTERFACE=$(
        ip -o route show default 2>/dev/null |
        awk '{print $5; exit}'
    )

    if [[ -z "${INTERFACE:-}" ]]; then
        echo "ERROR: Could not detect default Ethernet adapter."
        echo
        echo "Available interfaces:"
        ip -br link
        exit 1
    fi

    echo "[+] Detected default Ethernet adapter: ${INTERFACE}"

fi

# ------------------------------------------------------------
# Verify interface
# ------------------------------------------------------------

if ! ip link show "${INTERFACE}" >/dev/null 2>&1; then
    echo "ERROR: Interface '${INTERFACE}' does not exist."
    echo
    echo "Available interfaces:"
    ip -br link
    exit 1
fi

# ------------------------------------------------------------
# Check Zeek
# ------------------------------------------------------------

echo "[+] Checking Zeek installation..."

if [[ ! -x "${ZEEK}" ]]; then
    echo "ERROR: Zeek executable not found:"
    echo "  ${ZEEK}"
    exit 1
fi

echo "[+] Zeek version:"
"${ZEEK}" --version

# ------------------------------------------------------------
# Check ethtool
# ------------------------------------------------------------

if ! command -v ethtool >/dev/null 2>&1; then

    echo "[+] ethtool not found. Installing..."

    apt-get update
    apt-get install -y ethtool

fi

# ------------------------------------------------------------
# Create Zeek log directory
# ------------------------------------------------------------

if [[ ! -d "${LOG_DIR}" ]]; then

    echo "[+] Creating ${LOG_DIR}"
    mkdir -p "${LOG_DIR}"

else

    echo "[+] ${LOG_DIR} already exists"

fi

# ------------------------------------------------------------
# Create Zeek configuration if missing
# ------------------------------------------------------------

if [[ ! -f "${CONFIG_FILE}" ]]; then

    echo "[+] Creating ${CONFIG_FILE}"

    cat > "${CONFIG_FILE}" <<EOF
ZEEK_INTERFACE="${INTERFACE}"
ZEEK_PREFIX="${ZEEK_PREFIX}"
EOF

else

    echo "[+] ${CONFIG_FILE} already exists — not overwriting"

fi

# ------------------------------------------------------------
# Create Zeek systemd service if missing
# ------------------------------------------------------------

if [[ ! -f "${SERVICE_FILE}" ]]; then

    echo "[+] Creating ${SERVICE_FILE}"

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Zeek Network Security Monitor
Documentation=https://docs.zeek.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

EnvironmentFile=-${CONFIG_FILE}

ExecStart=${ZEEK} -i \${ZEEK_INTERFACE} local

WorkingDirectory=${LOG_DIR}

Restart=on-failure
RestartSec=5

AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

else

    echo "[+] ${SERVICE_FILE} already exists — not overwriting"

fi

# ------------------------------------------------------------
# Create persistent NIC offloading service if missing
# ------------------------------------------------------------

if [[ ! -f "${OFFLOAD_SERVICE}" ]]; then

    echo "[+] Creating persistent NIC offloading service"

    cat > "${OFFLOAD_SERVICE}" <<EOF
[Unit]
Description=Disable NIC checksum offloading for Zeek IDS
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -K ${INTERFACE} tx off rx off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

else

    echo "[+] ${OFFLOAD_SERVICE} already exists — not overwriting"

fi

# ------------------------------------------------------------
# Reload systemd
# ------------------------------------------------------------

echo "[+] Reloading systemd..."

systemctl daemon-reload

# ------------------------------------------------------------
# Enable NIC offloading service
# ------------------------------------------------------------

echo "[+] Enabling NIC offloading configuration..."

systemctl enable zeek-disable-offloading.service

# ------------------------------------------------------------
# Apply NIC offloading immediately
# ------------------------------------------------------------

echo "[+] Disabling NIC checksum offloading on ${INTERFACE}..."

if ! systemctl start zeek-disable-offloading.service; then

    echo "WARNING: Unable to disable NIC offloading."
    echo "Continuing with Zeek setup..."

fi

# ------------------------------------------------------------
# Show checksum configuration
# ------------------------------------------------------------

echo
echo "[+] Current checksum offloading settings:"

ethtool -k "${INTERFACE}" 2>/dev/null |
    grep -E 'checksum|scatter-gather' || true

# ------------------------------------------------------------
# Enable Zeek
# ------------------------------------------------------------

echo
echo "[+] Enabling ${SERVICE_NAME}.service..."

systemctl enable "${SERVICE_NAME}.service"

# ------------------------------------------------------------
# Start Zeek
# ------------------------------------------------------------

echo "[+] Starting ${SERVICE_NAME}.service..."

systemctl restart "${SERVICE_NAME}.service"

sleep 2

# ------------------------------------------------------------
# Verify Zeek
# ------------------------------------------------------------

if systemctl is-active --quiet "${SERVICE_NAME}.service"; then

    echo
    echo "============================================================"
    echo " Zeek is running"
    echo "============================================================"
    echo
    echo "Interface: ${INTERFACE}"
    echo "Service:   ${SERVICE_NAME}.service"
    echo
    systemctl --no-pager --full status "${SERVICE_NAME}.service"

else

    echo
    echo "============================================================"
    echo " ERROR: Zeek failed to start"
    echo "============================================================"
    echo

    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true

    echo
    echo "Recent Zeek journal:"
    journalctl -u "${SERVICE_NAME}.service" --no-pager -n 50

    exit 1

fi

# ------------------------------------------------------------
# Finished
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Setup complete"
echo "============================================================"
echo
echo "Zeek:"
echo "  sudo systemctl status zeek"
echo
echo "Zeek logs:"
echo "  sudo journalctl -u zeek -f"
echo
echo "NIC offloading:"
echo "  sudo systemctl status zeek-disable-offloading"
echo
echo "Verify NIC:"
echo "  sudo ethtool -k ${INTERFACE}"
echo
echo "Zeek log directory:"
echo "  ${LOG_DIR}"
echo

