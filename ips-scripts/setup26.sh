#!/usr/bin/env bash

# ============================================================================
# Ubuntu 26.04 LTS
#
# AUTOMATIC IDS / IPS INSTALLER
#
# Features:
#   - Completely non-interactive
#   - Dynamically detects the primary Ethernet interface
#   - Automatically determines the local IPv4 network
#   - Configures Suricata AF_PACKET
#   - Installs/updates Suricata rules
#   - Enables and starts Suricata
#   - Installs other IDS/IPS packages when available
#   - Installs a systemd watchdog
#   - Watchdog runs every minute
#   - Missing packages are reinstalled
#   - Stopped/masked services are recovered
#
# IMPORTANT:
#   The watchdog does NOT blindly restart healthy services.
#
# SURICATA:
#   The script uses the packaged Suricata configuration as its base.
#   A timestamped backup is created before modifying it.
#
# ============================================================================

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# ROOT CHECK
# ============================================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    echo
    echo "Example:"
    echo "  sudo $0"
    exit 1
fi

# ============================================================================
# UBUNTU CHECK
# ============================================================================

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    echo "ERROR: This script requires Ubuntu."
    echo "Detected: ${PRETTY_NAME:-unknown}"
    exit 1
fi

if [[ "${VERSION_ID}" != "26.04" ]]; then
    echo "ERROR: This script requires Ubuntu 26.04."
    echo "Detected: ${PRETTY_NAME:-unknown}"
    exit 1
fi

# ============================================================================
# DIRECTORIES / LOGGING
# ============================================================================

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

INSTALL_LOG_DIR="/var/log/ids-ips-installer"

INSTALL_LOG="${INSTALL_LOG_DIR}/install-${TIMESTAMP}.log"

WATCHDOG_LOG="/var/log/ids-ips-watchdog.log"

BACKUP_DIR="/root/suricata-auto-backup-${TIMESTAMP}"

mkdir -p "${INSTALL_LOG_DIR}"
mkdir -p "${BACKUP_DIR}"

touch "${INSTALL_LOG}"
touch "${WATCHDOG_LOG}"

chmod 0600 "${INSTALL_LOG}"
chmod 0600 "${WATCHDOG_LOG}"

exec > >(tee -a "${INSTALL_LOG}") 2>&1

echo
echo "=========================================================="
echo " Ubuntu 26.04 IDS / IPS Automatic Installer"
echo "=========================================================="
echo
echo "System:"
echo "  ${PRETTY_NAME}"
echo
echo "Backup:"
echo "  ${BACKUP_DIR}"
echo
echo "Installer log:"
echo "  ${INSTALL_LOG}"
echo

# ============================================================================
# APT OPTIONS
# ============================================================================

APT_OPTIONS=(
    "-y"
    "-o"
    "Dpkg::Options::=--force-confdef"
    "-o"
    "Dpkg::Options::=--force-confold"
)

# ============================================================================
# 1. DETECT NETWORK INTERFACE
# ============================================================================

echo
echo "=========================================================="
echo " Detecting network interface"
echo "=========================================================="

PRIMARY_IFACE=""

# First choice:
# Interface associated with the IPv4 default route.
PRIMARY_IFACE="$(
    ip -4 route show default 2>/dev/null |
        awk '
            {
                for (i=1; i<=NF; i++) {
                    if ($i == "dev") {
                        print $(i+1)
                        exit
                    }
                }
            }
        '
)"

# Second choice:
# IPv6 default route, if there is no IPv4 default route.
if [[ -z "${PRIMARY_IFACE}" ]]; then

    PRIMARY_IFACE="$(
        ip -6 route show default 2>/dev/null |
            awk '
                {
                    for (i=1; i<=NF; i++) {
                        if ($i == "dev") {
                            print $(i+1)
                            exit
                        }
                    }
                }
            '
    )"

fi

# Third choice:
# Select the first physical Ethernet interface that is UP.
if [[ -z "${PRIMARY_IFACE}" ]]; then

    while read -r IFACE; do

        [[ -z "${IFACE}" ]] && continue

        if [[ -d "/sys/class/net/${IFACE}" ]]; then

            if [[ -e "/sys/class/net/${IFACE}/device" ]]; then

                PRIMARY_IFACE="${IFACE}"
                break

            fi

        fi

    done < <(
        ip -o link show |
            awk -F': ' '{print $2}' |
            cut -d'@' -f1
    )

