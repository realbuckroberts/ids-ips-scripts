#!/usr/bin/env bash
#
# Non-interactive OSSEC HIDS installer
# Ubuntu 24.04
#
# Local installation using OSSEC defaults.
# Installs and manages OSSEC through systemd.
#

set -Eeuo pipefail

OSSEC_VERSION="4.3.0"
OSSEC_DIR="/var/ossec"
BUILD_DIR="$(mktemp -d /tmp/ossec-build.XXXXXXXX)"
SERVICE_FILE="/etc/systemd/system/ossec.service"

cleanup() {
    rm -rf "${BUILD_DIR}"
}
trap cleanup EXIT

log() {
    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Root / OS checks
# ---------------------------------------------------------------------------

[[ "${EUID}" -eq 0 ]] ||
    die "Run this script as root."

[[ -f /etc/os-release ]] ||
    die "Cannot determine operating system."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID}" == "ubuntu" ]] ||
    die "This script requires Ubuntu."

[[ "${VERSION_ID}" == "24.04" ]] ||
    die "This script requires Ubuntu 24.04."

log "Ubuntu ${VERSION_ID} detected."

# ---------------------------------------------------------------------------
# Install build dependencies
#
# IMPORTANT:
# libmagic-dev provides /usr/lib/.../libmagic.so, which is required by
# OSSEC's ossec-maild linker:
#
#     /usr/bin/ld: cannot find -lmagic
#
# The 'file' package provides the associated libmagic runtime/tooling.
# ---------------------------------------------------------------------------

log "Updating APT package lists..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

log "Installing OSSEC build dependencies..."

apt-get install -y \
    build-essential \
    ca-certificates \
    curl \
    file \
    gcc \
    g++ \
    libevent-dev \
    libmagic-dev \
    libpcre2-dev \
    libssl-dev \
    libsystemd-dev \
    pkg-config \
    tar \
    zlib1g-dev

# ---------------------------------------------------------------------------
# Verify libmagic before compiling OSSEC
# ---------------------------------------------------------------------------

log "Verifying libmagic development library..."

dpkg -s libmagic-dev >/dev/null 2>&1 ||
    die "libmagic-dev was not installed correctly."

MAGIC_LIB="$(find /usr/lib /lib \
    -type f \
    \( -name 'libmagic.so' -o -name 'libmagic.so.*' \) \
    2>/dev/null | head -n 1)"

[[ -n "${MAGIC_LIB}" ]] ||
    die "libmagic library was not found after installing libmagic-dev."

log "libmagic found: ${MAGIC_LIB}"

if ! ldconfig -p 2>/dev/null | grep -q 'libmagic\.so'; then
    log "Refreshing dynamic linker cache..."
    ldconfig
fi

# ---------------------------------------------------------------------------
# Download OSSEC
# ---------------------------------------------------------------------------

cd "${BUILD_DIR}"

OSSEC_URL="https://github.com/ossec/ossec-hids/archive/refs/tags/${OSSEC_VERSION}.tar.gz"

log "Downloading OSSEC ${OSSEC_VERSION}..."

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --output ossec.tar.gz \
    "${OSSEC_URL}"

[[ -s ossec.tar.gz ]] ||
    die "OSSEC download failed."

log "Extracting OSSEC..."

tar -xzf ossec.tar.gz

SOURCE_DIR="${BUILD_DIR}/ossec-hids-${OSSEC_VERSION}"

[[ -d "${SOURCE_DIR}" ]] ||
    die "OSSEC source directory was not found."

cd "${SOURCE_DIR}"

# ---------------------------------------------------------------------------
# Configure non-interactive installation
# ---------------------------------------------------------------------------

log "Creating OSSEC preloaded configuration..."

cat > etc/preloaded-vars.conf <<EOF
USER_LANGUAGE="en"
USER_INSTALL_TYPE="local"
USER_DIR="${OSSEC_DIR}"
EOF

chmod 0644 etc/preloaded-vars.conf

# ---------------------------------------------------------------------------
# Build and install OSSEC
# ---------------------------------------------------------------------------

log "Building and installing OSSEC..."

PCRE2_SYSTEM=yes ./install.sh

# ---------------------------------------------------------------------------
# Verify installation
# ---------------------------------------------------------------------------

[[ -x "${OSSEC_DIR}/bin/ossec-control" ]] ||
    die "OSSEC installation failed: ossec-control was not created."

log "OSSEC installed successfully."

# ---------------------------------------------------------------------------
# Create systemd service
# ---------------------------------------------------------------------------

log "Creating systemd service..."

cat > "${SERVICE_FILE}" <<'EOF'
[Unit]
Description=OSSEC Host-based Intrusion Detection System
Documentation=https://www.ossec.net/docs/
After=network-online.target
Wants=network-online.target

StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=forking

ExecStart=/var/ossec/bin/ossec-control start
ExecStop=/var/ossec/bin/ossec-control stop
ExecReload=/var/ossec/bin/ossec-control restart

TimeoutStartSec=120
TimeoutStopSec=120

Restart=on-failure
RestartSec=10

StandardOutput=journal
StandardError=journal

SyslogIdentifier=ossec

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "${SERVICE_FILE}"

# ---------------------------------------------------------------------------
# Configure systemd
# ---------------------------------------------------------------------------

log "Reloading systemd..."

systemctl daemon-reload

log "Enabling OSSEC at boot..."

systemctl enable ossec.service

# ---------------------------------------------------------------------------
# Start OSSEC
# ---------------------------------------------------------------------------

log "Starting OSSEC..."

systemctl restart ossec.service

sleep 5

# ---------------------------------------------------------------------------
# Verify service
# ---------------------------------------------------------------------------

if ! systemctl is-active --quiet ossec.service; then

    log "OSSEC failed to start."

    echo
    echo "========== SYSTEMD STATUS =========="

    systemctl --no-pager --full status ossec.service || true

    echo
    echo "========== JOURNAL =========="

    journalctl \
        -u ossec.service \
        --no-pager \
        -n 100 || true

    echo
    echo "========== OSSEC LOG =========="

    tail -n 100 \
        "${OSSEC_DIR}/logs/ossec.log" \
        2>/dev/null || true

    exit 1
fi

# ---------------------------------------------------------------------------
# Verify OSSEC processes
# ---------------------------------------------------------------------------

log "Checking OSSEC process status..."

"${OSSEC_DIR}/bin/ossec-control" status

# ---------------------------------------------------------------------------
# Final information
# ---------------------------------------------------------------------------

echo
echo "=========================================================="
echo " OSSEC installation successful"
echo "=========================================================="
echo
echo "OSSEC directory:"
echo "  ${OSSEC_DIR}"
echo
echo "Systemd:"
echo "  systemctl status ossec"
echo "  systemctl restart ossec"
echo "  systemctl stop ossec"
echo "  systemctl enable ossec"
echo
echo "Systemd logs:"
echo "  journalctl -u ossec"
echo "  journalctl -u ossec -f"
echo "  journalctl -u ossec --since today"
echo
echo "OSSEC logs:"
echo "  ${OSSEC_DIR}/logs/ossec.log"
echo "  ${OSSEC_DIR}/logs/alerts/alerts.log"
echo
echo "OSSEC processes:"
echo "  ${OSSEC_DIR}/bin/ossec-control status"
echo
echo "=========================================================="
