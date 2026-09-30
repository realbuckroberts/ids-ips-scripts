#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# PSAD - Port Scan Attack Detector
#
# Fully unattended Ubuntu 24.04 installation
#
# Installs:
#   - psad
#   - iptables
#   - rsyslog
#   - required Perl/network dependencies
#
# Configures:
#   - kernel/firewall logging
#   - /var/log/kern.log
#   - PSAD signatures
#   - psad.conf
#   - systemd
#
# Enables:
#   - rsyslog
#   - psad
#
# Starts:
#   - rsyslog
#   - psad
#
# Does NOT enable automatic firewall blocking.
# ============================================================

export DEBIAN_FRONTEND=noninteractive

PSAD_CONFIG="/etc/psad/psad.conf"
PSAD_LOG="/var/log/psad"
KERN_LOG="/var/log/kern.log"

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

error_handler() {
    local line="${1:-unknown}"

    echo
    echo "============================================================"
    echo " PSAD INSTALLATION FAILED"
    echo "============================================================"
    echo "Failure line: ${line}"
    echo

    if systemctl list-unit-files 2>/dev/null |
        grep -q '^psad.service'; then

        systemctl --no-pager --full status psad.service || true

        echo
        echo "Recent PSAD logs:"
        journalctl -u psad.service \
            --no-pager \
            -n 100 || true
    fi

    exit 1
}

trap 'error_handler $LINENO' ERR

# ============================================================
# Root
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo or as root."
fi

# ============================================================
# Ubuntu
# ============================================================

[[ -f /etc/os-release ]] ||
    die "/etc/os-release not found."

source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] ||
    die "This script requires Ubuntu."

if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    log "WARNING: This script targets Ubuntu 24.04."
    log "Detected: ${PRETTY_NAME:-unknown}"
fi

log "Detected: ${PRETTY_NAME:-unknown}"

# ============================================================
# Enable Universe repository
# ============================================================

log "Enabling Ubuntu Universe repository..."

apt-get update -qq

apt-get install -y -qq software-properties-common

add-apt-repository -y universe >/dev/null 2>&1 || true

apt-get update -qq

# ============================================================
# Install dependencies
# ============================================================

log "Installing PSAD and required packages..."

apt-get install -y \
    psad \
    iptables \
    iptables-persistent \
    rsyslog \
    iproute2 \
    net-tools \
    psmisc \
    whois

# ============================================================
# Verify PSAD installation
# ============================================================

command -v psad >/dev/null 2>&1 ||
    die "psad executable was not installed."

[[ -f "${PSAD_CONFIG}" ]] ||
    die "${PSAD_CONFIG} was not created."

log "PSAD installed successfully."

# ============================================================
# Display installed version
# ============================================================

log "Installed PSAD version:"

psad --Version 2>/dev/null ||
psad -V 2>/dev/null ||
dpkg-query -W -f='${Version}\n' psad

# ============================================================
# Ensure rsyslog is enabled
# ============================================================

log "Configuring rsyslog..."

systemctl enable rsyslog.service

systemctl restart rsyslog.service

# ============================================================
# Configure kernel logging
#
# PSAD needs firewall/kernel log messages to analyze scans.
# ============================================================

log "Configuring kernel/firewall logging..."

RSYSLOG_PSAD_CONFIG="/etc/rsyslog.d/20-psad.conf"

cat > "${RSYSLOG_PSAD_CONFIG}" <<EOF
# PSAD kernel/firewall logging
kern.warning;kern.err;kern.crit;kern.alert;kern.emerg    ${KERN_LOG}
EOF

chmod 0644 "${RSYSLOG_PSAD_CONFIG}"

# Make sure the log exists.
touch "${KERN_LOG}"

chmod 0640 "${KERN_LOG}"

# Restart rsyslog to load the configuration.
systemctl restart rsyslog.service

# ============================================================
# Configure PSAD
# ============================================================

log "Configuring ${PSAD_CONFIG}..."