fi

if [[ -z "${PRIMARY_IFACE}" ]]; then

    echo "ERROR: Could not automatically determine an Ethernet interface."
    echo
    echo "Available interfaces:"
    ip -br link || true
    exit 1

fi

# ============================================================================
# VERIFY INTERFACE
# ============================================================================

if [[ ! -d "/sys/class/net/${PRIMARY_IFACE}" ]]; then

    echo "ERROR: Detected interface does not exist:"
    echo "  ${PRIMARY_IFACE}"
    exit 1

fi

if [[ "${PRIMARY_IFACE}" == "lo" ]]; then

    echo "ERROR: Detected loopback interface."
    exit 1

fi

echo "Detected interface:"
echo "  ${PRIMARY_IFACE}"

echo
echo "Interface status:"

ip -br link show "${PRIMARY_IFACE}" || true

# ============================================================================
# DETECT IP / NETWORK
# ============================================================================

echo
echo "=========================================================="
echo " Detecting local network"
echo "=========================================================="

PRIMARY_IPV4="$(
    ip -4 -o addr show dev "${PRIMARY_IFACE}" scope global 2>/dev/null |
        awk '{print $4}' |
        head -n1
)"

if [[ -z "${PRIMARY_IPV4}" ]]; then

    echo "WARNING: No global IPv4 address found on ${PRIMARY_IFACE}."

    PRIMARY_NETWORK=""

else

    PRIMARY_NETWORK="$(
        ip -4 route show dev "${PRIMARY_IFACE}" proto kernel scope link 2>/dev/null |
            awk '{print $1}' |
            head -n1
    )"

fi

echo "IPv4 address:"
echo "  ${PRIMARY_IPV4:-none}"

echo "Network:"
echo "  ${PRIMARY_NETWORK:-unknown}"

# ============================================================================
# 2. UPDATE APT
# ============================================================================

echo
echo "=========================================================="
echo " Updating package repositories"
echo "=========================================================="

apt-get update

# ============================================================================
# REPAIR PACKAGE STATE
# ============================================================================

echo
echo "=== Repairing dpkg state ==="

dpkg --configure -a || true

apt-get \
    "${APT_OPTIONS[@]}" \
    -f install || true

# ============================================================================
# 3. BASE DEPENDENCIES
# ============================================================================

echo
echo "=========================================================="
echo " Installing base dependencies"
echo "=========================================================="

apt-get \
    "${APT_OPTIONS[@]}" \
    install \
    ca-certificates \
    curl \
    jq \
    iproute2 \
    systemd \
    rsyslog \
    ethtool

# ============================================================================
# 4. INSTALL SURICATA
# ============================================================================

echo
echo "=========================================================="
echo " Installing Suricata"
echo "=========================================================="

if ! apt-cache show suricata >/dev/null 2>&1; then

    echo "ERROR: Suricata is unavailable from configured repositories."
    exit 1

fi

apt-get \
    "${APT_OPTIONS[@]}" \
    install \
    suricata

# ============================================================================
# 5. SURICATA-UPDATE
#
# Newer Suricata packages may already contain the executable.
#
# Therefore DO NOT blindly install the separate package.
# ============================================================================

echo
echo "=========================================================="
echo " Checking Suricata rule updater"
echo "=========================================================="

if command -v suricata-update >/dev/null 2>&1; then

    echo "suricata-update is already installed."

else

    echo "suricata-update command is missing."

    if apt-cache show suricata-update >/dev/null 2>&1; then

        echo "Installing separate suricata-update package."

        apt-get \
            "${APT_OPTIONS[@]}" \
            install \
            suricata-update \
            || echo "WARNING: suricata-update installation failed."

    else

        echo "No separate suricata-update package available."

    fi

fi

# ============================================================================
# 6. BACKUP SURICATA CONFIGURATION
# ============================================================================

echo
echo "=========================================================="
echo " Backing up Suricata configuration"
echo "=========================================================="

