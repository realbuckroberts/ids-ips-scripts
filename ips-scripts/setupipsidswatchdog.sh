#!/usr/bin/env bash

# ============================================================================
# Fully Non-Interactive IDS/IPS Watchdog Installer
#
# Ubuntu 24.04
#
# Installs:
#   /usr/local/sbin/ids-ips-watchdog.sh
#   /etc/systemd/system/ids-ips-watchdog.service
#   /etc/systemd/system/ids-ips-watchdog.timer
#
# Behavior:
#   - Runs automatically 2 minutes after boot
#   - Runs every 1 minute thereafter
#   - Detects installed IDS/IPS services
#   - If a service is stopped:
#       * unmask
#       * enable
#       * restart
#   - Suricata is restarted ONLY through suricata.service
#   - Does not modify suricata.yaml
#   - Does not hard-code a network interface
#   - Fully non-interactive
#
# ============================================================================

set -Eeuo pipefail

WATCHDOG="/usr/local/sbin/ids-ips-watchdog.sh"
SERVICE="/etc/systemd/system/ids-ips-watchdog.service"
TIMER="/etc/systemd/system/ids-ips-watchdog.timer"

echo "=========================================================="
echo " Installing IDS/IPS Watchdog"
echo "=========================================================="

# ---------------------------------------------------------------------------
# Require root
# ---------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo
    echo "Run:"
    echo "  sudo $0"
    exit 1
fi

# ---------------------------------------------------------------------------
# Create watchdog script
# ---------------------------------------------------------------------------

echo "Creating watchdog script..."

cat > "${WATCHDOG}" <<'WATCHDOG_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail

LOG="/var/log/ids-ips-watchdog.log"

mkdir -p "$(dirname "${LOG}")"
touch "${LOG}"

exec >> "${LOG}" 2>&1

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=========================================================="
log "IDS/IPS watchdog check started"
log "=========================================================="

# ---------------------------------------------------------------------------
# Known IDS/IPS services
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
    "wazuh-manager.service"
    "wazuh-agent.service"
    "wazuh-indexer.service"
    "wazuh-dashboard.service"
    "fail2ban.service"
    "so-suricata.service"
    "so-zeek.service"
    "so-manager.service"
    "so-strelka.service"
    "so-elasticsearch.service"
    "so-logstash.service"
    "psad.service"
    "fwsnort.service"
)

# ---------------------------------------------------------------------------
# Determine whether a unit exists
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Suricata configuration validation
#
# IMPORTANT:
#
# We do not manually launch Suricata.
#
# The actual service is restarted with:
#
#     systemctl restart suricata.service
#
# Therefore the installed systemd unit supplies the normal startup
# parameters and /etc/suricata/suricata.yaml supplies configuration.
# ---------------------------------------------------------------------------

validate_suricata()
{
    local SURICATA="/usr/bin/suricata"
    local CONFIG="/etc/suricata/suricata.yaml"

    if [[ ! -x "${SURICATA}" ]]; then
        log "Suricata executable not found."
        return 1
    fi

    if [[ ! -f "${CONFIG}" ]]; then
        log "Suricata configuration not found."
        return 1
    fi

    local HELP

    HELP="$("${SURICATA}" -h 2>&1 || true)"

    local COMMAND=()

    # Suricata 8 uses -T for configuration testing.
    if grep -Eq '(^|[[:space:]])-T([[:space:]]|$)' <<< "${HELP}"; then
        COMMAND+=("-T")
    else
        log "Suricata does not support -T."
        return 1
    fi

    COMMAND+=(
        "-c"
        "${CONFIG}"
    )

    if grep -Eq \
        '(^|[[:space:]])--init-errors-fatal([[:space:]]|$)' \
        <<< "${HELP}"; then

        COMMAND+=("--init-errors-fatal")
    fi

    log "Testing Suricata configuration..."

    if "${SURICATA}" "${COMMAND[@]}"; then
        log "Suricata configuration is valid."
        return 0
    fi

    log "Suricata configuration validation FAILED."
    return 1
}

# ---------------------------------------------------------------------------
# Suricata recovery
# ---------------------------------------------------------------------------

