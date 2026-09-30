#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# FWSNORT - Ubuntu 24.04
#
# Fully unattended installation.
#
# Features:
#   - Installs fwsnort
#   - Installs Ubuntu Snort rules
#   - Attempts Emerging Threats update
#   - Generates fwsnort policy
#   - Applies policy
#   - Runs immediately
#   - Runs automatically every hour
#   - Skips duplicate runs within one hour
#   - Persists across reboot
#   - Prevents concurrent executions
#
# Security:
#   LOGGING ONLY
#   No automatic DROP
#   No automatic REJECT
# ============================================================

export DEBIAN_FRONTEND=noninteractive

FWSNORT="/usr/sbin/fwsnort"

CONFIG_DIR="/etc/fwsnort"
CONFIG_FILE="/etc/fwsnort/fwsnort.conf"
RULE_DIR="/etc/fwsnort/snort_rules"

STATE_DIR="/var/lib/fwsnort"
STATE_FILE="${STATE_DIR}/last-successful-run"

RUN_LOG="/var/log/fwsnort-hourly.log"
GENERATION_LOG="/var/log/fwsnort-generation.log"

SERVICE="/etc/systemd/system/fwsnort.service"
TIMER="/etc/systemd/system/fwsnort.timer"

MIN_INTERVAL=3600

# ============================================================
# Logging
# ============================================================

log() {
    local msg="$*"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" \
        >> "${RUN_LOG}" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    exit 1
}

# ============================================================
# Root
# ============================================================

[[ "${EUID}" -eq 0 ]] ||
    die "Run this script as root or with sudo."

# ============================================================
# OS
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

# ============================================================
# Logging/state directories
# ============================================================

mkdir -p "${STATE_DIR}"

touch "${RUN_LOG}"
touch "${GENERATION_LOG}"

chmod 0640 "${RUN_LOG}"
chmod 0640 "${GENERATION_LOG}"

# ============================================================
# Enable Universe
# ============================================================

log "Enabling Ubuntu Universe repository..."

apt-get update -qq

apt-get install -y -qq \
    software-properties-common \
    ca-certificates

add-apt-repository -y universe >/dev/null 2>&1 || true

apt-get update -qq

# ============================================================
# Install packages
# ============================================================

log "Installing fwsnort and dependencies..."

apt-get install -y \
    fwsnort \
    snort-rules-default \
    iptables \
    iptables-persistent \
    perl \
    libiptables-parse-perl \
    libnet-rawip-perl \
    libnetaddr-ip-perl

# ============================================================
# Verify fwsnort
# ============================================================

command -v fwsnort >/dev/null 2>&1 ||
    die "fwsnort was not installed."

[[ -x "${FWSNORT}" ]] ||
    die "Expected fwsnort at ${FWSNORT}."

command -v iptables >/dev/null 2>&1 ||
    die "iptables was not installed."

log "Installed fwsnort version:"

"${FWSNORT}" --Version || \
    dpkg-query -W -f='${Version}\n' fwsnort

# ============================================================
# Prepare directories
# ============================================================

mkdir -p "${CONFIG_DIR}"
mkdir -p "${RULE_DIR}"
mkdir -p "${STATE_DIR}"

# ============================================================
# Configuration
# ============================================================

if [[ -f "${CONFIG_FILE}" ]]; then

    if [[ ! -f "${CONFIG_FILE}.original" ]]; then
        cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.original"
    fi

else

    cat > "${CONFIG_FILE}" <<'EOF'
# fwsnort configuration

HOME_NET 192.168.0.0/16;
EXTERNAL_NET any;

EOF

fi

# ============================================================
# Determine HOME_NET
# ============================================================

log "Determining local IPv4 networks..."

HOME_NET="$(
    ip -o -4 addr show scope global 2>/dev/null |
    awk '{print $4}' |
    paste -sd, -
)"

if [[ -z "${HOME_NET}" ]]; then
    HOME_NET="192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
fi

log "Detected HOME_NET: ${HOME_NET}"

if grep -Eq '^[[:space:]]*HOME_NET[[:space:]]' \
    "${CONFIG_FILE}"