SURICATA_CONFIG="/etc/suricata/suricata.yaml"

if [[ -f "${SURICATA_CONFIG}" ]]; then

    cp -a \
        "${SURICATA_CONFIG}" \
        "${BACKUP_DIR}/suricata.yaml"

    echo "Backup created."

else

    echo "WARNING: Suricata configuration does not exist yet."

fi

# ============================================================================
# 7. DETERMINE SURICATA VERSION
# ============================================================================

echo
echo "=========================================================="
echo " Detecting Suricata version"
echo "=========================================================="

SURICATA_BIN="$(command -v suricata)"

SURICATA_VERSION=""

if "${SURICATA_BIN}" -V >/dev/null 2>&1; then

    SURICATA_VERSION="$(
        "${SURICATA_BIN}" -V 2>&1 |
            head -n1
    )"

elif "${SURICATA_BIN}" --version >/dev/null 2>&1; then

    SURICATA_VERSION="$(
        "${SURICATA_BIN}" --version 2>&1 |
            head -n1
    )"

else

    SURICATA_VERSION="Unknown"

fi

echo "${SURICATA_VERSION}"

# ============================================================================
# 8. AUTOMATICALLY CONFIGURE AF_PACKET
#
# We don't replace the entire YAML.
#
# Instead we locate the af-packet interface entry and replace its interface
# value.
#
# A backup has already been created.
# ============================================================================

echo
echo "=========================================================="
echo " Configuring Suricata interface"
echo "=========================================================="

if [[ ! -f "${SURICATA_CONFIG}" ]]; then

    echo "ERROR: ${SURICATA_CONFIG} does not exist."
    exit 1

fi

python3 <<PYTHON
from pathlib import Path
import re
import sys

config = Path("${SURICATA_CONFIG}")
interface = "${PRIMARY_IFACE}"

text = config.read_text()

# ---------------------------------------------------------------------------
# Locate the af-packet section.
# ---------------------------------------------------------------------------

match = re.search(
    r'(?m)^af-packet:\s*\n',
    text
)

if not match:
    print("ERROR: af-packet section was not found.")
    sys.exit(1)

start = match.end()

# Find the next top-level YAML section.
next_section = re.search(
    r'(?m)^[A-Za-z0-9_-]+:\s*$',
    text[start:]
)

if next_section:
    end = start + next_section.start()
else:
    end = len(text)

section = text[start:end]

# ---------------------------------------------------------------------------
# Look for:
#
#   - interface: something
#
# in the AF_PACKET section.
# ---------------------------------------------------------------------------

pattern = re.compile(
    r'(?m)^(\s*-\s*interface:\s*)(\S+)(\s*)$'
)

new_section, count = pattern.subn(
    lambda m: m.group(1) + interface + m.group(3),
    section,
    count=1
)

if count == 0:

    # No interface entry existed.
    #
    # Insert one immediately below af-packet.
    new_section = (
        "  - interface: " + interface + "\n"
        + section
    )

    print("Created AF_PACKET interface entry.")

else:

    print("Updated existing AF_PACKET interface entry.")

config.write_text(
    text[:start] + new_section + text[end:]
)

print("Suricata interface configured as:", interface)
PYTHON

# ============================================================================
# 9. SET HOME_NET WHEN A LOCAL NETWORK WAS DETECTED
#
# Only modify HOME_NET when we have a reliable network value.
# ============================================================================

if [[ -n "${PRIMARY_NETWORK}" ]]; then

    echo
    echo "Configuring HOME_NET:"
    echo "  ${PRIMARY_NETWORK}"

    python3 <<PYTHON
from pathlib import Path
import re

config = Path("${SURICATA_CONFIG}")
network = "${PRIMARY_NETWORK}"

text = config.read_text()

# Match the first HOME_NET assignment.
pattern = re.compile(
    r'(?m)^(\s*HOME_NET:\s*)\[.*?\]'
)

replacement = r'\1["' + network + r'"]'

new_text, count = pattern.subn(
    replacement,
    text,
    count=1
)

if count:
    config.write_text(new_text)
    print("HOME_NET updated.")
