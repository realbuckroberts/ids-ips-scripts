#!/usr/bin/env bash

# ============================================================================
# SELF-HEALING IDS/IPS WATCHDOG
#
# Ubuntu 24.04
#
# Based on the previous 1-minute IDS/IPS watchdog.
#
# FEATURES
# --------
# - Completely non-interactive
# - Runs every 1 minute
# - Creates an inventory of currently installed IDS/IPS packages
# - Detects packages that have subsequently been removed
# - Reinstalls missing packages when available from configured APT sources
# - Repairs interrupted dpkg/apt states
# - Restores systemd services supplied by packages
# - Unmasks services
# - Enables services
# - Restarts stopped services
# - Validates Suricata before starting it
# - Never hard-codes a Suricata network interface
# - Does NOT install the conflicting standalone suricata-update package
# - Logs all activity
#
# IMPORTANT
# ---------
# The script only attempts to reinstall software that was present when
# the baseline inventory was created.
#
# It does NOT automatically install every IDS/IPS product listed below.
#
# ============================================================================

set -Eeuo pipefail

# ============================================================================
# Configuration
# ============================================================================

WATCHDOG="/usr/local/sbin/ids-ips-watchdog.sh"

SERVICE_UNIT="/etc/systemd/system/ids-ips-watchdog.service"
TIMER_UNIT="/etc/systemd/system/ids-ips-watchdog.timer"

STATE_DIR="/var/lib/ids-ips-watchdog"
BASELINE="${STATE_DIR}/installed-packages"

LOG_DIR="/var/log"
LOG="${LOG_DIR}/ids-ips-watchdog.log"

LOCK_FILE="/run/ids-ips-watchdog.lock"

# ============================================================================
# Known IDS/IPS packages
#
# The script only records packages that are actually installed.
# ============================================================================

KNOWN_PACKAGES=(
    "suricata"
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
)

# ============================================================================
# Known systemd services
# ============================================================================

KNOWN_SERVICES=(
    "suricata.service"
    "snort.service"
    "snort3.service"
    "snortd.service"
    "zeek.service"
    "bro.service"
    "ossec.service"
    "ossec-hids.service"
    "wazuh-agent.service"
    "wazuh-manager.service"
    "wazuh-indexer.service"
    "wazuh-dashboard.service"
    "fail2ban.service"
    "psad.service"
    "fwsnort.service"
)

# ============================================================================
# Root check
# ============================================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must run as root."
    exit 1
fi

# ============================================================================
# Prepare directories
# ============================================================================

mkdir -p "${STATE_DIR}"
mkdir -p "${LOG_DIR}"

touch "${LOG}"

chmod 0640 "${LOG}"

# ============================================================================
# Prevent overlapping watchdog executions
# ============================================================================

exec 9>"${LOCK_FILE}"

if ! flock -n 9; then
    echo "Another IDS/IPS watchdog instance is already running."
    exit 0
fi

# ============================================================================
# Logging
# ============================================================================

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"
}

log "=========================================================="
log "IDS/IPS self-healing watchdog started"
log "=========================================================="

# ============================================================================
# APT environment
#
# Prevent any package installation prompts.
# ============================================================================

export DEBIAN_FRONTEND=noninteractive

APT_OPTIONS=(
    "-y"
    "-o"
    "Dpkg::Options::=--force-confold"
    "-o"
    "Dpkg::Options::=--force-confdef"
)

# ============================================================================
# Create initial package baseline
# ============================================================================

create_baseline()
{
    if [[ -f "${BASELINE}" && -s "${BASELINE}" ]]; then
        return 0
    fi

    log "Creating IDS/IPS package baseline."

    : > "${BASELINE}"

    for PACKAGE in "${KNOWN_PACKAGES[@]}"; do

        if dpkg-query \
            -W \
            -f='${Status}' \
            "${PACKAGE}" 2>/dev/null |
            grep -q '^install ok installed$'; then

            echo "${PACKAGE}" >> "${BASELINE}"

            log "Baseline package detected: ${PACKAGE}"
        fi

    done

    if [[ ! -s "${BASELINE}" ]]; then
        log "WARNING: No known IDS/IPS packages were detected."
    fi

    chmod 0640 "${BASELINE}"
}

# ============================================================================
# Check APT package availability
# ============================================================================

package_available()
{
    local PACKAGE="$1"

    apt-cache policy "${PACKAGE}" 2>/dev/null |
        grep -q 'Candidate:'
}

# ============================================================================
# Check whether package is installed
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
# Repair broken package manager state
# ============================================================================

repair_package_manager()
{
    log "Checking package manager state."

    if dpkg --audit 2>/dev/null | grep -q .; then

        log "dpkg reports incomplete package state."
        log "Running dpkg --configure -a."

        dpkg --configure -a >> "${LOG}" 2>&1 || true
    fi

    if ! apt-get check >> "${LOG}" 2>&1; then

        log "APT dependency check failed."
        log "Attempting apt-get -f install."

        apt-get \
            "${APT_OPTIONS[@]}" \
            -f install >> "${LOG}" 2>&1 || true
    fi
}