check_suricata()
{
    local UNIT="suricata.service"

    if ! unit_exists "${UNIT}"; then
        return 0
    fi

    local STATE

    STATE="$(systemctl is-active "${UNIT}" 2>/dev/null || true)"

    if [[ "${STATE}" == "active" ]]; then
        log "Suricata: RUNNING"
        return 0
    fi

    log "Suricata: NOT RUNNING"
    log "Attempting automatic recovery."

    log "Unmasking ${UNIT}..."
    systemctl unmask "${UNIT}" 2>/dev/null || true

    log "Enabling ${UNIT}..."
    systemctl enable "${UNIT}" 2>/dev/null || true

    # Never launch Suricata with a manually selected interface.
    # Use the normal packaged systemd service.
    if ! validate_suricata; then
        log "Suricata recovery aborted because configuration validation failed."
        return 1
    fi

    log "Restarting ${UNIT} using normal systemd configuration..."

    if systemctl restart "${UNIT}"; then
        sleep 3

        if systemctl is-active --quiet "${UNIT}"; then
            log "Suricata recovery SUCCESSFUL."
            return 0
        fi
    fi

    log "Suricata recovery FAILED."

    systemctl --no-pager --full status "${UNIT}" || true

    journalctl \
        -u "${UNIT}" \
        --no-pager \
        -n 30 || true

    return 1
}

# ---------------------------------------------------------------------------
# Generic service recovery
# ---------------------------------------------------------------------------

check_generic_service()
{
    local UNIT="$1"

    if ! unit_exists "${UNIT}"; then
        return 0
    fi

    local STATE

    STATE="$(systemctl is-active "${UNIT}" 2>/dev/null || true)"

    if [[ "${STATE}" == "active" ]]; then
        log "${UNIT}: RUNNING"
        return 0
    fi

    log "${UNIT}: NOT RUNNING"
    log "Attempting automatic recovery."

    systemctl unmask "${UNIT}" 2>/dev/null || true
    systemctl enable "${UNIT}" 2>/dev/null || true

    if systemctl restart "${UNIT}"; then

        sleep 2

        if systemctl is-active --quiet "${UNIT}"; then
            log "${UNIT}: RECOVERY SUCCESSFUL"
            return 0
        fi
    fi

    log "${UNIT}: RECOVERY FAILED"

    systemctl --no-pager --full status "${UNIT}" || true

    return 1
}

# ---------------------------------------------------------------------------
# Check Suricata first
# ---------------------------------------------------------------------------

check_suricata || true

# ---------------------------------------------------------------------------
# Check remaining services
# ---------------------------------------------------------------------------

for UNIT in "${SERVICES[@]}"; do

    [[ "${UNIT}" == "suricata.service" ]] && continue

    check_generic_service "${UNIT}" || true

done

log "IDS/IPS watchdog check completed."

exit 0
WATCHDOG_SCRIPT

chmod 0755 "${WATCHDOG}"

# ---------------------------------------------------------------------------
# Create systemd service
# ---------------------------------------------------------------------------

echo "Creating systemd service..."

cat > "${SERVICE}" <<'SYSTEMD_SERVICE'
[Unit]
Description=IDS/IPS Service Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ids-ips-watchdog.sh
SYSTEMD_SERVICE

chmod 0644 "${SERVICE}"

# ---------------------------------------------------------------------------
# Create one-minute systemd timer
# ---------------------------------------------------------------------------

echo "Creating one-minute timer..."

cat > "${TIMER}" <<'SYSTEMD_TIMER'
[Unit]
Description=IDS/IPS Service Watchdog Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
SYSTEMD_TIMER

chmod 0644 "${TIMER}"

# ---------------------------------------------------------------------------
# Reload systemd
# ---------------------------------------------------------------------------

echo "Reloading systemd..."

systemctl daemon-reload

# ---------------------------------------------------------------------------
# Enable and start timer
# ---------------------------------------------------------------------------

echo "Enabling watchdog timer..."

systemctl enable ids-ips-watchdog.timer

systemctl start ids-ips-watchdog.timer

# ---------------------------------------------------------------------------
# Run first check immediately
# ---------------------------------------------------------------------------

echo "Running initial IDS/IPS check..."

systemctl start ids-ips-watchdog.service

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

echo
echo "=========================================================="
echo " IDS/IPS Watchdog Installed"
echo "=========================================================="

echo
echo "Timer status:"
systemctl --no-pager --full status \
    ids-ips-watchdog.timer || true

echo
echo "Next scheduled execution:"
systemctl list-timers \
    ids-ips-watchdog.timer \
    --no-pager || true

echo
echo "Watchdog log:"
echo "  /var/log/ids-ips-watchdog.log"

echo
echo "The watchdog runs automatically every 1 minute."

echo
echo "Installation complete."