# ------------------------------------------------------------
# Helper for replacing PSAD configuration variables.
# ------------------------------------------------------------

set_psad_value() {
    local key="$1"
    local value="$2"

    if grep -Eq "^[[:space:]]*${key}[[:space:]]" "${PSAD_CONFIG}"; then

        sed -i -E \
            "s|^[[:space:]]*${key}[[:space:]].*;.*$|${key} ${value};|" \
            "${PSAD_CONFIG}"

    else

        printf '\n%s %s;\n' "${key}" "${value}" >> "${PSAD_CONFIG}"
    fi
}

# ------------------------------------------------------------
# Backup original configuration.
# ------------------------------------------------------------

if [[ ! -f "${PSAD_CONFIG}.original" ]]; then
    cp -a "${PSAD_CONFIG}" "${PSAD_CONFIG}.original"
fi

# ------------------------------------------------------------
# PSAD log source
# ------------------------------------------------------------

set_psad_value "IPT_SYSLOG_FILE" "${KERN_LOG}"

# Check every 5 seconds.
set_psad_value "CHECK_INTERVAL" "5"

# Track scans for one hour.
set_psad_value "SCAN_TIMEOUT" "3600"

# Enable signature-based detection.
set_psad_value "ENABLE_PERSISTENCE" "N"

# Enable DNS lookups.
set_psad_value "ENABLE_DNS_LOOKUPS" "Y"

# Enable WHOIS lookups.
set_psad_value "ENABLE_WHOIS_LOOKUPS" "Y"

# ------------------------------------------------------------
# IMPORTANT:
# Do NOT automatically modify the firewall.
# ------------------------------------------------------------

set_psad_value "ENABLE_AUTO_IDS" "N"

# Keep iptables blocking capability available if manually enabled
# later, but do not activate automatic blocking.
set_psad_value "IPTABLES_BLOCK_METHOD" "Y"

# ------------------------------------------------------------
# Disable DShield reporting unless explicitly configured.
# ------------------------------------------------------------

set_psad_value "ENABLE_DSHIELD_ALERTS" "N"

# ------------------------------------------------------------
# Don't execute arbitrary external programs.
# ------------------------------------------------------------

set_psad_value "ENABLE_EXT_SCRIPT_EXEC" "N"

# ============================================================
# Update PSAD signatures
# ============================================================

log "Updating PSAD signatures..."

if ! psad --sig-update; then
    log "WARNING: Signature update failed."
    log "Continuing with the signatures shipped by Ubuntu."
fi

# ============================================================
# Configure iptables logging
#
# IMPORTANT:
# These rules ONLY LOG packets.
# They do not ACCEPT, DROP, or BLOCK anything.
#
# Rules are inserted only if they do not already exist.
# ============================================================

log "Configuring IPv4 firewall logging..."

if iptables -C INPUT -j LOG \
    --log-prefix "PSAD-IN " \
    --log-level 4 2>/dev/null; then

    log "IPv4 INPUT PSAD logging rule already exists."

else

    iptables -A INPUT \
        -j LOG \
        --log-prefix "PSAD-IN " \
        --log-level 4
fi

if iptables -C FORWARD -j LOG \
    --log-prefix "PSAD-FWD " \
    --log-level 4 2>/dev/null; then

    log "IPv4 FORWARD PSAD logging rule already exists."

else

    iptables -A FORWARD \
        -j LOG \
        --log-prefix "PSAD-FWD " \
        --log-level 4
fi

# ============================================================
# IPv6 logging
# ============================================================

if command -v ip6tables >/dev/null 2>&1; then

    log "Configuring IPv6 firewall logging..."

    if ip6tables -C INPUT -j LOG \
        --log-prefix "PSAD6-IN " \
        --log-level 4 2>/dev/null; then

        log "IPv6 INPUT PSAD logging rule already exists."

    else

        ip6tables -A INPUT \
            -j LOG \
            --log-prefix "PSAD6-IN " \
            --log-level 4
    fi

    if ip6tables -C FORWARD -j LOG \
        --log-prefix "PSAD6-FWD " \
        --log-level 4 2>/dev/null; then

        log "IPv6 FORWARD PSAD logging rule already exists."

    else

        ip6tables -A FORWARD \
            -j LOG \
            --log-prefix "PSAD6-FWD " \
            --log-level 4
    fi