# ============================================================================
# Reinstall missing package
# ============================================================================

repair_package()
{
    local PACKAGE="$1"

    if package_installed "${PACKAGE}"; then
        return 0
    fi

    log "PACKAGE MISSING: ${PACKAGE}"

    # ------------------------------------------------------------------------
    # Special Suricata handling
    #
    # Do NOT install Ubuntu's standalone suricata-update package.
    # Suricata 8 packages can provide /usr/bin/suricata-update themselves.
    # ------------------------------------------------------------------------

    if [[ "${PACKAGE}" == "suricata-update" ]]; then
        log "Skipping standalone suricata-update package."
        return 0
    fi

    if ! package_available "${PACKAGE}"; then

        log "WARNING: ${PACKAGE} is not available from configured APT sources."
        return 1
    fi

    log "Reinstalling ${PACKAGE}."

    if apt-get \
        "${APT_OPTIONS[@]}" \
        install "${PACKAGE}" >> "${LOG}" 2>&1; then

        log "Successfully reinstalled ${PACKAGE}."
        return 0

    fi

    log "Initial installation attempt failed for ${PACKAGE}."

    log "Repairing APT/dpkg state."

    dpkg --configure -a >> "${LOG}" 2>&1 || true

    apt-get \
        "${APT_OPTIONS[@]}" \
        -f install >> "${LOG}" 2>&1 || true

    log "Retrying ${PACKAGE} installation."

    if apt-get \
        "${APT_OPTIONS[@]}" \
        install "${PACKAGE}" >> "${LOG}" 2>&1; then

        log "Successfully reinstalled ${PACKAGE} on retry."
        return 0
    fi

    log "ERROR: Unable to reinstall ${PACKAGE}."

    return 1
}

# ============================================================================
# Determine whether systemd service exists
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
# Find service associated with package
#
# We primarily use known service names.
# ============================================================================

package_service()
{
    local PACKAGE="$1"

    case "${PACKAGE}" in

        suricata)
            echo "suricata.service"
            ;;

        snort)
            echo "snort.service"
            ;;

        snort3)
            echo "snort3.service"
            ;;

        zeek)
            echo "zeek.service"
            ;;

        bro)
            echo "bro.service"
            ;;

        ossec-hids)
            echo "ossec-hids.service"
            ;;

        wazuh-agent)
            echo "wazuh-agent.service"
            ;;

        wazuh-manager)
            echo "wazuh-manager.service"
            ;;

        wazuh-indexer)
            echo "wazuh-indexer.service"
            ;;

        wazuh-dashboard)
            echo "wazuh-dashboard.service"
            ;;

        fail2ban)
            echo "fail2ban.service"
            ;;

        psad)
            echo "psad.service"
            ;;

        fwsnort)
            echo "fwsnort.service"
            ;;

        *)
            echo ""
            ;;

    esac
}

# ============================================================================
# Detect Suricata CLI capabilities
# ============================================================================

detect_suricata_options()
{
    local SURICATA="/usr/bin/suricata"

    [[ -x "${SURICATA}" ]] || return 1

    local HELP

    HELP="$("${SURICATA}" -h 2>&1 || true)"

    if grep -Eq \
        '(^|[[:space:]])-T([[:space:]]|$)' \
        <<< "${HELP}"; then

        SURICATA_TEST_OPTION="-T"

    else

        SURICATA_TEST_OPTION=""
    fi

    if grep -Eq \
        '(^|[[:space:]])--init-errors-fatal([[:space:]]|$)' \
        <<< "${HELP}"; then

        SURICATA_FATAL_OPTION="--init-errors-fatal"

    else

        SURICATA_FATAL_OPTION=""
    fi

    return 0
}

# ============================================================================
# Validate Suricata configuration
# ============================================================================

validate_suricata()
{
    local SURICATA="/usr/bin/suricata"
    local CONFIG="/etc/suricata/suricata.yaml"

    [[ -x "${SURICATA}" ]] || {
        log "Suricata executable missing."
        return 1
    }

    [[ -f "${CONFIG}" ]] || {
        log "Suricata configuration missing."
        return 1
    }

    detect_suricata_options || {
        log "Unable to detect Suricata options."
        return 1
    }

    [[ -n "${SURICATA_TEST_OPTION}" ]] || {
        log "Suricata does not support configuration testing."
        return 1
    }

    local COMMAND=(
        "${SURICATA}"
        "${SURICATA_TEST_OPTION}"
        "-c"
        "${CONFIG}"
    )

    if [[ -n "${SURICATA_FATAL_OPTION}" ]]; then
        COMMAND+=("${SURICATA_FATAL_OPTION}")
    fi

    log "Validating Suricata configuration."

    if "${COMMAND[@]}" >> "${LOG}" 2>&1; then
        log "Suricata configuration VALID."
        return 0
    fi

    log "Suricata configuration INVALID."
    return 1
}

