#!/usr/bin/env bash

# ============================================================================
# Restore and start Suricata using the normal packaged systemd service
#
# Designed for Ubuntu 24.04 / Suricata 8.x
#
# NON-INTERACTIVE
#
# This script:
#   - Stops/removes the previous custom suricata-auto service
#   - Unmasks the normal suricata.service
#   - Does NOT modify suricata.yaml
#   - Uses the existing system configuration
#   - Generates Suricata rules if necessary
#   - Detects supported Suricata CLI options
#   - Validates the configuration
#   - Enables Suricata at boot
#   - Restarts Suricata
#   - Verifies the service
#
# ============================================================================

set -Eeuo pipefail

SURICATA="/usr/bin/suricata"
CONFIG="/etc/suricata/suricata.yaml"
RULE_DIR="/var/lib/suricata/rules"
RULE_FILE="${RULE_DIR}/suricata.rules"

NORMAL_SERVICE="suricata.service"
CUSTOM_SERVICE="suricata-auto.service"
CUSTOM_WRAPPER="/usr/local/bin/suricata-wrapper.sh"

BACKUP_DIR="/root/suricata-service-backup-$(date +%Y%m%d-%H%M%S)"

# ============================================================================
# Helper functions
# ============================================================================

log() {
    echo
    echo "=== $* ==="
}

