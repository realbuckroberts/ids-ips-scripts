#!/usr/bin/env bash
#
# Install and configure Fail2Ban on Ubuntu 24.04
#
# Usage:
#   sudo bash install-fail2ban.sh
#

set -Eeuo pipefail

readonly FAIL2BAN_CONF="/etc/fail2ban/fail2ban.local"
readonly JAIL_CONF="/etc/fail2ban/jail.local"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

[[ "${EUID}" -eq 0 ]] || die "Run this script as root (sudo)."

if [[ ! -f /etc/os-release ]]; then
    die "Cannot determine operating system."
fi

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] || die "This script requires Ubuntu."
[[ "${VERSION_ID:-}" == "24.04" ]] || die "This script requires Ubuntu 24.04."

log "Updating package index..."
apt-get update

log "Installing Fail2Ban..."
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban

log "Creating Fail2Ban logging configuration..."

# For a systemd service, STDOUT is captured by journald.
# This avoids maintaining a separate Fail2Ban log file/logrotate setup.
cat > "${FAIL2BAN_CONF}" <<'EOF'
[Definition]
loglevel = INFO
logtarget = STDOUT

# Keep the persistent Fail2Ban database.
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
dbpurgeage = 1d
EOF

log "Creating jail configuration..."

# Use systemd's journal for SSH authentication events.
# This is appropriate for Ubuntu 24.04's systemd-based logging.
cat > "${JAIL_CONF}" <<'EOF'
[DEFAULT]

# Do not ban localhost.
ignoreip = 127.0.0.1/8 ::1

# Ban an address for one hour.
bantime = 1h

# Count failures over a 10-minute window.
findtime = 10m

# Ban after 5 failures.
maxretry = 5

# Use systemd journal for the SSH jail.
backend = systemd

# Default action: firewall ban.
banaction = nftables-multiport

[sshd]
enabled = true
port = ssh
backend = systemd
EOF

log "Validating Fail2Ban configuration..."

fail2ban-client -t

log "Enabling Fail2Ban service..."
systemctl daemon-reload
systemctl enable fail2ban.service
systemctl restart fail2ban.service

log "Waiting for service startup..."
sleep 2

if ! systemctl is-active --quiet fail2ban.service; then
    systemctl --no-pager --full status fail2ban.service || true
    journalctl -u fail2ban.service --no-pager -n 50 || true
    die "Fail2Ban failed to start."
fi

log "Verifying SSH jail..."
fail2ban-client status sshd

log "Installation completed successfully."
echo
echo "Useful commands:"
echo "  systemctl status fail2ban"
echo "  fail2ban-client status"
echo "  fail2ban-client status sshd"
echo "  journalctl -u fail2ban -f"
echo "  journalctl -u fail2ban --since today"
echo