else:
    print("HOME_NET entry not found; leaving existing configuration unchanged.")
PYTHON

else

    echo "No reliable network detected."
    echo "Leaving existing HOME_NET unchanged."

fi

# ============================================================================
# 10. VERIFY CONFIGURATION
# ============================================================================

echo
echo "=========================================================="
echo " Testing Suricata configuration"
echo "=========================================================="

if ! "${SURICATA_BIN}" \
    -T \
    -c "${SURICATA_CONFIG}"; then

    echo
    echo "ERROR: Suricata configuration validation failed."

    echo
    echo "Restoring backup:"

    cp -a \
        "${BACKUP_DIR}/suricata.yaml" \
        "${SURICATA_CONFIG}"

    echo "Original configuration restored."

    exit 1

fi

echo
echo "Suricata configuration: PASSED"

# ============================================================================
# 11. DOWNLOAD DEFAULT RULES
# ============================================================================

echo
echo "=========================================================="
echo " Installing Suricata rules"
echo "=========================================================="

if command -v suricata-update >/dev/null 2>&1; then

    if suricata-update; then

        echo
        echo "Suricata rules successfully installed."

    else

        echo
        echo "WARNING: suricata-update failed."

        echo "Suricata may not generate alerts until rules are available."

    fi

else

    echo "WARNING: suricata-update is unavailable."

fi

# ============================================================================
# 12. ENABLE SURICATA
# ============================================================================

echo
echo "=========================================================="
echo " Enabling Suricata system service"
echo "=========================================================="

systemctl daemon-reload

systemctl unmask suricata.service 2>/dev/null || true

systemctl enable suricata.service

systemctl restart suricata.service

sleep 2

if systemctl is-active --quiet suricata.service; then

    echo "Suricata: ACTIVE"

else

    echo "WARNING: Suricata did not become active."

    systemctl status \
        suricata.service \
        --no-pager \
        --full \
        || true

fi

# ============================================================================
# 13. INSTALL OTHER AVAILABLE IDS/IPS SOFTWARE
# ============================================================================

echo
echo "=========================================================="
echo " Installing additional IDS/IPS software"
echo "=========================================================="

install_if_available()
{
    local PACKAGE="$1"

    if apt-cache show "${PACKAGE}" >/dev/null 2>&1; then

        echo
        echo "Installing ${PACKAGE}..."

        apt-get \
            "${APT_OPTIONS[@]}" \
            install \
            "${PACKAGE}"

    else

        echo
        echo "Skipping unavailable package:"
        echo "  ${PACKAGE}"

    fi
}

install_if_available "snort"
install_if_available "zeek"
install_if_available "fail2ban"
install_if_available "ossec-hids"
install_if_available "wazuh-agent"
install_if_available "wazuh-manager"
install_if_available "wazuh-indexer"
install_if_available "wazuh-dashboard"
install_if_available "psad"
install_if_available "fwsnort"
install_if_available "aide"

# ============================================================================
# 14. ENABLE AVAILABLE SERVICES
# ============================================================================

echo
echo "=========================================================="
echo " Enabling available IDS/IPS services"
echo "=========================================================="

IDS_SERVICES=(
    "suricata.service"
    "snort.service"
    "snort3.service"
    "snortd.service"
    "zeek.service"
    "bro.service"
    "ossec.service"
    "ossec-hids.service"
    "ossec-hids"
    "wazuh-agent.service"
    "wazuh-manager.service"
    "wazuh-indexer.service"
    "wazuh-dashboard.service"
    "fail2ban.service"
    "psad.service"
    "fwsnort.service"
    "aide.service"
)

unit_exists()
{
    local UNIT="$1"

    systemctl list-unit-files \
        --all \
        --no-legend 2>/dev/null |
        awk '{print $1}' |
        grep -Fxq "${UNIT}"
}

for SERVICE in "${IDS_SERVICES[@]}"; do

    if unit_exists "${SERVICE}"; then

        echo
        echo "Processing ${SERVICE}"

        systemctl unmask "${SERVICE}" 2>/dev/null || true

        systemctl enable "${SERVICE}" 2>/dev/null || true

        if systemctl restart "${SERVICE}" 2>/dev/null; then

            echo "ACTIVE: ${SERVICE}"

        else

            echo "WARNING: Could not start ${SERVICE}"

        fi

    fi

