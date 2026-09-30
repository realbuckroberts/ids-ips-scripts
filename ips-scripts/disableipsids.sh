#!/usr/bin/env bash

set -Eeuo pipefail

echo "=========================================================="
echo " IDS / IPS Service Disable Script"
echo "=========================================================="

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root:"
    echo "  sudo $0"
    exit 1
fi

BACKUP_DIR="/root/ids-ips-disable-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"

echo
echo "Backup/log directory:"
echo "  ${BACKUP_DIR}"

# ---------------------------------------------------------------------------
# Services commonly associated with IDS / IPS / host intrusion detection
# ---------------------------------------------------------------------------

SERVICES=(
    # Suricata
    "suricata.service"
    "suricata-auto.service"

    # Snort
    "snort.service"
    "snort3.service"
    "snortd.service"

    # Zeek / Bro
    "zeek.service"
    "bro.service"

    # OSSEC
    "ossec.service"
    "ossec-hids.service"
    "ossec-hids"

    # Wazuh
    "wazuh-manager.service"
    "wazuh-agent.service"
    "wazuh-indexer.service"
    "wazuh-dashboard.service"

    # Fail2Ban
    "fail2ban.service"

    # Security Onion
    "so-suricata.service"
    "so-zeek.service"
    "so-manager.service"
    "so-strelka.service"
    "so-elasticsearch.service"
    "so-logstash.service"

    # Common IPS / firewall daemons
    "psad.service"
    "fwsnort.service"

    # AIDE monitoring daemon, where present
    "aide.service"
)

# ---------------------------------------------------------------------------
# Log currently active services before changing anything
# ---------------------------------------------------------------------------

echo
echo "=== Detecting active IDS/IPS-related services ==="

FOUND=()

for SERVICE in "${SERVICES[@]}"; do
    if systemctl list-unit-files --all 2>/dev/null |
        grep -qE "^${SERVICE}[[:space:]]"; then

        FOUND+=("${SERVICE}")

        echo "Found: ${SERVICE}"

        systemctl is-active "${SERVICE}" 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------------------
# Also detect matching processes.
# This catches some installations that don't use the expected service name.
# ---------------------------------------------------------------------------

echo
echo "=== Detecting relevant processes ==="

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

    if pgrep -af "${PATTERN}" 2>/dev/null; then
        echo
        echo "Detected process matching: ${PATTERN}"
        pgrep -af "${PATTERN}" || true
    fi

done

# ---------------------------------------------------------------------------
# Disable and stop detected systemd services
# ---------------------------------------------------------------------------

echo
echo "=== Disabling IDS/IPS services ==="

for SERVICE in "${SERVICES[@]}"; do

    if systemctl list-unit-files --all 2>/dev/null |
        grep -qE "^${SERVICE}[[:space:]]"; then

        echo
        echo "Processing ${SERVICE}"

        # Record current state
        {
            echo "===== ${SERVICE} ====="
            systemctl is-enabled "${SERVICE}" 2>&1 || true
            systemctl is-active "${SERVICE}" 2>&1 || true
            systemctl status "${SERVICE}" --no-pager --full 2>&1 || true
        } > "${BACKUP_DIR}/${SERVICE//\//_}.txt"

        # Stop it if running
        systemctl stop "${SERVICE}" 2>/dev/null || true

        # Disable startup
        systemctl disable "${SERVICE}" 2>/dev/null || true

        # Prevent accidental automatic startup through dependencies
        systemctl mask "${SERVICE}" 2>/dev/null || true

        echo "  Stopped/disabled/masked: ${SERVICE}"
    fi

done

# ---------------------------------------------------------------------------
# Disable common timer units associated with IDS/security monitoring
# ---------------------------------------------------------------------------

echo
echo "=== Checking security-related systemd timers ==="

TIMER_PATTERNS=(
    "suricata"
    "snort"
    "zeek"
    "ossec"
    "wazuh"
    "fail2ban"
    "psad"
)

for PATTERN in "${TIMER_PATTERNS[@]}"; do

    mapfile -t TIMERS < <(
        systemctl list-unit-files --type=timer --all --no-legend 2>/dev/null |
        awk -v p="${PATTERN}" 'tolower($1) ~ p {print $1}'
    )

    for TIMER in "${TIMERS[@]}"; do

        echo "Disabling timer: ${TIMER}"

        systemctl stop "${TIMER}" 2>/dev/null || true
        systemctl disable "${TIMER}" 2>/dev/null || true
        systemctl mask "${TIMER}" 2>/dev/null || true

    done
done

# ---------------------------------------------------------------------------
# Check for Docker containers that appear to be IDS/IPS systems
# ---------------------------------------------------------------------------

echo
echo "=== Checking Docker containers ==="

if command -v docker >/dev/null 2>&1; then

    docker ps --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null |
    while read -r ID IMAGE NAME; do

        if echo "${IMAGE} ${NAME}" |
            grep -Eiq 'suricata|snort|zeek|bro|ossec|wazuh|securityonion'; then

            echo
            echo "WARNING: IDS/IPS container detected:"
            echo "  ID:     ${ID}"
            echo "  Image:  ${IMAGE}"
            echo "  Name:   ${NAME}"

            echo "${ID} ${IMAGE} ${NAME}" \
                >> "${BACKUP_DIR}/docker-ids-ips.txt"

            echo "Stopping container: ${NAME}"

            docker stop "${ID}" 2>/dev/null || true
        fi

    done

else
    echo "Docker is not installed."
fi

# ---------------------------------------------------------------------------
# Check for Podman containers
# ---------------------------------------------------------------------------

echo
echo "=== Checking Podman containers ==="

if command -v podman >/dev/null 2>&1; then

    podman ps --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null |
    while read -r ID IMAGE NAME; do

        if echo "${IMAGE} ${NAME}" |
            grep -Eiq 'suricata|snort|zeek|bro|ossec|wazuh|securityonion'; then

            echo
            echo "WARNING: IDS/IPS container detected:"
            echo "  ID:     ${ID}"
            echo "  Image:  ${IMAGE}"
            echo "  Name:   ${NAME}"

            echo "${ID} ${IMAGE} ${NAME}" \
                >> "${BACKUP_DIR}/podman-ids-ips.txt"

            echo "Stopping container: ${NAME}"

            podman stop "${ID}" 2>/dev/null || true
        fi

    done

else
    echo "Podman is not installed."
fi

# ---------------------------------------------------------------------------
# Reload systemd
# ---------------------------------------------------------------------------

echo
echo "=== Reloading systemd ==="

systemctl daemon-reload

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

echo
echo "=========================================================="
echo " Verification"
echo "=========================================================="

echo
echo "Potentially relevant services still active:"

for SERVICE in "${SERVICES[@]}"; do

    if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then
        echo "  WARNING: ACTIVE: ${SERVICE}"
    fi

done

echo
echo "Relevant processes still running:"

for PATTERN in "${PROCESS_PATTERNS[@]}"; do

    if pgrep -af "${PATTERN}" >/dev/null 2>&1; then
        echo
        echo "  ${PATTERN}:"
        pgrep -af "${PATTERN}" || true
    fi

done

echo
echo "=========================================================="
echo " Completed"
echo "=========================================================="

echo
echo "Service state backups:"
echo "  ${BACKUP_DIR}"

echo
echo "IMPORTANT:"
echo "This script only targets recognized IDS/IPS/security-monitoring"
echo "services. It does not modify firewall rules, nftables, iptables,"
echo "network interfaces, or kernel packet filtering."