error_exit() {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

# ============================================================================
# Root check
# ============================================================================

if [[ "${EUID}" -ne 0 ]]; then
    error_exit "Run this script with sudo:

  sudo $0"
fi

# ============================================================================
# Create backup directory
# ============================================================================

mkdir -p "${BACKUP_DIR}"

echo "=========================================================="
echo " Suricata Normal Service Restore"
echo "=========================================================="
echo
echo "Backup directory:"
echo "  ${BACKUP_DIR}"

# ============================================================================
# Verify Suricata
# ============================================================================

log "Checking Suricata installation"

[[ -x "${SURICATA}" ]] || \
    error_exit "Suricata was not found at ${SURICATA}"

echo "Suricata executable:"
echo "  ${SURICATA}"

# ============================================================================
# Detect supported command-line options
# ============================================================================

log "Detecting Suricata command-line options"

SURICATA_HELP="$("${SURICATA}" -h 2>&1 || true)"

has_option() {
    local option="$1"

    grep -Eq \
        "(^|[[:space:]])${option}([[:space:]=]|$)" \
        <<< "${SURICATA_HELP}"
}

# Version option
if has_option "-V"; then
    VERSION_OPTION="-V"
elif has_option "--version"; then
    VERSION_OPTION="--version"
else
    VERSION_OPTION=""
fi

# Configuration test
if has_option "-T"; then
    TEST_OPTION="-T"
else
    error_exit "This Suricata binary does not support configuration testing with -T."
fi

# Fatal initialization errors
if has_option "--init-errors-fatal"; then
    FATAL_OPTION="--init-errors-fatal"
else
    FATAL_OPTION=""
fi

echo "Detected options:"

if [[ -n "${VERSION_OPTION}" ]]; then
    echo "  Version:     ${VERSION_OPTION}"
else
    echo "  Version:     unavailable"
fi

echo "  Config test: ${TEST_OPTION}"

if [[ -n "${FATAL_OPTION}" ]]; then
    echo "  Fatal init:  ${FATAL_OPTION}"
else
    echo "  Fatal init:  unavailable"
fi

# ============================================================================
# Display version
# ============================================================================

log "Installed Suricata version"

if [[ -n "${VERSION_OPTION}" ]]; then
    "${SURICATA}" "${VERSION_OPTION}" || true
else
    "${SURICATA}" --build-info 2>/dev/null | head -n 10 || true
fi

# ============================================================================
# Stop custom service
# ============================================================================

log "Stopping previous custom Suricata service"

systemctl stop "${CUSTOM_SERVICE}" 2>/dev/null || true
systemctl disable "${CUSTOM_SERVICE}" 2>/dev/null || true

# ============================================================================
# Back up custom service/wrapper
# ============================================================================

log "Backing up previous custom configuration"

if [[ -f "${CUSTOM_SERVICE}" ]]; then
    cp -a \
        "${CUSTOM_SERVICE}" \
        "${BACKUP_DIR}/suricata-auto.service"
fi

if [[ -f "${CUSTOM_WRAPPER}" ]]; then
    cp -a \
        "${CUSTOM_WRAPPER}" \
        "${BACKUP_DIR}/suricata-wrapper.sh"
fi

# ============================================================================
# Remove custom service
# ============================================================================

log "Removing custom Suricata service"

rm -f "${CUSTOM_SERVICE}"
rm -f "${CUSTOM_WRAPPER}"

systemctl daemon-reload
systemctl reset-failed "${CUSTOM_SERVICE}" 2>/dev/null || true

# ============================================================================
# Unmask normal service
# ============================================================================

log "Restoring normal Suricata systemd service"

systemctl unmask "${NORMAL_SERVICE}" 2>/dev/null || true

# ============================================================================
# Back up existing Suricata configuration
#
# IMPORTANT:
# We are NOT modifying it.
# ============================================================================

if [[ -f "${CONFIG}" ]]; then

    cp -a \
        "${CONFIG}" \
        "${BACKUP_DIR}/suricata.yaml"

    echo
    echo "Configuration backed up:"
    echo "  ${BACKUP_DIR}/suricata.yaml"

else
    error_exit "Suricata configuration not found:

  ${CONFIG}"
fi

# ============================================================================
# Ensure rule directory exists
# ============================================================================

log "Checking Suricata rule directory"

mkdir -p "${RULE_DIR}"

chmod 0755 "${RULE_DIR}"

# ============================================================================
# Detect suricata-update
#
# IMPORTANT:
# Do NOT apt install suricata-update.
#
# Your Suricata 8.0.7 installation already provides it.
# ============================================================================

SURICATA_UPDATE="/usr/bin/suricata-update"

log "Checking suricata-update"

if [[ ! -x "${SURICATA_UPDATE}" ]]; then
    error_exit "The installed Suricata package does not provide:

  ${SURICATA_UPDATE}

Do not install the Ubuntu suricata-update package if it conflicts
with your Suricata package."
fi

echo "Using:"
echo "  ${SURICATA_UPDATE}"

# ============================================================================
# Generate rules
# ============================================================================

log "Updating Suricata rules"

if [[ ! -s "${RULE_FILE}" ]]; then

    echo "Rule file does not exist."
    echo "Running suricata-update..."

    "${SURICATA_UPDATE}"

else

    echo "Existing rule file found:"
    echo "  ${RULE_FILE}"

    echo
    echo "Updating rules..."

    "${SURICATA_UPDATE}"
fi

# ============================================================================
# Verify rules
# ============================================================================

log "Verifying Suricata rules"

if [[ ! -s "${RULE_FILE}" ]]; then
    error_exit "Suricata rule file was not generated:

  ${RULE_FILE}"
fi

echo "Rule file:"
echo "  ${RULE_FILE}"

echo
echo "Rule file size:"
ls -lh "${RULE_FILE}"

# ============================================================================
# Remove stale PID files
# ============================================================================

log "Removing stale PID files"

rm -f /run/suricata.pid
rm -f /var/run/suricata.pid

# ============================================================================
# Reload systemd
# ============================================================================

log "Reloading systemd"

systemctl daemon-reload

# ============================================================================
# Enable normal service
# ============================================================================

log "Enabling normal Suricata service"

systemctl enable "${NORMAL_SERVICE}"

# ============================================================================
# Validate configuration
# ============================================================================

log "Validating Suricata configuration"

TEST_COMMAND=(
    "${SURICATA}"
    "${TEST_OPTION}"
    "-c"
    "${CONFIG}"
)

if [[ -n "${FATAL_OPTION}" ]]; then
    TEST_COMMAND+=("${FATAL_OPTION}")
fi

echo
echo "Running:"
printf ' %q' "${TEST_COMMAND[@]}"
echo
echo

if ! "${TEST_COMMAND[@]}"; then

    echo
    echo "Configuration validation failed."
    echo
    echo "Your configuration backup is:"
    echo
    echo "  ${BACKUP_DIR}/suricata.yaml"
    echo

    exit 1
fi

echo
echo "Suricata configuration is valid."

# ============================================================================
# Start/restart normal service
# ============================================================================

log "Starting normal Suricata service"

systemctl restart "${NORMAL_SERVICE}"

# ============================================================================
# Wait for service
# ============================================================================

log "Waiting for Suricata"

SERVICE_OK=0

for ((i=1; i<=15; i++)); do

    if systemctl is-active --quiet "${NORMAL_SERVICE}"; then
        SERVICE_OK=1
        break
    fi

    sleep 1
done

# ============================================================================
# Verify service
# ============================================================================

if [[ "${SERVICE_OK}" -ne 1 ]]; then

    echo
    echo "=========================================================="
    echo " ERROR: Suricata did not remain running"
    echo "=========================================================="

    echo
    systemctl --no-pager --full status "${NORMAL_SERVICE}" || true

    echo
    echo "Recent Suricata journal:"
    journalctl \
        -u "${NORMAL_SERVICE}" \
        --no-pager \
        -n 100 || true

    echo
    echo "Suricata log:"
    
    if [[ -f /var/log/suricata/suricata.log ]]; then
        tail -n 50 /var/log/suricata/suricata.log
    fi

    exit 1
fi

# ============================================================================
# Final status
# ============================================================================

echo
echo "=========================================================="
echo " Suricata successfully restored"
echo "=========================================================="

echo
echo "Service:"
systemctl --no-pager --full status "${NORMAL_SERVICE}"

echo
echo "Enabled at boot:"
systemctl is-enabled "${NORMAL_SERVICE}"

echo
echo "Current state:"
systemctl is-active "${NORMAL_SERVICE}"

echo
echo "Configuration:"
echo "  ${CONFIG}"

echo
echo "Rules:"
echo "  ${RULE_FILE}"

echo
echo "Logs:"
echo "  /var/log/suricata/suricata.log"
echo "  /var/log/suricata/eve.json"
echo "  journalctl -u suricata"

echo
echo "Backup:"
echo "  ${BACKUP_DIR}"

echo
echo "=========================================================="
echo " COMPLETE"
echo "=========================================================="

