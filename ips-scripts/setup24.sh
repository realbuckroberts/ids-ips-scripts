#!/usr/bin/env bash

# ============================================================================
# Ubuntu 24.04 IDS / IPS INSTALLER + SELF-HEALING WATCHDOG
#
# Installs:
#   - Suricata
#   - Snort (if available)
#   - Zeek (if available)
#   - Fail2Ban
#   - OSSEC (if available)
#   - Wazuh components (if available)
#   - PSAD
#   - fwsnort
#   - AIDE
#
# Also installs:
#   - IDS/IPS watchdog
#   - systemd watchdog service
#   - systemd watchdog timer
#
# Watchdog behavior:
#   - Runs every 1 minute.
#   - Checks whether configured IDS/IPS packages are installed.
#   - Reinstalls missing packages.
#   - Checks whether their services exist.
#   - Unmasks disabled/masked services.
#   - Enables services.
#   - Restarts services that are not running.
#
# Suricata:
#   - Uses the packaged/default Ubuntu configuration.
#   - Does NOT modify suricata.yaml.
#   - Does NOT create a custom interface wrapper.
#   - Does NOT add custom command-line parameters.
#
# NON-INTERACTIVE
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
# VARIABLES
# ============================================================================

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

LOG_DIR="/var/log/ids-ips-installer"

LOG_FILE="${LOG_DIR}/install-${TIMESTAMP}.log"

WATCHDOG_SCRIPT="/usr/local/sbin/ids-ips-watchdog.sh"

WATCHDOG_SERVICE="/etc/systemd/system/ids-ips-watchdog.service"

WATCHDOG_TIMER="/etc/systemd/system/ids-ips-watchdog.timer"

WATCHDOG_LOG="/var/log/ids-ips-watchdog.log"

mkdir -p "${LOG_DIR}"

touch "${LOG_FILE}"

touch "${WATCHDOG_LOG}"

chmod 0600 "${LOG_FILE}" "${WATCHDOG_LOG}"

# ============================================================================
# LOG INSTALLER
# ============================================================================

exec > >(tee -a "${LOG_FILE}") 2>&1

echo
echo "=========================================================="
echo " Ubuntu 24.04 IDS / IPS Installer"
echo "=========================================================="
echo
echo "Installation log:"
echo "  ${LOG_FILE}"
echo

# ============================================================================
# VERIFY UBUNTU
# ============================================================================

if [[ ! -r /etc/os-release ]]; then

    echo "ERROR: /etc/os-release not found."
    exit 1

fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then

    echo "ERROR: This script is intended for Ubuntu."
    echo "Detected: ${PRETTY_NAME:-unknown}"
    exit 1

fi

if [[ "${VERSION_ID}" != "24.04" ]]; then

    echo "WARNING: This script targets Ubuntu 24.04."
    echo "Detected: ${PRETTY_NAME:-unknown}"
    echo

fi

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
# PACKAGE DEFINITIONS
#
# These are the packages the watchdog is authorized to reinstall.
# ============================================================================