then

    sed -i -E \
        "s|^[[:space:]]*HOME_NET[[:space:]].*|HOME_NET ${HOME_NET};|" \
        "${CONFIG_FILE}"

else

    printf '\nHOME_NET %s;\n' "${HOME_NET}" \
        >> "${CONFIG_FILE}"

fi

if ! grep -Eq '^[[:space:]]*EXTERNAL_NET[[:space:]]' \
    "${CONFIG_FILE}"
then

    printf 'EXTERNAL_NET any;\n' \
        >> "${CONFIG_FILE}"

fi

chmod 0644 "${CONFIG_FILE}"

# ============================================================
# Locate ONLY packaged Snort rules
#
# IMPORTANT:
# Do NOT search /etc here.
#
# /etc/fwsnort/snort_rules is the DESTINATION and may contain
# rules from a previous installation.
# ============================================================

log "Locating packaged Snort rules..."

SNORT_SOURCE_DIR=""

for candidate in \
    /usr/share/snort/rules \
    /usr/share/doc/snort-rules-default/rules
do

    if [[ -d "${candidate}" ]] &&
       find "${candidate}" \
           -type f \
           -name "*.rules" \
           -print -quit |
       grep -q .
    then

        SNORT_SOURCE_DIR="${candidate}"
        break
    fi

done

if [[ -z "${SNORT_SOURCE_DIR}" ]]; then

    SNORT_SOURCE_DIR="$(
        find /usr/share \
            -type f \
            -name "*.rules" \
            2>/dev/null |
        head -n 1 |
        xargs -r dirname
    )"

fi

[[ -n "${SNORT_SOURCE_DIR}" ]] ||
    die "Could not locate packaged Snort rules under /usr/share."

log "Using rule source:"
log "${SNORT_SOURCE_DIR}"

# ============================================================
# Copy rules safely
#
# Never copy a file onto itself.
# ============================================================

log "Installing Snort rules..."

SOURCE_RULE_COUNT=0
COPIED_RULE_COUNT=0
SKIPPED_RULE_COUNT=0

while IFS= read -r -d '' source_rule; do

    SOURCE_RULE_COUNT=$((SOURCE_RULE_COUNT + 1))

    destination="${RULE_DIR}/$(basename "${source_rule}")"

    # --------------------------------------------------------
    # Safety check:
    # If source and destination are the same inode/path,
    # do not attempt cp.
    # --------------------------------------------------------

    if [[ "${source_rule}" -ef "${destination}" ]]; then

        SKIPPED_RULE_COUNT=$((SKIPPED_RULE_COUNT + 1))

        continue
    fi

    cp -f \
        "${source_rule}" \
        "${destination}"

    COPIED_RULE_COUNT=$((COPIED_RULE_COUNT + 1))

done < <(
    find "${SNORT_SOURCE_DIR}" \
        -type f \
        -name "*.rules" \
        -print0
)

[[ "${SOURCE_RULE_COUNT}" -gt 0 ]] ||
    die "No Snort rule files were found."