# ============================================================================
# Recover a service
# ============================================================================

recover_service()
{
    local SERVICE="$1"

    if ! unit_exists "${SERVICE}"; then

        log "Service unit not currently present: ${SERVICE}"
        return 1
    fi

    local STATE

    STATE="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"

    if [[ "${STATE}" == "active" ]]; then

        log "${SERVICE}: RUNNING"
        return 0
    fi

    log "${SERVICE}: NOT RUNNING"
    log "Beginning service recovery."

    # ------------------------------------------------------------------------
    # Remove systemd mask
    # ------------------------------------------------------------------------

    log "Unmasking ${SERVICE}."

    systemctl unmask "${SERVICE}" >> "${LOG}" 2>&1 || true

    # ------------------------------------------------------------------------
    # Enable at boot
    # ------------------------------------------------------------------------

    log "Enabling ${SERVICE}."

    systemctl enable "${SERVICE}" >> "${LOG}" 2>&1 || true

    # ------------------------------------------------------------------------
    # Suricata-specific validation
    # ------------------------------------------------------------------------

    if [[ "${SERVICE}" == "suricata.service" ]]; then

        if ! validate_suricata; then

            log "Suricata recovery cancelled because configuration is invalid."

            return 1
        fi

        # IMPORTANT:
        #
        # Never do:
        #
        #   suricata -i eth0
        #
        # or any manually selected interface.
        #
        # Use the normal packaged systemd unit.
        #

        log "Restarting Suricata through normal systemd service."

    fi

    # ------------------------------------------------------------------------
    # Restart service
    # ------------------------------------------------------------------------

    if systemctl restart "${SERVICE}" >> "${LOG}" 2>&1; then

        sleep 3

        if systemctl is-active --quiet "${SERVICE}"; then

            log "${SERVICE}: RECOVERY SUCCESSFUL"
            return 0

        fi

    fi

    log "${SERVICE}: RECOVERY FAILED"

    systemctl \
        --no-pager \
        --full \
        status "${SERVICE}" >> "${LOG}" 2>&1 || true

    journalctl \
        -u "${SERVICE}" \
        --no-pager \
        -n 50 >> "${LOG}" 2>&1 || true

    return 1
}

# ============================================================================
# Main
# ============================================================================

create_baseline

# ---------------------------------------------------------------------------
# Repair package manager before attempting package recovery.
# ---------------------------------------------------------------------------

repair_package_manager

# ---------------------------------------------------------------------------
# Check every package that was part of the baseline.
# ---------------------------------------------------------------------------

if [[ -s "${BASELINE}" ]]; then

    while IFS= read -r PACKAGE; do

        [[ -z "${PACKAGE}" ]] && continue

        if ! package_installed "${PACKAGE}"; then

            log "Detected removed package: ${PACKAGE}"

            repair_package "${PACKAGE}" || true

        else

            log "Package present: ${PACKAGE}"

        fi

    done < "${BASELINE}"

fi

# ---------------------------------------------------------------------------
# Rebuild systemd unit cache after package installation.
# ---------------------------------------------------------------------------

systemctl daemon-reload

# ---------------------------------------------------------------------------
# Check services.
# ---------------------------------------------------------------------------

for SERVICE in "${KNOWN_SERVICES[@]}"; do

    # Only monitor a service if its corresponding package was in the
    # original baseline.
    PACKAGE=""

    case "${SERVICE}" in

        suricata.service)
            PACKAGE="suricata"
            ;;

        snort.service)
            PACKAGE="snort"
            ;;

        snort3.service)
            PACKAGE="snort3"
            ;;

        zeek.service)
            PACKAGE="zeek"
            ;;

        bro.service)
            PACKAGE="bro"
            ;;

        ossec-hids.service)
            PACKAGE="ossec-hids"
            ;;

        wazuh-agent.service)
            PACKAGE="wazuh-agent"
            ;;

        wazuh-manager.service)
            PACKAGE="wazuh-manager"
            ;;

        wazuh-indexer.service)
            PACKAGE="wazuh-indexer"
            ;;

        wazuh-dashboard.service)
            PACKAGE="wazuh-dashboard"
            ;;

        fail2ban.service)
            PACKAGE="fail2ban"
            ;;

        psad.service)
            PACKAGE="psad"
            ;;

        fwsnort.service)
            PACKAGE="fwsnort"
            ;;

    esac

    [[ -n "${PACKAGE}" ]] || continue

    # Only manage services whose packages were in the baseline.
    if grep -Fxq "${PACKAGE}" "${BASELINE}" 2>/dev/null; then

        recover_service "${SERVICE}" || true

    fi

done

log "IDS/IPS self-healing watchdog completed."

exit 0

