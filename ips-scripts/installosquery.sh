#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# FULLY UNATTENDED OSQUERY INSTALLER
#
# Target:
#   Ubuntu 24.04
#
# Installs:
#   osquery 5.23.1
#   osqueryd
#   osqueryi
#   All official query packs included with the release
#
# Configures:
#   systemd
#   scheduled security/visibility queries
#   official osquery packs
#   filesystem logging
#   persistent osquery database
#
# No interactive input required.
# ============================================================

export DEBIAN_FRONTEND=noninteractive

OSQUERY_VERSION="5.23.1"

BASE_DIR="/opt/osquery"
DOWNLOAD_DIR="/tmp/osquery-install"
CONFIG_DIR="/etc/osquery"
CONFIG_FILE="${CONFIG_DIR}/osquery.conf"
PACK_DIR="${CONFIG_DIR}/packs"
LOG_DIR="/var/log/osquery"
DB_DIR="/var/osquery"

SERVICE_FILE="/etc/systemd/system/osqueryd.service"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

log() {
    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo
    echo "============================================================"
    echo " ERROR"
    echo "============================================================"
    echo "$*" >&2
    echo
    exit 1
}

# ------------------------------------------------------------
# Error handler
# ------------------------------------------------------------

error_handler() {
    local line="${1:-unknown}"

    echo
    echo "============================================================"
    echo " INSTALLATION FAILED"
    echo "============================================================"
    echo "Line: ${line}"
    echo

    if systemctl list-unit-files 2>/dev/null |
        grep -q '^osqueryd.service'; then

        systemctl --no-pager --full status osqueryd.service || true

        echo
        echo "Recent osquery logs:"
        journalctl -u osqueryd.service \
            --no-pager \
            -n 100 || true
    fi

    exit 1
}

trap 'error_handler $LINENO' ERR

# ------------------------------------------------------------
# Root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo or as root."
fi

# ------------------------------------------------------------
# Ubuntu detection
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found."
fi

# shellcheck source=/dev/null
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This installer requires Ubuntu."
fi

if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    log "WARNING: This script was written for Ubuntu 24.04."
    log "Detected: ${PRETTY_NAME:-unknown}"
fi

# ------------------------------------------------------------
# Architecture
# ------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"

case "${ARCH}" in

    amd64)
        OSQUERY_ARCH="x86_64"
        OSQUERY_SHA256="0f37a478a1dbda24b67c81551e32d734b392c5a2f5deb156bf1c41ca204cfa67"
        ;;

    arm64)
        OSQUERY_ARCH="aarch64"
        OSQUERY_SHA256="9ae763820166f75f19970b5147b1930a308865a923ab127f4b8bbaea7b69962a"
        ;;

    *)
        die "Unsupported CPU architecture: ${ARCH}"
        ;;
esac

TARBALL="osquery-${OSQUERY_VERSION}_1.linux_${OSQUERY_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/osquery/osquery/releases/download/${OSQUERY_VERSION}/${TARBALL}"

log "Operating system : ${PRETTY_NAME}"
log "Architecture     : ${ARCH}"
log "osquery version  : ${OSQUERY_VERSION}"

# ------------------------------------------------------------
# Install dependencies
# ------------------------------------------------------------

log "Installing required dependencies..."

apt-get update -qq

apt-get install -y -qq \
    ca-certificates \
    curl \
    tar \
    gzip \
    coreutils \
    systemd \
    procps \
    jq

# ------------------------------------------------------------
# Stop an existing osquery installation
# ------------------------------------------------------------

log "Stopping any existing osquery service..."

systemctl stop osqueryd.service 2>/dev/null || true
systemctl disable osqueryd.service 2>/dev/null || true

# ------------------------------------------------------------
# Prepare directories
# ------------------------------------------------------------

log "Preparing directories..."

rm -rf "${DOWNLOAD_DIR}"

mkdir -p "${DOWNLOAD_DIR}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${PACK_DIR}"
mkdir -p "${LOG_DIR}"
mkdir -p "${DB_DIR}"

chmod 0755 "${CONFIG_DIR}"
chmod 0755 "${PACK_DIR}"
chmod 0755 "${LOG_DIR}"
chmod 0755 "${DB_DIR}"

# ------------------------------------------------------------
# Download official release
# ------------------------------------------------------------

TARBALL_PATH="${DOWNLOAD_DIR}/${TARBALL}"

log "Downloading official osquery ${OSQUERY_VERSION}..."

