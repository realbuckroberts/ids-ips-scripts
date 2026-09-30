#!/usr/bin/env bash

# ============================================================================
# IDS / IPS COMPLETE UNINSTALL
#
# Ubuntu 24.04
#
# IMPORTANT:
#   - Removes installed IDS/IPS packages.
#   - Stops and disables IDS/IPS services.
#   - PRESERVES the IDS/IPS watchdog script.
#   - PRESERVES the watchdog systemd service and timer.
#   - Temporarily stops the watchdog during removal.
#   - Leaves the watchdog DISABLED after removal so it does not immediately
#     reinstall the removed software.
#   - Does NOT modify iptables/nftables/firewall rules.
#   - Does NOT modify network interfaces.
#   - Fully non-interactive.
#
# ============================================================================

set -Eeuo pipefail

# ============================================================================
# ROOT
# ============================================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo
    echo "Run:"
    echo "  sudo $0"
    exit 1
fi

# ============================================================================
# SETTINGS
# ============================================================================

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

BACKUP_DIR="/root/ids-ips-uninstall-backup-${TIMESTAMP}"

LOG="${BACKUP_DIR}/uninstall.log"

WATCHDOG_SERVICE="ids-ips-watchdog.service"
WATCHDOG_TIMER="ids-ips-watchdog.timer"

mkdir -p "${BACKUP_DIR}"

touch "${LOG}"

chmod 0600 "${LOG}"

export DEBIAN_FRONTEND=noninteractive

APT_OPTIONS=(
    "-y"
    "-o"
    "Dpkg::Options::=--force-confold"
    "-o"
    "Dpkg::Options::=--force-confdef"
)

# ============================================================================
# LOGGING
# ============================================================================

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG}"
}

log ""
log "=========================================================="
log " IDS / IPS UNINSTALL"
log "=========================================================="

log "Backup directory: ${BACKUP_DIR}"

# ============================================================================
# IDS/IPS PACKAGES
# ============================================================================

PACKAGES=(
    "suricata"
    "suricata-update"

    "snort"
    "snort3"

    "zeek"
    "bro"

    "ossec-hids"

    "wazuh-agent"
    "wazuh-manager"
    "wazuh-indexer"
    "wazuh-dashboard"

    "fail2ban"

    "psad"
    "fwsnort"

    "aide"
)

# ============================================================================
# IDS/IPS SERVICES
# ============================================================================