WATCHDOG_PACKAGES=(
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

# ============================================================================
# SERVICES
# ============================================================================

WATCHDOG_SERVICES=(
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

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

package_available()
{
    local PACKAGE="$1"

    apt-cache show "${PACKAGE}" >/dev/null 2>&1
}

package_installed()
{
    local PACKAGE="$1"

    dpkg-query \
        -W \
        -f='${Status}' \
        "${PACKAGE}" 2>/dev/null |
        grep -q '^install ok installed$'
}

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
# UPDATE APT
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
echo "=== Repairing package manager state ==="

dpkg --configure -a || true

apt-get \
    "${APT_OPTIONS[@]}" \
    -f install || true

# ============================================================================
# BASE PACKAGES
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
    gnupg \
    jq \
    iproute2 \
    lsb-release \
    systemd \
    rsyslog

# ============================================================================
# SURICATA
#
# Do NOT separately force-install suricata-update.
#
# This prevents the exact collision previously encountered:
#
#   /usr/bin/suricata-update
#
# being owned by both Suricata and suricata-update.
# ============================================================================

echo
echo "=========================================================="
echo " Installing Suricata"
echo "=========================================================="

if package_available "suricata"; then

    apt-get \
        "${APT_OPTIONS[@]}" \
        install \
        suricata

else

    echo "ERROR: Suricata is not available from configured repositories."
    exit 1

fi

# ============================================================================
# SURICATA-UPDATE
# ============================================================================

echo
echo "=== Checking Suricata update utility ==="

if command -v suricata-update >/dev/null 2>&1; then

    echo "suricata-update is already available."

elif package_available "suricata-update"; then

    echo "Installing separate suricata-update package."

    apt-get \
        "${APT_OPTIONS[@]}" \
        install \
        suricata-update || {

        echo
        echo "WARNING: Could not install separate suricata-update."
        echo "Continuing because Suricata itself is installed."

    }

else

    echo "suricata-update package is unavailable."

fi

# ============================================================================
# OTHER IDS/IPS PACKAGES
# ============================================================================

install_if_available()
{
    local PACKAGE="$1"

    echo
    echo "Checking package: ${PACKAGE}"

    if package_available "${PACKAGE}"; then

        apt-get \
            "${APT_OPTIONS[@]}" \
            install \
            "${PACKAGE}"

        echo "Installed: ${PACKAGE}"

    else

        echo "Not available in current repositories: ${PACKAGE}"
        echo "Skipping."

    fi
}

echo
echo "=========================================================="
echo " Installing additional IDS/IPS software"
echo "=========================================================="

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
# SYSTEMD
# ============================================================================

echo
echo "=========================================================="
echo " Reloading systemd"
echo "=========================================================="

systemctl daemon-reload

# ============================================================================
# ENABLE / START AVAILABLE SERVICES
# ============================================================================

echo
echo "=========================================================="
echo " Enabling and starting IDS/IPS services"
echo "=========================================================="

for SERVICE in "${WATCHDOG_SERVICES[@]}"; do

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
# SURICATA DEFAULT CONFIGURATION
# ============================================================================

echo
echo "=========================================================="
echo " Validating default Suricata configuration"
echo "=========================================================="

if command -v suricata >/dev/null 2>&1; then

    SURICATA_BIN="$(command -v suricata)"

    echo "Suricata binary:"
    echo "  ${SURICATA_BIN}"

    # Suricata 8 uses -V.
    # Older versions may support --version.
    if "${SURICATA_BIN}" -V >/dev/null 2>&1; then

        "${SURICATA_BIN}" -V || true

    elif "${SURICATA_BIN}" --version >/dev/null 2>&1; then

        "${SURICATA_BIN}" --version || true

    fi

    if [[ -f "/etc/suricata/suricata.yaml" ]]; then

        echo
        echo "Testing /etc/suricata/suricata.yaml"

        if "${SURICATA_BIN}" \
            -T \
            -c /etc/suricata/suricata.yaml; then

            echo "Suricata configuration: OK"

        else

            echo
            echo "WARNING: Suricata configuration test failed."

        fi

    else

        echo "WARNING: Default Suricata configuration not found."

    fi

fi

# ============================================================================
# CREATE WATCHDOG
# ============================================================================

echo
echo "=========================================================="
echo " Installing IDS/IPS self-healing watchdog"
echo "=========================================================="

cat > "${WATCHDOG_SCRIPT}" <<'WATCHDOG_EOF'
#!/usr/bin/env bash

# ============================================================================
# IDS / IPS SELF-HEALING WATCHDOG
#
# Runs from systemd every minute.
#
# It:
#   1. Checks configured IDS/IPS packages.
#   2. Reinstalls missing packages when available.
#   3. Checks their services.
#   4. Unmasks services if necessary.
#   5. Enables services.
#   6. Restarts services that aren't running.
#
# Suricata uses the packaged/default service.
# No custom interface is supplied.
# ============================================================================

set -u

export DEBIAN_FRONTEND=noninteractive

LOG="/var/log/ids-ips-watchdog.log"

exec >> "${LOG}" 2>&1

echo
echo "=========================================================="
echo "Watchdog run: $(date)"
echo "=========================================================="

# ---------------------------------------------------------------------------
# Packages authorized for automatic reinstallation
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Services associated with those packages
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Package functions
# ---------------------------------------------------------------------------

package_installed()
{
    local PACKAGE="$1"

    dpkg-query \
        -W \
        -f='${Status}' \
        "${PACKAGE}" 2>/dev/null |
        grep -q '^install ok installed$'
}

package_available()
{
    local PACKAGE="$1"

    apt-cache show "${PACKAGE}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Refresh package index if needed.
#
# APT's own cache is used first. This prevents unnecessary downloads every
# minute.
# ---------------------------------------------------------------------------

APT_UPDATE_STAMP="/var/lib/ids-ips-watchdog-apt-update"

mkdir -p "$(dirname "${APT_UPDATE_STAMP}")"

UPDATE_REQUIRED=0

if [[ ! -f "${APT_UPDATE_STAMP}" ]]; then

    UPDATE_REQUIRED=1

else

    NOW="$(date +%s)"
    LAST="$(stat -c %Y "${APT_UPDATE_STAMP}" 2>/dev/null || echo 0)"

    if (( NOW - LAST >= 21600 )); then
        UPDATE_REQUIRED=1
    fi

fi

if (( UPDATE_REQUIRED == 1 )); then

    echo "Refreshing APT package information."

    apt-get update \
        -qq \
        || true

    touch "${APT_UPDATE_STAMP}"

fi

# ---------------------------------------------------------------------------
# Reinstall missing packages
# ---------------------------------------------------------------------------

for PACKAGE in "${PACKAGES[@]}"; do

    if package_installed "${PACKAGE}"; then

        echo "Package OK: ${PACKAGE}"

    else

        echo "Package missing: ${PACKAGE}"

        if package_available "${PACKAGE}"; then

            echo "Installing: ${PACKAGE}"

            apt-get \
                -y \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold \
                install \
                "${PACKAGE}" \
                || echo "WARNING: Failed installing ${PACKAGE}"

        else

            echo "Package unavailable: ${PACKAGE}"

        fi

    fi

done

# ---------------------------------------------------------------------------
# Special Suricata handling
#
# Never separately install suricata-update when Suricata already supplies
# /usr/bin/suricata-update.
# ---------------------------------------------------------------------------

if package_installed "suricata"; then

    if command -v suricata-update >/dev/null 2>&1; then

        echo "Suricata-update command present."

    else

        echo "Suricata-update command missing."

        if package_available "suricata-update"; then

            apt-get \
                -y \
                install \
                suricata-update \
                || echo "WARNING: suricata-update installation failed."

        fi

    fi

fi

# ---------------------------------------------------------------------------
# Repair dpkg state
# ---------------------------------------------------------------------------

dpkg --configure -a >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Ensure services are available
# ---------------------------------------------------------------------------

systemctl daemon-reload

for SERVICE in "${SERVICES[@]}"; do

    if systemctl list-unit-files \
        --all \
        --no-legend \
        2>/dev/null |
        awk '{print $1}' |
        grep -Fxq "${SERVICE}"; then

        echo "Checking service: ${SERVICE}"

        # Remove a mask if one exists.
        systemctl unmask "${SERVICE}" 2>/dev/null || true

        # Enable service at boot.
        systemctl enable "${SERVICE}" 2>/dev/null || true

        # Start/restart only if not currently active.
        if systemctl is-active --quiet "${SERVICE}"; then

            echo "Already running: ${SERVICE}"

        else

            echo "Starting/restarting: ${SERVICE}"

            systemctl restart "${SERVICE}" 2>/dev/null || {

                echo "WARNING: Failed to start ${SERVICE}"

            }

        fi

    fi

done

# ---------------------------------------------------------------------------
# Suricata uses its packaged system service.
#
# Do NOT call:
#
#   suricata -i eth0
#
# Do NOT dynamically modify suricata.yaml.
# ---------------------------------------------------------------------------

if unit_exists_suricata="$(systemctl list-unit-files \
    --all \
    --no-legend 2>/dev/null |
    awk '{print $1}' |
    grep -Fx "suricata.service" || true)"; then

    if [[ -n "${unit_exists_suricata}" ]]; then

        if systemctl is-active --quiet suricata.service; then

            echo "Suricata is running."

        else

            echo "Suricata is not running. Restarting."

            systemctl unmask suricata.service 2>/dev/null || true
            systemctl enable suricata.service 2>/dev/null || true
            systemctl restart suricata.service 2>/dev/null || true

        fi

    fi

fi

echo "Watchdog run complete: $(date)"

exit 0
WATCHDOG_EOF

chmod 0755 "${WATCHDOG_SCRIPT}"

# ============================================================================
# CREATE WATCHDOG SERVICE
# ============================================================================

cat > "${WATCHDOG_SERVICE}" <<EOF
[Unit]
Description=IDS/IPS Self-Healing Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
User=root
Nice=10
IOSchedulingClass=idle
StandardOutput=append:${WATCHDOG_LOG}
StandardError=append:${WATCHDOG_LOG}
EOF

# ============================================================================
# CREATE WATCHDOG TIMER
# ============================================================================

cat > "${WATCHDOG_TIMER}" <<EOF
[Unit]
Description=Run IDS/IPS Self-Healing Watchdog Every Minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ============================================================================
# ENABLE WATCHDOG
# ============================================================================

echo
echo "=========================================================="
echo " Enabling IDS/IPS watchdog"
echo "=========================================================="

systemctl daemon-reload

systemctl unmask ids-ips-watchdog.service 2>/dev/null || true
systemctl unmask ids-ips-watchdog.timer 2>/dev/null || true

systemctl enable ids-ips-watchdog.timer

systemctl start ids-ips-watchdog.timer

# ============================================================================
# RUN FIRST WATCHDOG CHECK IMMEDIATELY
# ============================================================================

echo
echo "=== Running initial watchdog check ==="

systemctl start ids-ips-watchdog.service || true

# ============================================================================
# FINAL STATUS
# ============================================================================

echo
echo "=========================================================="
echo " Final Status"
echo "=========================================================="

echo
echo "Watchdog timer:"

systemctl is-enabled ids-ips-watchdog.timer 2>/dev/null || true
systemctl is-active ids-ips-watchdog.timer 2>/dev/null || true

echo
echo "IDS/IPS services:"

for SERVICE in "${WATCHDOG_SERVICES[@]}"; do

    if unit_exists "${SERVICE}"; then

        printf "%-30s " "${SERVICE}"

        if systemctl is-active --quiet "${SERVICE}"; then

            echo "ACTIVE"

        else

            echo "NOT ACTIVE"

        fi

    fi

done

# ============================================================================
# SURICATA FINAL CHECK
# ============================================================================

echo
echo "=========================================================="
echo " Suricata"
echo "=========================================================="

if command -v suricata >/dev/null 2>&1; then

    echo "Binary:"
    command -v suricata

    echo
    echo "Version:"

    if suricata -V >/dev/null 2>&1; then

        suricata -V 2>&1 | head -n 2

    elif suricata --version >/dev/null 2>&1; then

        suricata --version 2>&1 | head -n 2

    fi

    echo
    echo "Service:"

    systemctl status \
        suricata.service \
        --no-pager \
        --full \
        2>/dev/null || true

fi

# ============================================================================
# FINAL INFORMATION
# ============================================================================

echo
echo "=========================================================="
echo " Installation Complete"
echo "=========================================================="

echo
echo "Watchdog script:"
echo "  ${WATCHDOG_SCRIPT}"

echo
echo "Watchdog service:"
echo "  ${WATCHDOG_SERVICE}"

echo
echo "Watchdog timer:"
echo "  ${WATCHDOG_TIMER}"

echo
echo "Watchdog log:"
echo "  ${WATCHDOG_LOG}"

echo
echo "Installer log:"
echo "  ${LOG_FILE}"

echo
echo "Watchdog interval:"
echo "  1 minute"

echo
echo "Suricata:"
echo "  Uses packaged/default system configuration."
echo "  No custom interface wrapper."
echo "  No dynamically generated -i argument."
echo "  No modification of /etc/suricata/suricata.yaml."

echo
echo "=========================================================="

exit 0