curl \
    --fail \
    --location \
    --show-error \
    --silent \
    --retry 5 \
    --retry-delay 3 \
    "${DOWNLOAD_URL}" \
    -o "${TARBALL_PATH}"

[[ -s "${TARBALL_PATH}" ]] ||
    die "osquery download failed."

# ------------------------------------------------------------
# Verify SHA256
# ------------------------------------------------------------

log "Verifying SHA-256 checksum..."

echo "${OSQUERY_SHA256}  ${TARBALL_PATH}" |
    sha256sum --check --strict -

log "Checksum verified."

# ------------------------------------------------------------
# Extract release
# Official layout:
#   opt/osquery/bin/osqueryd
#   opt/osquery/share/osquery/packs/*.conf
# ------------------------------------------------------------

EXTRACT_DIR="${DOWNLOAD_DIR}/extracted"

rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"

log "Extracting osquery..."

tar -xzf "${TARBALL_PATH}" -C "${EXTRACT_DIR}"

# ------------------------------------------------------------
# Locate binaries
# ------------------------------------------------------------

log "Locating osquery binaries..."

OSQUERYD_SOURCE="${EXTRACT_DIR}/opt/osquery/bin/osqueryd"

if [[ ! -f "${OSQUERYD_SOURCE}" ]]; then
    OSQUERYD_SOURCE="$(
        find "${EXTRACT_DIR}" -type f -name osqueryd -print -quit 2>/dev/null || true
    )"
fi

[[ -n "${OSQUERYD_SOURCE}" && -f "${OSQUERYD_SOURCE}" ]] ||
    die "osqueryd was not found inside the official release."

log "osqueryd source: ${OSQUERYD_SOURCE}"

# ------------------------------------------------------------
# Install osquery
# ------------------------------------------------------------

log "Installing osquery into ${BASE_DIR}..."

rm -rf "${BASE_DIR}"
mkdir -p "${BASE_DIR}"

if [[ -d "${EXTRACT_DIR}/opt/osquery" ]]; then
    cp -a "${EXTRACT_DIR}/opt/osquery/." "${BASE_DIR}/"
else
    cp -a "${EXTRACT_DIR}/." "${BASE_DIR}/"
fi

# ------------------------------------------------------------
# Locate installed binaries
# ------------------------------------------------------------

OSQUERYD="${BASE_DIR}/bin/osqueryd"
OSQUERYI="${BASE_DIR}/bin/osqueryi"

[[ -f "${OSQUERYD}" ]] ||
    die "Installed osqueryd could not be located at ${OSQUERYD}."

chown root:root "${OSQUERYD}"
chmod 0755 "${OSQUERYD}"

# osqueryi is the same binary; create the conventional symlink
ln -sfn "${OSQUERYD}" "${OSQUERYI}"
chmod 0755 "${OSQUERYI}"

log "Installed osqueryd: ${OSQUERYD}"
log "Installed osqueryi: ${OSQUERYI}"

# ------------------------------------------------------------
# Convenience symlinks
# ------------------------------------------------------------

ln -sfn "${OSQUERYD}" /usr/local/bin/osqueryd
ln -sfn "${OSQUERYI}" /usr/local/bin/osqueryi

# ------------------------------------------------------------
# Locate official packs
# ------------------------------------------------------------

log "Locating official osquery query packs..."

OFFICIAL_PACK_DIR="${BASE_DIR}/share/osquery/packs"

if [[ ! -d "${OFFICIAL_PACK_DIR}" ]]; then
    OFFICIAL_PACK_DIR="$(
        find "${BASE_DIR}" \
            -type d \
            \( -path "*/packs" -o -path "*/share/osquery/packs" \) \
            -print -quit 2>/dev/null || true
    )"
fi

[[ -n "${OFFICIAL_PACK_DIR}" && -d "${OFFICIAL_PACK_DIR}" ]] ||
    die "Could not locate official osquery query packs."

log "Official pack directory: ${OFFICIAL_PACK_DIR}"

# ------------------------------------------------------------
# Install ALL official packs
# ------------------------------------------------------------

log "Installing all official query packs..."

find "${PACK_DIR}" \
    -maxdepth 1 \
    -type f \
    \( -name "*.conf" -o -name "*.json" \) \
    -delete 2>/dev/null || true

find "${OFFICIAL_PACK_DIR}" \
    -maxdepth 1 \
    -type f \
    \( -name "*.conf" -o -name "*.json" \) \
    -exec cp -f {} "${PACK_DIR}/" \;