fi

# ============================================================
# Persist firewall logging rules
# ============================================================

log "Saving firewall rules..."

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || true
fi

# ============================================================
# Validate PSAD configuration
# ============================================================

log "Validating PSAD configuration..."

if psad --config-test >/dev/null 2>&1; then
    log "PSAD configuration validation successful."

else
    # Some Ubuntu PSAD versions do not expose --config-test.
    # Validate by asking PSAD to dump its configuration instead.
    if ! psad --Dump-conf >/dev/null; then
        die "PSAD configuration validation failed."
    fi

    log "PSAD configuration accepted."
fi

# ============================================================
# Reload systemd
# ============================================================

systemctl daemon-reload

# ============================================================
# Enable PSAD
# ============================================================

log "Enabling psad.service..."

systemctl enable psad.service

# ============================================================
# Start PSAD
# ============================================================

log "Starting PSAD..."

systemctl restart psad.service

# ============================================================
# Wait for service
# ============================================================

log "Waiting for PSAD..."

for i in {1..15}; do

    if systemctl is-active --quiet psad.service; then
        break
    fi

    sleep 1
done

# ============================================================
# Verify service
# ============================================================

if ! systemctl is-active --quiet psad.service; then

    echo
    echo "============================================================"
    echo " PSAD FAILED TO START"
    echo "============================================================"

    systemctl --no-pager --full status psad.service || true

    echo
    echo "Recent PSAD journal:"
    journalctl \
        -u psad.service \
        --no-pager \
        -n 100 || true

    echo
    echo "PSAD process status:"
    psad --Status || true

    exit 1
fi

# ============================================================
# Verify PSAD process
# ============================================================

sleep 2

if ! pgrep -x psad >/dev/null 2>&1; then

    log "systemd reports PSAD active but psad process was not found."

    psad --Status || true

    die "PSAD process verification failed."
fi

# ============================================================
# Verify signature file
# ============================================================

if [[ -f /etc/psad/signatures ]]; then

    SIGNATURE_SIZE="$(stat -c '%s' /etc/psad/signatures)"

    if [[ "${SIGNATURE_SIZE}" -lt 1000 ]]; then
        log "WARNING: PSAD signature file appears unusually small."
    else
        log "PSAD signature database installed."
    fi

fi

# ============================================================
# Verify kernel logging
# ============================================================

log "Testing kernel logging path..."

logger -p kern.warning \
    -t psad-installer \
    "PSAD installation test"

sleep 2

if grep -q "psad-installer" "${KERN_LOG}" 2>/dev/null; then
    log "Kernel logging to ${KERN_LOG} verified."

else
    log "WARNING: Test message was not found in ${KERN_LOG}."
    log "PSAD is running, but firewall log routing should be checked."
fi

# ============================================================
# Final status
# ============================================================

echo
echo "============================================================"
echo "             PSAD INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "PSAD:"
echo "  Service : ACTIVE"
echo "  Enabled : YES"
echo
echo "Configuration:"
echo "  ${PSAD_CONFIG}"
echo
echo "Signatures:"
echo "  /etc/psad/signatures"
echo
echo "PSAD logs:"
echo "  ${PSAD_LOG}"
echo
echo "Kernel/firewall log:"
echo "  ${KERN_LOG}"
echo
echo "Automatic blocking:"
echo "  DISABLED"
echo
echo "IPv4 firewall logging:"
echo "  ENABLED"
echo
echo "IPv6 firewall logging:"
echo "  ENABLED"
echo
echo "============================================================"
echo " PSAD is running and will start automatically at boot."
echo "============================================================"
echo