done

# ============================================================================
# 15. CREATE WATCHDOG
# ============================================================================

echo
echo "=========================================================="
echo " Installing one-minute watchdog"
echo "=========================================================="

cat > /usr/local/sbin/ids-ips-watchdog.sh <<'WATCHDOG'
#!/usr/bin/env bash

set -u

export DEBIAN_FRONTEND=noninteractive

LOG="/var/log/ids-ips-watchdog.log"

exec >> "${LOG}" 2>&1

echo
echo "=========================================================="
echo "Watchdog: $(date)"
echo "=========================================================="

PACKAGES=(
    "suricata"
    "snort"
    "zeek"
    "fail2ban"
    "ossec-hids"
    "wazuh-agent"
    "wazuh-manager"
    "wazuh-indexer"
    "wazuh-dashboard"
    "psad"
    "fwsnort"
    "aide"
)

SERVICES=(
    "suricata.service"
    "snort.service"
    "snort3.service"
    "snortd.service"
    "zeek.service"
    "bro.service"
    "ossec.service"
    "ossec-hids.service"
    "ossec-hids"
    "wazuh-agent.service"
    "wazuh-manager.service"
    "wazuh-indexer.service"
    "wazuh-dashboard.service"
    "fail2ban.service"
    "psad.service"
    "fwsnort.service"
    "aide.service"
)

package_installed()
{
    dpkg-query \
        -W \
        -f='${Status}' \
        "$1" 2>/dev/null |
        grep -q '^install ok installed$'
}

package_available()
{
    apt-cache show "$1" >/dev/null 2>&1
}

unit_exists()
{
    systemctl list-unit-files \
        --all \
        --no-legend 2>/dev/null |
        awk '{print $1}' |
        grep -Fxq "$1"
}

# ============================================================================
# Refresh APT metadata at most every 6 hours.
# ============================================================================

STAMP="/var/lib/ids-ips-watchdog-apt-update"

mkdir -p "$(dirname "${STAMP}")"

if [[ ! -f "${STAMP}" ]] ||
   (( $(date +%s) - $(stat -c %Y "${STAMP}" 2>/dev/null || echo 0) >= 21600 )); then

    echo "Refreshing APT metadata."

    apt-get update -qq || true

    touch "${STAMP}"

fi

# ============================================================================
# Repair package manager.
# ============================================================================

dpkg --configure -a >/dev/null 2>&1 || true

apt-get \
    -y \
    -f install \
    >/dev/null 2>&1 || true

# ============================================================================
# Reinstall missing packages.
# ============================================================================

for PACKAGE in "${PACKAGES[@]}"; do

    if package_installed "${PACKAGE}"; then

        echo "Package OK: ${PACKAGE}"

    elif package_available "${PACKAGE}"; then

        echo "Package missing: ${PACKAGE}"
        echo "Installing: ${PACKAGE}"

        apt-get \
            -y \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            install \
            "${PACKAGE}" \
            || echo "WARNING: Failed to install ${PACKAGE}"

    else

        echo "Package unavailable: ${PACKAGE}"

    fi

done

# ============================================================================
# DO NOT separately install suricata-update when Suricata already provides it.
# ============================================================================

if package_installed "suricata"; then

    if command -v suricata-update >/dev/null 2>&1; then

        echo "suricata-update: OK"

    elif package_available "suricata-update"; then

        echo "Installing missing suricata-update."

        apt-get \
            -y \
            install \
            suricata-update \
            || echo "WARNING: suricata-update failed"

    fi

fi

systemctl daemon-reload

# ============================================================================
# Repair services.
# ============================================================================

for SERVICE in "${SERVICES[@]}"; do

    if unit_exists "${SERVICE}"; then

        echo "Checking ${SERVICE}"

        systemctl unmask "${SERVICE}" 2>/dev/null || true

        systemctl enable "${SERVICE}" 2>/dev/null || true

        if systemctl is-active --quiet "${SERVICE}"; then

            echo "RUNNING: ${SERVICE}"

        else

            echo "DOWN: ${SERVICE}"

            systemctl restart "${SERVICE}" 2>/dev/null || \
                echo "WARNING: Failed to restart ${SERVICE}"

        fi

    fi