chmod 0644 "${PACK_DIR}"/* 2>/dev/null || true

PACK_COUNT="$(
    find "${PACK_DIR}" \
        -maxdepth 1 \
        -type f \
        \( -name "*.conf" -o -name "*.json" \) |
    wc -l
)"

[[ "${PACK_COUNT}" -gt 0 ]] ||
    die "No official query packs were installed."

log "Installed ${PACK_COUNT} official query-pack files."

# ------------------------------------------------------------
# Back up existing configuration
# ------------------------------------------------------------

if [[ -f "${CONFIG_FILE}" ]]; then
    BACKUP="${CONFIG_FILE}.backup.$(date '+%Y%m%d%H%M%S')"
    log "Backing up existing osquery configuration: ${BACKUP}"
    cp -a "${CONFIG_FILE}" "${BACKUP}"
fi

# ------------------------------------------------------------
# Create osquery configuration
# ------------------------------------------------------------

log "Creating osquery configuration..."

cat > "${CONFIG_FILE}" <<'EOF'
{
  "options": {
    "config_plugin": "filesystem",
    "logger_plugin": "filesystem",
    "logger_path": "/var/log/osquery",
    "database_path": "/var/osquery/osquery.db",
    "host_identifier": "hostname",
    "schedule_splay_percent": 10,
    "schedule_default_interval": 3600,
    "pack_refresh_interval": 3600,
    "events_expiry": 3600,
    "disable_events": false
  },
  "schedule": {
    "system_info": {
      "query": "SELECT hostname, cpu_brand, physical_memory FROM system_info;",
      "interval": 3600
    },
    "logged_in_users": {
      "query": "SELECT * FROM logged_in_users;",
      "interval": 900
    },
    "running_processes": {
      "query": "SELECT pid, name, path, cmdline, uid FROM processes;",
      "interval": 300
    },
    "listening_ports": {
      "query": "SELECT * FROM listening_ports;",
      "interval": 300
    },
    "installed_packages": {
      "query": "SELECT name, version, source, arch, status FROM deb_packages;",
      "interval": 3600
    },
    "kernel_modules": {
      "query": "SELECT name, size, status FROM kernel_modules;",
      "interval": 3600
    },
    "users": {
      "query": "SELECT uid, gid, username, description, directory, shell FROM users;",
      "interval": 3600
    },
    "sudoers": {
      "query": "SELECT * FROM sudoers;",
      "interval": 3600
    },
    "startup_items": {
      "query": "SELECT * FROM startup_items;",
      "interval": 3600
    },
    "process_open_sockets": {
      "query": "SELECT DISTINCT p.pid, p.name, p.path, p.cmdline, s.local_address, s.local_port, s.remote_address, s.remote_port FROM processes p JOIN process_open_sockets s ON p.pid = s.pid;",
      "interval": 600
    },
    "mounts": {
      "query": "SELECT * FROM mounts;",
      "interval": 3600
    },
    "crontab": {
      "query": "SELECT * FROM crontab;",
      "interval": 3600
    },
    "etc_hosts": {
      "query": "SELECT * FROM etc_hosts;",
      "interval": 3600
    },
    "apt_sources": {
      "query": "SELECT * FROM apt_sources;",
      "interval": 3600
    },
    "ssh_keys": {
      "query": "SELECT * FROM users CROSS JOIN user_ssh_keys USING (uid);",
      "interval": 3600
    },
    "kernel_info": {
      "query": "SELECT * FROM kernel_info;",
      "interval": 3600
    },
    "os_version": {
      "query": "SELECT * FROM os_version;",
      "interval": 3600
    },
    "usb_devices": {
      "query": "SELECT * FROM usb_devices;",
      "interval": 3600
    },
    "arp_cache": {
      "query": "SELECT * FROM arp_cache;",
      "interval": 600
    },
    "interface_addresses": {
      "query": "SELECT * FROM interface_addresses;",
      "interval": 600
    }
  },
  "packs": {
    "official": "/etc/osquery/packs/*"
  }
}
EOF

chmod 0644 "${CONFIG_FILE}"

# ------------------------------------------------------------
# Validate JSON (main config)
# ------------------------------------------------------------

log "Validating configuration syntax..."
jq empty "${CONFIG_FILE}"

# ------------------------------------------------------------
# Validate with osquery itself
# ------------------------------------------------------------

log "Validating configuration with osquery..."

"${OSQUERYI}" \
    --config_path="${CONFIG_FILE}" \
    --config_check

log "osquery configuration validated successfully."

# ------------------------------------------------------------
# Verify packs individually (best-effort only)
#
# Some official packs (e.g. osx-attacks.conf) intentionally use
# multi-line query strings with \ continuations.  osquery accepts
# them; strict jq does not.  Never fail the install for this.
# ------------------------------------------------------------

log "Checking official packs (best-effort)..."

PACK_WARNINGS=0

while IFS= read -r pack; do
    if ! jq empty "${pack}" >/dev/null 2>&1; then
        echo "WARNING: pack is not strict JSON (osquery still accepts it): ${pack}"
        PACK_WARNINGS=$((PACK_WARNINGS + 1))
    fi
done < <(
    find "${PACK_DIR}" \
        -maxdepth 1 \
        -type f \
        \( -name "*.conf" -o -name "*.json" \)
)

if [[ "${PACK_WARNINGS}" -gt 0 ]]; then
    log "Note: ${PACK_WARNINGS} pack(s) are not strict JSON. This is normal for some official packs."
fi

# ------------------------------------------------------------
# Create systemd service
# ------------------------------------------------------------

log "Installing systemd service..."

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=osquery - Operating System Instrumentation
Documentation=https://osquery.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${OSQUERYD} --config_path=${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=4096
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=false
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "${SERVICE_FILE}"

# ------------------------------------------------------------
# systemd reload
# ------------------------------------------------------------

log "Reloading systemd..."
systemctl daemon-reload

# ------------------------------------------------------------
# Enable service
# ------------------------------------------------------------

log "Enabling osqueryd at boot..."
systemctl enable osqueryd.service

# ------------------------------------------------------------
# Start service
# ------------------------------------------------------------

log "Starting osqueryd..."
systemctl restart osqueryd.service

# ------------------------------------------------------------
# Wait for daemon
# ------------------------------------------------------------

log "Waiting for osqueryd..."

for i in {1..20}; do
    if systemctl is-active --quiet osqueryd.service; then
        break
    fi
    sleep 1
done

# ------------------------------------------------------------
# Verify daemon
# ------------------------------------------------------------

if ! systemctl is-active --quiet osqueryd.service; then
    echo
    echo "============================================================"
    echo " osqueryd FAILED TO START"
    echo "============================================================"
    systemctl --no-pager --full status osqueryd.service || true
    echo
    echo "Recent osquery logs:"
    journalctl -u osqueryd.service --no-pager -n 100 || true
    exit 1
fi

# ------------------------------------------------------------
# Verify process
# ------------------------------------------------------------

if ! pgrep -f "${OSQUERYD}" >/dev/null 2>&1; then
    die "systemd reports osqueryd active, but the process was not found."
fi

# ------------------------------------------------------------
# Verify enabled state
# ------------------------------------------------------------

if ! systemctl is-enabled --quiet osqueryd.service; then
    die "osqueryd service is not enabled."
fi

# ------------------------------------------------------------
# Verify osquery database directory
# ------------------------------------------------------------

if [[ ! -d "${DB_DIR}" ]]; then
    die "osquery database directory was not created."
fi

# ------------------------------------------------------------
# Record installation information
# ------------------------------------------------------------

"${OSQUERYI}" --version > "${CONFIG_DIR}/installed-version.txt" 2>&1 || true
date -Is > "${CONFIG_DIR}/installed-at.txt"

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

rm -rf "${DOWNLOAD_DIR}"

# ------------------------------------------------------------
# Final status
# ------------------------------------------------------------

echo
echo "============================================================"
echo "             OSQUERY INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Version:"
cat "${CONFIG_DIR}/installed-version.txt" 2>/dev/null || true
echo
echo "Architecture:"
echo "  ${ARCH}"
echo
echo "osqueryd:"
echo "  ${OSQUERYD}"
echo
echo "osqueryi:"
echo "  ${OSQUERYI}"
echo
echo "Service:"
echo "  Status : ACTIVE"
echo "  Boot   : ENABLED"
echo
echo "Configuration:"
echo "  ${CONFIG_FILE}"
echo
echo "Official query packs:"
echo "  ${PACK_COUNT}"
echo
echo "Pack directory:"
echo "  ${PACK_DIR}"
echo
echo "Logs:"
echo "  ${LOG_DIR}"
echo
echo "Database:"
echo "  ${DB_DIR}"
echo
echo "============================================================"
echo " osquery is running and will start automatically at boot."
echo "============================================================"
echo