chmod 0644 \
    "${RULE_DIR}"/*.rules \
    2>/dev/null || true

RULE_COUNT="$(
    find "${RULE_DIR}" \
        -maxdepth 1 \
        -type f \
        -name "*.rules" |
    wc -l
)"

log "Found ${SOURCE_RULE_COUNT} packaged rule files."
log "Copied ${COPIED_RULE_COUNT} rule files."
log "Skipped ${SKIPPED_RULE_COUNT} already-present files."
log "Total rules in ${RULE_DIR}: ${RULE_COUNT}"

# ============================================================
# Update Emerging Threats
#
# Failure does not abort installation.
# ============================================================

log "Attempting Emerging Threats rule update..."

if "${FWSNORT}" --update-rules \
    >> "${GENERATION_LOG}" 2>&1
then

    log "Emerging Threats update completed."

else

    log "WARNING: Emerging Threats update failed."
    log "Continuing with existing rules."

fi

# ============================================================
# Load useful iptables modules
# ============================================================

log "Loading iptables modules..."

modprobe xt_string 2>/dev/null || true
modprobe xt_comment 2>/dev/null || true
modprobe xt_LOG 2>/dev/null || true

# ============================================================
# Verify fwsnort capabilities
# ============================================================

log "Checking fwsnort iptables capabilities..."

if ! "${FWSNORT}" --ipt-check-capabilities \
    >> "${GENERATION_LOG}" 2>&1
then

    log "WARNING: fwsnort capability check reported a problem."

    log "Continuing to policy generation."

fi

# ============================================================
# Generate policy
#
# IMPORTANT:
# No --ipt-drop.
# No --ipt-reject.
#
# fwsnort's normal mode generates logging rules.
# ============================================================

log "Generating fwsnort policy..."

if ! "${FWSNORT}" \
    --config "${CONFIG_FILE}" \
    --snort-rdir "${RULE_DIR}" \
    --verbose \
    >> "${GENERATION_LOG}" 2>&1
then

    log "ERROR: fwsnort policy generation failed."

    echo
    echo "============================================================"
    echo " FWSNORT GENERATION LOG"
    echo "============================================================"

    tail -n 200 "${GENERATION_LOG}" || true

    exit 1
fi

# ============================================================
# Locate generated script
# ============================================================

GENERATED_SCRIPT=""

for candidate in \
    /var/lib/fwsnort/fwsnort.sh \
    /etc/fwsnort/fwsnort.sh
do

    if [[ -s "${candidate}" ]]; then
        GENERATED_SCRIPT="${candidate}"
        break
    fi

done

[[ -n "${GENERATED_SCRIPT}" ]] ||
    die "fwsnort did not generate an executable policy script."

chmod 0755 "${GENERATED_SCRIPT}"

log "Generated policy:"
log "${GENERATED_SCRIPT}"

# ============================================================
# Apply policy
# ============================================================

log "Applying fwsnort policy..."

if ! "${FWSNORT}" \
    --config "${CONFIG_FILE}" \
    --ipt-apply \
    >> "${GENERATION_LOG}" 2>&1
then

    log "ERROR: fwsnort policy application failed."

    tail -n 200 "${GENERATION_LOG}" || true

    exit 1
fi

# ============================================================
# Verify active policy
# ============================================================

log "Checking active iptables policy..."

FWSNORT_RULE_COUNT="$(
    iptables -S 2>/dev/null |
    grep -ci "fwsnort" ||
    true
)"

log "Detected ${FWSNORT_RULE_COUNT} fwsnort-related IPv4 rules."

# ============================================================
# Save current firewall
# ============================================================

if command -v netfilter-persistent >/dev/null 2>&1; then

    log "Saving iptables configuration..."

    netfilter-persistent save \
        >> "${GENERATION_LOG}" 2>&1 || true

fi

# ============================================================
# Record successful execution
# ============================================================

date +%s > "${STATE_FILE}"

chmod 0644 "${STATE_FILE}"

# ============================================================
# Hourly runner
# ============================================================

log "Installing hourly fwsnort runner..."

cat > /usr/local/sbin/fwsnort-hourly <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

FWSNORT="/usr/sbin/fwsnort"

CONFIG="/etc/fwsnort/fwsnort.conf"
RULE_DIR="/etc/fwsnort/snort_rules"

STATE_DIR="/var/lib/fwsnort"
STATE_FILE="${STATE_DIR}/last-successful-run"

LOG="/var/log/fwsnort-hourly.log"
GENERATION_LOG="/var/log/fwsnort-generation.log"

MIN_INTERVAL=3600

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"
}

mkdir -p "${STATE_DIR}"

# ============================================================
# Prevent concurrent executions.
# ============================================================

exec 9>/run/fwsnort-hourly.lock

if ! flock -n 9; then
    log "Another fwsnort execution is already running. Skipping."
    exit 0
fi

# ============================================================
# Check previous successful execution.
# ============================================================

NOW="$(date +%s)"

if [[ -f "${STATE_FILE}" ]]; then

    LAST="$(cat "${STATE_FILE}" 2>/dev/null || echo 0)"

    if [[ "${LAST}" =~ ^[0-9]+$ ]]; then

        AGE=$((NOW - LAST))

        if (( AGE < MIN_INTERVAL )); then

            log "Last successful run was ${AGE} seconds ago."
            log "Less than one hour; skipping."

            exit 0
        fi

    fi
fi

log "Starting fwsnort hourly execution."

# ============================================================
# Update rules.
# ============================================================

if "${FWSNORT}" --update-rules \
    >> "${GENERATION_LOG}" 2>&1
then

    log "Emerging Threats rules updated."

else

    log "WARNING: Emerging Threats update failed."
    log "Using existing rules."

fi

# ============================================================
# Generate policy.
#
# Logging only.
# ============================================================

if ! "${FWSNORT}" \
    --config "${CONFIG}" \
    --snort-rdir "${RULE_DIR}" \
    --verbose \
    >> "${GENERATION_LOG}" 2>&1
then

    log "ERROR: Policy generation failed."

    tail -n 100 "${GENERATION_LOG}" \
        >> "${LOG}" 2>/dev/null || true

    exit 1
fi

# ============================================================
# Apply policy.
# ============================================================

if ! "${FWSNORT}" \
    --config "${CONFIG}" \
    --ipt-apply \
    >> "${GENERATION_LOG}" 2>&1
then

    log "ERROR: Policy application failed."

    tail -n 100 "${GENERATION_LOG}" \
        >> "${LOG}" 2>/dev/null || true

    exit 1
fi

# ============================================================
# Successful completion.
# ============================================================

date +%s > "${STATE_FILE}"

log "fwsnort policy successfully generated and applied."

exit 0
EOF

chmod 0755 /usr/local/sbin/fwsnort-hourly

# ============================================================
# systemd service
# ============================================================

log "Creating systemd service..."

cat > "${SERVICE}" <<EOF
[Unit]
Description=FWSNORT Snort-to-iptables Policy Update
Documentation=https://www.cipherdyne.org/fwsnort/
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fwsnort-hourly
TimeoutStartSec=30min
EOF

chmod 0644 "${SERVICE}"

# ============================================================
# systemd timer
# ============================================================

log "Creating hourly systemd timer..."

cat > "${TIMER}" <<EOF
[Unit]
Description=Run FWSNORT every hour

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true
AccuracySec=1min
RandomizedDelaySec=2min

[Install]
WantedBy=timers.target
EOF

chmod 0644 "${TIMER}"

# ============================================================
# Enable timer
# ============================================================

log "Enabling fwsnort timer..."

systemctl daemon-reload

systemctl enable fwsnort.timer

systemctl start fwsnort.timer

# ============================================================
# Verify timer
# ============================================================

systemctl is-enabled --quiet fwsnort.timer ||
    die "fwsnort.timer is not enabled."

systemctl is-active --quiet fwsnort.timer ||
    die "fwsnort.timer is not active."

# ============================================================
# Verify successful initial run
# ============================================================

[[ -f "${STATE_FILE}" ]] ||
    die "Initial fwsnort execution did not complete successfully."

LAST_RUN="$(cat "${STATE_FILE}")"

[[ "${LAST_RUN}" =~ ^[0-9]+$ ]] ||
    die "Invalid fwsnort state file."

# ============================================================
# Final status
# ============================================================

echo
echo "============================================================"
echo "          FWSNORT INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Version:"
echo "  $(dpkg-query -W -f='${Version}' fwsnort)"
echo
echo "Configuration:"
echo "  ${CONFIG_FILE}"
echo
echo "Rules:"
echo "  ${RULE_DIR}"
echo "  ${RULE_COUNT} rule files"
echo
echo "Generated policy:"
echo "  ${GENERATED_SCRIPT}"
echo
echo "Active fwsnort iptables entries:"
echo "  ${FWSNORT_RULE_COUNT}"
echo
echo "Last successful run:"
echo "  $(date -d "@${LAST_RUN}" '+%Y-%m-%d %H:%M:%S %Z')"
echo
echo "Hourly timer:"
echo "  ${TIMER}"
echo "  ENABLED"
echo
echo "Policy:"
echo "  LOGGING ONLY"
echo "  DROP   : DISABLED"
echo "  REJECT : DISABLED"
echo
echo "============================================================"
echo " FWSNORT is installed and applied."
echo " It will automatically run approximately once per hour."
echo " Duplicate executions within one hour are skipped."
echo "============================================================"
echo