done

# ============================================================================
# Suricata-specific recovery.
#
# We deliberately use the packaged service.
#
# We DO NOT issue:
#
#   suricata -i eth0
#
# because the interface has already been configured in suricata.yaml.
# ============================================================================

if unit_exists "suricata.service"; then

    if systemctl is-active --quiet suricata.service; then

        echo "Suricata: RUNNING"

    else

        echo "Suricata: DOWN"

        systemctl unmask suricata.service 2>/dev/null || true

        systemctl enable suricata.service 2>/dev/null || true

        systemctl restart suricata.service 2>/dev/null || \
            echo "WARNING: Suricata restart failed."

    fi

fi

echo "Watchdog complete: $(date)"

exit 0
WATCHDOG

chmod 0755 /usr/local/sbin/ids-ips-watchdog.sh

# ============================================================================
# 16. WATCHDOG SERVICE
# ============================================================================

cat > /etc/systemd/system/ids-ips-watchdog.service <<'SERVICE'
[Unit]
Description=IDS/IPS Self-Healing Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ids-ips-watchdog.sh
User=root
Nice=10
IOSchedulingClass=idle
StandardOutput=append:/var/log/ids-ips-watchdog.log
StandardError=append:/var/log/ids-ips-watchdog.log
SERVICE

# ============================================================================
# 17. WATCHDOG TIMER
# ============================================================================

cat > /etc/systemd/system/ids-ips-watchdog.timer <<'TIMER'
[Unit]
Description=IDS/IPS Self-Healing Watchdog - Every Minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
TIMER

# ============================================================================
# 18. ENABLE WATCHDOG
# ============================================================================

echo
echo "=========================================================="
echo " Enabling watchdog"
echo "=========================================================="

systemctl daemon-reload

systemctl unmask ids-ips-watchdog.service 2>/dev/null || true
systemctl unmask ids-ips-watchdog.timer 2>/dev/null || true

systemctl enable ids-ips-watchdog.timer

systemctl start ids-ips-watchdog.timer

# ============================================================================
# 19. RUN INITIAL WATCHDOG
# ============================================================================

echo
echo "=== Running initial watchdog ==="

systemctl start ids-ips-watchdog.service || true

# ============================================================================
# 20. FINAL STATUS
# ============================================================================

echo
echo "=========================================================="
echo " Final Configuration"
echo "=========================================================="

echo
echo "Detected interface:"
echo "  ${PRIMARY_IFACE}"

echo
echo "Detected IPv4:"
echo "  ${PRIMARY_IPV4:-none}"

echo
echo "Detected network:"
echo "  ${PRIMARY_NETWORK:-unknown}"

echo
echo "Suricata configuration:"
echo "  ${SURICATA_CONFIG}"

echo
echo "Suricata service:"

systemctl is-enabled suricata.service 2>/dev/null || true
systemctl is-active suricata.service 2>/dev/null || true

echo
echo "Watchdog timer:"

systemctl is-enabled ids-ips-watchdog.timer 2>/dev/null || true
systemctl is-active ids-ips-watchdog.timer 2>/dev/null || true

echo
echo "Watchdog schedule:"

systemctl list-timers \
    ids-ips-watchdog.timer \
    --no-pager \
    2>/dev/null || true

echo
echo "=========================================================="
echo " Logs"
echo "=========================================================="

echo
echo "Installer:"
echo "  ${INSTALL_LOG}"

echo
echo "Watchdog:"
echo "  ${WATCHDOG_LOG}"

echo
echo "Suricata:"
echo "  journalctl -u suricata.service"

echo
echo "Watchdog journal:"
echo "  journalctl -u ids-ips-watchdog.service"

echo
echo "=========================================================="
echo " Installation Complete"
echo "=========================================================="

echo
echo "Suricata will monitor:"
echo "  ${PRIMARY_IFACE}"

echo
echo "The watchdog will check the IDS/IPS installation every minute."

echo