SERVICES=(
    "suricata.service"
    "suricata-auto.service"

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

# ============================================================================
# CONFIGURATION DIRECTORIES
# ============================================================================

CONFIG_DIRS=(
    "/etc/suricata"
    "/etc/snort"
    "/etc/snort3"
    "/etc/zeek"
    "/etc/bro"
    "/var/ossec/etc"
    "/etc/wazuh"
    "/etc/fail2ban"
    "/etc/psad"
    "/etc/fwsnort"
    "/etc/aide"
)

# ============================================================================
# PACKAGE CHECK
# ============================================================================

package_installed()
{
    local PACKAGE="$1"

    dpkg-query \
        -W \
        -f='${Status}' \
        "${PACKAGE}" 2>/dev/null |
        grep -q '^install ok installed$'
}

# ============================================================================
# SERVICE CHECK
# ============================================================================

unit_exists()
{
    local UNIT="$1"

    systemctl list-unit-files \
        --all \
        --no-legend \
        2>/dev/null |
        awk '{print $1}' |
        grep -Fxq "${UNIT}"
}

# ============================================================================
# BACKUP CONFIGURATION
# ============================================================================

log ""
log "=== Backing up IDS/IPS configuration ==="

for DIR in "${CONFIG_DIRS[@]}"; do

    if [[ -d "${DIR}" ]]; then

        NAME="$(basename "${DIR}")"

        log "Backing up ${DIR}"

        cp -a \
            "${DIR}" \
            "${BACKUP_DIR}/${NAME}" \
            2>>"${LOG}" || true

    fi

done

# ============================================================================
# RECORD INSTALLED PACKAGES
# ============================================================================

log ""
log "=== Recording installed packages ==="

INSTALLED_PACKAGES="${BACKUP_DIR}/installed-packages.txt"

touch "${INSTALLED_PACKAGES}"

for PACKAGE in "${PACKAGES[@]}"; do

    if package_installed "${PACKAGE}"; then

        echo "${PACKAGE}" >> "${INSTALLED_PACKAGES}"

        log "Installed: ${PACKAGE}"

    fi

done

# ============================================================================
# PRESERVE WATCHDOG
#
# We deliberately DO NOT delete:
#
#   /usr/local/sbin/ids-ips-watchdog.sh
#   /etc/systemd/system/ids-ips-watchdog.service
#   /etc/systemd/system/ids-ips-watchdog.timer
#
# We only stop the timer while uninstalling.
# ============================================================================

log ""
log "=== Preserving IDS/IPS watchdog ==="

if systemctl list-unit-files \
    --all \
    --no-legend \
    2>/dev/null |
    awk '{print $1}' |
    grep -Fxq "${WATCHDOG_TIMER}"; then

    log "Stopping watchdog timer."

    systemctl stop "${WATCHDOG_TIMER}" 2>/dev/null || true

    log "Disabling watchdog timer temporarily."

    systemctl disable "${WATCHDOG_TIMER}" 2>/dev/null || true

else

    log "Watchdog timer was not installed."

fi

# Make sure the watchdog service itself isn't currently executing.

systemctl stop "${WATCHDOG_SERVICE}" 2>/dev/null || true

# ============================================================================
# STOP IDS/IPS SERVICES
# ============================================================================

log ""
log "=== Stopping IDS/IPS services ==="

for SERVICE in "${SERVICES[@]}"; do

    if unit_exists "${SERVICE}"; then

        log "Processing ${SERVICE}"

        {
            echo "=================================================="
            echo "Service: ${SERVICE}"
            echo "=================================================="

            systemctl is-enabled "${SERVICE}" 2>&1 || true
            systemctl is-active "${SERVICE}" 2>&1 || true

            systemctl status \
                "${SERVICE}" \
                --no-pager \
                --full \
                2>&1 || true

        } > "${BACKUP_DIR}/${SERVICE//\//_}.txt"

        systemctl stop "${SERVICE}" 2>/dev/null || true

        systemctl disable "${SERVICE}" 2>/dev/null || true

        systemctl unmask "${SERVICE}" 2>/dev/null || true

        log "Stopped: ${SERVICE}"

    fi

done

# ============================================================================
# DOCKER
# ============================================================================

log ""
log "=== Checking Docker containers ==="

if command -v docker >/dev/null 2>&1; then

    docker ps -a \
        --format '{{.ID}} {{.Image}} {{.Names}}' \
        > "${BACKUP_DIR}/docker-containers.txt" \
        2>/dev/null || true

    while read -r ID IMAGE NAME; do

        [[ -z "${ID:-}" ]] && continue

        if echo "${IMAGE} ${NAME}" |
            grep -Eiq \
            'suricata|snort|zeek|bro|ossec|wazuh|securityonion|fail2ban'; then

            log "Stopping/removing IDS/IPS Docker container: ${NAME}"

            docker stop "${ID}" 2>/dev/null || true
            docker rm "${ID}" 2>/dev/null || true

        fi

    done < "${BACKUP_DIR}/docker-containers.txt"

fi

# ============================================================================
# PODMAN
# ============================================================================

log ""
log "=== Checking Podman containers ==="

if command -v podman >/dev/null 2>&1; then

    podman ps -a \
        --format '{{.ID}} {{.Image}} {{.Names}}' \
        > "${BACKUP_DIR}/podman-containers.txt" \
        2>/dev/null || true

    while read -r ID IMAGE NAME; do

        [[ -z "${ID:-}" ]] && continue

        if echo "${IMAGE} ${NAME}" |
            grep -Eiq \
            'suricata|snort|zeek|bro|ossec|wazuh|securityonion|fail2ban'; then

            log "Stopping/removing IDS/IPS Podman container: ${NAME}"

            podman stop "${ID}" 2>/dev/null || true
            podman rm "${ID}" 2>/dev/null || true

        fi

    done < "${BACKUP_DIR}/podman-containers.txt"

fi

# ============================================================================
# RELOAD SYSTEMD
# ============================================================================

systemctl daemon-reload

# ============================================================================
# SURICATA
#
# Remove Suricata and suricata-update together to avoid the package conflict
# encountered with Suricata 8 on Ubuntu 24.04.
# ============================================================================

log ""
log "=== Removing Suricata ==="

if package_installed "suricata" ||
   package_installed "suricata-update"; then

    log "Purging Suricata packages."

    apt-get \
        "${APT_OPTIONS[@]}" \
        purge \
        "suricata" \
        "suricata-update" \
        >> "${LOG}" 2>&1 || true

fi

# ============================================================================
# REMOVE REMAINING PACKAGES
# ============================================================================

log ""
log "=== Removing remaining IDS/IPS packages ==="

for PACKAGE in "${PACKAGES[@]}"; do

    [[ "${PACKAGE}" == "suricata" ]] && continue
    [[ "${PACKAGE}" == "suricata-update" ]] && continue

    if package_installed "${PACKAGE}"; then

        log "Purging ${PACKAGE}"

        apt-get \
            "${APT_OPTIONS[@]}" \
            purge \
            "${PACKAGE}" \
            >> "${LOG}" 2>&1 || {

            log "WARNING: Could not completely remove ${PACKAGE}."

        }

    fi

done

# ============================================================================
# REMOVE CONFIGURATION DIRECTORIES
#
# Everything is backed up first.
# ============================================================================

log ""
log "=== Removing IDS/IPS configuration ==="

for DIR in "${CONFIG_DIRS[@]}"; do

    if [[ -d "${DIR}" ]]; then

        log "Removing ${DIR}"

        rm -rf "${DIR}"

    fi

done

# ============================================================================
# IMPORTANT:
# DO NOT REMOVE THE WATCHDOG.
#
# The following files intentionally remain:
#
#   /usr/local/sbin/ids-ips-watchdog.sh
#   /etc/systemd/system/ids-ips-watchdog.service
#   /etc/systemd/system/ids-ips-watchdog.timer
#
# ============================================================================

log ""
log "=== Verifying watchdog preservation ==="

if [[ -f "/usr/local/sbin/ids-ips-watchdog.sh" ]]; then
    log "Watchdog script preserved."
else
    log "WARNING: Watchdog script was not found."
fi

if [[ -f "/etc/systemd/system/ids-ips-watchdog.service" ]]; then
    log "Watchdog service preserved."
else
    log "WARNING: Watchdog service unit was not found."
fi

if [[ -f "/etc/systemd/system/ids-ips-watchdog.timer" ]]; then
    log "Watchdog timer preserved."
else
    log "WARNING: Watchdog timer unit was not found."
fi

# ============================================================================
# REPAIR PACKAGE DATABASE
# ============================================================================

log ""
log "=== Repairing package database ==="

dpkg --configure -a >> "${LOG}" 2>&1 || true

apt-get \
    "${APT_OPTIONS[@]}" \
    -f install \
    >> "${LOG}" 2>&1 || true

apt-get clean >> "${LOG}" 2>&1 || true

# ============================================================================
# SYSTEMD RELOAD
# ============================================================================

log ""
log "=== Reloading systemd ==="

systemctl daemon-reload

# ============================================================================
# VERIFY WATCHDOG REMAINS DISABLED
# ============================================================================

log ""
log "=== Watchdog status ==="

if systemctl list-unit-files \
    --all \
    --no-legend \
    2>/dev/null |
    awk '{print $1}' |
    grep -Fxq "${WATCHDOG_TIMER}"; then

    systemctl is-enabled "${WATCHDOG_TIMER}" 2>&1 || true
    systemctl is-active "${WATCHDOG_TIMER}" 2>&1 || true

fi

# ============================================================================
# VERIFY IDS/IPS REMOVAL
# ============================================================================

log ""
log "=== Verifying package removal ==="

REMAINING=0

for PACKAGE in "${PACKAGES[@]}"; do

    if package_installed "${PACKAGE}"; then

        log "WARNING: Still installed: ${PACKAGE}"

        REMAINING=1

    fi

done

# ============================================================================
# VERIFY PROCESSES
# ============================================================================

log ""
log "=== Checking remaining IDS/IPS processes ==="

PROCESS_PATTERNS=(
    "suricata"
    "snort"
    "snort3"
    "zeek"
    "bro"
    "ossec"
    "wazuh"
    "fail2ban"
    "psad"
    "fwsnort"
)

for PATTERN in "${PROCESS_PATTERNS[@]}"; do

    if pgrep -af "${PATTERN}" >/dev/null 2>&1; then

        log "WARNING: Process still running: ${PATTERN}"

        pgrep -af "${PATTERN}" >> "${LOG}" 2>&1 || true

        REMAINING=1

    fi

done

# ============================================================================
# FINAL
# ============================================================================

log ""
log "=========================================================="

if [[ "${REMAINING}" -eq 0 ]]; then

    log " IDS / IPS SOFTWARE REMOVED"
    log "=========================================================="

else

    log " IDS / IPS REMOVAL COMPLETED WITH WARNINGS"
    log "=========================================================="

fi

log ""
log "The watchdog was PRESERVED."

log "The watchdog timer was left DISABLED."

log ""
log "Backup:"
log "  ${BACKUP_DIR}"

log ""
log "Log:"
log "  ${LOG}"

log ""
log "To reactivate the self-healing watchdog later:"
log ""
log "  systemctl enable --now ids-ips-watchdog.timer"
log ""

log "Firewall rules and network configuration were NOT modified."

exit 0

